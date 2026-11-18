# script-entry.Tests.ps1 — keeps the script-lane entry template honest (Pester 3.4, bundled with PS 5.1)
#
# The template is the only carrier of the contract a PAD shell flow has with an external script:
# argument parsing, a preflight that exits 2 before any work, a result file with RUNNING / OK: / FAIL:,
# and an exit code map. These cases run the template itself, so the contract cannot rot silently.

$script:Entry = Join-Path $PSScriptRoot '..\tools\script-entry\entry-template.js'
$script:Node = (Get-Command node -ErrorAction SilentlyContinue).Source

function New-Work {
    $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $d | Out-Null
    return $d
}

function Invoke-Entry {
    param([string[]]$Arguments)
    $out = & $script:Node $script:Entry @Arguments 2>&1 | Out-String
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

Describe 'Script-lane entry template' {

    It 'the template is present and prints its usage' {
        if (-not $script:Node) { Write-Host '[skip] node is not on PATH'; return }
        (Test-Path -LiteralPath $script:Entry) | Should Be $true
        $r = Invoke-Entry @('--help')
        $r.Code | Should Be 0
        $r.Out | Should Match 'usage:'
    }

    It 'a missing output directory exits 2 before any work and records the failure' {
        if (-not $script:Node) { Write-Host '[skip] node is not on PATH'; return }
        $work = New-Work
        $in = Join-Path $work 'input.txt'
        Set-Content -LiteralPath $in -Value 'x' -Encoding ASCII
        $missing = Join-Path $work 'no-such-dir'
        $state = Join-Path $work 'state.txt'

        $r = Invoke-Entry @('--in', $in, '--out-dir', $missing, '--result-file', $state)
        $r.Code | Should Be 2
        $r.Out | Should Match 'EnvError: output directory not found'
        # nothing was created on the way out
        (Test-Path -LiteralPath $missing) | Should Be $false
        (Get-Content -LiteralPath $state -Raw) | Should Match '^FAIL: 2 '
    }

    It 'a valid run exits 0 and leaves OK: in the result file' {
        if (-not $script:Node) { Write-Host '[skip] node is not on PATH'; return }
        $work = New-Work
        $in = Join-Path $work 'input.txt'
        Set-Content -LiteralPath $in -Value 'x' -Encoding ASCII
        $out = Join-Path $work 'out'
        New-Item -ItemType Directory -Path $out | Out-Null
        $state = Join-Path $work 'state.txt'

        $r = Invoke-Entry @('--in', $in, '--out-dir', $out, '--result-file', $state)
        $r.Code | Should Be 0
        $r.Out | Should Match 'Done: 0/0 ok'
        (Get-Content -LiteralPath $state -Raw) | Should Match '^OK: 0 '
    }

    It 'console output stays ASCII even when a path carries non-ASCII text' {
        if (-not $script:Node) { Write-Host '[skip] node is not on PATH'; return }
        $work = New-Work
        $in = Join-Path $work 'export.txt'
        Set-Content -LiteralPath $in -Value 'x' -Encoding ASCII
        # the missing directory is named in local script: the message carries it, the console must not
        $missing = Join-Path $work ([string][char]0x4E2D + [string][char]0x6587)

        $r = Invoke-Entry @('--in', $in, '--out-dir', $missing)
        $r.Code | Should Be 2
        ([regex]::Matches($r.Out, '[^\x09\x0A\x0D\x20-\x7E]')).Count | Should Be 0
        $r.Out | Should Match '\?\?'
    }
}
