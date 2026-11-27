#!/usr/bin/env node
/**
 * check-design.js — validate a design record and its requirement coverage.
 *
 * Usage:
 *   node tools/verify/check-design.js <design.json> [--flow <flow.json>]
 *   node tools/verify/check-design.js --flow <flow.json> [--require]
 *
 * The second form derives <name>.design.json next to the flow and skips when the
 * record does not exist, so a repository without design records keeps working.
 * With --require a missing record is an input error (exit 2) instead of a skip.
 *
 * Design record path: business/flows/<name>.design.json
 * Shape and rules: docs/design-record.md
 *
 * Exit codes: 0 pass/skip, 1 at least one violation, 2 input error.
 * Output stays ASCII so a non-UTF-8 console code page cannot garble the evidence.
 */
"use strict";

const fs = require("fs");
const path = require("path");

const LANES = new Set(["pad", "ps1", "py"]);
const FAILURE_KINDS = new Set(["branch", "guard", "early-exit"]);
const STATE_KINDS = new Set(["run-timestamp-dir", "state-ledger", "idempotency-key", "none"]);
// Keep this predicate in step with tools/pad-robin/eval-flow.js failurePath.
const EXTERNAL_CALL_RE =
  /^(Outlook\.|Excel\.|SAP\.|FTP\.|Web\.|WebAutomation\.|Scripting\.(RunDOSCommand|RunVBScript|RunPowershellScript))/i;

function ascii(value) {
  return String(value).replace(/[^\x20-\x7E]/g, (ch) => "\\u" + ch.charCodeAt(0).toString(16).padStart(4, "0"));
}

function line(text) {
  process.stdout.write(ascii(text) + "\n");
}

function isNonEmptyString(value) {
  return typeof value === "string" && value.trim() !== "";
}

function stringList(value) {
  return Array.isArray(value) ? value.map((x) => String(x)) : [];
}

function parseArgs(argv) {
  let designPath = null;
  let flowPath = null;
  let require = false;
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--flow") {
      flowPath = argv[++i] || null;
    } else if (arg === "--require") {
      require = true;
    } else if (arg === "--help" || arg === "-h") {
      return { help: true };
    } else if (!designPath) {
      designPath = arg;
    } else {
      return { error: `unexpected argument: ${arg}` };
    }
  }
  return { designPath, flowPath, require };
}

function resolveFlowPath(designPath, declared) {
  if (!declared) return null;
  if (typeof declared !== "string") return null;
  const candidates = [path.resolve(process.cwd(), declared), path.resolve(path.dirname(designPath), declared)];
  return candidates.find((p) => fs.existsSync(p)) || null;
}

