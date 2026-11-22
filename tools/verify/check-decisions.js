#!/usr/bin/env node
/**
 * check-decisions.js - decision-ledger gate (read-only, engine-agnostic)
 *
 * Usage:
 *   node check-decisions.js <flow.json> [--ledger <path>] [--repo <path>] [--mode=warn|fail]
 *   node check-decisions.js --ledger-only [--ledger <path>] [--repo <path>]
 *
 * --ledger-only validates the shared ledger's schema and nothing else: no flow is read, every row is
 * checked (scope domain, class, decided_by, duplicate/unreadable ids) and it exits 1 on any violation.
 * It is the prerequisite for flipping the flow gate to fail: one dirty historical row would otherwise
 * fail every business flow at once. This mode is strict regardless of --mode, because it judges the
 * ledger itself rather than the two-phase migration of the flows.
 *
 * Two-phase rollout (do not leave it in warn forever):
 *   --mode=warn (default) prints every violation and exits 0; --mode=fail exits 1. The default is now
 *   "fail": the business layer declares every risk node, the ledger carries a class on every row, and
 *   `node tools/verify/check-decisions.js --ledger-only` reports "ledger-only passed". Flipping the mode back
 *   to warn would be a loosening of the gate, so the callers below use "fail" as well.
 *   The callers (flow-to-robin.js, pad-admit.ps1) pass --mode explicitly; CI runs this in fail mode, because
 *   a public sample never cites a decision: there fail mode can only catch a broken setup.
 *
 * What it checks (all of it derived from flow.json + business/decisions.jsonl; nothing is inferred):
 *   1. every risk node (reversible=false or intent_destructive=true) is covered by a decisions entry, and
 *      at least one record covering it is class=risk (a standard record cannot stand in for a risk one, or
 *      the person-approval rule below could be dodged by citing a routine decision)
 *   2. every decisions[].node exists in flow.json
 *   3. every decisions[].decision_id exists in the ledger
 *   4. a class=risk ledger record must be approved by a person (decided_by=user); an agent may record a
 *      decision, but it may not approve a risk one
 *   5. every ledger record uses the closed scope domain: global | flow:<name> | script:<repo-relative path>.
 *      scope does NOT decide which flow a decision belongs to (decisions[].node does that); it is the
 *      human-readable subject of the decision, and it is validated as a schema field so it cannot drift
 *      into ad-hoc spellings.
 *   6. class and decided_by use only their closed value sets
 *
 * A missing ledger is never read as "there is nothing to verify". When the business layer is absent (the
 * public tree) and the flow cites nothing, the gate skips explicitly; when the flow cites decisions but
 * there is no ledger to verify them against, that is a violation - otherwise deleting the ledger file would
 * disable the gate (the same shape as the output-root registry's REGISTRY_MISSING mistake).
 *
 * Output is pure ASCII: any non-ASCII character is reported as \uXXXX so the codes stay greppable.
 * Exit codes: 0 = pass, skip, or violations while mode=warn; 1 = violations while mode=fail (and any
 *             violation in --ledger-only); 2 = usage error or unreadable flow.
 */
const fs = require("fs");
const path = require("path");

const CLASSES = ["risk", "standard"];
const DECIDED_BY = ["user", "agent(recorded)"];
const MODES = ["warn", "fail"];

/** Escape everything outside printable ASCII so the report is greppable in any console */
function toAscii(value) {
  return String(value == null ? "" : value).replace(/[^\x20-\x7E]/gu, (ch) => {
    const cp = ch.codePointAt(0);
    if (cp <= 0xffff) return "\\u" + cp.toString(16).toUpperCase().padStart(4, "0");
    const hi = 0xd800 + ((cp - 0x10000) >> 10);
    const lo = 0xdc00 + ((cp - 0x10000) & 0x3ff);
    return "\\u" + hi.toString(16).toUpperCase().padStart(4, "0") + "\\u" + lo.toString(16).toUpperCase().padStart(4, "0");
  });
}

