<#
.SYNOPSIS
    Output-root registry gate: a path outside business/ must be a registered exception.
.DESCRIPTION
    Workflow content lives under business/. A produced artifact may leave it only when its output root was
    declared as a decision: the root is listed in business/output-roots.json and that entry names a decision
    record in business/decisions.jsonl. This script is the local counterpart of
    check-workflow-content.ps1 (which polices the committed layer).

    Four conditions fail the gate:
      1. a registry entry whose path is not an absolute drive path, or which points inside the repository
         outside business/;
      2. a registry entry without a decision_id, or whose decision_id is missing from decisions.jsonl;
      3. two entries registering the same root;
      4. an absolute path literal in a business script that is neither under business/, nor under a registered
         root, nor an executable path.

    A fifth condition fails the gate: a registry entry whose decision_id has been superseded
    (DECISION_SUPERSEDED). The old ledger row stays on file for the audit trail, but citing it means
    working with a revoked authorisation, which is not an audit concern but an operational one.

    MISSING FILES: SKIP OR FAIL
      - business/ absent -> skip, exit 0, unconditionally. business/ is excluded by .gitignore, so a CI
        runner never checks it out; failing there would fail every build for a file that cannot exist.
      - business/ present but business/output-roots.json absent -> fail, exit 1 (REGISTRY_MISSING). Locally
        the business layer is exactly what these rules govern, so an absent registry means the declaration
        was never made, not that there are no exceptions. A silent pass here is how violations hide.
      - a registry entry exists but business/decisions.jsonl is absent -> fail (LEDGER_MISSING). With zero
        entries there is nothing to resolve, so the ledger is not required in that case.

    Path literals are read as quoted segments plus whitespace-delimited tokens, so a flag that follows a
    path on the same line ("--exp-dir D:\EXP --exp-png-dir D:\IMP") cannot be swallowed into one literal.
    A literal that cannot be resolved is reported, never skipped.

    Usage: .\tools\publish\check-output-roots.ps1 [-RepoRoot c:\path\to\repo]
    Exit codes: 0 pass (or skipped), 1 any violation.

    The report stays ASCII so a non-UTF-8 console code page cannot turn the evidence into question marks;
    non-ASCII characters in a path are printed as \uXXXX escapes.
