// drawio-to-flow.test.js — read-back tests (node --test)
//
// drawio-to-flow.js is CLI-only (no module.exports, process.argv is read at load time), so every case spawns it.
// Canvases come from flow-to-drawio-bfs.js rather than flow-to-drawio.js: the elkjs build needs node_modules/elkjs,
// which CI does not install, while the BFS build emits identical edge objects (same ids, from/to and labels) and
// needs only fs. The whole round trip is therefore exercised without stubbing anything.
//
// Usage: node --test tools/flow-drawio/drawio-to-flow.test.js
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const GEN = path.join(__dirname, "flow-to-drawio-bfs.js");
const READBACK = path.join(__dirname, "drawio-to-flow.js");

/** A neutral action node; extras override the defaults */
function action(id, extras) {
  return Object.assign(
    { id, label: `Node ${id}`, type: "action", pad_hint: "Test.Log", params: {}, next: [], run_mode: "auto", idempotent: true, reversible: true },
    extras || {}
  );
}

function baseFlow(nodes) {
  return { name: "probe", trigger: { kind: "manual" }, budget: { maxLoop: 1 }, nodes };
}

/** IF(1) -> true:2 / false:3, both paths rejoin at 3 */
function ifFlow() {
  return baseFlow([
    {
      id: "1", label: "Check", type: "branch", pad_hint: "IF",
      params: { Condition: "X > 0" },
      next: ["3"],
      branch: { condition: "X > 0", true: "2", false: "3", body: ["2"] },
      run_mode: "auto", idempotent: true, reversible: true,
    },
    action("2", { next: ["3"] }),
    action("3"),
  ]);
}

/**
 * Generate a canvas from `flow`, optionally rewrite its edge labels, then read it back.
 * Returns the change summary text and the parsed read-back flow.
 */
function roundTrip(flow, editCanvas) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "d2f-"));
  const flowPath = path.join(dir, "flow.json");
  const drawioPath = path.join(dir, "flow.drawio");
  const backPath = path.join(dir, "back.json");
  fs.writeFileSync(flowPath, JSON.stringify(flow, null, 2), "utf8");

  const gen = spawnSync(process.execPath, [GEN, flowPath, drawioPath], { encoding: "utf8" });
  assert.strictEqual(gen.status, 0, `canvas generation failed: ${gen.stderr}`);
  if (editCanvas) fs.writeFileSync(drawioPath, editCanvas(fs.readFileSync(drawioPath, "utf8")), "utf8");

  const back = spawnSync(process.execPath, [READBACK, drawioPath, flowPath, backPath], { encoding: "utf8" });
  assert.strictEqual(back.status, 0, `read-back failed: ${back.stderr}`);
  return { summary: back.stdout, flow: JSON.parse(fs.readFileSync(backPath, "utf8")) };
}

function nodeById(flow, id) {
  const found = flow.nodes.find((n) => n.id === id);
  assert.ok(found, `read-back lost node ${id}`);
  return found;
}

test("IF with yes/no labels: branch.true, branch.body, branch.false and next are rebuilt", () => {
  const n1 = nodeById(roundTrip(ifFlow()).flow, "1");
  assert.ok(n1.branch, "an IF with a yes edge must come back with a branch field");
  assert.strictEqual(n1.branch.true, "2", "branch.true must be the yes target");
  assert.deepStrictEqual(n1.branch.body, ["2"], "branch.body must list every yes target in canvas order");
  assert.strictEqual(n1.branch.false, "3", "branch.false must be the no target");
  assert.deepStrictEqual(n1.next, ["3"], "next must hold the false target (the join point)");
  assert.strictEqual(n1.branch.condition, "X > 0", "branch.condition must be copied from params.Condition");
});

test("IF with the legacy translated labels: identical result to the yes/no case", () => {
  const { flow } = roundTrip(ifFlow(), (xml) => xml.replace('label="yes"', 'label="是"').replace('label="no"', 'label="否"'));
  const n1 = nodeById(flow, "1");
  assert.strictEqual(n1.branch.true, "2", "the legacy true label must be read as the true branch");
  assert.strictEqual(n1.branch.false, "3", "the legacy false label must be read as the false branch");
  assert.deepStrictEqual(n1.next, ["3"], "next must still hold only the join point");
});

