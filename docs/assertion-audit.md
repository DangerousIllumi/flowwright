# Tautological assertion audit (case-by-case verdict on negative assertions)

Scope (pre-fix baseline, measured before the five repairs below): 25 Pester files under `tests/` (51 `Should Not *` occurrences), 6 `node --test` files (9 occurrences), 3 pytest files (2 `pytest.raises`).
Verdict rule: whether the forbidden thing could **really occur** on this code path. Three classes: **effective** (can go red on a regression), **tautological** (cannot occur under any implementation, so the assertion never goes red), **nearly tautological** (only an extreme case can produce it, and the test never constructs that case).
Handling of tautologies: replace them with an equivalent or stronger falsifiable assertion, and prove it with **mutation testing** — break the protected behaviour in a repository copy under %TEMP%, the assertion must go red, and it must go green again once the copy is restored.

---

## 1. Judged tautological and already fixed (5)

| # | File:line | Assertion as written | The thing expected not to appear | What this path actually outputs | Verdict | Rewrite |
|---|---|---|---|---|---|---|
| F1 | `tests/pad-verify.Tests.ps1:38` (original) | `$out \| Should Not Match 'VERIFY_SUMMARY'` | The summary marker of the acceptance-check stage | The sandbox contains no runnable flow+criteria combination at all, so `build-acceptance.ps1` is never called and the marker **cannot** appear under any implementation | **Tautological** | Pin the real early error output: exactly 1 line, a result with exactly the fields `ok,error`, and `error` starting with `E_FLOW_FILE_REQUIRED` |
| F2 | `tests/pad-verify.Tests.ps1:52` (original) | `$out \| Should Not Match '"checks"'` | The checks field in the result | Same as above: the acceptance stage is unreachable, so `"checks"` is never printed | **Tautological** | Same as F1 (already covered by the `ok,error` field-list assertion) |
| F3 | `tests/pad-admit.Tests.ps1:425` (original) | `$text \| Should Not Match 'POLICY_'` | POLICY_* error codes | POLICY is the only check that produces `POLICY_*`, and it only runs after the flow has been loaded; the flow name in this case makes loading fail every time | **Tautological** | Pin the final state: `"summary":{"total":1,"pass":0,"warn":0,"ask":0,"fail":1}` (the report holds only the ADMIT item, and it is the only failure) |
| F4 | `tests/pad-release.Tests.ps1:226` (original) | `$out \| Should Not Match 'pytestPassed'` | The test-summary field | The call passes `-SkipTests`, so `Get-TestSummary` — the only thing that can populate `pytestPassed` — is never called | **Tautological** | Pin the observable consequence: `"tests":null` (the test summary is not even initialized) |
| F5 | `tests/pad-flow-name.Tests.ps1:86-87` (original) | `Should Not Match 'pad_flow_name'` / the sample display-name literal ending in `-XYZ` | That field name, or an unconsumed top-level value, appearing in `.robin` | The generator emits only PAD statements; no JSON field name and no unconsumed top-level value can **ever** get into `.robin` | **Tautological** | Behaviourally equivalent and stronger: the `.robin` generated from the same flow with and without `pad_flow_name` must be byte-identical |

## 2. Mutation testing (red/green evidence)

All of it was done in a repository copy under `%TEMP%`; the copy was deleted afterwards; the real repository was never modified.

| Id | Mutation | Affected assertion | Result |
|---|---|---|---|
| M1 | In `pad-verify.ps1`, early error text `E_FLOW_FILE_REQUIRED:` → `E_FLOW_DEFAULTED:` | The assertions fixed for F1/F2 | **Red**: `[-] empty flows directory: non-zero exit demanding an explicit -FlowFile…` (Expected: `{"ok":false,"error":"E_FLOW_DEFAULTED…`) |
| M1b | `E_FLOW_AMBIGUOUS(candidates=` → `E_FLOW_DEFAULTED_AMBIGUOUS(candidates=` | The ambiguity case fixed for F1/F2 | **Red**: `[-] multiple flow candidates: non-zero exit reporting the candidate count` |
| M2 | In `pad-admit.ps1`, add one extra POLICY check to the error report (2 check ids) | The assertion fixed for F3 | **Red**: `[-] no -FlowFile and the flow name resolves to nothing: non-zero exit before any admission check` |
| M3 | `flow-to-robin.js` writes `pad_flow_name` into `.robin` | The byte-identical assertion for F5 | **Red**: `[-] the generator and check.js accept the field without writing it into .robin` |
| M4 | In `pad-release.ps1`, drop the `-SourceRobin` guard so the pipeline continues into the tests stage | The assertion fixed for F4 | **Red**: `[-] no -SourceRobin and the flow name resolves to nothing: non-zero exit before the execution stage` |

