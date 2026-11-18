# output-roots.Tests.ps1 — the output-root registry gate (Pester 3.4)
#
# Covers: skip when business/ is absent (CI), fail when business/ exists but the registry is missing,
#         non-absolute root, missing decision_id, decision_id not in the ledger, ledger missing while a
#         root is registered, duplicate root, unregistered absolute path in a script, a path covered by a
#         registered root, ASCII-only report, and the checked-out repository itself.

$script:GateScript = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\publish\check-output-roots.ps1')).Path
$script:Repo = Split-Path -Parent $PSScriptRoot

function New-TempRepo {
    $root = Join-Path $env:TEMP ('flowwright-output-roots-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return $root
}

function Remove-TempRepo {
    param([string]$Root)
    if ($Root -and (Test-Path -LiteralPath $Root)) {
        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-Gate {
    param([string]$Root)
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:GateScript -RepoRoot $Root 2>&1
    return @{ Code = $LASTEXITCODE; Text = ($output -join "`n") }
}

function Write-RepoFile {
    param([string]$Root, [string]$Relative, [string]$Text)
    $path = Join-Path $Root $Relative
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Set-Registry {
    param([string]$Root, [string]$Json)
    Write-RepoFile $Root 'business\output-roots.json' $Json
}

function Set-Ledger {
    param([string]$Root, [string[]]$Ids)
    $lines = @($Ids | ForEach-Object {
        '{"id":"' + $_ + '","scope":"test","decision":"synthetic record","decided_by":"agent(recorded)","decided_at":"2026-01-01"}'
    })
    Write-RepoFile $Root 'business\decisions.jsonl' ($lines -join "`r`n")
}

Describe 'Output-root registry gate' {

    It 'skips with exit 0 when the business layer is absent (the CI case)' {
        $root = New-TempRepo
        try {
            $result = Invoke-Gate $root
            $result.Code | Should Be 0
            $result.Text | Should Match 'skip: business layer not present'
        } finally { Remove-TempRepo $root }
    }

    It 'fails when business/ exists but the registry is missing (missing registry is a fail, not a skip)' {
        $root = New-TempRepo
        try {
            New-Item -ItemType Directory -Path (Join-Path $root 'business') -Force | Out-Null
            $result = Invoke-Gate $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'REGISTRY_MISSING'
            $result.Text | Should Not Match 'skip:'
        } finally { Remove-TempRepo $root }
    }

    It 'fails on a root that is not an absolute drive path' {
        $root = New-TempRepo
        try {
            Set-Registry $root '{"roots":[{"path":"relative-out","decision_id":"D-1"}]}'
            Set-Ledger $root @('D-1')
            $result = Invoke-Gate $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'ROOT_NOT_ABSOLUTE relative-out'
        } finally { Remove-TempRepo $root }
    }

    It 'fails on a root without decision_id' {
        $root = New-TempRepo
        try {
            Set-Registry $root '{"roots":[{"path":"Q:\\qa\\out"}]}'
            Set-Ledger $root @('D-1')
            $result = Invoke-Gate $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'ROOT_WITHOUT_DECISION Q:\\qa\\out'
        } finally { Remove-TempRepo $root }
    }

    It 'fails on a decision_id that is not in the ledger' {
        $root = New-TempRepo
        try {
            Set-Registry $root '{"roots":[{"path":"Q:\\qa\\out","decision_id":"D-999"}]}'
            Set-Ledger $root @('D-1')
            $result = Invoke-Gate $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'DECISION_NOT_IN_LEDGER Q:\\qa\\out D-999'
        } finally { Remove-TempRepo $root }
    }

    It 'fails when a root is registered but the ledger file is missing' {
        $root = New-TempRepo
        try {
            Set-Registry $root '{"roots":[{"path":"Q:\\qa\\out","decision_id":"D-1"}]}'
            $result = Invoke-Gate $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'LEDGER_MISSING'
        } finally { Remove-TempRepo $root }
    }

    It 'fails on a duplicate root' {
        $root = New-TempRepo
        try {
            Set-Registry $root '{"roots":[{"path":"Q:\\qa\\out","decision_id":"D-1"},{"path":"Q:\\qa\\out\\","decision_id":"D-1"}]}'
            Set-Ledger $root @('D-1')
            $result = Invoke-Gate $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'DUPLICATE_ROOT Q:\\qa\\out'
        } finally { Remove-TempRepo $root }
    }

    It 'fails on an unregistered absolute path in a script' {
        $root = New-TempRepo
        try {
            Set-Registry $root '{"roots":[]}'
            Write-RepoFile $root 'business\scripts\writer.ps1' '$target = "Q:\qa\elsewhere\report.txt"'
            $result = Invoke-Gate $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'UNREGISTERED_OUTPUT_PATH'
            $result.Text | Should Match 'writer\.ps1 line 1'
            $result.Text | Should Match 'Q:\\qa\\elsewhere\\report\.txt'
        } finally { Remove-TempRepo $root }
    }

    It 'passes a script path covered by a registered root' {
        $root = New-TempRepo
        try {
            Set-Registry $root '{"roots":[{"path":"Q:\\qa\\out","decision_id":"D-1"}]}'
            Set-Ledger $root @('D-1')
            Write-RepoFile $root 'business\scripts\writer.ps1' '$target = "Q:\qa\out\deep\report.txt"'
            $result = Invoke-Gate $root
            $result.Code | Should Be 0
            $result.Text | Should Match 'passed \(registered roots=1, scripts scanned=1\)'
        } finally { Remove-TempRepo $root }
    }

    It 'keeps the report ASCII when a path contains non-ASCII characters' {
        $root = New-TempRepo
        try {
            Set-Registry $root '{"roots":[]}'
            # built from code points so this file stays ASCII for the public-language gate
            $cjk = [string][char]0x8868 + [string][char]0x683C
            Write-RepoFile $root 'business\scripts\writer.ps1' ('$target = "Q:\qa\' + $cjk + '\report.txt"')
            $result = Invoke-Gate $root
            $result.Code | Should Be 1
            ([regex]::IsMatch($result.Text, '[^\x00-\x7F]')) | Should Be $false
            $result.Text | Should Match '\\u8868'
        } finally { Remove-TempRepo $root }
    }

    It 'exits 0 on the checked-out repository (pass locally, skip on CI where business/ is absent)' {
        $result = Invoke-Gate $script:Repo
        $result.Code | Should Be 0
    }
}
