<#
.SYNOPSIS
    Produce one test report for one run. This is the producer; it never runs the verdict gate.
.DESCRIPTION
    Runs the acceptance check and the adversarial harness for one run, then writes
    <WorkRoot>\logs\<flow>\test-report-<runId>.json once and never overwrites it.

      acceptance  -> build-acceptance.ps1 + pad-verify.ps1, bound to -Since; only checks that actually ran
                     enter acceptance[], an optional check that was skipped goes to skipped[] and is never
                     recorded as pass (a pass is an assertion, a skipped check asserted nothing). Every
                     optional check must carry an ASCII optional_reason in the spec, or no report is written;
                     that reason is copied to skipped[].reason and registered in known_limitations as
                     "skipped:<id>: <reason>". The generator copies, it never invents a reason.
      adversarial -> tests\harness\, one case at a time; cases not implemented yet are recorded as "gap"
      verdict     -> derived from the evidence above, never taken as an input; values: pass | fail | blocked | logic-only
      provenance  -> runner{path, sha256, run_id, generated_at} proves the gate who produced the report;
                     environment_verified says whether acceptance ran in the real target environment, and
                     defaults to false because a sandbox run only verifies logic

    The report is UTF-8. Console output is ASCII only; non-ASCII is escaped as \uXXXX.

    Usage:
      .\tools\verify\run-test-report.ps1 -FlowName <name> [-WorkRoot <dir>] [-RunId <id>] [-Since <iso>]
          [-EnvironmentVerified true|false|unknown] [-Json]
    Exit codes: 0 report written, verdict=pass / 1 report written, verdict!=pass / 2 environment or declaration error
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$FlowName,
    [string]$RepoRoot,
    [string]$WorkRoot,
    [string]$RunId,
    [datetime]$Since,
    [string]$FlowFile,
    [string]$ConfigFile,
    [string]$ManifestPath,
    [ValidateSet('true', 'false', 'unknown')][string]$EnvironmentVerified = 'false',
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

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

function Stop-Env([string]$Code, [string]$Message) {
    Write-Output ("[run-test-report] {0} {1}" -f $Code, (ConvertTo-AsciiEscape $Message))
    exit 2
}

if (-not $RepoRoot) { $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
if (-not $WorkRoot) { $WorkRoot = Join-Path $RepoRoot 'business' }
$WorkRoot = [IO.Path]::GetFullPath($WorkRoot)
if (-not $ManifestPath) { $ManifestPath = Join-Path $WorkRoot 'manifest.jsonl' }
if (-not $FlowFile) { $FlowFile = Join-Path $WorkRoot ("flows\$FlowName.json") }
if (-not $ConfigFile) { $ConfigFile = Join-Path $WorkRoot ("config\$FlowName.json") }

# ---- run id: explicit, else the latest completed run entry in the manifest ----
$manifestEntry = $null
if (Test-Path -LiteralPath $ManifestPath) {
    foreach ($line in [IO.File]::ReadAllLines($ManifestPath, [Text.Encoding]::UTF8)) {
        if (-not $line.Trim()) { continue }
        try { $e = $line | ConvertFrom-Json } catch { continue }
        if ([string]$e.type -ne 'run') { continue }
        if ([string]$e.flow -ne $FlowName) { continue }
        if ([string]$e.stage -ne 'done') { continue }
        if (@('publish', 'local', 'run-only') -notcontains [string]$e.mode) { continue }
        if (-not [string]$e.runId) { continue }
        $manifestEntry = $e
    }
}

if (-not $RunId) {
    if ($manifestEntry) { $RunId = [string]$manifestEntry.runId }
    else { Stop-Env 'REPORT_RUNID_UNRESOLVED' 'no -RunId given and no completed run entry for this flow exists in the manifest; refusing to fabricate a run' }
}
if ($RunId -notmatch '^[A-Za-z0-9._-]+$') { Stop-Env 'REPORT_RUNID_INVALID' ("run id is not usable as a file name: {0}" -f $RunId) }

# ---- since: explicit, else the manifest timestamp, else the run directory creation time ----
if (-not $PSBoundParameters.ContainsKey('Since')) {
    if ($manifestEntry -and [string]$manifestEntry.runId -eq $RunId -and [string]$manifestEntry.ts) {
        $Since = [datetime]::Parse([string]$manifestEntry.ts)
    } else {
        $scriptsRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Scripts'
        $found = $null
        if (Test-Path -LiteralPath $scriptsRoot) {
            $found = @(Get-ChildItem -LiteralPath $scriptsRoot -Directory -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq $RunId } | Select-Object -First 1)
        }
        if ($found -and $found.Count -gt 0) { $Since = $found[0].CreationTime }
        else { Stop-Env 'REPORT_SINCE_UNRESOLVED' 'no -Since given and no manifest or run-directory timestamp resolves this run; refusing the 6-hour default' }
    }
}

