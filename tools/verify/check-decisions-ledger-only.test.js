// check-decisions-ledger-only.test.js - unit tests for the ledger-only mode (node --test)
//
// --ledger-only validates the shared ledger's schema with no flow input at all. It is the prerequisite for
// flipping the per-flow gate to fail (one dirty historical row would otherwise fail every flow at once), so
// it has to be strict on its own and able to exit 1.
// Usage: node --test tools/verify/check-decisions-ledger-only.test.js
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

/**
 * Run --ledger-only against a throwaway repo; `ledger: null` leaves the business/ dir without a ledger.
 * `opts.assertAscii === false` leaves the printable-ASCII check to the caller: a test that asserts the
 * escaping on the raw output itself cannot use a helper whose guard runs first, or its own assertion
 * would be unable to fail.
 */
function runLedgerOnly(options = {}, opts = {}) {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), "check-decisions-ledger-"));
  if (options.business !== false) {
    fs.mkdirSync(path.join(repo, "business"), { recursive: true });
    if (options.ledger != null) {
      fs.writeFileSync(path.join(repo, "business", "decisions.jsonl"), options.ledger, "utf8");
    }
  }
  const args = [CLI, "--ledger-only", "--repo", repo];
  if (options.extra) args.push(...options.extra);
  const r = spawnSync(process.execPath, args, { encoding: "utf8" });
  const stdout = r.stdout || "";
  if (opts.assertAscii !== false) {
    assert.match(stdout, PRINTABLE_ASCII, "stdout must be printable ASCII, got: " + JSON.stringify(stdout));
  }
  return { status: r.status, stdout, stderr: r.stderr || "" };
}

test("clean ledger: no flow input needed, exit 0", () => {
  const r = runLedgerOnly({ ledger: ledgerText([record({}), record({ id: "D-002", class: "standard" })]) });
  assert.strictEqual(r.status, 0, r.stderr);
  assert.match(r.stdout, /\[check-decisions\] ledger-only passed \(ledger=business\/decisions\.jsonl records=2\)/);
  // Exact report, not just "skip: is absent": --ledger-only has no skip branch and exits on both paths, so a
  // doesNotMatch(skip:) here could never fail on any ledger input. Pinning the whole stdout fails if the
  // report ever grows an extra line (a per-flow skip/pass summary included).
  assert.strictEqual(
    r.stdout,
    "[check-decisions] ledger-only passed (ledger=business/decisions.jsonl records=2)\n",
    "the ledger-only pass must print exactly its own summary line, never a per-flow skip/pass line"
  );
});

test("scope outside the closed domain: exit 1 with the row's id", () => {
  const r = runLedgerOnly({ ledger: ledgerText([record({ scope: "business/flows/x.json" })]) });
  assert.strictEqual(r.status, 1, r.stderr);
  assert.match(r.stdout, /DECISION_SCOPE_INVALID decision=D-001 scope="business\/flows\/x\.json"/);
  assert.match(r.stdout, /ledger-only failed: 1 violation\(s\).*fix the ledger before flipping/);
});

test("class outside the closed domain: exit 1", () => {
  const r = runLedgerOnly({ ledger: ledgerText([record({ class: "approved" })]) });
  assert.strictEqual(r.status, 1, r.stderr);
  assert.match(r.stdout, /DECISION_CLASS_INVALID decision=D-001 class="approved"/);
});

test("decided_by outside the closed domain: exit 1", () => {
  const r = runLedgerOnly({ ledger: ledgerText([record({ decided_by: "robot" })]) });
  assert.strictEqual(r.status, 1, r.stderr);
  assert.match(r.stdout, /DECISION_DECIDED_BY_INVALID decision=D-001 decided_by="robot"/);
});

test("broken JSON line: exit 1 and the line number", () => {
  const r = runLedgerOnly({ ledger: ledgerText([record({})]) + '{"id":"D-002","class":' + "\n" });
  assert.strictEqual(r.status, 1, r.stderr);
  assert.match(r.stdout, /LEDGER_UNREADABLE ledger=business\/decisions\.jsonl line=2 error=/);
});

test("duplicate id: exit 1", () => {
  const r = runLedgerOnly({ ledger: ledgerText([record({}), record({})]) });
  assert.strictEqual(r.status, 1, r.stderr);
  assert.match(r.stdout, /LEDGER_UNREADABLE .*duplicate id=D-001 at line=2/);
});

test("missing ledger: exit 1, never a pass or a skip", () => {
  const r = runLedgerOnly({ ledger: null });
  assert.strictEqual(r.status, 1, r.stderr);
  assert.match(r.stdout, /LEDGER_MISSING .*this mode validates the ledger, so it must exist/);
});

test("a flow argument with --ledger-only is a usage error (exit 2), so the mode cannot silently ignore one", () => {
  const r = runLedgerOnly({ ledger: ledgerText([record({})]), extra: [path.join(os.tmpdir(), "x.json")] });
  assert.strictEqual(r.status, 2, r.stderr);
  assert.match(r.stderr, /--ledger-only takes no flow file/);
});

test("non-ASCII values are escaped as \\uXXXX", () => {
  // The helper's printable-ASCII guard is skipped for this run: it runs before the run returns, so with it
  // on the raw-character check below could never be the assertion that fails.
  const r = runLedgerOnly(
    { ledger: ledgerText([record({ scope: "\u4e1a\u52a1/x", id: "\u51b3\u7b56-1" })]) },
    { assertAscii: false }
  );
  assert.strictEqual(r.status, 1, r.stderr);
  assert.ok(!/[\u0080-\uFFFF]/.test(r.stdout), "no raw non-ASCII character in stdout");
  assert.match(r.stdout, /decision=\\u51B3\\u7B56-1/);
  assert.match(r.stdout, /scope="\\u4E1A\\u52A1\/x"/);
  assert.match(r.stdout, PRINTABLE_ASCII, "stdout must be printable ASCII");
});
