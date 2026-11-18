# Adversarial cases

Hold-out cases, written and owned by the verification role (T). The generation role (B/C) must not read
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
