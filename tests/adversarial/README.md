# Adversarial cases

Hold-out cases, written and owned by the verification role (T). The generation role (B) must not read
this directory: a generator that can see the expectations ends up written to the test instead of to the spec,
and then "passes" stops meaning "correct".

The set is organised by **failure category**, not by flow, so the second task reuses the first task's traps.

| Category | Question it asks |
|---|---|
| `input` | Is the input wrong (missing, renamed, empty)? |
| `data` | Is the content wrong (duplicate key, boundary date, impossible value)? |
| `auth` | Is access wrong, and is it distinguished from a plain failure? |
| `output` | Did the product come out empty or unreadable while the run claimed success? |
| `env` | Is the machine wrong (missing directory, locked file, full disk)? |

A case is a JSON file at `tests/adversarial/<category>/<name>.json`:

```json
{
  "id": "input/missing-input-file",
  "category": "input",
  "given": "The input file named in the configuration does not exist.",
  "when": "The entry script starts.",
  "expected": { "exit_code": 2, "side_effects": "no output is written" },
  "why": "A missing input must stop before the first side effect."
}
```

Rules the gate enforces (`tools/verify/check-adversarial-set.ps1`):

- `expected` carries `exit_code` or `status`, never neither: a case without an expected outcome is
  exploration, not a case.
- `id` equals `<category>/<file name without .json>`, so a rename cannot leave a report citing an id that
  no longer resolves.
- `category` equals the parent folder and is one of the five above.
- No file under `tools/pad-robin/` (the generator) references this directory.

Cases may be added at any time: they are T's asset, and adding one is not a change to a frozen spec.

## How a case is triggered

A case is not a description of a failure; it is a failure that a command reproduces. Every case carries
the gate that has to reject it, and the trigger file names the exact command. Two subjects exist:

| Subject | Which cases use it | How it runs |
|---|---|---|
| the neutral entry (`tests/harness/entry/mini-entry.js`) | the cases about a run's behaviour: input, data, auth, output, env | `node tests/harness/run-case.js --case <id> --repo-root <repo> --sandbox <dir>`, driven by `node tests/harness/selftest.js` |
| a verification gate (`tools/verify/check-*.ps1`) | the cases about the gates themselves | `tests/gate-cases.Tests.ps1` builds the accident's shape under the system temp directory and runs the gate against it |

The gate cases assert both directions: the defective shape has to make the gate fail, and the same
shape without the defect has to make it pass. A gate that rejects everything would otherwise satisfy a
negative case on its own.

Who runs what, and when:

| When | Who | Command |
|---|---|---|
| on every push and pull request | CI (`windows-latest`) | `Invoke-Pester -Script tests\gate-cases.Tests.ps1` runs as part of the Pester step, one file at a time |
| before a delivery | the verification role (T) | the same file, plus `node tests\harness\selftest.js` for the entry cases |
| when a gate's verdict is in doubt | the verification role (T) | the single gate command the case's `trigger.command` names, with `-RepoRoot` pointing at a sandbox |

The shapes are built in the system temp directory. The repository's `business/` layer is a real
business layer and is never a test target, and a `business/` directory left behind in the working copy
is itself an input to the three-tier gate, so no case creates one.