function validate(doc, designPath, flowOverride) {
  const failures = [];
  const fail = (code, detail) => failures.push(`${code}: ${detail}`);

  if (!doc || typeof doc !== "object" || Array.isArray(doc)) {
    fail("DESIGN_INVALID", "top level must be a JSON object");
    return failures;
  }

  // Requirements: every clause needs a stable id and readable text.
  const requirements = Array.isArray(doc.requirements) ? doc.requirements : [];
  if (requirements.length === 0) fail("REQUIREMENTS_EMPTY", "requirements[] must contain at least one clause");
  const reqIds = new Set();
  for (const [i, r] of requirements.entries()) {
    if (!r || typeof r !== "object") {
      fail("REQUIREMENT_INVALID", `requirements[${i}] must be an object`);
      continue;
    }
    if (!isNonEmptyString(r.id)) fail("REQUIREMENT_ID_MISSING", `requirements[${i}].id`);
    else if (reqIds.has(r.id)) fail("REQUIREMENT_ID_DUPLICATE", `requirements[${i}].id=${r.id}`);
    else reqIds.add(r.id);
    if (!isNonEmptyString(r.text)) fail("REQUIREMENT_TEXT_MISSING", `requirements[${i}] (${r.id || "?"})`);
  }

  // Mapping: every clause must point at a node, an acceptance check, or both.
  const mapping = Array.isArray(doc.mapping) ? doc.mapping : [];
  if (mapping.length === 0) fail("MAPPING_EMPTY", "mapping[] must contain at least one entry");
  const mappedClauses = new Set();
  const mappedNodes = [];
  for (const [i, m] of mapping.entries()) {
    if (!m || typeof m !== "object") {
      fail("MAPPING_INVALID", `mapping[${i}] must be an object`);
      continue;
    }
    if (!isNonEmptyString(m.clause)) {
      fail("MAPPING_CLAUSE_MISSING", `mapping[${i}].clause`);
      continue;
    }
    if (!reqIds.has(m.clause)) fail("MAPPING_UNKNOWN_CLAUSE", `mapping[${i}].clause=${m.clause}`);
    mappedClauses.add(m.clause);
    const nodes = stringList(m.nodes);
    const acceptance = stringList(m.acceptance);
    if (nodes.length === 0 && acceptance.length === 0) {
      fail("MAPPING_TARGET_MISSING", `mapping[${i}] (${m.clause}) has neither nodes nor acceptance`);
    }
    mappedNodes.push(...nodes);
  }
  for (const id of reqIds) {
    if (!mappedClauses.has(id)) {
      const text = (requirements.find((r) => r && r.id === id) || {}).text || "";
      fail("CLAUSE_UNMAPPED", `${id} "${text}"`);
    }
  }

  // Lane: a recorded choice and a reason, not just a label.
  const lane = doc.lane;
  if (!lane || typeof lane !== "object" || Array.isArray(lane)) {
    fail("LANE_MISSING", "lane{} is required");
  } else {
    if (!LANES.has(lane.choice)) {
      fail("LANE_CHOICE_INVALID", `lane.choice=${JSON.stringify(lane.choice)} (expected pad|ps1|py)`);
    }
    if (!isNonEmptyString(lane.reason)) fail("LANE_REASON_MISSING", "lane.reason");
  }

  // Failure paths: recorded per external node, with the handling strategy.
  const failurePaths = Array.isArray(doc.failure_paths) ? doc.failure_paths : [];
  if (!Array.isArray(doc.failure_paths)) fail("FAILURE_PATHS_INVALID", "failure_paths must be an array");
  const recordedFailureNodes = new Set();
  for (const [i, f] of failurePaths.entries()) {
    if (!f || typeof f !== "object") {
      fail("FAILURE_PATH_INVALID", `failure_paths[${i}] must be an object`);
      continue;
    }
    if (!isNonEmptyString(f.node)) fail("FAILURE_PATH_NODE_MISSING", `failure_paths[${i}].node`);
    else recordedFailureNodes.add(String(f.node));
    if (!FAILURE_KINDS.has(f.kind)) {
      fail("FAILURE_PATH_KIND_INVALID", `failure_paths[${i}].kind=${JSON.stringify(f.kind)} (expected branch|guard|early-exit)`);
    }
    if (!isNonEmptyString(f.on_failure)) fail("FAILURE_PATH_HANDLER_MISSING", `failure_paths[${i}].on_failure`);
  }

  // State design: what tells this run apart from the previous one.
  const stateMarkers = Array.isArray(doc.state_markers) ? doc.state_markers : [];
  if (!Array.isArray(doc.state_markers)) fail("STATE_MARKERS_INVALID", "state_markers must be an array");
  for (const [i, s] of stateMarkers.entries()) {
    if (!s || typeof s !== "object") {
      fail("STATE_MARKER_INVALID", `state_markers[${i}] must be an object`);
      continue;
    }
    if (!isNonEmptyString(s.name)) fail("STATE_MARKER_NAME_MISSING", `state_markers[${i}].name`);
    if (!STATE_KINDS.has(s.kind)) {
      fail("STATE_MARKER_KIND_INVALID", `state_markers[${i}].kind=${JSON.stringify(s.kind)}`);
    }
    if (!isNonEmptyString(s.where)) fail("STATE_MARKER_WHERE_MISSING", `state_markers[${i}].where`);
  }

  // Rejected alternatives: the design rationale that a later reviewer needs.
  const rejected = Array.isArray(doc.rejected_alternatives) ? doc.rejected_alternatives : [];
  if (!Array.isArray(doc.rejected_alternatives)) {
    fail("REJECTED_ALTERNATIVES_INVALID", "rejected_alternatives must be an array");
  }
  for (const [i, r] of rejected.entries()) {
    if (!r || typeof r !== "object") {
      fail("REJECTED_ALTERNATIVE_INVALID", `rejected_alternatives[${i}] must be an object`);
      continue;
    }
    if (!isNonEmptyString(r.option)) fail("REJECTED_OPTION_MISSING", `rejected_alternatives[${i}].option`);
    if (!isNonEmptyString(r.reason)) fail("REJECTED_REASON_MISSING", `rejected_alternatives[${i}].reason`);
  }

  // Optional flow cross-check: mapped nodes exist, and every external call has
  // a recorded failure path. This is where the record stops being prose.
  const declaredFlow = flowOverride || doc.flow;
  if (declaredFlow && !isNonEmptyString(declaredFlow)) fail("FLOW_INVALID", "flow must be a path string");
  const flowPath = resolveFlowPath(designPath, declaredFlow);
  if (declaredFlow && isNonEmptyString(declaredFlow) && !flowPath) fail("FLOW_NOT_FOUND", declaredFlow);
  if (flowPath) {
    let flow;
    try {
      flow = JSON.parse(fs.readFileSync(flowPath, "utf8"));
    } catch (e) {
      fail("FLOW_INVALID", `${flowPath}: ${e.message}`);
      return failures;
    }
    const nodeIds = new Set((flow.nodes || []).map((n) => String(n.id)));
    for (const id of mappedNodes) {
      if (!nodeIds.has(String(id))) fail("MAPPING_NODE_UNKNOWN", `mapping references node ${id}, not present in ${flowPath}`);
    }
    for (const id of recordedFailureNodes) {
      if (!nodeIds.has(String(id))) {
        fail("FAILURE_PATH_NODE_UNKNOWN", `failure_paths references node ${id}, not present in ${flowPath}`);
      }
    }
    for (const n of flow.nodes || []) {
      if (!EXTERNAL_CALL_RE.test(String(n.pad_hint || ""))) continue;
      if (!recordedFailureNodes.has(String(n.id))) {
        fail("FAILURE_PATH_UNRECORDED", `external node ${n.id} (${n.pad_hint}) has no failure_paths entry`);
      }
    }
  }

  return failures;
}

