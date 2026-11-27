<#
.SYNOPSIS
    Adversarial-set gate: the hold-out cases belong to verification and generation must not read them.
.DESCRIPTION
    tests/adversarial/<category>/<case>.json is written by the verification role (T) only. The generation
    role (B) must not read it: the set is the only thing that keeps "passes the tests" different from
    "does what the spec says", and a generator that can see the expectations is written to the test.

    Four conditions fail the gate:
      1. no tests/adversarial directory, or a case file that does not parse;
      2. a category folder that is not one of the five known ones (input, data, auth, output, env), or a case
         whose category differs from its folder;
      3. a case whose id is not "<category>/<file name without .json>", or which declares no expectation:
         "exit_code" or "status" is required, because a case without an expected outcome is exploration;
      4. a file under tools/pad-robin/ (the generator) that references the adversarial directory.

    Usage: .\tools\verify\check-adversarial-set.ps1 [-RepoRoot <path>] [-AdversarialRoot <path>]
    Exit codes: 0 pass, 1 any violation.

    The report stays ASCII so a non-UTF-8 console code page cannot turn the evidence into question marks.
#>
param(
    [string]$RepoRoot,
    [string]$AdversarialRoot
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) { $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
while ($RepoRoot.Length -gt 3 -and $RepoRoot.EndsWith('\')) { $RepoRoot = $RepoRoot.Substring(0, $RepoRoot.Length - 1) }
if (-not $AdversarialRoot) { $AdversarialRoot = Join-Path $RepoRoot 'tests\adversarial' }
$AdversarialRoot = [IO.Path]::GetFullPath($AdversarialRoot)

$knownCategories = @('input', 'data', 'auth', 'output', 'env')
$knownStatuses = @('OK', 'PARTIAL', 'ENV_ERROR', 'NEEDS_HUMAN', 'ABORTED')

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

function Test-UnderRoot {
    param([string]$Path, [string]$Root)
    if ($Path.Equals($Root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $Root
    if (-not $prefix.EndsWith('\')) { $prefix += '\' }
    return $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

if (-not (Test-Path -LiteralPath $AdversarialRoot)) {
    Write-Output '[check-adversarial-set] ADVERSARIAL_SET_MISSING tests/adversarial/<category>/ is the hold-out set; an absent set is not a pass'
    exit 1
}

$violations = New-Object System.Collections.ArrayList
$caseCount = 0
$categories = @{}
$relativeRoot = $AdversarialRoot.Substring($RepoRoot.Length).TrimStart('\')

foreach ($folder in @(Get-ChildItem -LiteralPath $AdversarialRoot -Directory -ErrorAction SilentlyContinue)) {
    $category = $folder.Name
    if ($knownCategories -notcontains $category) {
        [void]$violations.Add(("UNKNOWN_CATEGORY {0}\{1}" -f $relativeRoot, $category))
        continue
    }
    foreach ($case in @(Get-ChildItem -LiteralPath $folder.FullName -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
        $caseCount++
        $categories[$category] = $true
        $relative = $case.FullName.Substring($AdversarialRoot.Length).TrimStart('\')
        try {
            $record = Get-Content -LiteralPath $case.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            [void]$violations.Add(("CASE_UNREADABLE {0}" -f (ConvertTo-AsciiEscape $relative)))
            continue
        }
        $expectedId = '{0}/{1}' -f $category, $case.BaseName
        if ([string]$record.id -ne $expectedId) {
            [void]$violations.Add(("CASE_ID_MISMATCH {0} id={1}" -f $relative, $record.id))
        }
        if ([string]$record.category -ne $category) {
            [void]$violations.Add(("CASE_CATEGORY_MISMATCH {0} category={1}" -f $relative, $record.category))
        }
        $expected = $record.expected
        $hasExit = $false
        $hasStatus = $false
        if ($null -ne $expected) {
            $hasExit = $null -ne $expected.PSObject.Properties['exit_code']
            $hasStatus = $null -ne $expected.PSObject.Properties['status']
        }
        if (-not $hasExit -and -not $hasStatus) {
            [void]$violations.Add(("CASE_WITHOUT_EXPECTATION {0}" -f $relative))
        }
        if ($hasStatus -and ($knownStatuses -notcontains [string]$expected.status)) {
            [void]$violations.Add(("CASE_UNKNOWN_STATUS {0} status={1}" -f $relative, $expected.status))
        }
        if ($hasExit -and ([string]$expected.exit_code -notmatch '^\d{1,3}$')) {
            [void]$violations.Add(("CASE_BAD_EXIT_CODE {0} exit_code={1}" -f $relative, $expected.exit_code))
        }
    }
}

$generatorRoot = Join-Path $RepoRoot 'tools\pad-robin'
if (Test-Path -LiteralPath $generatorRoot) {
    $generatorFiles = @(Get-ChildItem -LiteralPath $generatorRoot -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in @('.js', '.ps1', '.json') } |
        Where-Object { $_.FullName -notmatch '\\node_modules\\' })
    foreach ($file in $generatorFiles) {
        $lineNumber = 0
        foreach ($line in Get-Content -LiteralPath $file.FullName -Encoding UTF8) {
            $lineNumber++
            if ($line -match 'tests[\\/]+adversarial') {
                $relative = $file.FullName.Substring($RepoRoot.Length).TrimStart('\')
                [void]$violations.Add(("ADVERSARIAL_READ_BY_GENERATOR {0} line {1}" -f $relative, $lineNumber))
            }
        }
    }
}

if ($violations.Count -eq 0) {
    Write-Output ("[check-adversarial-set] passed (cases={0}, categories={1})" -f $caseCount, $categories.Count)
    exit 0
}

foreach ($violation in $violations) { Write-Output ("[check-adversarial-set] {0}" -f (ConvertTo-AsciiEscape $violation)) }
Write-Output ("[check-adversarial-set] failed: {0} violation(s). Fix the case under tests/adversarial/ or remove the generator's reference to it." -f $violations.Count)
exit 1