test("IF with unlabelled edges: everything goes to next and no branch is invented", () => {
  const { flow } = roundTrip(ifFlow(), (xml) => xml.replace(' label="yes"', "").replace(' label="no"', ""));
  const n1 = nodeById(flow, "1");
  assert.strictEqual("branch" in n1, false, "an unlabelled canvas must not produce a branch field");
  assert.deepStrictEqual(n1.next, ["2", "3"], "unlabelled edges must all land in next, in canvas order");
});

test("IF with mixed-case labels (Yes / NO): still grouped correctly", () => {
  const { flow } = roundTrip(ifFlow(), (xml) => xml.replace('label="yes"', 'label="Yes"').replace('label="no"', 'label="NO"'));
  const n1 = nodeById(flow, "1");
  assert.strictEqual(n1.branch.true, "2", "label matching must be case-insensitive for the true group");
  assert.strictEqual(n1.branch.false, "3", "label matching must be case-insensitive for the false group");
});

test("plain sequential nodes: edges stay in next and no branch appears", () => {
  const flow = baseFlow([action("1", { next: ["2"] }), action("2", { next: ["3"] }), action("3")]);
  const { flow: back, summary } = roundTrip(flow);
  const n1 = nodeById(back, "1");
  assert.strictEqual("branch" in n1, false, "an ordinary node must never gain a branch field");
  assert.deepStrictEqual(n1.next, ["2"], "an ordinary node keeps its next edge");
  assert.match(summary, /changed: 0/, "a plain chain must round-trip without changes");
});

test("SWITCH whose case value is literally yes: not treated as a branch", () => {
  const flow = baseFlow([
    {
      id: "1", label: "Pick", type: "branch", pad_hint: "SWITCH", params: {},
      next: ["4"],
      switch: { cases: [{ case: "yes", body: ["2"] }, { case: "no", body: ["3"] }], default: ["4"] },
      run_mode: "auto", idempotent: true, reversible: true,
    },
    action("2", { next: ["4"] }),
    action("3", { next: ["4"] }),
    action("4"),
  ]);
  const n1 = nodeById(roundTrip(flow).flow, "1");
  assert.strictEqual("branch" in n1, false, "a SWITCH must never be mistaken for a branch, even with a case named yes");
  assert.ok(n1.next.includes("2") && n1.next.includes("3"), "case targets must stay in next");
});

test("end to end on the shipped example: added 0, removed 0, changed 0", () => {
  const example = path.join(__dirname, "example-flow.json");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "d2f-example-"));
  const drawioPath = path.join(dir, "example.drawio");
  const backPath = path.join(dir, "example.back.json");

  const gen = spawnSync(process.execPath, [GEN, example, drawioPath], { encoding: "utf8" });
  assert.strictEqual(gen.status, 0, `generating the example canvas failed: ${gen.stderr}`);
  const back = spawnSync(process.execPath, [READBACK, drawioPath, example, backPath], { encoding: "utf8" });
  assert.strictEqual(back.status, 0, `reading the example canvas back failed: ${back.stderr}`);
  assert.match(back.stdout, /added: 0, removed: 0, changed: 0/, `the example must round-trip losslessly, got:\n${back.stdout}`);
});

// ── Fields the canvas does not carry ─────────────────────────────
// The canvas has no place for decisions/budget/acceptance, so the read-back must inherit them from an
// authoritative flow.json: <dir>/<name>.json for a <dir>/<name>.new.json target. Only when that file is absent
// does it fall back to the <orig.flow.json> argument, and then it must say so on stderr.

const BUDGET = { maxLoop: 4, note: "inherited budget" };
const ACCEPTANCE = {
  description: "inherited acceptance",
  checks: [{ name: "result file", type: "fileExists", path: "result.txt", minBytes: 1 }],
};
const DECISIONS = [{ node: "2", decision_id: "D-001", note: "risk node accepted" }];

/** The nodes are always the same; extras add the optional top-level fields. */
function chainFlow(extras) {
  return Object.assign(
    { name: "inherit", trigger: { kind: "manual" }, nodes: [action("1", { next: ["2"] }), action("2")] },
    extras || {}
  );
}

function generateCanvas(flowPath, drawioPath) {
  const gen = spawnSync(process.execPath, [GEN, flowPath, drawioPath], { encoding: "utf8" });
  assert.strictEqual(gen.status, 0, `canvas generation failed: ${gen.stderr}`);
}