if (-not (Test-Path -LiteralPath $FlowFile)) { Stop-Env 'REPORT_FLOW_FILE_MISSING' ("flow definition not found: {0}" -f $FlowFile) }
if (-not (Test-Path -LiteralPath $ConfigFile)) { Stop-Env 'REPORT_CONFIG_MISSING' ("config not found: {0}" -f $ConfigFile) }

$logsDir = Join-Path $WorkRoot ("logs\$FlowName")
New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
$reportPath = Join-Path $logsDir ("test-report-{0}.json" -f $RunId)
if (Test-Path -LiteralPath $reportPath) { Stop-Env 'REPORT_ALREADY_EXISTS' ("a report for this run already exists; reports are never overwritten: {0}" -f $reportPath) }

$specPath = Join-Path $logsDir (".acceptance-{0}.json" -f $RunId)
try {
    # ---- acceptance: build the spec ourselves so the id mapping is visible, then execute it ----
    $buildScript = Join-Path $RepoRoot 'tools\pad-sync\build-acceptance.ps1'
    $verifyScript = Join-Path $RepoRoot 'tools\pad-sync\pad-verify.ps1'
    if (-not (Test-Path -LiteralPath $buildScript)) { Stop-Env 'REPORT_TOOL_MISSING' ("build-acceptance.ps1 not found: {0}" -f $buildScript) }
    if (-not (Test-Path -LiteralPath $verifyScript)) { Stop-Env 'REPORT_TOOL_MISSING' ("pad-verify.ps1 not found: {0}" -f $verifyScript) }

    $buildOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $buildScript -FlowFile $FlowFile -OutFile $specPath 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Stop-Env 'REPORT_ACCEPTANCE_BUILD_FAILED' ($buildOut.Trim()) }

    # A skip is only acceptable when a human wrote why. An optional check without optional_reason is an
    # illegal spec: no report is produced, so "not done" can never hide behind "did not need to be done".
    $spec = Get-Content -LiteralPath $specPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $specChecks = @($spec.checks)
    foreach ($c in $specChecks) {
        if (-not [bool]$c.optional) { continue }
        $reason = [string]$c.optional_reason
        if (-not $reason.Trim()) {
            Stop-Env 'REPORT_OPTIONAL_REASON_MISSING' ("optional check has no optional_reason: {0} (id: {1})" -f [string]$c.name, [string]$c.id)
        }
        if ($reason -match '[^\x20-\x7E]') {
            Stop-Env 'REPORT_OPTIONAL_REASON_NOT_ASCII' ("optional_reason is not ASCII: {0}" -f [string]$c.name)
        }
    }

    $verifyOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $verifyScript -AcceptanceFile $specPath -ConfigFile $ConfigFile -Since $Since.ToString('o') 2>&1 | Out-String
    $verifyCode = $LASTEXITCODE
    $verifyLine = ($verifyOut -split "`r?`n" | Where-Object { $_.StartsWith('PAD_VERIFY_RESULT=') } | Select-Object -Last 1)
    if (-not $verifyLine) { Stop-Env 'REPORT_VERIFY_NO_RESULT' 'pad-verify.ps1 printed no PAD_VERIFY_RESULT line' }
    $verify = $verifyLine.Substring('PAD_VERIFY_RESULT='.Length) | ConvertFrom-Json

    $checkResults = @($verify.checks)
    if ($specChecks.Count -ne $checkResults.Count) {
        Stop-Env 'REPORT_ACCEPTANCE_MISMATCH' ("acceptance spec has {0} checks but pad-verify returned {1}" -f $specChecks.Count, $checkResults.Count)
    }

    $acceptance = New-Object System.Collections.ArrayList
    $skippedChecks = New-Object System.Collections.ArrayList
    $skipLimitations = New-Object System.Collections.ArrayList
    $staleExemptions = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $specChecks.Count; $i++) {
        $c = $specChecks[$i]
        $r = $checkResults[$i]
        $id = [string]$c.id
        # Fallback only: a positional id shifts when a check is inserted or reordered. Declare an explicit
        # lowercase ASCII id in flow.json's acceptance.checks to keep the id stable across edits.
        if (-not $id) { $id = ('{0}-{1:D2}' -f ([string]$c.type).ToLowerInvariant(), ($i + 1)) }
        if ($id -notmatch '^[a-z][a-z0-9-]{0,63}$') {
            Stop-Env 'REPORT_ACCEPTANCE_ID_NOT_ASCII' ("acceptance id is not a lowercase ASCII id: {0} (check: {1})" -f $id, [string]$c.name)
        }
        # A skipped optional check asserted nothing, so it is not an acceptance item: it is reported
        # separately, with the human-written reason copied verbatim and registered as a known limitation.
        if ([bool]$r.skipped) {
            $skipReason = [string]$c.optional_reason
            [void]$skippedChecks.Add([ordered]@{
                id     = $id
                type   = [string]$c.type
                reason = $skipReason
            })
            [void]$skipLimitations.Add(('skipped:{0}: {1}' -f $id, $skipReason))
            continue
        }
        # An exemption exists to cover a gap. The moment the check passes for real, the gap is gone and the
        # exemption outlives it: report that, so the next reader closes it instead of trusting a stale waiver.
        if ([bool]$c.optional -and [bool]$r.ok) {
            [void]$staleExemptions.Add([ordered]@{
                code    = 'OPTIONAL_EXEMPTION_STALE'
                id      = $id
                message = ('{0} passed in this run, drop optional/optional_reason' -f $id)
            })
        }
        [void]$acceptance.Add([ordered]@{
            id       = $id
            name     = [string]$c.name
            result   = $(if ($r.ok) { 'pass' } else { 'fail' })
            evidence = ('{0}: {1}' -f [string]$c.type, [string]$r.detail)
        })
    }
    if ($acceptance.Count -eq 0) {
        Stop-Env 'REPORT_INCOMPLETE_NO_EXECUTED_ACCEPTANCE' ('all {0} acceptance check(s) were skipped; a report of only skipped checks asserts nothing' -f $specChecks.Count)
    }

    # ---- adversarial: enumerate every case, run the implemented ones, record the rest as gaps ----
    $harnessDir = Join-Path $RepoRoot 'tests\harness'
    $casesConfigPath = Join-Path $harnessDir 'cases.json'
    $runCaseScript = Join-Path $harnessDir 'run-case.js'
    $adversarialRoot = Join-Path $RepoRoot 'tests\adversarial'
    if (-not (Test-Path -LiteralPath $casesConfigPath)) { Stop-Env 'REPORT_HARNESS_MISSING' ("harness case config not found: {0}" -f $casesConfigPath) }
    if (-not (Test-Path -LiteralPath $runCaseScript)) { Stop-Env 'REPORT_HARNESS_MISSING' ("harness runner not found: {0}" -f $runCaseScript) }

    $harness = Get-Content -LiteralPath $casesConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $implemented = @($harness.implemented)
    $subject = [string]$harness.entry
    if (-not $subject) { $subject = 'tests/harness/entry/mini-entry.js' }

    $caseFiles = @(Get-ChildItem -LiteralPath $adversarialRoot -Directory -ErrorAction SilentlyContinue |
        ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -File -Filter '*.json' -ErrorAction SilentlyContinue } |
        Sort-Object FullName)
    if ($caseFiles.Count -eq 0) { Stop-Env 'REPORT_ADVERSARIAL_SET_MISSING' ("no case files under {0}" -f $adversarialRoot) }

    $adversarial = New-Object System.Collections.ArrayList
    $limitations = New-Object System.Collections.ArrayList
    foreach ($entry in $skipLimitations) { [void]$limitations.Add([string]$entry) }
    foreach ($file in $caseFiles) {
        $record = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $caseId = [string]$record.id
        if (-not $caseId) { Stop-Env 'REPORT_CASE_WITHOUT_ID' ("case file has no id: {0}" -f $file.FullName) }

        if ($implemented -notcontains $caseId) {
            [void]$adversarial.Add([ordered]@{
                case     = $caseId
                subject  = $subject
                result   = 'gap'
                evidence = 'not implemented in this phase; recorded as a gap'
            })
            [void]$limitations.Add($caseId)
            continue
        }

        $sandbox = Join-Path $logsDir ("harness\{0}\{1}" -f $RunId, ($caseId -replace '/', '-'))
        $caseOut = & node $runCaseScript --case $caseId --repo-root $RepoRoot --sandbox $sandbox 2>&1 | Out-String
        $caseLine = ($caseOut -split "`r?`n" | Where-Object { $_.StartsWith('HARNESS_CASE_RESULT=') } | Select-Object -Last 1)
        if (-not $caseLine) {
            [void]$adversarial.Add([ordered]@{
                case     = $caseId
                subject  = $subject
                result   = 'gap'
                evidence = 'harness produced no result line; recorded as a gap'
            })
            [void]$limitations.Add($caseId)
            continue
        }

        $caseResult = $caseLine.Substring('HARNESS_CASE_RESULT='.Length) | ConvertFrom-Json
        $observed = $caseResult.observed
        $evidence = ('exit_code={0}; status={1}; new_products={2}' -f $observed.exit_code, $observed.status, $observed.new_products)
        if ($caseResult.detail) { $evidence = $evidence + '; ' + [string]$caseResult.detail }
        [void]$adversarial.Add([ordered]@{
            case     = $caseId
            subject  = [string]$caseResult.subject
            result   = $(if ($caseResult.ok) { 'pass' } else { 'bug' })
            evidence = $evidence
        })
    }

    [void]$limitations.Add('side_effects-text-unasserted')
    [void]$limitations.Add('adversarial-subject-is-neutral-reference')
    $limitations = @($limitations | Select-Object -Unique)

    # ---- verdict: derived, never supplied ----
    # environment_verified decides between pass and logic-only: a clean evidence set only earns pass
    # when the acceptance actually ran in the real target environment (true). false/unknown means
    # the sandbox verified logic only, and the verdict says so instead of passing silently.
    $environmentValue = $EnvironmentVerified
    if ($EnvironmentVerified -ne 'unknown') { $environmentValue = ($EnvironmentVerified -eq 'true') }
    $bugs = @($adversarial | Where-Object { $_.result -eq 'bug' }).Count
    $gaps = @($adversarial | Where-Object { $_.result -eq 'gap' }).Count
    $acceptanceFailed = @($acceptance | Where-Object { $_.result -ne 'pass' }).Count
    $verdict = 'pass'
    if ($acceptance.Count -eq 0 -or $adversarial.Count -eq 0) { $verdict = 'blocked' }
    elseif ($acceptanceFailed -gt 0 -or $bugs -gt 0) { $verdict = 'fail' }
    elseif ($environmentValue -ne $true) { $verdict = 'logic-only' }

    # ---- provenance: the report has to prove it came from this script at this content ----
    $scriptPath = [IO.Path]::GetFullPath($PSCommandPath)
    if (-not $scriptPath.StartsWith($RepoRoot, [StringComparison]::OrdinalIgnoreCase)) {
        Stop-Env 'REPORT_RUNNER_PATH_UNRESOLVED' ("the generator is not inside the repository root: {0}" -f $scriptPath)
    }
    $runnerPath = $scriptPath.Substring($RepoRoot.Length).TrimStart('\', '/').Replace('\', '/')
    $runnerHash = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $generatedAt = (Get-Date).ToString('o')

    $report = [ordered]@{
        flow                 = $FlowName
        run_id               = $RunId
        since                = $Since.ToString('o')
        runner               = [ordered]@{
            path         = $runnerPath
            sha256       = $runnerHash
            run_id       = $RunId
            generated_at = $generatedAt
        }
        generated_at         = $generatedAt
        verdict              = $verdict
        environment_verified = $environmentValue
        acceptance           = @($acceptance)
        skipped              = @($skippedChecks)
        warnings             = @($staleExemptions)
        adversarial          = @($adversarial)
        known_limitations    = @($limitations)
        notes                = [ordered]@{
            acceptance_exit_code = $verifyCode
            acceptance_ok        = [bool]$verify.ok
            acceptance_skipped   = $skippedChecks.Count
            adversarial_bugs     = $bugs
            adversarial_gaps     = $gaps
        }
    }

    $reportJson = $report | ConvertTo-Json -Depth 10
    $stream = [IO.File]::Open($reportPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
    try {
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($reportJson + "`r`n")
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }

    Write-Output ("[run-test-report] flow={0} runId={1} verdict={2} acceptance={3} skipped={4} adversarial={5} gaps={6} bugs={7}" -f
        $FlowName, $RunId, $verdict, $acceptance.Count, $skippedChecks.Count, $adversarial.Count, $gaps, $bugs)
    Write-Output ("[run-test-report] report={0}" -f (ConvertTo-AsciiEscape $reportPath))
    foreach ($warning in $staleExemptions) {
        Write-Output ("OPTIONAL_EXEMPTION_STALE {0}: passed in this run, drop optional/optional_reason" -f $warning.id)
    }
    if ($Json) { Write-Output ("TEST_REPORT_JSON=" + (ConvertTo-AsciiEscape $reportJson)) }
    if ($verdict -eq 'pass') { exit 0 } else { exit 1 }
} finally {
    if (Test-Path -LiteralPath $specPath) { Remove-Item -LiteralPath $specPath -Force -ErrorAction SilentlyContinue }
}