function usage() {
  console.error("Usage: node check-decisions.js <flow.json> [--ledger <path>] [--repo <path>] [--mode=warn|fail]");
  console.error("       node check-decisions.js --ledger-only [--ledger <path>] [--repo <path>]");
}

function parseArgs(argv) {
  const out = { flow: null, ledger: null, repo: path.resolve(__dirname, "..", ".."), mode: "fail", ledgerOnly: false };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--ledger") { out.ledger = argv[i + 1]; i += 1; continue; }
    if (a === "--repo") { out.repo = argv[i + 1]; i += 1; continue; }
    if (a === "--ledger-only") { out.ledgerOnly = true; continue; }
    if (a.startsWith("--mode=")) { out.mode = a.slice("--mode=".length); continue; }
    if (a.startsWith("--")) throw new Error(`unknown option ${a}`);
    if (out.flow) throw new Error(`unexpected argument ${a}`);
    out.flow = a;
  }
  if (out.ledgerOnly) {
    if (out.flow) throw new Error("--ledger-only takes no flow file; run the per-flow gate without it");
  } else if (!out.flow) {
    throw new Error("no flow file given (use --ledger-only to validate the ledger alone)");
  }
  if (!MODES.includes(out.mode)) throw new Error(`--mode must be one of ${MODES.join("|")}, got ${out.mode}`);
  if (out.repo == null) throw new Error("--repo needs a path");
  if (out.ledger === undefined) out.ledger = null;
  return out;
}

const slashes = (p) => String(p).replace(/\\/g, "/");

/** Repo-relative, forward-slash form of a file, so paths read the same on any OS */
function repoRelative(file, repo) {
  const abs = path.resolve(file);
  const rel = path.relative(path.resolve(repo), abs);
  return slashes(rel.startsWith("..") ? abs : rel);
}

function isRiskNode(node) {
  return node && (node.reversible === false || node.intent_destructive === true);
}

/**
 * The closed scope domain. scope answers "what is this decision about" for a human reader; it does not
 * bind a decision to a flow (decisions[].node does that). Keeping it a closed domain stops the drift into
 * ad-hoc path spellings that the ledger used before this schema existed.
 */
function isValidScope(scope) {
  if (typeof scope !== "string") return false;
  if (scope === "global") return true;
  if (scope.startsWith("flow:")) return scope.length > "flow:".length;
  if (scope.startsWith("script:")) return scope.length > "script:".length;
  return false;
}

/**
 * Read the ledger and validate the row schema (id / scope / class / decided_by). Schema is validated for
 * every row because the ledger is shared: a malformed historical row is a defect even when no flow cites it.
 * Person approval is NOT checked here - that is a per-citation rule and lives in checkDecisions.
 */