#>
param(
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) { $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
while ($RepoRoot.Length -gt 3 -and $RepoRoot.EndsWith('\')) { $RepoRoot = $RepoRoot.Substring(0, $RepoRoot.Length - 1) }

$businessRoot = Join-Path $RepoRoot 'business'
$registryFile = Join-Path $businessRoot 'output-roots.json'
$ledgerFile = Join-Path $businessRoot 'decisions.jsonl'

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

function Get-NormalizedPath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.Length -gt 3 -and $full.EndsWith('\')) { $full = $full.Substring(0, $full.Length - 1) }
    return $full
}

function Test-UnderRoot {
    param([string]$Path, [string]$Root)
    if ($Path.Equals($Root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $Root
    if (-not $prefix.EndsWith('\')) { $prefix += '\' }
    return $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-PathLiterals {
    param([string]$Line)
    $values = New-Object System.Collections.ArrayList
    # A path containing a space has to be quoted, so split the line into quoted segments and bare tokens,
    # then take the drive-letter run inside each. Stopping at the token boundary keeps a following flag
    # out of the literal.
    foreach ($token in [regex]::Matches($Line, '"[^"]*"|[^\s"'']+')) {
        $text = $token.Value
        if ($text.Length -ge 2 -and $text[0] -eq '"') { $text = $text.Substring(1, $text.Length - 2) }
        foreach ($found in [regex]::Matches($text, '[A-Za-z]:\\[^"'']*')) { [void]$values.Add($found.Value) }
    }
    return $values
}

if (-not (Test-Path -LiteralPath $businessRoot)) {
    Write-Output '[check-output-roots] skip: business layer not present'
    exit 0
}

if (-not (Test-Path -LiteralPath $registryFile)) {
    # business/ exists locally, so the declaration is missing rather than empty. CI never reaches this
    # branch: it stops at the business/ check above because .gitignore keeps the layer out of the clone.
    Write-Output '[check-output-roots] REGISTRY_MISSING business/output-roots.json is required whenever business/ exists (the gate skips only when business/ itself is absent, which is the CI case)'
    exit 1
}

try {
    $registry = Get-Content -LiteralPath $registryFile -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Output ("[check-output-roots] REGISTRY_UNREADABLE {0}" -f (ConvertTo-AsciiEscape $_.Exception.Message))
    exit 1
}

$violations = New-Object System.Collections.ArrayList

$hasRootsProperty = $null -ne $registry -and $null -ne $registry.PSObject.Properties['roots']
if (-not $hasRootsProperty) {
    [void]$violations.Add('REGISTRY_WITHOUT_ROOTS business/output-roots.json must be an object with a "roots" array')
}
$entries = @()
if ($hasRootsProperty) { $entries = @($registry.roots | Where-Object { $null -ne $_ }) }

$decisionIds = @{}
$supersededIds = @{}
if (Test-Path -LiteralPath $ledgerFile) {
    foreach ($line in Get-Content -LiteralPath $ledgerFile -Encoding UTF8) {
        if (-not $line.Trim()) { continue }
        try { $record = $line | ConvertFrom-Json } catch { continue }
        if ($record.id) { $decisionIds[[string]$record.id] = $true }
        # A record that supersedes another revokes that older record: the old row stays for the audit
        # trail, but it may no longer be cited as an authorisation.
        if ($record.supersedes) { $supersededIds[[string]$record.supersedes] = $true }
    }
} elseif ($entries.Count -gt 0) {
    Write-Output ("[check-output-roots] LEDGER_MISSING business/decisions.jsonl is required to resolve {0} registered root(s)" -f $entries.Count)
    exit 1
}

$roots = New-Object System.Collections.ArrayList
foreach ($entry in $entries) {
    $path = [string]$entry.path
    if (-not $path) {
        [void]$violations.Add('ROOT_ENTRY_WITHOUT_PATH')
        continue
    }
    if ($path -notmatch '^[A-Za-z]:\\') {
        [void]$violations.Add(("ROOT_NOT_ABSOLUTE {0}" -f $path))
        continue
    }
    $full = $null
    try { $full = Get-NormalizedPath $path } catch {
        [void]$violations.Add(("ROOT_UNRESOLVABLE {0}" -f $path))
        continue
    }
    if ((Test-UnderRoot $full $RepoRoot) -and -not (Test-UnderRoot $full $businessRoot)) {
        [void]$violations.Add(("ROOT_INSIDE_REPOSITORY_OUTSIDE_BUSINESS {0}" -f $full))
    }
    $decisionId = [string]$entry.decision_id
    if (-not $decisionId) {
        [void]$violations.Add(("ROOT_WITHOUT_DECISION {0}" -f $full))
    } elseif (-not $decisionIds.ContainsKey($decisionId)) {
        [void]$violations.Add(("DECISION_NOT_IN_LEDGER {0} {1}" -f $full, $decisionId))
    } elseif ($supersededIds.ContainsKey($decisionId)) {
        # The record exists but has been revoked by a later row that supersedes it. Citing it would mean
        # operating on an expired authorisation.
        [void]$violations.Add(("DECISION_SUPERSEDED {0} {1}" -f $full, $decisionId))
    }
    $duplicate = $false
    foreach ($seen in $roots) {
        if ($seen.Equals($full, [StringComparison]::OrdinalIgnoreCase)) { $duplicate = $true; break }
    }
    if ($duplicate) { [void]$violations.Add(("DUPLICATE_ROOT {0}" -f $full)) }
    else { [void]$roots.Add($full) }
}

function Test-CoveredByRegisteredRoot {
    param([string]$Path)
    foreach ($root in $roots) { if (Test-UnderRoot $Path $root) { return $true } }
    return $false
}

$scanExtensions = @('.js', '.py', '.ps1', '.bat')
$scripts = @(Get-ChildItem -Path $businessRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $scanExtensions -contains $_.Extension.ToLowerInvariant() } |
    Where-Object { $_.FullName -notmatch '\\node_modules\\' } |
    Where-Object { $_.FullName -notmatch '\\profile\\' })

foreach ($script in $scripts) {
    $relative = $script.FullName.Substring($RepoRoot.Length).TrimStart('\')
    $lineNumber = 0
    foreach ($line in Get-Content -LiteralPath $script.FullName -Encoding UTF8) {
        $lineNumber++
        foreach ($literal in Get-PathLiterals $line) {
            $candidate = $literal.TrimEnd('.', ')', ',', ';', ']')
            $full = $null
            try { $full = Get-NormalizedPath $candidate } catch {
                [void]$violations.Add(("UNRESOLVABLE_PATH_LITERAL {0} line {1} {2}" -f $relative, $lineNumber, $candidate))
                continue
            }
            if ($full.Length -lt 4) { continue }
            if (Test-UnderRoot $full $businessRoot) { continue }
            if ($full -match '\.(exe|cmd|bat|msi|dll)$') { continue }
            if (Test-CoveredByRegisteredRoot $full) { continue }
            [void]$violations.Add(("UNREGISTERED_OUTPUT_PATH {0} line {1} {2}" -f $relative, $lineNumber, $full))
        }
    }
}

if ($violations.Count -eq 0) {
    Write-Output ("[check-output-roots] passed (registered roots={0}, scripts scanned={1})" -f $roots.Count, $scripts.Count)
    exit 0
}

foreach ($violation in $violations) { Write-Output ("[check-output-roots] {0}" -f (ConvertTo-AsciiEscape $violation)) }
Write-Output ("[check-output-roots] failed: {0} violation(s). Register the root in business/output-roots.json with the decision_id that approved it, or move the path under business/." -f $violations.Count)
exit 1
