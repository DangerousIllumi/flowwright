<#
.SYNOPSIS
    Verdict gate: a task may not move to the next stage without test-report.verdict = pass.
.DESCRIPTION
    A test report is the verification role's (T) output. Shape:

      {
        "flow": "<name>",
        "runner": "<who ran it>",
        "generated_at": "<ISO 8601 timestamp>",
        "verdict": "pass" | "fail" | "blocked",
        "acceptance":  [ { "id": "<assertion id>", "result": "pass" | "fail", "evidence": "<...>" } ],
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
         verified nothing cannot pass.

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

if ($violations.Count -eq 0) {
    Write-Output ("[check-test-report] verdict=pass (acceptance={0}, adversarial={1}, gaps={2})" -f $acceptance.Count, $adversarial.Count, $gapCount)
    exit 0
}

foreach ($violation in $violations) { Write-Output ("[check-test-report] {0}" -f (ConvertTo-AsciiEscape $violation)) }
Write-Output ("[check-test-report] failed: {0} contradiction(s) inside a verdict=pass report; the task stays where it is." -f $violations.Count)
exit 1
