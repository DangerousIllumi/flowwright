// check-decisions-supersede-nodes.test.js - unit tests for the supersede chain and the batch node list
// (node --test)
//
// Two rules are covered here:
//   - DECISION_SUPERSEDED: a ledger row may carry `supersedes: "<old-id>"`. The old row stays for the audit
//     trail, but it is revoked, so citing it fails - from a flow's decisions array and from the output-root
//     registry.
//   - DECISION_NODE_NOT_IN_RECORD / DECISION_NODES_EMPTY: a record that lists `nodes` authorises exactly
//     those nodes. No `nodes` field means a single-node citation, not "every node".
// Usage: node --test tools/verify/check-decisions-supersede-nodes.test.js
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const CLI = path.join(__dirname, "check-decisions.js");
const PRINTABLE_ASCII = /^[\x20-\x7E\r\n\t]*$/;

function record(overrides) {
  return Object.assign({
    id: "D-001",
    class: "risk",
    scope: "global",
    decision: "decided for the test",
    decided_by: "user",
    decided_at: "2026-11-19",
  }, overrides);
}

function ledgerText(records) {
  return records.map((r) => JSON.stringify(r)).join("\n") + (records.length ? "\n" : "");
}

/** Throwaway repo with a business flow and a ledger; run the CLI and assert the report is printable ASCII. */
function runCheck(options) {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), "check-decisions-snod-"));
  // business/flows/ is what makes this a business flow: a flow outside business/ that cites nothing is
  // skipped, and a skipped flow never reads the ledger, so the ledger-only rules could not be exercised.
  fs.mkdirSync(path.join(repo, "business", "flows"), { recursive: true });
  const flowPath = path.join(repo, "business", "flows", "x.json");
  fs.writeFileSync(flowPath, JSON.stringify(options.flow, null, 2), "utf8");
  if (options.ledger !== undefined) {
    fs.writeFileSync(path.join(repo, "business", "decisions.jsonl"), options.ledger, "utf8");
  }
  const mode = options.mode || "fail";
  const r = spawnSync(process.execPath, [CLI, flowPath, "--repo", repo, "--mode=" + mode], { encoding: "utf8" });
  const stdout = r.stdout || "";
  assert.match(stdout, PRINTABLE_ASCII, "stdout must be printable ASCII, got: " + JSON.stringify(stdout));
  return { status: r.status, stdout, stderr: r.stderr || "" };
}

// ── DECISION_SUPERSEDED ────────────────────────────────────────────────

test("DECISION_SUPERSEDED: citing a record that a later row supersedes fails", () => {
  const r = runCheck({
    flow: {
      nodes: [{ id: "15", reversible: false }],
      decisions: [{ node: "15", decision_id: "D-001" }],
    },
    ledger: ledgerText([
      record({ id: "D-001", decided_by: "agent(recorded)" }),
      record({ id: "D-011", decided_by: "user", supersedes: "D-001" }),
    ]),
  });
  assert.strictEqual(r.status, 1, r.stderr);
  assert.match(r.stdout, /DECISION_SUPERSEDED decision=D-001 node=15 has been superseded/);
  assert.match(r.stdout, /failed: \d+ violation\(s\)/);
});

