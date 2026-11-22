#!/usr/bin/env node
// Self-test for the neutral entry and the harness.
//
// It runs all five hold-out cases (not just the ones wired into the report yet) and prints
// HARNESS_SELFTEST ok=<passed>/<total>. Exit 0 only when every case comes back as expected.
// Sandboxes live under <work-root>/logs/harness-selftest/ and are removed by run-case.js.

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const repoRoot = path.resolve(__dirname, '..', '..');
const workArg = process.argv.indexOf('--work-root');
const workRoot = workArg >= 0 ? path.resolve(process.argv[workArg + 1]) : path.join(repoRoot, 'business');
const adversarialRoot = path.join(repoRoot, 'tests', 'adversarial');
const runner = path.join(__dirname, 'run-case.js');

const ids = [];
for (const dir of fs.readdirSync(adversarialRoot, { withFileTypes: true })) {
  if (!dir.isDirectory()) continue;
  for (const name of fs.readdirSync(path.join(adversarialRoot, dir.name))) {
    if (name.endsWith('.json')) ids.push(dir.name + '/' + name.slice(0, -5));
  }
}
ids.sort();

const stamp = Date.now().toString(36) + Math.random().toString(16).slice(2, 8);
let passed = 0;

for (const id of ids) {
  const sandbox = path.join(workRoot, 'logs', 'harness-selftest', 'selftest-' + stamp, id.replace('/', '-'));
  const res = spawnSync(process.execPath, [runner, '--case', id, '--repo-root', repoRoot, '--sandbox', sandbox], { encoding: 'utf8' });
  const line = (res.stdout || '').split(/\r?\n/).reverse().find((l) => l.startsWith('HARNESS_CASE_RESULT='));
  let ok = false;
  let detail = '';
  if (line) {
    try {
      const result = JSON.parse(line.slice('HARNESS_CASE_RESULT='.length));
      ok = result.ok === true;
      detail = result.detail || '';
    } catch (err) {
      detail = 'result line is not valid JSON: ' + err.message;
    }
  } else {
    detail = 'no result line';
  }
  if (ok) passed++;
  console.log('CASE ' + id + ' ok=' + (ok ? 'true' : 'false') + (detail ? ' detail=' + detail : ''));
  if (!ok && res.stderr) {
    const first = (res.stderr.split(/\r?\n/).find((l) => l.trim()) || '').trim();
    if (first) console.log('STDERR ' + first);
  }
}

console.log('HARNESS_SELFTEST ok=' + passed + '/' + ids.length);
process.exit(passed === ids.length && ids.length > 0 ? 0 : 1);
