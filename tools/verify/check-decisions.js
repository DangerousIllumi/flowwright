#!/usr/bin/env node
/**
 * check-decisions.js - decision-ledger gate (read-only, engine-agnostic)
 *
 * Usage:
 *   node check-decisions.js <flow.json> [--ledger <path>] [--repo <path>] [--mode=warn|fail]
 *
 * Two-phase rollout (do not leave it in warn forever):
 *   --mode=warn (default) prints every violation and exits 0, so the gate can be introduced before the
 *   business layer is complete; --mode=fail exits 1. Flip the default of this file and the --mode of every
 *   caller (flow-to-robin.js, pad-admit.ps1, CI) in one change once every flow under business/flows/
 *   declares its decisions and every ledger record carries a class.
 *
 * What it checks (all of it derived from flow.json + business/decisions.jsonl; nothing is inferred):
 *   1. every risk node (reversible=false or intent_destructive=true) is covered by a decisions entry, and
 *      at least one record covering it is class=risk (a standard record cannot stand in for a risk one, or
 *      the person-approval rule below could be dodged by citing a routine decision)
 *   2. every decisions[].node exists in flow.json
 *   3. every decisions[].decision_id exists in the ledger
 *   4. a class=risk ledger record must be approved by a person (decided_by=user); an agent may record a
 *      decision, but it may not approve a risk one
 *   5. a cited ledger record's scope is "global" or this flow (a record scoped to another artifact is a
 *      stale or mistaken reference)
 *   6. class and decided_by use only their closed value sets
 *
 * Output is pure ASCII: any non-ASCII character is reported as \uXXXX so the codes stay greppable.
 * Exit codes: 0 = pass, skip, or violations while mode=warn; 1 = violations while mode=fail;
 *             2 = usage error or unreadable flow.
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
}

function parseArgs(argv) {
  const out = { flow: null, ledger: null, repo: path.resolve(__dirname, "..", ".."), mode: "warn" };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--ledger") { out.ledger = argv[i + 1]; i += 1; continue; }
    if (a === "--repo") { out.repo = argv[i + 1]; i += 1; continue; }
    if (a.startsWith("--mode=")) { out.mode = a.slice("--mode=".length); continue; }
    if (a.startsWith("--")) throw new Error(`unknown option ${a}`);
    if (out.flow) throw new Error(`unexpected argument ${a}`);
    out.flow = a;
  }
  if (!out.flow) throw new Error("no flow file given");
  if (!MODES.includes(out.mode)) throw new Error(`--mode must be one of ${MODES.join("|")}, got ${out.mode}`);
  if (out.repo == null) throw new Error("--repo needs a path");
  if (out.ledger === undefined) out.ledger = null;
  return out;
}

const slashes = (p) => String(p).replace(/\\/g, "/");

/** Repo-relative, forward-slash form of a file, so a ledger scope compares the same on any OS */
function repoRelative(file, repo) {
  const abs = path.resolve(file);
  const rel = path.relative(path.resolve(repo), abs);
  return slashes(rel.startsWith("..") ? abs : rel);
}

function isRiskNode(node) {
  return node && (node.reversible === false || node.intent_destructive === true);
}

/**
 * Pure check: returns { violations: [{code, detail}], stats, skip }.
 * Reads both files itself so the CLI and any caller judge with exactly one implementation.
 */
