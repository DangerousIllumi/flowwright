<#
.SYNOPSIS
    Three gate tiers, one command each: pre-generation, admission, delivery.
.DESCRIPTION
    The checks that guard business/ used to live in five places with no single command that ran them
    together. "Nobody remembers to run them all" is how a dead reference survived for half a year. Each
    tier is orchestration only: it runs the existing gates and reads their exit codes. No gate's verdict is
    re-implemented, relaxed or interpreted beyond pass/skip/red/blocked.

      pregen   decision ledger (check-decisions.js --mode=fail)
               + path origin (check-hardcoded-paths.ps1)
               + referenced-target existence (check-referenced-paths.ps1)
      admit    pregen
               + output-root registry (check-output-roots.ps1)
               + admission (pad-admit.ps1: reversibility/ask, policy, fingerprint, preflight)
      deliver  hold-out set (check-adversarial-set.ps1)
               + acceptance execution and report production (run-test-report.ps1)
               + verdict gate (check-test-report.ps1)

    reuse, not a copy: every child is the existing script, called with the same arguments as before.

    Exit codes: 0 all checks pass or the whole tier skips / 1 at least one check red /
                2 at least one check blocked (a parameter or environment problem, or pad-admit's ask:
                an undeclared reversibility blocks delivery in this repository, so ask maps to 2 here).
    With no business/ layer every tier prints "skip: business layer not present" and exits 0.

    The tier's own lines are ASCII; a child's report is printed unchanged.
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('pregen', 'admit', 'deliver')]
    [string]$Tier,
    [string]$RepoRoot,
    [string]$FlowFile,
    [string]$RobinFile,
    [string]$ConfigFile,
    [string]$ReportFile,
    [string]$RunId,
    [datetime]$Since
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) { $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
while ($RepoRoot.Length -gt 3 -and $RepoRoot.EndsWith('\')) { $RepoRoot = $RepoRoot.Substring(0, $RepoRoot.Length - 1) }

$businessRoot = Join-Path $RepoRoot 'business'
if (-not (Test-Path -LiteralPath $businessRoot)) {
    Write-Output 'skip: business layer not present'
    Write-Output ("[run-gates] tier={0} passed (checks=0, red=0, skip=1)" -f $Tier)
    exit 0
}

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

# A tier that cannot even name its input is a parameter error (exit 2), not a passing tier.
if (-not $FlowFile) {
    Write-Output ("[run-gates] PARAM_FLOW_MISSING tier={0} needs -FlowFile" -f $Tier)
    exit 2
}
$FlowFile = [IO.Path]::GetFullPath($FlowFile)
if (-not (Test-Path -LiteralPath $FlowFile)) {
    Write-Output ("[run-gates] PARAM_FLOW_MISSING flow definition not found: {0}" -f (ConvertTo-AsciiEscape $FlowFile))
    exit 2
}

$flowName = [IO.Path]::GetFileNameWithoutExtension($FlowFile)
if ($ReportFile) { $ReportFile = [IO.Path]::GetFullPath($ReportFile) }
if (-not $RobinFile) {
    $candidate = Join-Path (Split-Path -Parent $FlowFile) ($flowName + '.robin')
    if (Test-Path -LiteralPath $candidate) { $RobinFile = $candidate }
}
if (-not $ConfigFile) {
    $candidate = Join-Path $businessRoot ("config\$flowName.json")
    if (Test-Path -LiteralPath $candidate) { $ConfigFile = $candidate }
}

$script:Total = 0
$script:Red = 0
$script:Skips = 0
$script:Blocked = 0

function Invoke-GateCheck {
    param(
        [string]$Name,
        [string]$Command,
        [string[]]$Arguments
    )

    $script:Total++
    $output = ''
    try {
        $output = (& $Command @Arguments 2>&1 | Out-String)
    } catch {
        $output = [string]$_.Exception.Message
    }
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 1 }

    $state = 'pass'
    if ($code -eq 1) { $state = 'red' }
    elseif ($code -eq 2) { $state = 'blocked' }
    elseif ($code -ne 0) { $state = 'red' }
    elseif ($output -match '(?m)^\s*(\[[^\]]+\]\s*)?skip:') { $state = 'skip' }

    if ($output.Trim()) { Write-Output $output.TrimEnd() }
    Write-Output ("[run-gates] {0}: {1} (exit={2})" -f $Name, $state, $code)

    if ($state -eq 'red') { $script:Red++ }
    elseif ($state -eq 'blocked') { $script:Blocked++ }
    elseif ($state -eq 'skip') { $script:Skips++ }
}

function Invoke-PsGate {
    param([string]$Name, [string]$ScriptPath, [string[]]$Arguments)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptPath) + $Arguments
    Invoke-GateCheck $Name 'powershell' $all
}

# Latest completed run of this flow in the manifest: the only defensible default window for acceptance
# (run-test-report refuses to invent a six-hour window, and so does this tier).
function Get-LatestRunSince {
    $manifest = Join-Path $businessRoot 'manifest.jsonl'
    if (-not (Test-Path -LiteralPath $manifest)) { return $null }
    $padName = $flowName
    try {
        $flowJson = Get-Content -LiteralPath $FlowFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($flowJson.PSObject.Properties['pad_flow_name'] -and [string]$flowJson.pad_flow_name) {
            $padName = [string]$flowJson.pad_flow_name
        }
    } catch { }
    $last = $null
    foreach ($line in [IO.File]::ReadAllLines($manifest, [Text.Encoding]::UTF8)) {
        if (-not $line.Trim()) { continue }
        try { $entry = $line | ConvertFrom-Json } catch { continue }
        if ([string]$entry.type -ne 'run') { continue }
        if ([string]$entry.stage -ne 'done') { continue }
        if ([string]$entry.flow -ne $padName) { continue }
        if ([string]$entry.ts) { $last = [string]$entry.ts }
    }
    if (-not $last) { return $null }
    return [datetime]::Parse($last)
}

$decisionTool = Join-Path $RepoRoot 'tools\verify\check-decisions.js'
$hardcodedTool = Join-Path $RepoRoot 'tools\verify\check-hardcoded-paths.ps1'
$referencedTool = Join-Path $RepoRoot 'tools\verify\check-referenced-paths.ps1'
$outputRootsTool = Join-Path $RepoRoot 'tools\publish\check-output-roots.ps1'
$admitTool = Join-Path $RepoRoot 'tools\pad-sync\pad-admit.ps1'
$adversarialTool = Join-Path $RepoRoot 'tools\verify\check-adversarial-set.ps1'
$reportRunner = Join-Path $RepoRoot 'tools\verify\run-test-report.ps1'
$reportGate = Join-Path $RepoRoot 'tools\verify\check-test-report.ps1'

$repoBoundary = $RepoRoot
if (-not $repoBoundary.EndsWith('\')) { $repoBoundary += '\' }
# The two path gates judge repository content (business/scripts, business/flows). A flow outside the
# repository has nothing for them to judge, and running them anyway would scan the whole business layer on
# behalf of an unrelated file (check-hardcoded-paths alone takes ~7s). The ledger check stays unconditional:
# it reads the flow itself and was already run for every flow before the tiers existed.
$flowInsideRepo = $FlowFile.StartsWith($repoBoundary, [StringComparison]::OrdinalIgnoreCase)

if ($Tier -eq 'pregen' -or $Tier -eq 'admit') {
    Invoke-GateCheck 'decisions' 'node' @($decisionTool, $FlowFile, '--mode=fail')
    if ($flowInsideRepo) {
        Invoke-PsGate 'hardcoded-paths' $hardcodedTool @('-RepoRoot', $RepoRoot)
        Invoke-PsGate 'referenced-paths' $referencedTool @('-RepoRoot', $RepoRoot)
    } else {
        foreach ($name in @('hardcoded-paths', 'referenced-paths')) {
            $script:Total++
            $script:Skips++
            Write-Output ("[run-gates] {0}: skip (flow outside the repository)" -f $name)
        }
    }
}

if ($Tier -eq 'admit') {
    Invoke-PsGate 'output-roots' $outputRootsTool @('-RepoRoot', $RepoRoot)
    $admitArguments = @('-FlowFile', $FlowFile)
    if ($RobinFile) { $admitArguments += @('-RobinFile', $RobinFile) }
    if ($ConfigFile) { $admitArguments += @('-ConfigFile', $ConfigFile) }
    Invoke-PsGate 'pad-admit' $admitTool $admitArguments
}

if ($Tier -eq 'deliver') {
    Invoke-PsGate 'adversarial-set' $adversarialTool @('-RepoRoot', $RepoRoot)

    $report = $ReportFile
    if (-not $report) {
        if (-not $RunId) { $RunId = 'gate-' + (Get-Date -Format 'yyyyMMdd-HHmmss') }
        $logsDir = Join-Path $businessRoot ("logs\$flowName")
        $report = Join-Path $logsDir ("test-report-{0}.json" -f $RunId)
        $runnerArguments = @('-FlowName', $flowName, '-RunId', $RunId, '-FlowFile', $FlowFile, '-RepoRoot', $RepoRoot)
        if ($ConfigFile) { $runnerArguments += @('-ConfigFile', $ConfigFile) }
        $hasSince = $PSBoundParameters.ContainsKey('Since')
        if (-not $hasSince) {
            $manifestSince = Get-LatestRunSince
            if ($manifestSince) { $Since = $manifestSince; $hasSince = $true }
        }
        if ($hasSince) { $runnerArguments += @('-Since', $Since.ToString('o')) }
        Invoke-PsGate 'acceptance+report' $reportRunner $runnerArguments
        if (-not (Test-Path -LiteralPath $report)) { $report = $null }
    }

    if ($report) {
        Invoke-PsGate 'test-report' $reportGate @('-ReportFile', $report, '-RepoRoot', $RepoRoot)
    } else {
        $script:Total++
        $script:Skips++
        Write-Output '[run-gates] test-report: skip (acceptance produced no report to judge)'
    }
}

$red = $script:Red
$blocked = $script:Blocked
$skips = $script:Skips
$total = $script:Total

if ($red -eq 0 -and $blocked -eq 0) {
    Write-Output ("[run-gates] tier={0} passed (checks={1}, red=0, skip={2})" -f $Tier, $total, $skips)
    exit 0
}
Write-Output ("[run-gates] tier={0} failed (checks={1}, red={2}, blocked={3}, skip={4})" -f $Tier, $total, $red, $blocked, $skips)
if ($blocked -gt 0) { exit 2 }
exit 1