Control (unmutated copy, all green): `pad-verify.Tests.ps1` 2/2, `pad-release.Tests.ps1` 17/17, `pad-flow-name.Tests.ps1` 6/6.

## 3. Assertions judged effective (can go red on a regression), with mutation evidence one by one

The assertions below are **not** tautological. Each of them goes red under the corresponding mutation, so they stay as they are.

| File:line | Assertion | Mutation | Result |
|---|---|---|---|
| `pad-schedule.Tests.ps1:45` | `Should Not Match 'RunOnly'` | The workday gating branch also prints `-RunOnly` | **Red** (`action command: workday calendar mode…`) |
| `pad-schedule.Tests.ps1:61,72,93` | `Should Not Match 'RUN_START'` | Drop the "missing calendar" guard so the run continues | **Red** (2 cases: `run entry without a calendar`, `register mode without a calendar`) |
| `pad-schedule.Tests.ps1:113` | `Should Not Match 'CONFIG_MISSING'` | The ignore-calendar path also prints `CONFIG_MISSING` | **Red** |
| `pad-schedule.Tests.ps1:144,145` | `Should Not Match 'RunIfWorkday'` / `'AllowProd'` | Ignore-calendar mode also emits `-RunIfWorkday` | **Red** |
| `pad-schedule.Tests.ps1:169,174` | `Should Not Match '-LockWaitSec'` | Write `-LockWaitSec` into the task command | **Red** |
| `pad-schedule.Tests.ps1:271` | First byte `Should Not Be 0xEF` | The alert file carries a BOM (PS 5.1 `Add-Content` behaviour) | Effective (asserts the first byte directly) |
| `trigger-registry.Tests.ps1:213` | Hash `Should Not Be $base` | time changed from 09:00 to 10:00 | Effective (the hash includes time) |
| `trigger-registry.Tests.ps1:226` | `$h2 Should Not Be $h1` | The `assisted` field is dropped from the hash | **Red** (`assisted is part of specHash…`) |
| `trigger-registry.Tests.ps1:259,274` | `Should Not Match 'RunOnly'` / `'RunIfWorkday'` | Change the gating-branch argument string | Effective (same origin as pad-schedule) |
| `pad-fingerprint.Tests.ps1:561` | `status Should Not Be 'fail'` | The legacy branch changed to `status='fail'` | **Red** (2 legacy cases) |
| `pad-fingerprint.Tests.ps1:597,598,618` | Evidence `Should Not Match 'posting\.vbs'` / `'scripts/a\.vbs'` / `'tools/b\.py'` | The evidence lists every script instead of only the changed ones | **Red** (3 cases) |
| `pad-rollback.Tests.ps1:67` | `Should Not Be $latest` | The selector ignores `-Back` | **Red** (3 cases) |
| `pad-rollback.Tests.ps1:150,151` | `Should Not Match '"stage":"select"'` / `'"stage":"done"'` | Drop the `-ConfigFile` guard | **Red** |
| `pad-release.Tests.ps1:230` | `Should Not Match '"stage":"done"'` | Drop the `-SourceRobin` guard | **Red** (same as M4 above) |
| `pad-admit.Tests.ps1:593,595` | Evidence `Should Not Match 'node 8'` / `'node 7'` | Both blocks list all nodes (duplicate reporting) | **Red** (2 cases) |
| `PadConfigure.Tests.ps1:142,143` | `Should Not Match 'INTERACTIVE_CONFIRM'` / `'CONFIG_WRITTEN'` | Drop the "sample config missing" guard | **Red** |
| `PadConfigure.Tests.ps1:136` | `ExitCode Should Not Be 0` | Asserts the exit code directly | Effective |
| `PadConfigure.Tests.ps1:24` | `Hint Should Not BeNullOrEmpty` | Asserts the hint is non-empty directly | Effective |
| `policy-docs.Tests.ps1:69` | Document `Should Not Match 'must be explicitly allowlisted'` | Document reverted to the old wording | **Red** |
| `policy-docs.Tests.ps1:77` | Document `Should Not Match 'unless the user supplies…'` | Same as above | **Red** |
| `pad-alerts.Tests.ps1:42` | `ts Should Not BeNullOrEmpty` | Timestamp written as an empty string | **Red** (2 cases) |
| `output-roots.Tests.ps1:86` | `Should Not Match 'skip:'` | Missing registry changed to skip | **Red** |
| `eval-flow.Tests.ps1:73` | `Should Not Match 'notes\.json'` | The summary reports the skipped companion file | **Red** |
| `drawio-to-flow.test.js:192` | `doesNotMatch(/DRAWIO_ROUNDTRIP_NO_SOURCE_FLOW/)` | Round-trip always warns | **Red** (node --test: 10/10 fail after the mutation, 10/10 pass in the control) |
| `check-decisions.test.js` 8 places | `doesNotMatch` / `ok(!…)` | See section 4 | Effective |

