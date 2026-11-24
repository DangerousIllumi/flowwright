#!/usr/bin/env node
// Self-test for the neutral entry and the harness.
//
// It runs the hold-out cases whose subject is the neutral entry (the ones listed as implemented in
// tests/harness/cases.json) and prints HARNESS_SELFTEST ok=<passed>/<total>. Exit 0 only when every
// case comes back as expected. A case whose subject is a verification gate has no entry strategy here:
// it is triggered by tests/gate-cases.Tests.ps1, which runs the gate itself.
// Sandboxes live under <work-root>/logs/harness-selftest/ and are removed by run-case.js.

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const repoRoot = path.resolve(__dirname, '..', '..');
const workArg = process.argv.indexOf('--work-root');
const workRoot = workArg >= 0 ? path.resolve(process.argv[workArg + 1]) : path.join(repoRoot, 'business');
const runner = path.join(__dirname, 'run-case.js');

// Only the cases with a fault-injection strategy in run-case.js can be executed here. The set may
// also hold cases whose subject is a verification gate; those have their own trigger and are run by
// tests/gate-cases.Tests.ps1.
const casesConfigPath = path.join(repoRoot, 'tests', 'harness', 'cases.json');
const harness = JSON.parse(fs.readFileSync(casesConfigPath, 'utf8'));
const ids = (harness.implemented || []).slice().sort();

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
