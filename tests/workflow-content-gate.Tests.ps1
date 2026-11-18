# workflow-content-gate.Tests.ps1 — workflow content must live under business/ (Pester 3.4)
#
# Covers: current repository passes, business/ and tests/ are exempt, a workflow artifact type outside
#         business/ fails, a repository-root workflow directory fails, report format stays ASCII.

$script:GateScript = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\publish\check-workflow-content.ps1')).Path
$script:Repo = Split-Path -Parent $PSScriptRoot

function Invoke-Gate([string[]]$Files) {
    $quoted = ($Files | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ','
    $cmd = "& '$($script:GateScript)' -Files @($quoted)"
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1
    return @{ Code = $LASTEXITCODE; Text = ($output -join "`n") }
}

Describe 'Workflow content gate' {

    It 'passes on the current repository' {
        Push-Location $script:Repo
        try { $tracked = @(git ls-files) } finally { Pop-Location }
        $tracked = @($tracked | Where-Object { $_ })
        $tracked.Count | Should BeGreaterThan 0
        $result = Invoke-Gate $tracked
        $result.Code | Should Be 0
        $result.Text | Should Match 'passed'
    }

    It 'exempts business/ and tests/' {
        $result = Invoke-Gate @('business/flows/x.json', 'business/logs/speed-download/run.log', 'tests/fixtures/a.log')
        $result.Code | Should Be 0
    }

    It 'fails on a workflow artifact type outside business/' {
        $result = Invoke-Gate @('out.robin')
        $result.Code | Should Be 1
        $result.Text | Should Match 'WORKFLOW_ARTIFACT_OUTSIDE_BUSINESS out\.robin'
    }

    It 'fails on an Excel configuration table in the public layer' {
        $result = Invoke-Gate @('docs/speed-config.xlsx')
        $result.Code | Should Be 1
        $result.Text | Should Match 'WORKFLOW_ARTIFACT_OUTSIDE_BUSINESS docs/speed-config\.xlsx'
    }

    It 'fails on a log file under tools/' {
        $result = Invoke-Gate @('tools/pad-sync/run.log')
        $result.Code | Should Be 1
        $result.Text | Should Match 'WORKFLOW_ARTIFACT_OUTSIDE_BUSINESS tools/pad-sync/run\.log'
    }

    It 'fails on a repository-root workflow directory even for an unknown extension' {
        $result = Invoke-Gate @('flows/whatever.json', 'logs/run.txt')
        $result.Code | Should Be 1
        $result.Text | Should Match 'WORKFLOW_DIRECTORY_OUTSIDE_BUSINESS flows/whatever\.json'
        $result.Text | Should Match 'WORKFLOW_DIRECTORY_OUTSIDE_BUSINESS logs/run\.txt'
    }

    It 'keeps the report ASCII' {
        $result = Invoke-Gate @('out.robin')
        $nonAscii = [regex]::IsMatch($result.Text, '[^\x00-\x7F]')
        $nonAscii | Should Be $false
    }
}
