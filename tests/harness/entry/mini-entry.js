#!/usr/bin/env node
// Neutral entry used by the adversarial harness. It is not business code: it implements the
// shell contract from docs/engine-selection.md section 3.2 and tools/script-entry/entry-template.js
// so the five hold-out cases have an executable subject that returns a process exit code.
//
// Contract:
//   1. Argument parsing  every path arrives as an argument; nothing about a real machine is hard-coded
//   2. The preflight     input and output are checked BEFORE any work; a missing path exits 2
//   3. The result file   RUNNING at the start, OK:/FAIL: at the end, so a lost console still says what happened
//   4. The exit code map 0 all done, 1 some items failed, 2 parameter or environment, 3 a human must act
//
// Status tokens: NEEDS_HUMAN is already expressible as exit code 3, so no extra line is written for it.
// ABORTED and PARTIAL both have to be exit code 1, so only those two values get one extra "STATUS:" line.
// Console output is ASCII only.

'use strict';

const fs = require('fs');
const path = require('path');

const EXIT = { OK: 0, PARTIAL: 1, ENV: 2, NEEDS_HUMAN: 3 };
const STATUS = { PARTIAL: 'PARTIAL', ABORTED: 'ABORTED' };

class EnvError extends Error {}
class NeedsHumanError extends Error {}
class AbortedError extends Error {}
class PartialError extends Error {}

const USAGE = 'usage: mini-entry.js --in <file> --out-dir <dir> [--result-file <file>] [--auth-state <file>]';

function say(line) {
  process.stdout.write(String(line).replace(/[^\x09\x0A\x0D\x20-\x7E]/g, '?') + '\n');
}

function oneLine(text) {
  return String(text).replace(/\r?\n/g, ' ');
}

function writeLines(file, lines) {
  if (!file) return;
  fs.writeFileSync(file, lines.map(oneLine).join('\n') + '\n', 'utf8');
}

function need(argv, i, name) {
  const value = argv[i];
  if (value === undefined || value.startsWith('--')) throw new EnvError('missing value for --' + name);
  return value;
}

function parseArgs(argv) {
  const opts = { input: null, outDir: null, resultFile: null, authState: null };
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--in': opts.input = need(argv, ++i, 'in'); break;
      case '--out-dir': opts.outDir = need(argv, ++i, 'out-dir'); break;
      case '--result-file': opts.resultFile = need(argv, ++i, 'result-file'); break;
      case '--auth-state': opts.authState = need(argv, ++i, 'auth-state'); break;
      case '--help':
      case '-h': say(USAGE); process.exit(EXIT.OK); break;
      default: throw new EnvError('unknown argument "' + argv[i] + '"');
    }
  }
  if (!opts.input) throw new EnvError('--in is required');
  if (!opts.outDir) throw new EnvError('--out-dir is required');
  return opts;
}

function statOrNull(p) {
  try { return fs.statSync(p); } catch { return null; }
}

// Never creates a directory, never deletes one. Reports every problem at once.
function preflight(opts) {
  const problems = [];
  const input = statOrNull(opts.input);
  if (!input) problems.push('input file not found: ' + opts.input);
  else if (!input.isFile()) problems.push('input is not a file: ' + opts.input);
  const out = statOrNull(opts.outDir);
  if (!out) problems.push('output directory not found: ' + opts.outDir);
  else if (!out.isDirectory()) problems.push('output path is not a directory: ' + opts.outDir);
  if (opts.resultFile && !statOrNull(path.dirname(path.resolve(opts.resultFile)))) {
    problems.push('result file directory not found: ' + path.dirname(path.resolve(opts.resultFile)));
  }
  if (problems.length) throw new EnvError(problems.join('; '));
}

// NEEDS_HUMAN has its own exit code (3), so it never needs a STATUS line.
function checkAuth(opts) {
  if (!opts.authState) return;
  const state = statOrNull(opts.authState);
  if (!state) throw new EnvError('auth state file not found: ' + opts.authState);
  const text = fs.readFileSync(opts.authState, 'utf8');
  if (/expired/i.test(text)) throw new NeedsHumanError('saved session expired; a person must sign in again');
}

function readRows(opts) {
  const text = fs.readFileSync(opts.input, 'utf8');
  let rows;
  try { rows = JSON.parse(text); } catch { throw new EnvError('input is not valid JSON: ' + opts.input); }
  if (!Array.isArray(rows)) throw new EnvError('input must be a JSON array of rows');
  const seen = new Set();
  for (const row of rows) {
    const key = row && row.key;
    if (key === undefined || key === null || key === '') continue;
    if (seen.has(String(key))) throw new AbortedError('duplicate business key: ' + key);
    seen.add(String(key));
  }
  return rows;
}

function run(opts) {
  const rows = readRows(opts);
  const outPath = path.join(opts.outDir, 'result.csv');
  fs.writeFileSync(outPath, rows.map((r) => JSON.stringify(r)).join('\n'), 'utf8');
  const size = fs.statSync(outPath).size;
  if (size === 0) throw new PartialError('empty product: ' + outPath);
  return { done: rows.length, total: rows.length };
}

function finish(opts, code, reason, status) {
  const lines = ['FAIL: ' + code + ' ' + reason];
  if (status) lines.push('STATUS: ' + status);
  writeLines(opts.resultFile, lines);
}

function main() {
  let opts = null;
  try {
    opts = parseArgs(process.argv.slice(2));
    preflight(opts);
    checkAuth(opts);
  } catch (err) {
    const needsHuman = err instanceof NeedsHumanError;
    const code = needsHuman ? EXIT.NEEDS_HUMAN : EXIT.ENV;
    const reason = String(err && err.message ? err.message : err);
    say((needsHuman ? 'NeedsHuman: ' : 'EnvError: ') + reason);
    if (opts) finish(opts, code, reason, null);
    return code;
  }

  writeLines(opts.resultFile, ['RUNNING 0/0']);
  try {
    const r = run(opts);
    writeLines(opts.resultFile, ['OK: 0 done=' + r.done + ' failed=0 total=' + r.total]);
    say('Done: ' + r.done + '/' + r.total + ' ok');
    return EXIT.OK;
  } catch (err) {
    if (err instanceof AbortedError) {
      say('Aborted: ' + err.message);
      finish(opts, EXIT.PARTIAL, err.message, STATUS.ABORTED);
      return EXIT.PARTIAL;
    }
    if (err instanceof PartialError) {
      say('Partial: ' + err.message);
      finish(opts, EXIT.PARTIAL, err.message, STATUS.PARTIAL);
      return EXIT.PARTIAL;
    }
    const needsHuman = err instanceof NeedsHumanError;
    const code = needsHuman ? EXIT.NEEDS_HUMAN : EXIT.ENV;
    const reason = String(err && err.message ? err.message : err);
    say((needsHuman ? 'NeedsHuman: ' : 'EnvError: ') + reason);
    finish(opts, code, reason, null);
    return code;
  }
}

process.exit(main());
