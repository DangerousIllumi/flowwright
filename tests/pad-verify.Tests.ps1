# pad-verify.Tests.ps1 — regression tests proving the acceptance script no longer defaults to a concrete business flow (Pester 3.4)
#
# Why the script is copied into a temporary directory: the flows directory is derived from the script's own location,
# so only a temporary directory can produce the "0 / multiple candidates" failure scenarios.

Describe 'pad-verify no longer defaults to a concrete business flow' {

    # Copy tools\pad-sync into an isolated directory to get a controllable business\flows directory
    function New-VerifySandbox {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $tools = Join-Path $root 'tools\pad-sync'
        New-Item -ItemType Directory -Path $tools -Force | Out-Null
        Copy-Item (Join-Path $PSScriptRoot '..\tools\pad-sync\*') $tools -Recurse -Force
        New-Item -ItemType Directory -Path (Join-Path $root 'business\flows') -Force | Out-Null
        return [pscustomobject]@{
            Script = Join-Path $tools 'pad-verify.ps1'
            Flows  = Join-Path $root 'business\flows'
        }
    }

    # The config only satisfies the -ConfigFile parameter: both cases fail before the flow is parsed and never read the config
    function New-EmptyConfig {
        $p = Join-Path $TestDrive ('cfg-' + [guid]::NewGuid().ToString('N') + '.json')
        [IO.File]::WriteAllText($p, '{}', (New-Object Text.UTF8Encoding($false)))
        return $p
    }

    It 'empty flows directory: non-zero exit demanding an explicit -FlowFile and generating no criteria' {
        $box = New-VerifySandbox
        $cfg = New-EmptyConfig
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $box.Script `
            -BuildFromFlow -ConfigFile $cfg 2>&1 | Out-String
        $LASTEXITCODE | Should Not Be 0
        $out | Should Match 'E_FLOW_FILE_REQUIRED'
        $out | Should Match '-FlowFile'
        # The acceptance-check stage must not be reached. Asserting the absence of its markers (VERIFY_SUMMARY,
        # the "checks" field) was vacuous: this sandbox never contains a runnable flow+criteria pair, so the
        # early-error guard can be broken (e.g. a candidate is defaulted/picked) without those markers ever being
        # printed. Pin the exact early-error output instead: one result line, carrying exactly ok+error.
        $lines = @($out.Trim() -split "`r?`n")
        $lines.Count | Should Be 1
        $r = [regex]::Match($out, 'PAD_VERIFY_RESULT=(\{.*\})').Groups[1].Value | ConvertFrom-Json
        $r.ok | Should Be $false
        $r.error | Should Match '^E_FLOW_FILE_REQUIRED'
        (@($r.PSObject.Properties.Name) -join ',') | Should Be 'ok,error'
    }

    It 'multiple flow candidates: non-zero exit reporting the candidate count' {
        $box = New-VerifySandbox
        foreach ($n in 'a.json', 'b.json') {
            [IO.File]::WriteAllText((Join-Path $box.Flows $n), '{}', (New-Object Text.UTF8Encoding($false)))
        }
        $cfg = New-EmptyConfig
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $box.Script `
            -BuildFromFlow -ConfigFile $cfg 2>&1 | Out-String
        $LASTEXITCODE | Should Not Be 0
        $out | Should Match 'E_FLOW_AMBIGUOUS'
        $out | Should Match 'candidates=2'
        $out | Should Match '-FlowFile'
        # Same vacuous shape as the empty-flows case: only the result line may be printed, and the early error
        # must stay the ambiguous-candidates error (a silently picked candidate would reach a different path).
        $lines = @($out.Trim() -split "`r?`n")
        $lines.Count | Should Be 1
        $r = [regex]::Match($out, 'PAD_VERIFY_RESULT=(\{.*\})').Groups[1].Value | ConvertFrom-Json
        $r.ok | Should Be $false
        $r.error | Should Match '^E_FLOW_AMBIGUOUS\(candidates=2\)'
        (@($r.PSObject.Properties.Name) -join ',') | Should Be 'ok,error'
    }
}