/**
 * Design decisions must live in the ledger. The optional `decisions` field of a design record cites
 * decision ids: [{"decision_id":"D-00X"}]. When the field is present, every cited id must exist in
 * business/decisions.jsonl (derived from the design record's own directory, never from cwd) as a record
 * with class=design and decided_by=user. A missing ledger counts as a violation, never as a pass.
 * When the field is absent the record is not judged at all - the field stays optional.
 */
function checkDesignDecisions(doc, designPath) {
  const failures = [];
  if (!doc || !Object.prototype.hasOwnProperty.call(doc, "decisions")) return failures;
  const entries = doc.decisions;
  if (!Array.isArray(entries)) {
    failures.push("DESIGN_DECISION_NOT_IN_LEDGER: decisions must be an array of {decision_id} objects");
    return failures;
  }
  const ledgerPath = path.join(path.dirname(designPath), "..", "decisions.jsonl");
  const ledgerExists = fs.existsSync(ledgerPath);
  const records = new Map();
  if (ledgerExists) {
    for (const raw of fs.readFileSync(ledgerPath, "utf8").split(/\r?\n/)) {
      const text = raw.trim();
      if (!text) continue;
      let rec = null;
      try {
        rec = JSON.parse(text);
      } catch (e) {
        continue; // an unreadable row is not a record
      }
      if (rec && typeof rec.id === "string" && rec.id) records.set(rec.id, rec);
    }
  }
  for (const [index, entry] of entries.entries()) {
    const id = entry && typeof entry === "object" ? entry.decision_id : undefined;
    if (typeof id !== "string" || !id) {
      failures.push(`DESIGN_DECISION_NOT_IN_LEDGER: decisions[${index}] has no string decision_id`);
      continue;
    }
    const rec = records.get(id);
    if (!rec) {
      const why = ledgerExists ? `not found in ${ledgerPath}` : `ledger not found: ${ledgerPath}`;
      failures.push(`DESIGN_DECISION_NOT_IN_LEDGER: decision_id=${id} class=null decided_by=null ${why}`);
      continue;
    }
    if (rec.class !== "design" || rec.decided_by !== "user") {
      failures.push(
        `DESIGN_DECISION_NOT_IN_LEDGER: decision_id=${id} class=${JSON.stringify(rec.class)} decided_by=${JSON.stringify(rec.decided_by)} expected class=design and decided_by=user in ${ledgerPath}`
      );
    }
  }
  return failures;
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    line("usage: node tools/verify/check-design.js <design.json> [--flow <flow.json>]");
    line("       node tools/verify/check-design.js --flow <flow.json> [--require]   # derives <name>.design.json; skips when absent unless --require; with --require it also requires <name>.cases.json");
    return 0;
  }
  if (args.error) {
    line(`[check-design] ${args.error}`);
    return 2;
  }

  let designPath = args.designPath;
  if (!designPath && args.flowPath) {
    designPath = args.flowPath.replace(/\.json$/i, ".design.json");
    if (!fs.existsSync(designPath)) {
      if (args.require) {
        line(`[check-design] DESIGN_RECORD_MISSING: ${args.flowPath}`);
        return 2;
      }
      line(`[check-design] skip: no design record for ${args.flowPath}`);
      return 0;
    }
  }
  if (!designPath) {
    line("[check-design] usage: node tools/verify/check-design.js <design.json> [--flow <flow.json>]");
    return 2;
  }
  if (!fs.existsSync(designPath)) {
    line(`[check-design] DESIGN_NOT_FOUND: ${designPath}`);
    return 2;
  }

  // --require also demands the flow's design cases: business/flows/<name>.json pairs with
  // business/tests/eval/<name>.cases.json. Paths are derived from the flow path itself, never from cwd.
  if (args.require && args.flowPath) {
    const flowName = path.basename(args.flowPath).replace(/\.json$/i, "");
    const casesPath = path.join(path.dirname(args.flowPath), "..", "tests", "eval", flowName + ".cases.json");
    if (!fs.existsSync(casesPath)) {
      line(`[check-design] DESIGN_CASES_MISSING: ${casesPath}`);
      return 2;
    }
  }

  let doc;
  try {
    doc = JSON.parse(fs.readFileSync(designPath, "utf8"));
  } catch (e) {
    line(`[check-design] DESIGN_INVALID: ${designPath}: ${e.message}`);
    return 2;
  }

  const failures = validate(doc, designPath, args.flowPath).concat(checkDesignDecisions(doc, designPath));
  line(`[check-design] ${designPath}`);
  if (failures.length === 0) {
    const clauses = Array.isArray(doc.requirements) ? doc.requirements.length : 0;
    line(`[check-design] passed (${clauses} clause(s), all mapped)`);
    return 0;
  }
  for (const failure of failures) line(`[check-design] ${failure}`);
  line(`[check-design] failed: ${failures.length} violation(s)`);
  return failures.some((f) => f.startsWith("DESIGN_DECISION_NOT_IN_LEDGER:")) ? 2 : 1;
}

process.exit(main());
