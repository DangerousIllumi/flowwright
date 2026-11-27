"use strict";

const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const REPO = path.resolve(__dirname, "..", "..");
const TOOL = path.join(__dirname, "check-design.js");

function validDesign(overrides = {}) {
  return {
    flow: "tests/eval/fixtures/file-copy-text.json",
    requirements: [
      { id: "R1", text: "read the source" },
      { id: "R2", text: "write the target" },
    ],
    mapping: [
      { clause: "R1", nodes: ["1"], acceptance: ["source-read"] },
      { clause: "R2", nodes: ["2"], acceptance: [] },
    ],
    lane: { choice: "py", reason: "file-only job" },
    failure_paths: [],
    state_markers: [],
    rejected_alternatives: [{ option: "PAD", reason: "no UI step" }],
    ...overrides,
  };
}

function run(args, cwd = REPO) {
  return spawnSync(process.execPath, [TOOL, ...args], { cwd, encoding: "utf8" });
}

function writeDesign(dir, doc) {
  const file = path.join(dir, "sample.design.json");
  fs.writeFileSync(file, JSON.stringify(doc, null, 2));
  return file;
}

test("accepts a fully mapped design record", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "check-design-"));
  const file = writeDesign(dir, validDesign());
  const result = run([file]);
  assert.strictEqual(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /passed \(2 clause\(s\), all mapped\)/);
});

test("reports the exact unmapped clause id", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "check-design-"));
  const file = writeDesign(
    dir,
    validDesign({
      mapping: [{ clause: "R1", nodes: ["1"], acceptance: [] }],
    })
  );
  const result = run([file]);
  assert.strictEqual(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /CLAUSE_UNMAPPED: R2/);
});

test("rejects a mapping entry for an unknown clause", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "check-design-"));
  const file = writeDesign(
    dir,
    validDesign({
      mapping: [
        { clause: "R1", nodes: ["1"], acceptance: [] },
        { clause: "R2", nodes: ["2"], acceptance: [] },
        { clause: "R9", nodes: ["2"], acceptance: [] },
      ],
    })
  );
  const result = run([file]);
  assert.strictEqual(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /MAPPING_UNKNOWN_CLAUSE: mapping\[2\]\.clause=R9/);
});

test("requires a lane reason", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "check-design-"));
  const file = writeDesign(dir, validDesign({ lane: { choice: "py" } }));
  const result = run([file]);
  assert.strictEqual(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /LANE_REASON_MISSING/);
});

test("reports an external flow node that has no failure path recorded", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "check-design-"));
  const file = writeDesign(
    dir,
    validDesign({
      flow: "tests/eval/fixtures/http-webhook.json",
      mapping: [
        { clause: "R1", nodes: ["1"], acceptance: [] },
        { clause: "R2", nodes: ["2"], acceptance: [] },
      ],
      failure_paths: [],
    })
  );
  const result = run([file]);
  assert.strictEqual(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /FAILURE_PATH_UNRECORDED: external node 1/);
});

test("accepts a failure path recorded for every external node", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "check-design-"));
  const file = writeDesign(
    dir,
    validDesign({
      flow: "tests/eval/fixtures/http-webhook.json",
      mapping: [
        { clause: "R1", nodes: ["1"], acceptance: [] },
        { clause: "R2", nodes: ["2"], acceptance: [] },
      ],
      failure_paths: [
        { node: "1", kind: "branch", on_failure: "node 2 checks HttpStatus; node 4 shows the error" },
      ],
    })
  );
  const result = run([file]);
  assert.strictEqual(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /passed \(2 clause\(s\), all mapped\)/);
});

test("--flow without a design record is a skip", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "check-design-"));
  const flow = path.join(dir, "lonely.json");
  fs.copyFileSync(path.join(REPO, "tests", "eval", "fixtures", "file-copy-text.json"), flow);
  const result = run(["--flow", flow]);
  assert.strictEqual(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /skip: no design record/);
});

