# run-gates.Tests.ps1 — the three gate tiers, one command each (Pester 3.4)
#
# Covers: every tier skips with exit 0 when business/ is absent (the CI case); a tier that cannot name its
# flow exits 2; a real violation turns the pre-generation tier red and the generator refuses to write; a
# failing report turns the delivery tier red; and the checked-out repository passes the pre-generation tier.

$script:GateScript = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\verify\run-gates.ps1')).Path
$script:Repo = Split-Path -Parent $PSScriptRoot
$script:ToolsSource = Join-Path $script:Repo 'tools'

function New-SandboxRepo {
    # A real repository copy of tools/ (868 KB, no junction: a junction plus recursive delete can follow the
    # link and delete the source tree). business/ is created empty so the tiers do not skip.
    param([switch]$WithBusiness)
    $root = Join-Path $env:TEMP ('flowwright-gates-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Copy-Item -LiteralPath $script:ToolsSource -Destination $root -Recurse
    if ($WithBusiness) {
        New-Item -ItemType Directory -Path (Join-Path $root 'business\flows') -Force | Out-Null
        # an existing business layer requires a ledger; an empty one keeps the sandbox honest
        Write-Text (Join-Path $root 'business\decisions.jsonl') ''
    }
    return $root
}

function Remove-SandboxRepo {
    param([string]$Root)
    if ($Root -and (Test-Path -LiteralPath $Root)) {
        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Native stderr is captured through files, never through 2>&1. PowerShell 5.1 turns a native process's
# stderr into an ErrorRecord, and when the caller runs with $ErrorActionPreference = 'Stop' that becomes a
# terminating error which aborts the test block before any assertion runs. Start-Process is not subject to
# the preference, so the test judges the exit code and the streams instead of inheriting the caller's setting.
function Invoke-Captured {
    param([string]$FilePath, [string[]]$Arguments)
    $stdoutFile = [IO.Path]::GetTempFileName()
    $stderrFile = [IO.Path]::GetTempFileName()
    try {
        $quoted = @($Arguments | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
        $process = Start-Process -FilePath $FilePath -ArgumentList $quoted -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        $stdout = [IO.File]::ReadAllText($stdoutFile)
        $stderr = [IO.File]::ReadAllText($stderrFile)
        return @{ Code = $process.ExitCode; StdOut = $stdout; StdErr = $stderr; Text = ($stdout + "`n" + $stderr) }
    } finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Tier {
    param([string]$Tier, [string]$Root, [string[]]$Extra = @())
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:GateScript, '-Tier', $Tier)
    $arguments += $Extra
    if ($Root) { $arguments += @('-RepoRoot', $Root) }
    return Invoke-Captured 'powershell' $arguments
}

function Write-Text {
    param([string]$Path, [string]$Text)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding($false)))
}

Describe 'Gate tiers' {

    It 'skips every tier with exit 0 when the business layer is absent' {
        $root = New-SandboxRepo
        try {
            foreach ($tier in @('pregen', 'admit', 'deliver')) {
                $result = Invoke-Tier $tier $root
                $result.Code | Should Be 0
                $result.Text | Should Match 'skip: business layer not present'
                $result.Text | Should Match ("tier={0} passed" -f $tier)
            }
        } finally { Remove-SandboxRepo $root }
    }

    It 'exits 2 when the tier cannot name a flow' {
        $root = New-SandboxRepo -WithBusiness
        try {
            $result = Invoke-Tier 'pregen' $root
            $result.Code | Should Be 2
            $result.Text | Should Match 'PARAM_FLOW_MISSING'
        } finally { Remove-SandboxRepo $root }
    }

    It 'exits 2 when the named flow does not exist' {
        $root = New-SandboxRepo -WithBusiness
        try {
            $result = Invoke-Tier 'pregen' $root @('-FlowFile', (Join-Path $root 'business\flows\absent.json'))
            $result.Code | Should Be 2
            $result.Text | Should Match 'PARAM_FLOW_MISSING'
        } finally { Remove-SandboxRepo $root }
    }

    It 'passes the pre-generation tier on a clean flow (four checks actually ran)' {
        $root = New-SandboxRepo -WithBusiness
        try {
            $flow = Join-Path $root 'business\flows\ok.json'
            Write-Text $flow '{"name":"ok","variables":[],"nodes":[]}'
            $result = Invoke-Tier 'pregen' $root @('-FlowFile', $flow)
            $result.Code | Should Be 0
            $result.Text | Should Match 'decisions: pass'
            $result.Text | Should Match 'declarations-warn: pass'
            $result.Text | Should Match 'hardcoded-paths: pass'
            $result.Text | Should Match 'referenced-paths: pass'
            $result.Text | Should Match 'inputs-self-produced: pass'
            $result.Text | Should Match 'task-name-collision: pass'
            $result.Text | Should Match 'checks=6, red=0'
        } finally { Remove-SandboxRepo $root }
    }

    It 'lists a node missing reversible but still passes the pre-generation tier (warn-only)' {
        $root = New-SandboxRepo -WithBusiness
        try {
            $flow = Join-Path $root 'business\flows\incomplete.json'
            Write-Text $flow '{"name":"incomplete","variables":[],"nodes":[{"id":"n1","pad_hint":"File.Copy","params":{},"run_mode":"auto","idempotent":true}]}'
            $result = Invoke-Tier 'pregen' $root @('-FlowFile', $flow)
            # the check is advisory: an incomplete declaration is named, never turned into red or blocked
            $result.Code | Should Be 0
            $result.Text | Should Match 'declarations-warn: pass'
            $result.Text | Should Match 'node n1: reversible'
            $result.Text | Should Match 'warn-only, generation is not blocked'
            $result.Text | Should Match 'checks=6, red=0'
        } finally { Remove-SandboxRepo $root }
    }

    It 'warns early on a self-produced inputs entry and a task-name collision without turning red' {
        $root = New-SandboxRepo -WithBusiness
        try {
            $other = Join-Path $root 'business\flows\other.json'
            Write-Text $other '{"name":"other","trigger":{"kind":"schedule","time":"09:00","gate":"none","task_name":"flow-ir-taken"},"variables":[],"nodes":[]}'
            $flow = Join-Path $root 'business\flows\bad-inputs.json'
            Write-Text $flow '{"name":"bad-inputs","trigger":{"kind":"schedule","time":"09:00","gate":"none","task_name":"flow-ir-taken"},"variables":[{"name":"OutDir","type":"string","default":"out"}],"nodes":[{"id":"n1","pad_hint":"File.ReadTextFromFile.ReadText","inputs":[{"dir":"{{variables.OutDir}}","pattern":"*.csv","required":true}],"params":{},"run_mode":"auto","idempotent":true,"reversible":true}]}'
            $result = Invoke-Tier 'pregen' $root @('-FlowFile', $flow)
            # advisory only: the tier stays green, the findings are named before generation
            $result.Code | Should Be 0
            $result.Text | Should Match 'inputs-self-produced: warn'
            $result.Text | Should Match 'node n1 inputs\[0\]\.dir'
            $result.Text | Should Match 'task-name-collision: warn'
            $result.Text | Should Match 'flow-ir-taken'
            $result.Text | Should Match 'checks=6, red=0'
        } finally { Remove-SandboxRepo $root }
    }

    It 'turns the pre-generation tier red on a dead reference and the generator writes nothing' {
        $root = New-SandboxRepo -WithBusiness
        try {
            $flow = Join-Path $root 'business\flows\bad.json'
            Write-Text $flow '{"name":"bad","variables":[{"name":"V","type":"string","default":"C:\\flow-ir\\business\\scripts\\gone.vbs"}],"nodes":[]}'
            $result = Invoke-Tier 'pregen' $root @('-FlowFile', $flow)
            $result.Code | Should Be 1
            $result.Text | Should Match 'referenced-paths: red'
            $result.Text | Should Match 'gone\.vbs'

            # the generator itself must be stopped by the same tier, not only by the command above
            $kb = Join-Path $root 'kb.json'
            Copy-Item -LiteralPath (Join-Path $script:Repo 'examples\smoke-kb.json') -Destination $kb -Force
            $robins = Join-Path $root 'out.robin'
            $generated = Invoke-Captured 'node' @((Join-Path $root 'tools\pad-robin\flow-to-robin.js'), $flow, $robins, '--kb', $kb, '--no-check')
            $generated.Code | Should Be 1
            ($generated.StdErr -match 'Pre-generation gate rejected the flow') | Should Be $true
            (Test-Path -LiteralPath $robins) | Should Be $false
        } finally { Remove-SandboxRepo $root }
    }

    It 'turns the delivery tier red when the report is not a pass' {
        $root = New-SandboxRepo -WithBusiness
        try {
            Copy-Item -LiteralPath (Join-Path $script:Repo 'tests\adversarial') -Destination $root -Recurse
            $flow = Join-Path $root 'business\flows\ok.json'
            Write-Text $flow '{"name":"ok","variables":[],"nodes":[]}'
            $report = Join-Path $root 'report.json'
            Write-Text $report '{"verdict":"fail"}'
            $result = Invoke-Tier 'deliver' $root @('-FlowFile', $flow, '-ReportFile', $report)
            $result.Code | Should Be 1
            $result.Text | Should Match 'test-report: red'
            $result.Text | Should Match 'VERDICT_NOT_PASS'
        } finally { Remove-SandboxRepo $root }
    }

    It 'passes the pre-generation tier on the checked-out repository (skip on CI where business/ is absent)' {
        # a public sample, so this file carries no business name; the tier skips before reading the flow
        # when business/ is absent, and judges the repository layer when it is present
        $result = Invoke-Tier 'pregen' $null @('-FlowFile', (Join-Path $script:Repo 'tests\eval\fixtures\file-copy-text.json'))
        $result.Code | Should Be 0
    }
}
