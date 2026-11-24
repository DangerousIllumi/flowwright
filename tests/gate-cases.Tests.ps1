# gate-cases.Tests.ps1 - the three gate negative cases, each run against the real gate (Pester 3.4)
#
# Covers: a script that froze the repository path of its old name (path-origin gate), a script whose
#         derived helper is gone (referenced-path gate), and an optional acceptance skip that never
#         reaches the report summary (verdict gate).
#
# Every case builds the accident's shape under the system temp directory and then runs the gate that
# is supposed to catch it. Nothing is written under the repository's business\: the local business layer
# is a real business layer and is never a test target. Each case also has a positive counterpart - the
# same shape without the defect has to pass - so a red gate can never be a gate that rejects everything.
#
# Trigger commands (one per case, all with -RepoRoot pointing at the sandbox this file builds):
#   env/hardcoded-drive-path           tools\verify\check-hardcoded-paths.ps1  -RepoRoot <sandbox>  -> HARDCODED_PATH, exit 1
#   input/reference-missing-script     tools\verify\check-referenced-paths.ps1 -RepoRoot <sandbox>  -> REFERENCE_MISSING, exit 1
#   output/skipped-acceptance-untraced tools\verify\check-test-report.ps1 -ReportFile <report> -RepoRoot <sandbox> -> SKIPPED_UNTRACED, exit 1

$script:Repo = Split-Path -Parent $PSScriptRoot
$script:HardcodedGate = Join-Path $script:Repo 'tools\verify\check-hardcoded-paths.ps1'
$script:ReferencedGate = Join-Path $script:Repo 'tools\verify\check-referenced-paths.ps1'
$script:ReportGate = Join-Path $script:Repo 'tools\verify\check-test-report.ps1'

# A root that is declared, so the gate has one allowed root and every other drive letter is a violation.
$script:DeclaredRoot = 'C:\deploy-root'

