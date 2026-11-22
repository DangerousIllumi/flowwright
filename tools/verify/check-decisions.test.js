// check-decisions.test.js - unit tests for the decision-ledger gate (node --test)
//
// Each case builds a throwaway repository (<tmp>/flows/x.json + <tmp>/business/decisions.jsonl), runs the
// CLI as a child process, and asserts the exit code and the report. Every case also asserts the report is
// printable ASCII: non-ASCII values (e.g. a Chinese scope) must come out escaped as \uXXXX, so the codes
// stay greppable in any console.
// Usage: node --test tools/verify/check-decisions.test.js
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const CLI = path.join(__dirname, "check-decisions.js");
const PRINTABLE_ASCII = /^[\x20-\x7E\r\n\t]*$/;

/** One ledger record with the contract's required fields; overrides change the field under test. */
function record(overrides) {
  return Object.assign({
    id: "D-001",
    class: "standard",
    scope: "global",
    decision: "decided for the test",
    decided_by: "user",
    decided_at: "2026-11-19",
  }, overrides);
}

/** Serialize records the way business/decisions.jsonl is written: one JSON object per line. */
function ledgerText(records) {
  return records.map((r) => JSON.stringify(r)).join("\n") + (records.length ? "\n" : "");
}

/**
 * Build a throwaway repo, write the flow (and the ledger unless it is left out), run the CLI, and assert the
 * report is printable ASCII. `business: false` leaves business/ out entirely (the public-tree skip case);
 * a `business` dir with no `ledger` option means the ledger file is missing (the LEDGER_MISSING case).
 * `opts.assertAscii === false` leaves the printable-ASCII check to the caller: a test that asserts the
 * escaping on the raw output itself cannot use a helper whose guard runs first, or its own assertion
 * would be unable to fail.
 */
function runCheck(options, opts = {}) {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), "check-decisions-"));
  // A flow under business/ is a business flow and is always judged; a flow outside it is a public sample
  // and is skipped when it cites nothing. Cases that exercise the per-flow rules therefore go under
  // business/flows/, exactly like a real business flow. `publicSample: true` puts the flow outside instead.
  const flowDir = options.publicSample || options.business === false
    ? path.join(repo, "flows")
    : path.join(repo, "business", "flows");
  fs.mkdirSync(flowDir, { recursive: true });
  const flowPath = path.join(flowDir, "x.json");
  fs.writeFileSync(flowPath, JSON.stringify(options.flow, null, 2), "utf8");
  if (options.business !== false) {
    fs.mkdirSync(path.join(repo, "business"), { recursive: true });
    if (options.ledger !== undefined) {
      fs.writeFileSync(path.join(repo, "business", "decisions.jsonl"), options.ledger, "utf8");
    }
  }
  const mode = options.mode || "warn";
  const r = spawnSync(process.execPath, [CLI, flowPath, "--repo", repo, "--mode=" + mode], { encoding: "utf8" });
  const stdout = r.stdout || "";
  if (opts.assertAscii !== false) {
    assert.match(stdout, PRINTABLE_ASCII, "stdout must be printable ASCII, got: " + JSON.stringify(stdout));
  }
  return { status: r.status, stdout, stderr: r.stderr || "" };
}

test("skip: a repository without the business layer reports skip and exits 0", () => {
  const r = runCheck({ flow: { nodes: [] }, business: false });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.match(r.stdout, /\[check-decisions\] skip: business layer not present in this repository/);
});