function loadLedger(ledgerPath, ledgerLabel, add) {
  const rows = [];
  const byId = new Map();
  const supersededIds = new Set();
  // Supersede targets are resolved after the whole file is read: the target may appear later in the
  // ledger (a hand-inserted row, or a file that was re-sorted), and that order is not a defect.
  const pendingSupersedes = [];
  const available = fs.existsSync(ledgerPath);
  if (!available) return { rows, byId, supersededIds, available };
  const lines = fs.readFileSync(ledgerPath, "utf8").split(/\r?\n/);
  for (let i = 0; i < lines.length; i += 1) {
    const line = lines[i].trim();
    if (!line) continue;
    let rec;
    try {
      rec = JSON.parse(line);
    } catch (e) {
      add("LEDGER_UNREADABLE", `ledger=${ledgerLabel} line=${i + 1} error=${e.message}`);
      continue;
    }
    if (!rec || typeof rec !== "object" || Array.isArray(rec) || typeof rec.id !== "string" || !rec.id) {
      add("LEDGER_UNREADABLE", `ledger=${ledgerLabel} line=${i + 1} must be a JSON object with a string id`);
      continue;
    }
    rows.push(rec);
    if (byId.has(rec.id)) add("LEDGER_UNREADABLE", `ledger=${ledgerLabel} duplicate id=${rec.id} at line=${i + 1}; the ledger must not repeat an id`);
    else byId.set(rec.id, rec);
    // A record that supersedes another revokes that older record: the old row stays for the audit trail,
    // but it may no longer be cited as an authorisation.
    if (rec.supersedes) {
      const old = String(rec.supersedes);
      supersededIds.add(old);
      pendingSupersedes.push({ id: rec.id, old, line: i + 1 });
    }
    if (!isValidScope(rec.scope)) {
      add("DECISION_SCOPE_INVALID", `decision=${rec.id} scope=${JSON.stringify(rec.scope)} expected global | flow:<name> | script:<repo-relative path>`);
    }
    if (!CLASSES.includes(rec.class)) {
      add("DECISION_CLASS_INVALID", `decision=${rec.id} class=${JSON.stringify(rec.class)} expected one of ${CLASSES.join("|")}`);
    }
    if (!DECIDED_BY.includes(rec.decided_by)) {
      add("DECISION_DECIDED_BY_INVALID", `decision=${rec.id} decided_by=${JSON.stringify(rec.decided_by)} expected one of ${DECIDED_BY.map((v) => JSON.stringify(v)).join("|")}`);
    }
    if (rec.nodes !== undefined) {
      // nodes is the optional node list of a batch authorisation. An empty list is not "applies to every
      // node", it is a malformed record, so it fails instead of being read as a wildcard.
      if (!Array.isArray(rec.nodes)) {
        add("DECISION_NODES_INVALID", `decision=${rec.id} nodes must be an array of node ids`);
      } else if (rec.nodes.length === 0) {
        add("DECISION_NODES_EMPTY", `decision=${rec.id} nodes is an empty array; an empty list is not "applies to every node", it is a malformed record`);
      } else {
        for (const n of rec.nodes) {
          if (typeof n !== "string" || !n) {
            add("DECISION_NODES_INVALID", `decision=${rec.id} nodes must contain non-empty node id strings`);
            break;
          }
        }
      }
    }
  }
  for (const p of pendingSupersedes) {
    if (!byId.has(p.old)) {
      add("LEDGER_UNREADABLE", `ledger=${ledgerLabel} line=${p.line} decision=${p.id} supersedes ${p.old}, which is not a record in this ledger`);
    }
  }
  return { rows, byId, supersededIds, available };
}

/**
 * Pure check of one flow: returns { violations: [{code, detail}], stats, skip }.
 * Reads both files itself so the CLI and any caller judge with exactly one implementation.
 */