test("--flow --require without a design record is DESIGN_RECORD_MISSING with exit 2", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "check-design-"));
  const flow = path.join(dir, "lonely.json");
  fs.copyFileSync(path.join(REPO, "tests", "eval", "fixtures", "file-copy-text.json"), flow);
  const result = run(["--flow", flow, "--require"]);
  assert.strictEqual(result.status, 2, result.stdout + result.stderr);
  assert.match(result.stdout, /DESIGN_RECORD_MISSING: /);
  assert.ok(result.stdout.includes(flow), "the message must name the flow path");
});

test("keeps output ASCII when the record contains non-ASCII text", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "check-design-"));
  const file = writeDesign(
    dir,
    validDesign({
      requirements: [
        { id: "R1", text: "\u8bfb\u53d6\u6e90\u6587\u4ef6" },
        { id: "R2", text: "write the target" },
      ],
      mapping: [{ clause: "R2", nodes: ["2"], acceptance: [] }],
    })
  );
  const result = run([file]);
  assert.strictEqual(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /\\u8bfb/);
  assert.ok(!result.stdout.includes("\u8bfb"));
});

test("--flow --require without a <name>.cases.json is DESIGN_CASES_MISSING with exit 2", () => {
  // business/flows/a.json pairs with business/tests/eval/a.cases.json; the cases file is deliberately
  // not created, so the --require cases check must fire after the design record is found.
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), "check-design-cases-"));
  const flowDir = path.join(repo, "business", "flows");
  fs.mkdirSync(flowDir, { recursive: true });
  const flow = path.join(flowDir, "a.json");
  fs.copyFileSync(path.join(REPO, "tests", "eval", "fixtures", "file-copy-text.json"), flow);
  fs.writeFileSync(path.join(flowDir, "a.design.json"), JSON.stringify(validDesign(), null, 2));
  const result = run(["--flow", flow, "--require"], repo);
  assert.strictEqual(result.status, 2, result.stdout + result.stderr);
  assert.match(result.stdout, /DESIGN_CASES_MISSING: /);
  assert.ok(
    result.stdout.includes(path.join("tests", "eval", "a.cases.json")),
    "the message must name the derived cases path"
  );
});

/** Build a business tree with a flow, its design record and (optionally) one ledger row. */
function writeBusinessWithLedger(ledgerRecord) {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), "check-design-ledger-"));
  const flowDir = path.join(repo, "business", "flows");
  fs.mkdirSync(flowDir, { recursive: true });
  const flow = path.join(flowDir, "a.json");
  fs.copyFileSync(path.join(REPO, "tests", "eval", "fixtures", "file-copy-text.json"), flow);
  const design = validDesign({ decisions: [{ decision_id: "D-900" }] });
  fs.writeFileSync(path.join(flowDir, "a.design.json"), JSON.stringify(design, null, 2));
  if (ledgerRecord) {
    fs.writeFileSync(path.join(repo, "business", "decisions.jsonl"), JSON.stringify(ledgerRecord) + "\n", "utf8");
  }
  return { repo, flow };
}

test("a design decision that is not a class=design ledger row is DESIGN_DECISION_NOT_IN_LEDGER with exit 2", () => {
  const { repo, flow } = writeBusinessWithLedger({
    id: "D-900",
    class: "standard",
    scope: "flow:a",
    decision: "recorded but not a design decision",
    decided_by: "user",
    decided_at: "2026-11-27",
  });
  const result = run(["--flow", flow], repo);
  assert.strictEqual(result.status, 2, result.stdout + result.stderr);
  assert.match(result.stdout, /DESIGN_DECISION_NOT_IN_LEDGER: /);
  assert.match(result.stdout, /decision_id=D-900/);
  assert.match(result.stdout, /class="standard"/);
});

test("a design decision backed by a class=design decided_by=user ledger row passes with exit 0", () => {
  const { repo, flow } = writeBusinessWithLedger({
    id: "D-900",
    class: "design",
    scope: "flow:a",
    decision: "the lane choice was made by a person",
    decided_by: "user",
    decided_at: "2026-11-27",
  });
  const result = run(["--flow", flow], repo);
  assert.strictEqual(result.status, 0, result.stdout + result.stderr);
  assert.doesNotMatch(result.stdout, /DESIGN_DECISION_NOT_IN_LEDGER/);
});
