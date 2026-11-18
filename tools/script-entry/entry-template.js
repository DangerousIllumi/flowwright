#!/usr/bin/env node
// Entry template for a script that a PAD shell flow starts with Scripting.RunDOSCommand.
// Copy this file, rename it, and keep these four pieces — they are the contract with the flow:
//
//   1. Argument parsing   every path and switch arrives as an argument; nothing about a real machine is hard-coded
//   2. The preflight      input and output locations are checked BEFORE any work starts; a missing directory exits 2
//                         with nothing touched, instead of failing halfway through a batch
//   3. The result file    RUNNING at the start, RUNNING n/total while it works, OK:/FAIL: at the end, so the
//                         outcome survives a lost console and a watchdog can tell "slow" from "stuck"
//   4. The exit code map  0 all done, 1 some items failed, 2 parameter or environment, 3 a human must log in
//
// The flow branches on the exit code, never on the text. Console output is ASCII only, because PAD decodes a
// child process with the system code page (docs/doc-language.md section 3).
//
// Output directory ownership is declared, not assumed: this template is the "must already exist" variant.
// A flow that wants self-creating output says so explicitly and changes preflight() alone — never half of each
// (docs/engine-selection.md section 3.2).

'use strict';

const fs = require('fs');
const path = require('path');

const EXIT = { OK: 0, PARTIAL: 1, ENV: 2, NEEDS_HUMAN: 3 };

// A parameter or the environment is wrong: retrying unchanged cannot help.
class EnvError extends Error {}
// A person has to act (log in, confirm a prompt, finish a wizard): retrying after that may help.
class NeedsHumanError extends Error {}

const USAGE = [
  'usage: <script>.js --in <file> --out-dir <dir> [--result-file <file>]',
  '                     [--date-from <YYYY-MM-DD>] [--date-to <YYYY-MM-DD>] [--limit <n>]',
].join('\n');

// Anything non-ASCII becomes '?' so a localized string can never reach a PAD variable.
function say(line) {
  process.stdout.write(String(line).replace(/[^\x09\x0A\x0D\x20-\x7E]/g, '?') + '\n');
}

function oneLine(text) {
  return String(text).replace(/\r?\n/g, ' ');
}

function writeResult(file, text) {
  if (!file) return;
  fs.writeFileSync(file, oneLine(text) + '\n', 'utf8');
}

function need(argv, i, name) {
  const value = argv[i];
  if (value === undefined || value.startsWith('--')) throw new EnvError('missing value for --' + name);
  return value;
}

function parseArgs(argv) {
  const opts = { input: null, outDir: null, resultFile: null, dateFrom: null, dateTo: null, limit: 0 };
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--in': opts.input = need(argv, ++i, 'in'); break;
      case '--out-dir': opts.outDir = need(argv, ++i, 'out-dir'); break;
      case '--result-file': opts.resultFile = need(argv, ++i, 'result-file'); break;
      case '--date-from': opts.dateFrom = need(argv, ++i, 'date-from'); break;
      case '--date-to': opts.dateTo = need(argv, ++i, 'date-to'); break;
      case '--limit':
        opts.limit = Number(need(argv, ++i, 'limit'));
        if (!Number.isInteger(opts.limit) || opts.limit < 0) throw new EnvError('--limit must be a non-negative integer');
        break;
      case '--help':
      case '-h': say(USAGE); process.exit(EXIT.OK); break;
      default: throw new EnvError('unknown argument "' + argv[i] + '"');
    }
  }
  if (!opts.input) throw new EnvError('--in is required');
  if (!opts.outDir) throw new EnvError('--out-dir is required');
  return opts;
}

// Never creates a directory, never deletes one. Reports every problem at once instead of the first one.
function preflight(opts) {
  const problems = [];
  const stat = (p, want) => {
    try { return fs.statSync(p); } catch { return null; }
  };
  const input = stat(opts.input);
  if (!input) problems.push('input file not found: ' + opts.input);
  else if (!input.isFile()) problems.push('input is not a file: ' + opts.input);
  const out = stat(opts.outDir);
  if (!out) problems.push('output directory not found: ' + opts.outDir);
  else if (!out.isDirectory()) problems.push('output path is not a directory: ' + opts.outDir);
  if (opts.resultFile && !stat(path.dirname(path.resolve(opts.resultFile)))) {
    problems.push('result file directory not found: ' + path.dirname(path.resolve(opts.resultFile)));
  }
  if (problems.length) throw new EnvError(problems.join('; '));
}

// The real work. Replace the body, keep the shape:
//   - one failed item is counted, never thrown: it does not stop the batch
//   - call progress(done, total) after each item so the result file shows movement
//   - throw NeedsHumanError when only a person can continue, EnvError when the environment is wrong
function run(opts, progress) {
  const total = 0;
  let done = 0;
  progress(done, total);
  return { done, failed: 0, total };
}

function main() {
  let opts = null;
  try {
    opts = parseArgs(process.argv.slice(2));
    preflight(opts);
  } catch (err) {
    const reason = err instanceof EnvError ? err.message : String(err && err.message ? err.message : err);
    say('EnvError: ' + reason);
    if (opts) writeResult(opts.resultFile, 'FAIL: ' + EXIT.ENV + ' ' + reason);
    return EXIT.ENV;
  }

  writeResult(opts.resultFile, 'RUNNING 0/0');
  try {
    const r = run(opts, (done, total) => writeResult(opts.resultFile, 'RUNNING ' + done + '/' + total));
    const code = r.failed === 0 ? EXIT.OK : EXIT.PARTIAL;
    say('Done: ' + r.done + '/' + r.total + ' ok, ' + r.failed + ' failed');
    writeResult(opts.resultFile, 'OK: ' + code + ' done=' + r.done + ' failed=' + r.failed + ' total=' + r.total);
    return code;
  } catch (err) {
    const needsHuman = err instanceof NeedsHumanError;
    const code = needsHuman ? EXIT.NEEDS_HUMAN : EXIT.ENV;
    const reason = needsHuman ? err.message : String(err && err.message ? err.message : err);
    say((needsHuman ? 'NeedsHuman: ' : 'EnvError: ') + reason);
    writeResult(opts.resultFile, 'FAIL: ' + code + ' ' + reason);
    return code;
  }
}

process.exit(main());