test("pass: a risk node covered by a user-approved global decision exits 0", () => {
  const r = runCheck({
    flow: {
      nodes: [{ id: "15", type: "action", reversible: false }],
      decisions: [{ node: "15", decision_id: "D-001" }],
    },
    ledger: ledgerText([record({ class: "risk", decided_by: "user" })]),
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.match(r.stdout, /passed \(flow=business\/flows\/x\.json decisions=1 risk_nodes=1 ledger_records=1\)/);
  assert.doesNotMatch(r.stdout, /violation/);
});

test("pass: the scope value domain is global | flow:<name> | script:<path>", () => {
  // scope is the human-readable subject of a decision and is NOT matched against the flow; decisions[].node
  // binds the decision. The gate only enforces that every row stays inside the closed domain.
  const flow = {
    nodes: [{ id: "15", reversible: false }],
    decisions: [{ node: "15", decision_id: "D-001" }],
  };
  for (const scope of ["global", "flow:some-other-flow", "script:business/scripts/other.ps1"]) {
    const r = runCheck({ flow, ledger: ledgerText([record({ class: "risk", scope })]) });
    assert.strictEqual(r.status, 0, r.stderr);
    assert.match(r.stdout, /passed/, `scope ${scope} must be accepted`);
  }
});

test("RISK_NODE_WITHOUT_DECISION: reversible=false needs a decisions entry, reported in warn mode", () => {
  const r = runCheck({
    flow: { nodes: [{ id: "15", type: "action", reversible: false }] },
    ledger: ledgerText([]),
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.match(r.stdout, /RISK_NODE_WITHOUT_DECISION .*node=15/);
  assert.match(r.stdout, /warn: 1 violation\(s\)/);
});

test("RISK_NODE_WITHOUT_DECISION: intent_destructive=true is a risk node too", () => {
  const r = runCheck({
    flow: { nodes: [{ id: "9", type: "action", reversible: true, intent_destructive: true }] },
    ledger: ledgerText([]),
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.match(r.stdout, /RISK_NODE_WITHOUT_DECISION .*node=9/);
});

test("RISK_NODE_DECISION_NOT_RISK: a standard record cannot stand in for a risk node", () => {
  // Citing a routine decision to cover an irreversible node would dodge the person-approval rule, so the
  // covering citation must include at least one class=risk record.
  const r = runCheck({
    flow: {
      nodes: [{ id: "43", reversible: false, intent_destructive: true }],
      decisions: [{ node: "43", decision_id: "D-001" }],
    },
    ledger: ledgerText([record({ class: "standard", decided_by: "agent(recorded)", scope: "global" })]),
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.match(r.stdout, /RISK_NODE_DECISION_NOT_RISK .*node=43 is irreversible or destructive but every decision naming it is class=standard/);
  assert.doesNotMatch(r.stdout, /DECISION_NOT_USER_APPROVED/);
});

test("RISK_NODE_DECISION_NOT_RISK: cleared as soon as one covering record is class=risk", () => {
  const r = runCheck({
    flow: {
      nodes: [{ id: "43", reversible: false }],
      decisions: [
        { node: "43", decision_id: "D-001" },
        { node: "43", decision_id: "D-002" },
      ],
    },
    ledger: ledgerText([
      record({ id: "D-001", class: "standard", decided_by: "agent(recorded)", scope: "global" }),
      record({ id: "D-002", class: "risk", decided_by: "user", scope: "global" }),
    ]),
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.doesNotMatch(r.stdout, /RISK_NODE_DECISION_NOT_RISK/);
  assert.match(r.stdout, /passed/);
});

test("DECISION_NODE_NOT_FOUND: a decisions entry names a node that is not in the flow", () => {
  const r = runCheck({
    flow: {
      nodes: [{ id: "15", reversible: true }],
      decisions: [{ node: "99", decision_id: "D-001" }],
    },
    ledger: ledgerText([record({})]),
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.match(r.stdout, /DECISION_NODE_NOT_FOUND .*node=99 is not a node of this flow/);
});

test("DECISION_NOT_IN_LEDGER: a decisions entry cites an id the ledger does not contain", () => {
  const r = runCheck({
    flow: {
      nodes: [{ id: "15", reversible: true }],
      decisions: [{ node: "15", decision_id: "D-404" }],
    },
    ledger: ledgerText([record({})]),
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.match(r.stdout, /DECISION_NOT_IN_LEDGER .*decision=D-404 not found in business\/decisions\.jsonl/);
});

test("DECISION_NOT_USER_APPROVED: class=risk may not be approved by an agent(recorded) row", () => {
  const r = runCheck({
    flow: {
      nodes: [{ id: "15", reversible: false }],
      decisions: [{ node: "15", decision_id: "D-001" }],
    },
    ledger: ledgerText([record({ class: "risk", decided_by: "agent(recorded)" })]),
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.match(r.stdout, /DECISION_NOT_USER_APPROVED .*a risk-class decision needs a person/);
  assert.match(r.stdout, /warn: 1 violation\(s\)/);
});

test("DECISION_SCOPE_INVALID: a scope outside the closed domain is rejected (a bare path is not a scope)", () => {
  const r = runCheck({
    flow: {
      nodes: [{ id: "15", reversible: true }],
      decisions: [{ node: "15", decision_id: "D-001" }],
    },
    ledger: ledgerText([record({ scope: "business/flows/other.json" })]),
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.match(r.stdout, /DECISION_SCOPE_INVALID .*scope="business\/flows\/other\.json" expected global \| flow:<name> \| script:<repo-relative path>/);
});

test("DECISION_SCOPE_INVALID: the ledger schema is checked for every row, not only the cited ones", () => {
  const r = runCheck({
    flow: { nodes: [{ id: "15", reversible: true }], decisions: [{ node: "15", decision_id: "D-001" }] },
    ledger: ledgerText([
      record({ id: "D-001", scope: "global" }),
      record({ id: "D-002", scope: "flow:" }),
    ]),
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.match(r.stdout, /DECISION_SCOPE_INVALID decision=D-002/);
});

test("DECISION_CLASS_INVALID: class must be risk or standard", () => {
  const r = runCheck({
    flow: {
      nodes: [{ id: "15", reversible: true }],
      decisions: [{ node: "15", decision_id: "D-001" }],
    },
    ledger: ledgerText([record({ class: "approved" })]),
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.match(r.stdout, /DECISION_CLASS_INVALID .*class="approved" expected one of risk\|standard/);
});

test("DECISION_DECIDED_BY_INVALID: decided_by must be user or agent(recorded)", () => {
  const r = runCheck({
    flow: {
      nodes: [{ id: "15", reversible: true }],
      decisions: [{ node: "15", decision_id: "D-001" }],
    },
    ledger: ledgerText([record({ decided_by: "robot" })]),
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.match(r.stdout, /DECISION_DECIDED_BY_INVALID .*decided_by="robot"/);
});

test("DECISION_ENTRY_INVALID: flow.decisions must be an array", () => {
  const r = runCheck({
    flow: { nodes: [], decisions: "D-001" },
    ledger: ledgerText([record({})]),
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.match(r.stdout, /DECISION_ENTRY_INVALID .*decisions must be an array of \{node, decision_id\} objects/);
});

test("DECISION_ENTRY_INVALID: an entry without a string decision_id", () => {
  const r = runCheck({
    flow: {
      nodes: [{ id: "15", reversible: true }],
      decisions: [{ node: "15" }],
    },
    ledger: ledgerText([record({})]),
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.match(r.stdout, /DECISION_ENTRY_INVALID .*decisions\[0\] node=15 has no string decision_id/);
});

test("LEDGER_MISSING: the business layer exists but the ledger file does not", () => {
  const r = runCheck({ flow: { nodes: [] } });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.match(r.stdout, /LEDGER_MISSING ledger=business\/decisions\.jsonl is missing \(the business layer exists, so the ledger must exist too\)/);
});

test("LEDGER_MISSING: with no business layer at all, a cited decision is a violation, never a skip", () => {
  // Deleting the ledger must not turn the gate off. The public tree has no business/ at all, so a flow that
  // cites decisions is exactly the case that used to fall through as "there is nothing to verify".
  const flow = {
    nodes: [{ id: "15", reversible: true }],
    decisions: [{ node: "15", decision_id: "D-001" }],
  };
  const warn = runCheck({ flow, business: false });
  assert.strictEqual(warn.status, 0, warn.stderr);
  assert.doesNotMatch(warn.stdout, /skip:/);
  assert.match(warn.stdout, /LEDGER_MISSING ledger=business\/decisions\.jsonl is missing \(the flow cites 1 decision\(s\) and a reference that cannot be checked is not a pass\)/);
  assert.match(warn.stdout, /warn: 1 violation\(s\)/);

  const fail = runCheck({ flow, business: false, mode: "fail" });
  assert.strictEqual(fail.status, 1, fail.stderr);
  assert.match(fail.stdout, /\[check-decisions\] failed: 1 violation\(s\)/);
});

test("LEDGER_MISSING: no citations and no business layer still skips (the public runner case)", () => {
  const r = runCheck({ flow: { nodes: [{ id: "15", reversible: false }] }, business: false });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.match(r.stdout, /skip: business layer not present in this repository/);
});

test("warn mode exits 0 with a warn summary; fail mode exits 1 on the same input", () => {
  const flow = { nodes: [{ id: "15", reversible: false }] };
  const ledger = ledgerText([]);
  const warn = runCheck({ flow, ledger });
  assert.strictEqual(warn.status, 0, warn.stderr);
  assert.match(warn.stdout, /\[check-decisions\] warn: 1 violation\(s\) .*mode=warn/);
  assert.doesNotMatch(warn.stdout, /failed:/);
  const fail = runCheck({ flow, ledger, mode: "fail" });
  assert.strictEqual(fail.status, 1, fail.stderr);
  assert.match(fail.stdout, /\[check-decisions\] failed: 1 violation\(s\)/);
  assert.doesNotMatch(fail.stdout, /warn:/);
});

test("ASCII: a non-ASCII scope and decision id are reported as \\uXXXX", () => {
  // The flow carries a Chinese note and the ledger a Chinese scope; neither may reach the report raw.
  // The helper's printable-ASCII guard is skipped for these two runs: it runs before the run returns, so with
  // it on the raw-character check below could never be the assertion that fails.
  const scope = runCheck({
    flow: {
      nodes: [{ id: "15", reversible: true }],
      decisions: [{ node: "15", decision_id: "D-001", note: "\u53d6\u6570\u8303\u56f4\u5df2\u5ba1\u6279" }],
    },
    ledger: ledgerText([record({ scope: "\u4e1a\u52a1/other.json" })]),
  }, { assertAscii: false });
  assert.strictEqual(scope.status, 0, scope.stderr);
  assert.ok(!/[\u0080-\uFFFF]/.test(scope.stdout), "no raw non-ASCII character in stdout");
  assert.match(scope.stdout, /DECISION_SCOPE_INVALID/);
  assert.match(scope.stdout, /scope="\\u4E1A\\u52A1\/other\.json"/);
  assert.match(scope.stdout, PRINTABLE_ASCII, "stdout must be printable ASCII");

  const decisionId = runCheck({
    flow: {
      nodes: [{ id: "15", reversible: true }],
      decisions: [{ node: "15", decision_id: "\u51b3\u7b56-1" }],
    },
    ledger: ledgerText([record({})]),
  }, { assertAscii: false });
  assert.strictEqual(decisionId.status, 0, decisionId.stderr);
  assert.ok(!/[\u0080-\uFFFF]/.test(decisionId.stdout), "no raw non-ASCII character in stdout");
  assert.match(decisionId.stdout, /DECISION_NOT_IN_LEDGER .*decision=\\u51B3\\u7B56-1 not found/);
  assert.match(decisionId.stdout, PRINTABLE_ASCII, "stdout must be printable ASCII");
});