## 4. Judged "nearly tautological", deliberately **not** changed (pending confirmation)

| File:line | Assertion | Why it is only nearly tautological | What you need to decide |
|---|---|---|---|
| `trigger-registry.Tests.ps1:505` | `$h2 \| Should Not Be $h1` (days change → hash change) | days is written into the canonical hash, but when `daysDeclared` is false days is normalized to the same Monday-to-Friday set, so the hash really changes **only when an explicit declaration differs from an omitted one**. A mutation that pins `days` in the hash to `@()` did **not** make this go red (still 37/37 green) — this assertion currently has discriminating power only for the "days declared" input, and the test happens to cover only that one | Whether to add a case for "the hash of an explicit mon..fri declaration differs from the hash of an omitted days" (which is exactly why `scheduleKind` exists), turning it from "nearly tautological" into "effective" |
| `pad-schedule.Tests.ps1:271` | Alert JSONL first byte `Should Not Be 0xEF` | Effective (asserts the byte directly), but it relies on PS 5.1 `Add-Content` writing a BOM by default; PS 7 does not, so under PS 7 it **falsely passes** | Whether to annotate the test with "this assertion only means something on PS 5.1" |
| Several `doesNotMatch(/violation/)`, `/DECISION_NOT_USER_APPROVED/`, `/RISK_NODE_DECISION_NOT_RISK/` in `check-decisions.test.js` | "the report does not contain a certain word" | Effective: under the corresponding fixture the forbidden code **does** appear (loosening the gate would print it) | No change needed |
| `doesNotMatch(/skip:/)`, `doesNotMatch(/warn:/)`, `doesNotMatch(/failed:/)` in `check-decisions.test.js` | "the report does not contain the wording of another mode" | Effective: the wording of a mode is hard-coded by the implementation, so a gate change exposes it immediately | No change needed |
| The two `assert.ok(!/[\u0080-\uFFFF]/…)` checks in `check-decisions.test.js` | No raw non-ASCII characters in the output | Effective: the gate would write raw Chinese if it did not escape | The assertion order was adjusted this round (check raw characters first, then printable ASCII) so the "escaping" assertion can really fail — in the original order the helper's printable-ASCII guard would fail first and the raw-character check would never get its turn, a hidden tautology of the "second assertion never gets its turn" kind |

## 5. Conclusion: sporadic or systematic?

**Sporadic, but concentrated in one identifiable pattern.**

- Of the 62 negative assertions in the repository, **5 are tautological** (about 8%), **1 is nearly tautological**, and the other 56 are effective.
- The 5 tautologies are **not random**; they share one shape: **the thing being asserted about is a product that is unreachable on the current test path** —
  - "the acceptance stage will not print `VERIFY_SUMMARY` / `"checks"`", but the acceptance stage is not reachable at all (F1, F2);
  - "it will not print `POLICY_`", but the POLICY stage is not reachable at all (F3);
  - "it will not print `pytestPassed`", but `Get-TestSummary` is never called at all (F4);
  - "`pad_flow_name` will not appear in `.robin`", but the generator emits only PAD statements, so no JSON field can appear at all (F5).
- The common cause is: **the scenario the test builds only reaches the first gate, while the assertion checks the product of the second gate**. It is not "the assertion has the wrong string" but "the assertion hangs off the wrong path", which is why this kind of assertion is tautological under any implementation — changing the implementation or the string will not make it go red.
- This class of problem **cannot be judged from the assertion text alone**: 4 of the 5 texts look entirely reasonable (`Should Not Match 'POLICY_'` reads like an ordinary negative assertion). The only identifying signal is to ask "could the forbidden thing really occur on this path".
- The conclusion is therefore: **not a systematic spread, but one design habit (using a negative assertion to check a downstream product) that is bound to be hit in "early-exit path tests"**. Any test where "the flow exits at the first gate" is prone to this. All 5 tautologies occur in this kind of case, while the 56 effective assertions are spread over normal paths.

## 6. Encoding problem found and fixed along the way

The audit sub-agent edited 4 `.ps1` files (`pad-admit` / `pad-flow-name` / `pad-release` / `pad-verify`), and the editing stripped the **UTF-8 BOM**, violating a hard repository rule (`.ps1` must be UTF-8 with BOM). All of them were restored to a BOM over their original byte content, and the first three bytes `EF BB BF` were verified file by file.
