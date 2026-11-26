# eval-flow.Tests.ps1 - declaration-only mode of the design-quality evaluator (Pester 3.4)
#
# Covers: a plain flow.json passed directly as the target, a directory with no *.cases.json, and the
#         unchanged cases mode (a real *.cases.json must keep behaving exactly as before).
# Every temporary flow is built under TestDrive; nothing under tests\eval is modified.

$script:Repo = Split-Path -Parent $PSScriptRoot
$script:EvalFlow = Join-Path $script:Repo 'tools\pad-robin\eval-flow.js'
$script:ExampleFlow = Join-Path $script:Repo 'tools\flow-drawio\example-flow.json'

function Invoke-EvalFlowCli {
    param([string[]]$EvalArgs)
    $code = 0
    $output = @()
    $eap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # Cases files reference their flows by repository-relative path, so run from the repository root
        Push-Location $script:Repo
        try {
            $output = @(& node $script:EvalFlow @EvalArgs 2>&1)
            $code = $LASTEXITCODE
        } finally { Pop-Location }
    } finally { $ErrorActionPreference = $eap }
    return [pscustomobject]@{ code = $code; text = ($output -join "`n") }
}

function New-FlowCopy {
    param([string]$Dir, [switch]$RemoveReversible)
    # Start from the repository example flow and optionally remove one reversible declaration,
    # so the fixture differs from a passing flow in exactly the declaration under test.
    $flow = [IO.File]::ReadAllText($script:ExampleFlow, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if ($RemoveReversible) {
        $node = @($flow.nodes | Where-Object { [string]$_.id -eq '1' })[0]
        $node.PSObject.Properties.Remove('reversible')
    }
    $path = Join-Path $Dir ('flow-' + [guid]::NewGuid().ToString('N') + '.json')
    [IO.File]::WriteAllText($path, ($flow | ConvertTo-Json -Depth 20), (New-Object Text.UTF8Encoding($false)))
    return $path
}

Describe 'eval-flow declaration-only mode (no *.cases.json required)' {

    It 'a complete flow.json passed directly: exit 0 with a declarations-complete PASS line' {
        $r = Invoke-EvalFlowCli @($script:ExampleFlow)
        $r.code | Should Be 0
        $r.text | Should Match 'PASS\s+declarations-complete'
        $r.text | Should Match '\[eval-flow\] passed 1 / 1 \(1 flow samples\)'
    }

    It 'a flow.json missing reversible: exit 1 with a FAIL line naming the node' {
        $dir = Join-Path $TestDrive ('eval-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $flow = New-FlowCopy -Dir $dir -RemoveReversible
        $r = Invoke-EvalFlowCli @($flow)
        $r.code | Should Be 1
        $r.text | Should Match 'FAIL\s+declarations-complete'
        $r.text | Should Match 'node 1'
        $r.text | Should Match 'reversible'
        $r.text | Should Match '\[eval-flow\] passed 0 / 1'
    }

    It 'a directory with no *.cases.json: declarations are checked over the flow definitions inside' {
        $dir = Join-Path $TestDrive ('eval-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $flow = New-FlowCopy -Dir $dir
        # A non-flow companion json in the same directory is skipped, not treated as a read failure
        [IO.File]::WriteAllText((Join-Path $dir 'notes.json'), '{"note":"not a flow"}', (New-Object Text.UTF8Encoding($false)))
        $r = Invoke-EvalFlowCli @($dir)
        $r.code | Should Be 0
        $r.text | Should Match 'PASS\s+declarations-complete'
        $r.text | Should Match '\[eval-flow\] passed 1 / 1 \(1 flow samples\)'
        $r.text | Should Not Match 'notes\.json'
    }

    It 'a directory with a flow missing reversible: exit 1 in declaration-only mode' {
        $dir = Join-Path $TestDrive ('eval-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $flow = New-FlowCopy -Dir $dir -RemoveReversible
        $r = Invoke-EvalFlowCli @($dir)
        $r.code | Should Be 1
        $r.text | Should Match 'FAIL\s+declarations-complete'
        $r.text | Should Match 'node 1'
    }

    It 'a real *.cases.json keeps the old cases behavior: exit 0' {
        $cases = Join-Path $script:Repo 'tests\eval\trigger.cases.json'
        $r = Invoke-EvalFlowCli @($cases)
        $r.code | Should Be 0
        $r.text | Should Match 'PASS\s+declarations-complete'
        $r.text | Should Match 'PASS\s+trigger-missing-reversibility'
        $r.text | Should Match '\[eval-flow\] passed 16 / 16 \(1 flow samples\)'
    }
}

Describe 'eval-flow --warn mode (advisory list, never fails)' {

    It 'a complete flow: exit 0 and a no-missing line' {
        $r = Invoke-EvalFlowCli @($script:ExampleFlow, '--warn')
        $r.code | Should Be 0
        $r.text | Should Match '\[eval-flow\]\[warn\] no missing declaration across 1 flow sample'
    }

    It 'a flow missing reversible: exit 0, and the node plus the field are listed' {
        $dir = Join-Path $TestDrive ('eval-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $flow = New-FlowCopy -Dir $dir -RemoveReversible
        $r = Invoke-EvalFlowCli @($flow, '--warn')
        # the same flow exits 1 without --warn; warn mode must not turn a declaration gap into a failure
        $r.code | Should Be 0
        $r.text | Should Match 'node 1: reversible'
        $r.text | Should Match 'warn-only, generation is not blocked'
        $r.text | Should Not Match 'FAIL'
    }

    It 'every deliberately incomplete public fixture still exits 0' {
        # three trigger fixtures omit reversible on purpose; warn mode names them and still exits 0
        $r = Invoke-EvalFlowCli @((Join-Path $script:Repo 'tests\eval\fixtures'), '--warn')
        $r.code | Should Be 0
        $r.text | Should Match 'trigger-schedule-confirm\.json'
        $r.text | Should Match 'warn-only, generation is not blocked'
    }

    It 'a *.cases.json target is skipped with exit 0 instead of being judged' {
        $r = Invoke-EvalFlowCli @((Join-Path $script:Repo 'tests\eval\trigger.cases.json'), '--warn')
        $r.code | Should Be 0
        $r.text | Should Match 'skip: .* is a case file'
    }
}
