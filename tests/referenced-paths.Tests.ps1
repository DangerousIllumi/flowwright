# referenced-paths.Tests.ps1 — the one-layer referenced-path gate (Pester 3.4)
#
# Covers: skip when business/ is absent (CI); a flow script and its one-layer helper that both exist;
#         a dead drive-letter script reference inside a flow; a helper derived from the script's own
#         location that is gone; a derived directory that is wrong while the basename exists elsewhere; a
#         log path whose directory is gone; an undecidable reference counted as unresolved, not a failure;
#         a UTF-16 script read with its BOM honoured; ASCII-only output for a non-ASCII missing target; and
#         the checked-out repository itself.

$script:GateScript = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\verify\check-referenced-paths.ps1')).Path
$script:Repo = Split-Path -Parent $PSScriptRoot

function New-TempRepo {
    $root = Join-Path $env:TEMP ('flowwright-references-' + [Guid]::NewGuid().ToString('N'))
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

function Write-Utf16RepoFile {
    param([string]$Root, [string]$Relative, [string]$Text)
    $path = Join-Path $Root $Relative
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($path, $Text, (New-Object Text.UnicodeEncoding($false, $true)))
}

function Set-Flow {
    param([string]$Root, [string]$Value)
    $json = '{"name":"case","variables":[{"name":"ScriptPath","default":"' + $Value + '"}]}'
    Write-RepoFile $Root 'business\flows\case.json' $json
}

Describe 'Referenced-path gate' {

    It 'skips with exit 0 when the business layer is absent (the CI case)' {
        $root = New-TempRepo
        try {
            $result = Invoke-Gate $root
            $result.Code | Should Be 0
            $result.Text | Should Match 'skip: business layer not present'
        } finally { Remove-TempRepo $root }
    }

    It 'passes when a flow script and the helper it derives both exist' {
        $root = New-TempRepo
        try {
            Set-Flow $root '%RepoRoot%\\business\\scripts\\run.vbs'
            Write-RepoFile $root 'business\scripts\run.vbs' ("REPO_ROOT = fso.GetParentFolderName(WScript.ScriptFullName)`n" + 'HELPER = REPO_ROOT & "\business\scripts\helper.ps1"' + "`n")
            Write-RepoFile $root 'business\scripts\helper.ps1' '# helper'
            $result = Invoke-Gate $root
            $result.Code | Should Be 0
            $result.Text | Should Match 'flows=1'
            $result.Text | Should Match 'scripts=1'
            $result.Text | Should Match 'references=2'
        } finally { Remove-TempRepo $root }
    }

    It 'fails on a dead drive-letter script reference in a flow' {
        $root = New-TempRepo
        try {
            Set-Flow $root 'C:\\stale-repo\\business\\scripts\\run.vbs'
            $result = Invoke-Gate $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'REFERENCE_MISSING'
            $result.Text | Should Match 'case\.json:1'
            $result.Text | Should Match 'stale-repo'
        } finally { Remove-TempRepo $root }
    }

    It 'fails when a helper derived from the script location no longer exists' {
        $root = New-TempRepo
        try {
            Set-Flow $root '%RepoRoot%\\business\\scripts\\run.vbs'
            Write-RepoFile $root 'business\scripts\run.vbs' ("REPO_ROOT = fso.GetParentFolderName(WScript.ScriptFullName)`n" + 'HELPER = REPO_ROOT & "\business\scripts\helper.ps1"' + "`n")
            $result = Invoke-Gate $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'REFERENCE_MISSING'
            $result.Text | Should Match 'run\.vbs:2'
            $result.Text | Should Match 'helper\.ps1'
        } finally { Remove-TempRepo $root }
    }

    It 'fails when the derived directory is wrong even though the basename exists elsewhere' {
        $root = New-TempRepo
        try {
            Set-Flow $root '%RepoRoot%\\business\\scripts\\run.vbs'
            Write-RepoFile $root 'business\scripts\run.vbs' ("REPO_ROOT = fso.GetParentFolderName(fso.GetParentFolderName(WScript.ScriptFullName))`n" + 'HELPER = REPO_ROOT & "\business\scriptz\helper.ps1"' + "`n")
            # the file exists, but not where the derivation says it is
            Write-RepoFile $root 'business\scripts\helper.ps1' '# helper'
            $result = Invoke-Gate $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'scriptz'
            $result.Text | Should Match 'run\.vbs:2'
        } finally { Remove-TempRepo $root }
    }

    It 'fails when a log path sits under a directory that no longer exists' {
        $root = New-TempRepo
        try {
            Set-Flow $root '%RepoRoot%\\business\\scripts\\run.ps1'
            Write-RepoFile $root 'business\scripts\run.ps1' '$logFile = "C:\gone-repo\business\scripts\run.log"'
            $result = Invoke-Gate $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'REFERENCE_DIR_MISSING'
            $result.Text | Should Match 'run\.ps1:1'
            $result.Text | Should Match 'gone-repo'
        } finally { Remove-TempRepo $root }
    }

    It 'counts an undecidable reference as unresolved without failing' {
        $root = New-TempRepo
        try {
            Set-Flow $root '%PadRoot%\\scripts\\run.ps1'
            $result = Invoke-Gate $root
            $result.Code | Should Be 0
            $result.Text | Should Match 'unresolved=1'
            $result.Text | Should Match 'scripts=0'
        } finally { Remove-TempRepo $root }
    }

    It 'reads a UTF-16 script whose BOM would otherwise hide every reference' {
        $root = New-TempRepo
        try {
            Set-Flow $root '%RepoRoot%\\business\\scripts\\run.vbs'
            Write-Utf16RepoFile $root 'business\scripts\run.vbs' ("REPO_ROOT = fso.GetParentFolderName(WScript.ScriptFullName)`n" + 'HELPER = REPO_ROOT & "\business\scripts\missing.ps1"' + "`n")
            $result = Invoke-Gate $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'REFERENCE_MISSING'
            $result.Text | Should Match 'missing\.ps1'
        } finally { Remove-TempRepo $root }
    }

    It 'keeps the report ASCII when a missing target contains non-ASCII characters' {
        $root = New-TempRepo
        try {
            # built from code points so this file stays ASCII for the public-language gate
            $cjk = [string][char]0x5bfc + [string][char]0x51fa
            Set-Flow $root ('%RepoRoot%\\business\\scripts\\' + $cjk + '.vbs')
            $result = Invoke-Gate $root
            $result.Code | Should Be 1
            ([regex]::IsMatch($result.Text, '[^\x00-\x7F]')) | Should Be $false
            $result.Text | Should Match '\\u5bfc'
        } finally { Remove-TempRepo $root }
    }

    It 'exits 0 on the checked-out repository (pass locally, skip on CI where business/ is absent)' {
        $result = Invoke-Gate $script:Repo
        $result.Code | Should Be 0
    }
}
