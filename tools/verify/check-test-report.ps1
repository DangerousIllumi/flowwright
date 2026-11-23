<#
.SYNOPSIS
    Verdict gate: a task may not move to the next stage without test-report.verdict = pass.
.DESCRIPTION
    A test report is the verification role's (T) output. Shape:

      {
        "flow": "<name>",
        "runner": {
          "path":   "tools/verify/run-test-report.ps1",
          "sha256": "<hash of that file's content>",
          "run_id": "<the run this report belongs to>",
          "generated_at": "<ISO 8601 timestamp>"
        },
        "generated_at": "<ISO 8601 timestamp>",
        "verdict": "pass" | "fail" | "blocked",
        "environment_verified": true | false | "unknown",
        "acceptance":  [ { "id": "<assertion id>", "result": "pass" | "fail", "evidence": "<...>" } ],
        "skipped":     [ { "id": "<assertion id>", "type": "<check type>", "reason": "<human-written reason>" } ],
        "adversarial": [ { "case": "<category>/<name>", "result": "pass" | "bug" | "gap", "evidence": "<...>" } ],
        "known_limitations": [ "<category>/<name>", ... ]
      }

    The gate answers one question: may this task be delivered? Only a report whose verdict is pass does
    that, and a pass must not contradict its own evidence:

      1. no report, no verdict, or a verdict other than pass -> VERDICT_NOT_PASS (there is no default);
      2. verdict=pass while an acceptance item is not pass -> ACCEPTANCE_NOT_PASS;
      3. verdict=pass while an adversarial case came back "bug" -> ADVERSARIAL_BUG;
      4. a "gap" that is not listed in known_limitations -> GAP_NOT_RECORDED (T reports gaps, A decides);
      5. a cited case that does not exist under tests/adversarial -> ADVERSARIAL_CASE_NOT_FOUND;
      6. no runner, no acceptance item, or no adversarial result -> REPORT_INCOMPLETE: a report that
         verified nothing cannot pass;
      7. a runner that is absent, names another path, or whose sha256 is not the current
         tools/verify/run-test-report.ps1 -> RUNNER_UNVERIFIED: a hand-written report cannot pass, because
         the report has to prove it was produced by the generator;
      8. environment_verified missing or outside true/false/unknown -> REPORT_INCOMPLETE. A value of false
         or unknown still passes (logic was verified) but prints a WARNING: the acceptance did not run in
         the real target environment, and the distinction must stay visible at the summary layer;
      9. a skipped[] item without a reason, or one not registered in known_limitations as
         "skipped:<id>: <reason>" -> SKIPPED_UNTRACED: optionality does not turn "not done" into
         "did not need to be done"; every skip carries a human-written reason and stays visible.

    Usage: .\tools\verify\check-test-report.ps1 -ReportFile <path> [-RepoRoot <path>]
    Exit codes: 0 only for a valid verdict=pass, 1 otherwise.

    CI does not run this script: the public repository carries no reports. It runs before delivery, on the
    machine holding the business layer. The hold-out set itself is checked in CI by
    check-adversarial-set.ps1.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$ReportFile,
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) { $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
while ($RepoRoot.Length -gt 3 -and $RepoRoot.EndsWith('\')) { $RepoRoot = $RepoRoot.Substring(0, $RepoRoot.Length - 1) }
$adversarialRoot = Join-Path $RepoRoot 'tests\adversarial'

function ConvertTo-AsciiEscape {
    param([string]$Text)
    $sb = New-Object Text.StringBuilder
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($code -lt 128) { [void]$sb.Append($ch) }
        else { [void]$sb.Append(('\u{0:x4}' -f $code)) }
    }
    return $sb.ToString()
}

if (-not (Test-Path -LiteralPath $ReportFile)) {
    Write-Output ("[check-test-report] VERDICT_NOT_PASS no report at {0}: a task without a verdict does not advance" -f $ReportFile)
    exit 1
}

try {
    $report = Get-Content -LiteralPath $ReportFile -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Output ("[check-test-report] REPORT_UNREADABLE {0}" -f (ConvertTo-AsciiEscape $_.Exception.Message))
    exit 1
}

$verdict = [string]$report.verdict
if (-not $verdict) {
    Write-Output '[check-test-report] VERDICT_NOT_PASS the report has no verdict field'
    exit 1
}
if (@('pass', 'fail', 'blocked') -notcontains $verdict) {
    Write-Output ("[check-test-report] VERDICT_NOT_PASS unknown verdict value: {0}" -f $verdict)
    exit 1
}
if ($verdict -ne 'pass') {
    Write-Output ("[check-test-report] VERDICT_NOT_PASS verdict={0}" -f $verdict)
    exit 1
}

$violations = New-Object System.Collections.ArrayList

if (-not ([string]$report.runner)) {
    [void]$violations.Add('REPORT_INCOMPLETE no runner: a verdict without "who ran it" cannot be checked')
}

# Provenance: the report must carry proof that run-test-report.ps1 produced it. A hand-written pass report
# has no runner object, or one whose hash does not match the generator in this repository.
$expectedRunnerPath = 'tools/verify/run-test-report.ps1'
$runnerPathValue = [string]$report.runner.path
$runnerHashValue = [string]$report.runner.sha256
if (-not $runnerPathValue -or -not $runnerHashValue) {
    [void]$violations.Add('RUNNER_UNVERIFIED no runner provenance: the report must name the generator script and its hash')
} elseif ($runnerPathValue -ne $expectedRunnerPath) {
    [void]$violations.Add(("RUNNER_UNVERIFIED runner path is not the report generator: {0}" -f $runnerPathValue))
} else {
    $generatorFile = Join-Path $RepoRoot ($expectedRunnerPath -replace '/', '\')
    if (-not (Test-Path -LiteralPath $generatorFile)) {
        [void]$violations.Add(("RUNNER_UNVERIFIED generator not found to verify the hash: {0}" -f $expectedRunnerPath))
    } else {
        $actualHash = (Get-FileHash -LiteralPath $generatorFile -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($runnerHashValue.ToLowerInvariant() -ne $actualHash) {
            [void]$violations.Add('RUNNER_UNVERIFIED runner hash does not match the current tools/verify/run-test-report.ps1')
        }
    }
}

$acceptance = @($report.acceptance | Where-Object { $null -ne $_ })
if ($acceptance.Count -eq 0) {
    [void]$violations.Add('REPORT_INCOMPLETE no acceptance item')
}
foreach ($item in $acceptance) {
    $result = [string]$item.result
    if ($result -ne 'pass') {
        [void]$violations.Add(("ACCEPTANCE_NOT_PASS {0} result={1}" -f $item.id, $result))
    }
}

$adversarial = @($report.adversarial | Where-Object { $null -ne $_ })
if ($adversarial.Count -eq 0) {
    [void]$violations.Add('REPORT_INCOMPLETE no adversarial result')
}
$limitations = @($report.known_limitations | Where-Object { $_ } | ForEach-Object { [string]$_ })
$gapCount = 0
foreach ($item in $adversarial) {
    $caseId = [string]$item.case
    $result = [string]$item.result
    if (@('pass', 'bug', 'gap') -notcontains $result) {
        [void]$violations.Add(("ADVERSARIAL_RESULT_INVALID {0} result={1}" -f $caseId, $result))
    }
    if ($result -eq 'bug') {
        [void]$violations.Add(("ADVERSARIAL_BUG {0}" -f $caseId))
    }
    if ($result -eq 'gap') {
        $gapCount++
        if ($limitations -notcontains $caseId) {
            [void]$violations.Add(("GAP_NOT_RECORDED {0}" -f $caseId))
        }
    }
    $casePath = Join-Path $adversarialRoot (($caseId -replace '/', '\') + '.json')
    if (-not (Test-Path -LiteralPath $casePath)) {
        [void]$violations.Add(("ADVERSARIAL_CASE_NOT_FOUND {0}" -f $caseId))
    }
}

# Skips: an optional criterion that produced nothing is acceptable only when a human wrote why, and that
# reason is registered for this run. A skip with no reason, or one that never reaches the summary, is the
# silent gap that optional checks used to create.
$skippedItems = @($report.skipped | Where-Object { $null -ne $_ })
foreach ($item in $skippedItems) {
    $skipId = [string]$item.id
    $skipReason = [string]$item.reason
    if (-not $skipReason.Trim()) {
        [void]$violations.Add(("SKIPPED_UNTRACED {0} has no reason: a skip without a written reason is a silent gap" -f $skipId))
        continue
    }
    $expectedEntry = ('skipped:{0}: {1}' -f $skipId, $skipReason)
    if ($limitations -notcontains $expectedEntry) {
        [void]$violations.Add(("SKIPPED_UNTRACED {0} is not registered in known_limitations as '{1}'" -f $skipId, $expectedEntry))
    }
}

# Environment: verified logic is not the same as verified environment. A missing or unknown value is
# incomplete; false or unknown still pass, but the difference has to stay visible in the summary.
$environmentVerified = $null
$environmentProperty = $report.PSObject.Properties['environment_verified']
if (-not $environmentProperty) {
    [void]$violations.Add('REPORT_INCOMPLETE no environment_verified: true, false or unknown is required')
} else {
    $environmentValue = $environmentProperty.Value
    if ($environmentValue -is [bool]) { $environmentText = $environmentValue.ToString().ToLowerInvariant() }
    elseif ($environmentValue -is [string]) { $environmentText = $environmentValue.ToLowerInvariant() }
    else { $environmentText = '' }
    if (@('true', 'false', 'unknown') -notcontains $environmentText) {
        [void]$violations.Add(("REPORT_INCOMPLETE environment_verified is not true|false|unknown: {0}" -f [string]$environmentValue))
    } else {
        $environmentVerified = $environmentText
    }
}

if ($violations.Count -eq 0) {
    Write-Output ("[check-test-report] verdict=pass (acceptance={0}, adversarial={1}, gaps={2})" -f $acceptance.Count, $adversarial.Count, $gapCount)
} else {
    foreach ($violation in $violations) { Write-Output ("[check-test-report] {0}" -f (ConvertTo-AsciiEscape $violation)) }
}

if ($environmentVerified -and $environmentVerified -ne 'true') {
    Write-Output ("[check-test-report] WARNING logic verified, environment not verified (environment_verified={0}): the acceptance did not run in the real target environment" -f $environmentVerified)
}

if ($violations.Count -eq 0) { exit 0 }
Write-Output ("[check-test-report] failed: {0} contradiction(s) inside a verdict=pass report; the task stays where it is." -f $violations.Count)
exit 1