function checkDecisions(flowFile, options = {}) {
  const repo = options.repo || path.resolve(__dirname, "..", "..");
  const mode = options.mode || "warn";
  const ledgerGiven = options.ledger != null;
  const businessDir = path.join(repo, "business");
  const businessPresent = fs.existsSync(businessDir);
  const ledgerPath = ledgerGiven ? path.resolve(options.ledger) : path.join(businessDir, "decisions.jsonl");
  const ledgerLabel = repoRelative(ledgerPath, repo);
  const flowLabel = repoRelative(flowFile, repo);
  const violations = [];
  const add = (code, detail) => violations.push({ code, detail });

  let flow;
  try {
    flow = JSON.parse(fs.readFileSync(flowFile, "utf8"));
  } catch (e) {
    return { fatal: true, code: "FLOW_UNREADABLE", detail: `path=${flowLabel} error=${e.message}`, violations, stats: {} };
  }

  const entries = flow.decisions;
  const cited = Array.isArray(entries) ? entries.length : 0;

  // Scope: the decision ledger governs the business layer. A public sample (under tests/, tools/ or
  // examples/) is not a business flow, so it is not judged against the business ledger - and it must
  // behave the same on the business machine and on the public runner, where business/ does not exist.
  // A flow that DOES cite decisions is always judged: a citation that cannot be verified must fail
  // rather than skip, otherwise deleting the ledger would turn the gate off.
  const businessAbs = path.resolve(businessDir);
  const flowAbs = path.resolve(flowFile);
  const underBusiness = flowAbs === businessAbs || flowAbs.startsWith(businessAbs + path.sep);
  if (!ledgerGiven && cited === 0 && !underBusiness) {
    const detail = !businessPresent
      ? "business layer not present in this repository"
      : "the flow is not part of the business layer, which the decision ledger governs";
    return { skip: true, detail, violations: [], stats: {} };
  }

  const { rows, byId, supersededIds, available: ledgerAvailable } = loadLedger(ledgerPath, ledgerLabel, add);
  if (!ledgerAvailable) {
    const why = businessPresent
      ? "the business layer exists, so the ledger must exist too"
      : `the flow cites ${cited} decision(s) and a reference that cannot be checked is not a pass`;
    add("LEDGER_MISSING", `ledger=${ledgerLabel} is missing (${why})`);
  }

  const nodes = Array.isArray(flow.nodes) ? flow.nodes : [];
  const nodeIds = new Set(nodes.map((n) => String(n && n.id)));
  const riskNodes = nodes.filter(isRiskNode).map((n) => String(n.id));

  const covered = new Set();
  const recordsByNode = new Map();
  if (entries !== undefined) {
    if (!Array.isArray(entries)) {
      add("DECISION_ENTRY_INVALID", `flow=${flowLabel} decisions must be an array of {node, decision_id} objects`);
    } else {
      entries.forEach((entry, index) => {
        if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
          add("DECISION_ENTRY_INVALID", `flow=${flowLabel} decisions[${index}] must be an object`);
          return;
        }
        if (typeof entry.node !== "string" || !entry.node) {
          add("DECISION_ENTRY_INVALID", `flow=${flowLabel} decisions[${index}] has no string node`);
          return;
        }
        if (typeof entry.decision_id !== "string" || !entry.decision_id) {
          add("DECISION_ENTRY_INVALID", `flow=${flowLabel} decisions[${index}] node=${entry.node} has no string decision_id`);
          return;
        }
        if (!nodeIds.has(entry.node)) {
          add("DECISION_NODE_NOT_FOUND", `flow=${flowLabel} decisions[${index}] node=${entry.node} is not a node of this flow`);
        } else {
          covered.add(entry.node);
          if (!recordsByNode.has(entry.node)) recordsByNode.set(entry.node, []);
        }
        // A missing ledger is already reported once above; resolving ids against it would just add noise.
        if (!ledgerAvailable) return;
        const rec = byId.get(entry.decision_id);
        if (!rec) {
          if (recordsByNode.has(entry.node)) recordsByNode.get(entry.node).push(null);
          add("DECISION_NOT_IN_LEDGER", `flow=${flowLabel} node=${entry.node} decision=${entry.decision_id} not found in ${ledgerLabel}`);
          return;
        }
        if (recordsByNode.has(entry.node)) recordsByNode.get(entry.node).push(rec);
        if (supersededIds.has(entry.decision_id)) {
          // The record exists but has been revoked by a later row that supersedes it. The old row stays for
          // the audit trail, but citing it would mean operating on an expired authorisation.
          add("DECISION_SUPERSEDED", `decision=${entry.decision_id} node=${entry.node} has been superseded by a later ledger row; cite the row that supersedes it instead`);
        }
        if (rec.class === "risk" && rec.decided_by !== "user") {
          add("DECISION_NOT_USER_APPROVED", `decision=${entry.decision_id} decided_by=${JSON.stringify(rec.decided_by)} a risk-class decision needs a person; record the confirmation as a new row with decided_by=user and supersedes=${entry.decision_id}`);
        }
        // A record that lists nodes authorises exactly those nodes. A flow that cites it for a node outside
        // the list is borrowing a batch approval for something nobody approved - this is the only thing that
        // stops a newly added node from silently inheriting an old batch confirmation.
        if (Array.isArray(rec.nodes) && rec.nodes.length > 0 && !rec.nodes.includes(entry.node)) {
          add("DECISION_NODE_NOT_IN_RECORD", `decision=${entry.decision_id} node=${entry.node} is not in the record's node list (${rec.nodes.join(",")}); cite a decision that covers this node`);
        }
      });
    }
  }

  for (const id of riskNodes) {
    if (!covered.has(id)) {
      add("RISK_NODE_WITHOUT_DECISION", `flow=${flowLabel} node=${id} is irreversible or destructive but no decisions entry names it; add {"node":"${id}","decision_id":"D-00X"} and record the decision in the ledger with class=risk and decided_by=user`);
      continue;
    }
    // A risk node covered only by standard-class records would dodge the person-approval rule: the citation
    // must include at least one class=risk record. When one of the cited records is missing from the ledger the
    // node already has DECISION_NOT_IN_LEDGER (or the whole ledger is missing), so do not report twice.
    const records = recordsByNode.get(id) || [];
    if (records.some((r) => r && r.class === "risk")) continue;
    if (records.length === 0 || records.some((r) => r == null)) continue;
    add("RISK_NODE_DECISION_NOT_RISK", `flow=${flowLabel} node=${id} is irreversible or destructive but every decision naming it is class=standard; a risk node needs a class=risk record with decided_by=user`);
  }

  return {
    flow: flowLabel,
    mode,
    violations,
    stats: { records: rows.length, decisions: cited, riskNodes: riskNodes.length },
  };
}

