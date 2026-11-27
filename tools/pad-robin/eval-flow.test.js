// eval-flow.test.js - unit tests for the NO_UI_ACTIONS_BUT_PAD warn-only rule (node --test)
//
// Covers: KB-based UI classification, the explicit fallback prefix list used when the KB is missing,
// the noUiActionsButPad assertion op, and the CLI behavior (warning on stderr, exit code unaffected).
// Usage: node --test tools/pad-robin/eval-flow.test.js
const test = require("node:test");
const assert = require("node:assert");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const {
  OPS,
  runCase,
  loadActionKb,
  isUiActionHint,
  hasNoUiAction,
  UI_ACTION_PREFIXES_FALLBACK,
} = require("./eval-flow.js");

const REPO = path.resolve(__dirname, "..", "..");
const CLI = path.join(__dirname, "eval-flow.js");

test("KB loads and flags a recorded UI action as UI-class", () => {
  const ui = loadActionKb();
  assert.ok(ui, "the action KB must load in this repository");
  assert.ok(ui.has("UIAutomation.Click.Click"), "UIAutomation.Click.Click is needs_ui_selector=true in the KB");
  assert.ok(!ui.has("Display.ShowMessageDialog.ShowMessage"), "a human dialog is not a UI action");
  assert.ok(!ui.has("WebAutomation.ExecuteJavascript"), "the DOM lane needs no recorded element");
  assert.ok(isUiActionHint("UIAutomation.Click.Click", ui));
  assert.ok(!isUiActionHint("Display.ShowMessageDialog.ShowMessage", ui));
  assert.ok(!isUiActionHint("IF", ui), "control-flow pseudo actions are never UI-class");
  assert.ok(!isUiActionHint("Scripting.RunDOSCommand.RunDOSCommand", ui));
});

test("fallback prefix list is used when the KB is unavailable, and never hard-guesses unknown ids", () => {
  const ui = null; // simulate a missing KB
  assert.ok(isUiActionHint("WebAutomation.PopulateTextField.PopulateTextField", ui));
  assert.ok(isUiActionHint("UIAutomation.PressButton", ui));
  assert.ok(isUiActionHint("MouseAndKeyboard.SendKeys.FocusAndSendKeysByControl", ui));
  assert.ok(!isUiActionHint("WebAutomation.ExecuteJavascript", ui));
  assert.ok(!isUiActionHint("Display.ShowMessageDialog.ShowMessage", ui));
  assert.ok(!isUiActionHint("File.WriteText", ui));
  // every fallback prefix must be a real actionId prefix in the shipped KB
  const kb = loadActionKb();
  assert.ok(kb, "KB present so the fallback list can be verified against it");
  for (const p of UI_ACTION_PREFIXES_FALLBACK) {
    if (p.endsWith(".")) {
      assert.ok([...kb].some((id) => id.startsWith(p)), `fallback prefix ${p} must match real KB actionIds`);
    } else {
      assert.ok(kb.has(p), `fallback entry ${p} must be a real KB actionId`);
    }
  }
});

test("hasNoUiAction: empty flow is not flagged, UI flow is not flagged, script-only flow is flagged", () => {
  const ui = loadActionKb();
  assert.strictEqual(hasNoUiAction({ nodes: [] }, ui), false);
  assert.strictEqual(
    hasNoUiAction({ nodes: [{ id: "1", pad_hint: "UIAutomation.Click.Click" }] }, ui),
    false
  );
  assert.strictEqual(
    hasNoUiAction(
      { nodes: [
        { id: "1", pad_hint: "Scripting.RunDOSCommand.RunDOSCommand" },
        { id: "2", pad_hint: "Display.ShowMessageDialog.ShowMessage" },
      ] },
      ui
    ),
    true
  );
});

test("op noUiActionsButPad: expect=warn fires only on UI-less flows; expect=present only on UI flows", () => {
  const scriptOnly = {
    nodes: [
      { id: "1", pad_hint: "Scripting.RunDOSCommand.RunDOSCommand" },
      { id: "2", pad_hint: "Display.ShowMessageDialog.ShowMessage" },
    ],
  };
  const withUi = { nodes: [{ id: "1", pad_hint: "UIAutomation.Click.Click" }] };
  assert.strictEqual(OPS.noUiActionsButPad(scriptOnly, { expect: "warn" }).ok, true);
  assert.strictEqual(OPS.noUiActionsButPad(withUi, { expect: "warn" }).ok, false);
  assert.strictEqual(OPS.noUiActionsButPad(withUi, { expect: "present" }).ok, true);
  assert.strictEqual(OPS.noUiActionsButPad(scriptOnly, { expect: "present" }).ok, false);
  // runCase wiring: a case using the op passes end-to-end on the script-only fixture
  const c = { id: "c1", requirement: "r", expect: [{ op: "noUiActionsButPad", expect: "warn" }] };
  const r = runCase(scriptOnly, c);
  assert.strictEqual(r.ok, true);
});

// CLI-level cases: plain child-process spawn, asserting status / stdout / stderr like every other
// test in this repository (tools/verify/*.test.js use the same shape).
function runCli(args) {
  return spawnSync(process.execPath, [CLI, ...args], { cwd: REPO, encoding: "utf8" });
}

test("CLI: the new fixture passes and prints the NO_UI_ACTIONS_BUT_PAD warning, exit code stays 0", () => {
  const cases = path.join(REPO, "tests", "eval", "script-only-shell.cases.json");
  const r = runCli([cases]);
  assert.strictEqual(r.status, 0, r.stdout + r.stderr);
  assert.match(r.stdout, /passed 4 \/ 4/);
  assert.match(r.stderr, /NO_UI_ACTIONS_BUT_PAD .*script-only-shell\.json/);
  assert.match(r.stderr, /warn-only, exit code is not affected/);
});

test("CLI: a flow with a UI action produces no NO_UI_ACTIONS_BUT_PAD warning and still exits 0", () => {
  const fs = require("node:fs");
  const os = require("node:os");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "eval-flow-ui-"));
  const flow = path.join(dir, "ui.json");
  fs.writeFileSync(
    flow,
    JSON.stringify({
      name: "ui",
      trigger: { kind: "manual" },
      nodes: [{ id: "1", pad_hint: "UIAutomation.Click.Click", run_mode: "auto", idempotent: true, reversible: true }],
    })
  );
  const r = runCli([flow]);
  assert.strictEqual(r.status, 0, r.stdout + r.stderr);
  assert.doesNotMatch(r.stderr, /NO_UI_ACTIONS_BUT_PAD/);
});