/** Read `drawioPath` back into <dir>/<name>.new.json (with `origPath` as the original) and return the result. */
function readBack(dir, name, drawioPath, origPath) {
  const backPath = path.join(dir, name + ".new.json");
  const back = spawnSync(process.execPath, [READBACK, drawioPath, origPath, backPath], { encoding: "utf8" });
  assert.strictEqual(back.status, 0, `read-back failed: ${back.stderr}`);
  return { stdout: back.stdout, stderr: back.stderr, flow: JSON.parse(fs.readFileSync(backPath, "utf8")) };
}

test("read-back inherits decisions, budget and acceptance from the same-directory <name>.json", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "d2f-inherit-"));
  const source = chainFlow({ budget: BUDGET, acceptance: ACCEPTANCE, decisions: DECISIONS });
  const sourcePath = path.join(dir, "keep.json");
  fs.writeFileSync(sourcePath, JSON.stringify(source, null, 2), "utf8");
  const drawioPath = path.join(dir, "keep.drawio");
  generateCanvas(sourcePath, drawioPath);

  // <orig.flow.json> has none of the three fields, so they can only have come from keep.json.
  const origPath = path.join(dir, "keep.orig.json");
  fs.writeFileSync(origPath, JSON.stringify(chainFlow(), null, 2), "utf8");

  const { flow, stderr } = readBack(dir, "keep", drawioPath, origPath);
  assert.deepStrictEqual(flow.decisions, DECISIONS, "decisions must be inherited from keep.json");
  assert.deepStrictEqual(flow.budget, BUDGET, "budget must be inherited from keep.json");
  assert.deepStrictEqual(flow.acceptance, ACCEPTANCE, "acceptance must be inherited from keep.json");
  assert.doesNotMatch(stderr, /DRAWIO_ROUNDTRIP_NO_SOURCE_FLOW/, "a present source flow must not warn");
});

test("without a same-directory <name>.json: fall back to the original flow and warn on stderr", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "d2f-fallback-"));
  const orig = chainFlow({ budget: BUDGET, acceptance: ACCEPTANCE, decisions: DECISIONS });
  const origPath = path.join(dir, "orig-flow.json");
  fs.writeFileSync(origPath, JSON.stringify(orig, null, 2), "utf8");
  const drawioPath = path.join(dir, "fallback.drawio");
  generateCanvas(origPath, drawioPath);

  // <dir>/fallback.json is deliberately absent, so the read-back target fallback.new.json has no source beside it.
  const { flow, stderr } = readBack(dir, "fallback", drawioPath, origPath);
  assert.deepStrictEqual(flow.decisions, DECISIONS, "decisions must fall back to the original flow");
  assert.deepStrictEqual(flow.budget, BUDGET, "budget must fall back to the original flow");
  assert.deepStrictEqual(flow.acceptance, ACCEPTANCE, "acceptance must fall back to the original flow");

  const warningLines = stderr.split(/\r?\n/).filter((line) => line.startsWith("DRAWIO_ROUNDTRIP_NO_SOURCE_FLOW:"));
  assert.strictEqual(warningLines.length, 1, `expected exactly one DRAWIO_ROUNDTRIP_NO_SOURCE_FLOW line, stderr:\n${stderr}`);
  assert.match(warningLines[0], /no fallback\.json next to fallback\.new\.json/, "the warning must name the missing source");
  assert.match(warningLines[0], /^[\x00-\x7f]*$/, "the warning line must be pure ASCII");
});

test("a source without the fields leaves them out of the output entirely", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "d2f-absent-"));
  const plain = chainFlow(); // no decisions / budget / acceptance anywhere
  const origPath = path.join(dir, "plain.json");
  fs.writeFileSync(origPath, JSON.stringify(plain, null, 2), "utf8");
  const drawioPath = path.join(dir, "plain.drawio");
  generateCanvas(origPath, drawioPath);

  // No <dir>/plain-back.json exists either, so the fallback source is the only candidate.
  const { flow } = readBack(dir, "plain-back", drawioPath, origPath);
  assert.strictEqual("decisions" in flow, false, "decisions must not be invented when no source defines it");
  assert.strictEqual("budget" in flow, false, "budget must not be invented when no source defines it");
  assert.strictEqual("acceptance" in flow, false, "acceptance must not be invented when no source defines it");
});