function checkDecisions(flowFile, options = {}) {
  const repo = options.repo || path.resolve(__dirname, "..", "..");
  const mode = options.mode || "warn";
  const ledgerGiven = options.ledger != null;
  const ledgerPath = ledgerGiven ? path.resolve(options.ledger) : path.join(repo, "business", "decisions.jsonl");
  const flowLabel = repoRelative(flowFile, repo);
  const violations = [];
  const add = (code, detail) => violations.push({ code, detail });

  let flow;
  try {
    flow = JSON.parse(fs.readFileSync(flowFile, "utf8"));
  } catch (e) {
    return { fatal: true, code: "FLOW_UNREADABLE", detail: `path=${flowLabel} error=${e.message}`, violations, stats: {} };
  }

  // The business layer is optional in the public tree: without it there is no ledger to judge against, and
  // skipping is reported, never silent. An explicit --ledger always counts as "the caller wants this judged".
  if (!ledgerGiven && !fs.existsSync(path.join(repo, "business"))) {
    return { skip: true, detail: "business layer not present in this repository", violations: [], stats: {} };
  }

  const ledger = [];
  const byId = new Map();
  if (!fs.existsSync(ledgerPath)) {
    add("LEDGER_MISSING", `ledger=${repoRelative(ledgerPath, repo)} required whenever the business layer exists`);
  } else {
    const text = fs.readFileSync(ledgerPath, "utf8");
    const lines = text.split(/\r?\n/);
    for (let i = 0; i < lines.length; i += 1) {
      const line = lines[i].trim();
      if (!line) continue;
      let rec;
      try {
        rec = JSON.parse(line);
      } catch (e) {
        add("LEDGER_UNREADABLE", `ledger=${repoRelative(ledgerPath, repo)} line=${i + 1} error=${e.message}`);
        continue;
      }
      ledger.push(rec);
      if (rec && typeof rec.id === "string") {
        if (byId.has(rec.id)) add("LEDGER_UNREADABLE", `duplicate id=${rec.id} at line=${i + 1}; the ledger must not repeat an id`);
        else byId.set(rec.id, rec);
      }
    }
  }

  const nodes = Array.isArray(flow.nodes) ? flow.nodes : [];
  const nodeIds = new Set(nodes.map((n) => String(n && n.id)));
  const riskNodes = nodes.filter(isRiskNode).map((n) => String(n.id));

  const entries = flow.decisions;
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
        const rec = byId.get(entry.decision_id);
        if (!rec) {
          if (recordsByNode.has(entry.node)) recordsByNode.get(entry.node).push(null);
          add("DECISION_NOT_IN_LEDGER", `flow=${flowLabel} node=${entry.node} decision=${entry.decision_id} not found in ${repoRelative(ledgerPath, repo)}`);
          return;
        }
        if (recordsByNode.has(entry.node)) recordsByNode.get(entry.node).push(rec);
        if (!CLASSES.includes(rec.class)) {
          add("DECISION_CLASS_INVALID", `decision=${entry.decision_id} class=${JSON.stringify(rec.class)} expected one of ${CLASSES.join("|")}`);
        }
        if (!DECIDED_BY.includes(rec.decided_by)) {
          add("DECISION_DECIDED_BY_INVALID", `decision=${entry.decision_id} decided_by=${JSON.stringify(rec.decided_by)} expected one of ${DECIDED_BY.map((v) => JSON.stringify(v)).join("|")}`);
        }
        if (rec.class === "risk" && rec.decided_by !== "user") {
          add("DECISION_NOT_USER_APPROVED", `decision=${entry.decision_id} decided_by=${JSON.stringify(rec.decided_by)} a risk-class decision needs a person; record the confirmation as a new row with decided_by=user and supersedes=${entry.decision_id}`);
        }
        const scope = typeof rec.scope === "string" ? slashes(rec.scope) : "";
        if (scope !== "global" && scope !== flowLabel) {
          add("DECISION_SCOPE_MISMATCH", `decision=${entry.decision_id} scope=${toAscii(rec.scope)} covers neither global nor ${flowLabel}`);
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
    // node already has DECISION_NOT_IN_LEDGER, so do not report twice.
    const records = recordsByNode.get(id) || [];
    if (records.some((r) => r && r.class === "risk")) continue;
    if (records.some((r) => r == null)) continue;
    add("RISK_NODE_DECISION_NOT_RISK", `flow=${flowLabel} node=${id} is irreversible or destructive but every decision naming it is class=standard; a risk node needs a class=risk record with decided_by=user`);
  }

  return {
    flow: flowLabel,
    mode,
    violations,
    stats: { records: ledger.length, decisions: Array.isArray(entries) ? entries.length : 0, riskNodes: riskNodes.length },
  };
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

module.exports = { checkDecisions, toAscii };
