#!/usr/bin/env node
// Run one adversarial case against the neutral entry.
//
// The case file (tests/adversarial/<category>/<name>.json) owns only given/when/expected/why; it does not say
// how to run. This runner supplies the executable subject, the real fault injection and the restore step:
//
//   subject  tests/harness/entry/mini-entry.js
//   inject   real filesystem preparation inside a throw-away sandbox, one strategy per case id
//   restore  the whole sandbox is deleted in finally; nothing outside it is written
//
// Assertion rule: only expected.exit_code / expected.status are compared, plus an existence check that a
// preflight failure (exit 2) created no new product. side_effects prose is recorded in the evidence only.

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

function parseArgs(argv) {
  const o = { case: null, repoRoot: null, sandbox: null };
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--case': o.case = argv[++i]; break;
      case '--repo-root': o.repoRoot = argv[++i]; break;
      case '--sandbox': o.sandbox = argv[++i]; break;
      default: break;
    }
  }
  return o;
}

function asciiJson(value) {
  return JSON.stringify(value).replace(/[^\x20-\x7E]/g, (c) => '\\u' + c.charCodeAt(0).toString(16).padStart(4, '0'));
}

function listFiles(dir) {
  if (!fs.existsSync(dir)) return [];
  const out = [];
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) walk(p);
      else out.push(path.relative(dir, p).split(path.sep).join('/'));
    }
  };
  walk(dir);
  return out.sort();
}

function writeJson(sandbox, name, value) {
  const p = path.join(sandbox, name);
  fs.writeFileSync(p, JSON.stringify(value), 'utf8');
  return p;
}

function prepare(sandbox, caseId) {
  const out = path.join(sandbox, 'out');
  const mkOut = () => fs.mkdirSync(out, { recursive: true });
  switch (caseId) {
    case 'input/missing-input-file':
      mkOut();
      return { outDir: out, args: ['--in', path.join(sandbox, 'input-missing.json')] };
    case 'env/output-directory-missing':
      return { outDir: path.join(sandbox, 'out-missing'), args: ['--in', writeJson(sandbox, 'input.json', [{ key: 'A' }])] };
    case 'output/empty-file':
      mkOut();
      return { outDir: out, args: ['--in', writeJson(sandbox, 'empty.json', [])] };
    case 'data/duplicate-key':
      mkOut();
      return { outDir: out, args: ['--in', writeJson(sandbox, 'dupes.json', [{ key: 'A' }, { key: 'A' }])] };
    case 'auth/expired-session':
      mkOut();
      return {
        outDir: out,
        args: ['--in', writeJson(sandbox, 'input.json', [{ key: 'A' }]), '--auth-state', writeJson(sandbox, 'auth.json', { state: 'expired' })],
      };
    default:
      return null;
  }
}

function readStatus(resultFile, exitCode) {
  if (resultFile && fs.existsSync(resultFile)) {
    for (const line of fs.readFileSync(resultFile, 'utf8').split(/\r?\n/)) {
      const m = /^STATUS:\s*([A-Z_]+)\s*$/.exec(line.trim());
      if (m) return m[1];
    }
  }
  const map = { 0: 'OK', 1: 'PARTIAL', 2: 'ENV_ERROR', 3: 'NEEDS_HUMAN' };
  return Object.prototype.hasOwnProperty.call(map, exitCode) ? map[exitCode] : null;
}

function main() {
  const o = parseArgs(process.argv.slice(2));
  if (!o.case || !o.repoRoot || !o.sandbox) {
    process.stdout.write('HARNESS_CASE_ERROR missing --case / --repo-root / --sandbox\n');
    return 2;
  }
  const repoRoot = path.resolve(o.repoRoot);
  const sandbox = path.resolve(o.sandbox);
  const caseFile = path.join(repoRoot, 'tests', 'adversarial', o.case + '.json');
  const entry = path.join(repoRoot, 'tests', 'harness', 'entry', 'mini-entry.js');

  if (!fs.existsSync(caseFile)) {
    process.stdout.write('HARNESS_CASE_ERROR case file not found: ' + caseFile + '\n');
    return 2;
  }
  if (!fs.existsSync(entry)) {
    process.stdout.write('HARNESS_CASE_ERROR entry not found: ' + entry + '\n');
    return 2;
  }

  let record;
  try {
    record = JSON.parse(fs.readFileSync(caseFile, 'utf8'));
  } catch (err) {
    process.stdout.write('HARNESS_CASE_ERROR case file is not valid JSON: ' + err.message + '\n');
    return 2;
  }
  const expected = record.expected || {};

  fs.mkdirSync(sandbox, { recursive: true });
  const prep = prepare(sandbox, o.case);
  if (!prep) {
    process.stdout.write('HARNESS_CASE_ERROR no fault-injection strategy for case: ' + o.case + '\n');
    fs.rmSync(sandbox, { recursive: true, force: true });
    return 2;
  }

  const resultFile = path.join(sandbox, 'result.txt');
  const before = listFiles(prep.outDir);
  const argv = [entry, ...prep.args, '--out-dir', prep.outDir, '--result-file', resultFile];
  const res = spawnSync(process.execPath, argv, { encoding: 'utf8' });
  const after = listFiles(prep.outDir);
  const added = after.filter((f) => !before.includes(f));

  if (res.error || res.status === null) {
    process.stdout.write('HARNESS_CASE_ERROR entry did not run: ' + (res.error ? res.error.message : 'terminated by signal') + '\n');
    fs.rmSync(sandbox, { recursive: true, force: true });
    return 2;
  }

  const exitCode = res.status;
  const status = readStatus(resultFile, exitCode);
  const reasons = [];
  if (Object.prototype.hasOwnProperty.call(expected, 'exit_code')) {
    if (exitCode !== Number(expected.exit_code)) reasons.push('exit_code expected ' + expected.exit_code + ' got ' + exitCode);
  }
  if (Object.prototype.hasOwnProperty.call(expected, 'status')) {
    if (status !== expected.status) reasons.push('status expected ' + expected.status + ' got ' + status);
  }
  if (!Object.prototype.hasOwnProperty.call(expected, 'exit_code') && !Object.prototype.hasOwnProperty.call(expected, 'status')) {
    reasons.push('case declares no expectation');
  }
  if (Number(expected.exit_code) === 2 && added.length > 0) {
    reasons.push('preflight failure produced ' + added.length + ' new product(s): ' + added.join(','));
  }

  const payload = {
    case: o.case,
    subject: 'tests/harness/entry/mini-entry.js',
    ok: reasons.length === 0,
    expected,
    observed: { exit_code: exitCode, status, new_products: added.length, added },
    detail: reasons.join('; '),
  };
  process.stdout.write('HARNESS_CASE_RESULT=' + asciiJson(payload) + '\n');

  fs.rmSync(sandbox, { recursive: true, force: true });
  return 0;
}

process.exit(main());