function New-Sandbox {
    param([string]$Name)
    $root = Join-Path $env:TEMP ('flowwright-gate-' + $Name + '-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return $root
}

function Remove-Sandbox {
    param([string]$Root)
    if ($Root -and (Test-Path -LiteralPath $Root)) {
        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Write-SandboxFile {
    param([string]$Root, [string]$Relative, [string]$Text, [switch]$Bom)
    $path = Join-Path $Root $Relative
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $encoding = New-Object Text.UTF8Encoding($Bom.IsPresent)
    [IO.File]::WriteAllText($path, $Text, $encoding)
}

function Invoke-Gate {
    param([string]$Script, [string[]]$Arguments)
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $Script @Arguments 2>&1
    return @{ Code = $LASTEXITCODE; Text = ($output -join "`n") }
}

Describe 'Path-origin gate: env/hardcoded-drive-path' {

    It 'fails on a script that froze the repository path of its old name' {
        $root = New-Sandbox 'hardcoded'
        try {
            Write-SandboxFile $root 'business\config\roots.json' ('{"PAD_ROOT":"' + $script:DeclaredRoot + '"}')
            # The accident: the path was written while the repository still had its old name.
            Write-SandboxFile $root 'business\scripts\run.ps1' @'
$source = 'C:\flow-ir\business\scripts\run.ps1'
if (-not (Test-Path -LiteralPath $source)) { Write-Output 'source missing'; exit 2 }
Write-Output 'ok'
'@ -Bom
            $result = Invoke-Gate $script:HardcodedGate @('-RepoRoot', $root)
            $result.Code | Should Be 1
            $result.Text | Should Match 'HARDCODED_PATH'
            $result.Text | Should Match 'business/scripts/run\.ps1'
            $result.Text | Should Match 'failed: 1 problem'
        } finally { Remove-Sandbox $root }
    }

    It 'passes when the same script derives the path instead of freezing it' {
        $root = New-Sandbox 'hardcoded-ok'
        try {
            Write-SandboxFile $root 'business\config\roots.json' ('{"PAD_ROOT":"' + $script:DeclaredRoot + '"}')
            Write-SandboxFile $root 'business\scripts\run.ps1' @'
$source = Join-Path $PSScriptRoot 'source.txt'
if (-not (Test-Path -LiteralPath $source)) { Write-Output 'source missing'; exit 2 }
Write-Output 'ok'
'@ -Bom
            $result = Invoke-Gate $script:HardcodedGate @('-RepoRoot', $root)
            $result.Code | Should Be 0
            $result.Text | Should Match '\[check-hardcoded-paths\] passed'
        } finally { Remove-Sandbox $root }
    }
}

Describe 'Referenced-path gate: input/reference-missing-script' {

    It 'fails when the helper a script derives from its own location is gone' {
        $root = New-Sandbox 'reference'
        try {
            # The flow starts a script that exists; the script derives a helper that was renamed away.
            Write-SandboxFile $root 'business\flows\case.json' '{"name":"case","variables":[{"name":"ScriptPath","default":"%RepoRoot%\\business\\scripts\\run.vbs"}]}'
            Write-SandboxFile $root 'business\scripts\run.vbs' @'
REPO_ROOT = fso.GetParentFolderName(WScript.ScriptFullName)
HELPER = REPO_ROOT & "\business\scripts\helper.ps1"
'@
            $result = Invoke-Gate $script:ReferencedGate @('-RepoRoot', $root)
            $result.Code | Should Be 1
            $result.Text | Should Match 'REFERENCE_MISSING'
            $result.Text | Should Match 'business/scripts/run\.vbs:2'
            $result.Text | Should Match 'helper\.ps1'
        } finally { Remove-Sandbox $root }
    }

    It 'passes when that helper exists' {
        $root = New-Sandbox 'reference-ok'
        try {
            Write-SandboxFile $root 'business\flows\case.json' '{"name":"case","variables":[{"name":"ScriptPath","default":"%RepoRoot%\\business\\scripts\\run.vbs"}]}'
            Write-SandboxFile $root 'business\scripts\run.vbs' @'
REPO_ROOT = fso.GetParentFolderName(WScript.ScriptFullName)
HELPER = REPO_ROOT & "\business\scripts\helper.ps1"
'@
            Write-SandboxFile $root 'business\scripts\helper.ps1' '# helper'
            $result = Invoke-Gate $script:ReferencedGate @('-RepoRoot', $root)
            $result.Code | Should Be 0
            $result.Text | Should Match '\[check-referenced-paths\] passed'
        } finally { Remove-Sandbox $root }
    }
}

Describe 'Verdict gate: output/skipped-acceptance-untraced' {

    It 'rejects a report whose optional skip was never registered, and passes the traced one' {
        $root = New-Sandbox 'skipped'
        try {
            # The producer and its inputs are copied in, so the report is a real report and not a
            # hand-written one: the verdict gate checks the runner hash against this copy.
            Copy-Item -LiteralPath (Join-Path $script:Repo 'tools') -Destination $root -Recurse -Force
            New-Item -ItemType Directory -Path (Join-Path $root 'tests') -Force | Out-Null
            Copy-Item -LiteralPath (Join-Path $script:Repo 'tests\harness') -Destination (Join-Path $root 'tests') -Recurse -Force
            Copy-Item -LiteralPath (Join-Path $script:Repo 'tests\adversarial') -Destination (Join-Path $root 'tests') -Recurse -Force
            # The harness has its own selftest; emptying the implemented list keeps this case about the
            # verdict gate alone, so the verdict cannot depend on the neutral entry's behaviour.
            Write-SandboxFile $root 'tests\harness\cases.json' '{"entry":"tests/harness/entry/mini-entry.js","implemented":[]}'

            $padRoot = Join-Path $root 'padroot'
            New-Item -ItemType Directory -Path $padRoot -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $padRoot 'present.txt'), 'x', (New-Object Text.UTF8Encoding($false)))

            $flow = [ordered]@{
                name = 'gate-skip'
                acceptance = [ordered]@{
                    description = 'synthetic shape for the untraced skip'
                    checks = @(
                        [ordered]@{ id = 'fileexists-01'; name = 'produced product'; type = 'fileExists'; path = '{{PAD_ROOT}}\present.txt' }
                        [ordered]@{ id = 'fileexists-02'; name = 'optional product that is never produced'; type = 'fileExists'; path = '{{PAD_ROOT}}\absent.txt'; optional = $true; optional_reason = 'the optional export is not produced in this environment' }
                    )
                }
            }
            Write-SandboxFile $root 'business\flows\gate-skip.json' ($flow | ConvertTo-Json -Depth 8)
            Write-SandboxFile $root 'business\config\gate-skip.json' ([ordered]@{ PAD_ROOT = $padRoot } | ConvertTo-Json)

            # The run: one criterion passes, the optional one is skipped on every run.
            $generated = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\verify\run-test-report.ps1') `
                -FlowName gate-skip -RepoRoot $root -RunId r1 -Since '2026-01-01T00:00:00Z' -EnvironmentVerified false 2>&1
            $generateCode = $LASTEXITCODE
            $generateText = ($generated -join "`n")
            $generateCode | Should Be 0
            $generateText | Should Match 'skipped=1'

            $reportPath = Join-Path $root 'business\logs\gate-skip\test-report-r1.json'
            $report = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $skipped = @($report.skipped)
            $skipped.Count | Should Be 1
            $skipped[0].id | Should Be 'fileexists-02'
            @($report.known_limitations | Where-Object { [string]$_ -like 'skipped:*' }).Count | Should Be 1

            # The traced report passes: the skip carries its reason and the reason is registered.
            $traced = Invoke-Gate $script:ReportGate @('-ReportFile', $reportPath, '-RepoRoot', $root)
            $traced.Code | Should Be 0
            $traced.Text | Should Match 'verdict=pass'

            # The accident: the report reaches the gate without the registration of that skip.
            $kept = @(@($report.known_limitations) | Where-Object { -not ([string]$_ -like 'skipped:*') })
            $report.known_limitations = $kept
            $untracedPath = Join-Path $root 'report-untraced.json'
            [IO.File]::WriteAllText($untracedPath, ($report | ConvertTo-Json -Depth 10), (New-Object Text.UTF8Encoding($false)))

            $untraced = Invoke-Gate $script:ReportGate @('-ReportFile', $untracedPath, '-RepoRoot', $root)
            $untraced.Code | Should Be 1
            $untraced.Text | Should Match 'SKIPPED_UNTRACED fileexists-02'
            $untraced.Text | Should Match 'is not registered in known_limitations'
        } finally { Remove-Sandbox $root }
    }
}