/**
 * Pure check of the ledger alone (no flow): schema violations only. Strict by design - this is the
 * prerequisite for flipping the per-flow gate to fail, so it must be able to exit non-zero.
 */
function checkLedgerOnly(options = {}) {
  const repo = options.repo || path.resolve(__dirname, "..", "..");
  const businessDir = path.join(repo, "business");
  const ledgerPath = options.ledger != null ? path.resolve(options.ledger) : path.join(businessDir, "decisions.jsonl");
  const ledgerLabel = repoRelative(ledgerPath, repo);
  const violations = [];
  const add = (code, detail) => violations.push({ code, detail });
  const { rows, available } = loadLedger(ledgerPath, ledgerLabel, add);
  if (!available) {
    add("LEDGER_MISSING", `ledger=${ledgerLabel} is missing (this mode validates the ledger, so it must exist)`);
  }
  return { ledger: ledgerLabel, violations, stats: { records: rows.length } };
}

function main() {
  let args;
  try {
    args = parseArgs(process.argv.slice(2));
  } catch (e) {
    console.error(`[check-decisions] ${e.message}`);
    usage();
    process.exit(2);
  }

  if (args.ledgerOnly) {
    const result = checkLedgerOnly({ repo: args.repo, ledger: args.ledger });
    for (const v of result.violations) console.log(`[check-decisions] ${v.code} ${toAscii(v.detail)}`);
    const summary = `ledger=${result.ledger} records=${result.stats.records}`;
    if (result.violations.length === 0) {
      console.log(`[check-decisions] ledger-only passed (${summary})`);
      process.exit(0);
    }
    console.log(`[check-decisions] ledger-only failed: ${result.violations.length} violation(s) (${summary}); fix the ledger before flipping the flow gate to fail`);
    process.exit(1);
  }

  const result = checkDecisions(args.flow, { repo: args.repo, ledger: args.ledger, mode: args.mode });
  if (result.fatal) {
    console.log(`[check-decisions] ${result.code} ${toAscii(result.detail)}`);
    process.exit(2);
  }
  if (result.skip) {
    console.log(`[check-decisions] skip: ${result.detail}`);
    process.exit(0);
  }

  for (const v of result.violations) console.log(`[check-decisions] ${v.code} ${toAscii(v.detail)}`);
  const s = result.stats;
  const summary = `flow=${result.flow} decisions=${s.decisions} risk_nodes=${s.riskNodes} ledger_records=${s.records}`;
  if (result.violations.length === 0) {
    console.log(`[check-decisions] passed (${summary})`);
    process.exit(0);
  }
  if (args.mode === "fail") {
    console.log(`[check-decisions] failed: ${result.violations.length} violation(s) (${summary})`);
    process.exit(1);
  }
  console.log(`[check-decisions] warn: ${result.violations.length} violation(s) (${summary}); mode=warn does not block, flip to --mode=fail once the declarations are in place`);
  process.exit(0);
}

if (require.main === module) main();

module.exports = { checkDecisions, checkLedgerOnly, toAscii, isValidScope };