test("a record that supersedes another is not itself superseded: citing it passes", () => {
  const r = runCheck({
    flow: {
      nodes: [{ id: "15", reversible: false }],
      decisions: [{ node: "15", decision_id: "D-011" }],
    },
    ledger: ledgerText([
      record({ id: "D-001", decided_by: "agent(recorded)" }),
      record({ id: "D-011", decided_by: "user", supersedes: "D-001" }),
    ]),
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.match(r.stdout, /passed/);
  assert.doesNotMatch(r.stdout, /DECISION_SUPERSEDED/);
});

test("a record nobody supersedes can still be cited (D-002 / D-005 style rows)", () => {
  const r = runCheck({
    flow: {
      nodes: [{ id: "15", reversible: false }],
      decisions: [{ node: "15", decision_id: "D-002" }],
    },
    ledger: ledgerText([
      record({ id: "D-001" }),
      record({ id: "D-002", class: "risk", decided_by: "user" }),
      record({ id: "D-011", supersedes: "D-001" }),
    ]),
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.doesNotMatch(r.stdout, /DECISION_SUPERSEDED/);
});

test("the supersede chain is two deep: the middle row is revoked too", () => {
  const r = runCheck({
    flow: {
      nodes: [{ id: "15", reversible: false }],
      decisions: [{ node: "15", decision_id: "D-011" }],
    },
    ledger: ledgerText([
      record({ id: "D-001" }),
      record({ id: "D-011", supersedes: "D-001" }),
      record({ id: "D-020", supersedes: "D-011" }),
    ]),
  });
  assert.strictEqual(r.status, 1, r.stderr);
  assert.match(r.stdout, /DECISION_SUPERSEDED decision=D-011/);
});

test("a supersedes pointer to an id that is not in the ledger is reported", () => {
  const r = runCheck({
    flow: { nodes: [{ id: "15", reversible: true }], decisions: [] },
    ledger: ledgerText([record({ id: "D-011", supersedes: "D-404" })]),
  });
  assert.strictEqual(r.status, 1, r.stderr);
  assert.match(r.stdout, /LEDGER_UNREADABLE .*supersedes D-404, which is not a record in this ledger/);
});

// ── nodes: batch authorisation ─────────────────────────────────────────

test("DECISION_NODE_NOT_IN_RECORD: a node outside the record's list fails", () => {
  const r = runCheck({
    flow: {
      nodes: [{ id: "15", reversible: false }],
      decisions: [{ node: "15", decision_id: "D-020" }],
    },
    ledger: ledgerText([record({ id: "D-020", nodes: ["11", "12"] })]),
  });
  assert.strictEqual(r.status, 1, r.stderr);
  assert.match(r.stdout, /DECISION_NODE_NOT_IN_RECORD decision=D-020 node=15 is not in the record's node list \(11,12\)/);
});

test("a node inside the record's list passes", () => {
  const r = runCheck({
    flow: {
      nodes: [{ id: "11", reversible: false }],
      decisions: [{ node: "11", decision_id: "D-020" }],
    },
    ledger: ledgerText([record({ id: "D-020", nodes: ["11", "12"] })]),
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.doesNotMatch(r.stdout, /DECISION_NODE_NOT_IN_RECORD/);
});

test("no nodes field means a single-node citation, not 'every node'", () => {
  // The record carries no node list, so it is a single-node citation and the citation is accepted.
  const r = runCheck({
    flow: {
      nodes: [{ id: "15", reversible: false }],
      decisions: [{ node: "15", decision_id: "D-020" }],
    },
    ledger: ledgerText([record({ id: "D-020" })]),
  });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.doesNotMatch(r.stdout, /DECISION_NODE_NOT_IN_RECORD/);
});

test("DECISION_NODES_EMPTY: an empty node list is a malformed record, not a wildcard", () => {
  const r = runCheck({
    flow: { nodes: [{ id: "15", reversible: true }], decisions: [] },
    ledger: ledgerText([record({ id: "D-020", nodes: [] })]),
  });
  assert.strictEqual(r.status, 1, r.stderr);
  assert.match(r.stdout, /DECISION_NODES_EMPTY decision=D-020 nodes is an empty array/);
});

test("DECISION_NODES_INVALID: nodes must be an array of non-empty strings", () => {
  const r = runCheck({
    flow: { nodes: [{ id: "15", reversible: true }], decisions: [] },
    ledger: ledgerText([record({ id: "D-020", nodes: "15" })]),
  });
  assert.strictEqual(r.status, 1, r.stderr);
  assert.match(r.stdout, /DECISION_NODES_INVALID decision=D-020 nodes must be an array of node ids/);
});
