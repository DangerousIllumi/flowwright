<#
.SYNOPSIS
    Static gate: scripts and flow definitions must not hardcode a drive-letter path.
.DESCRIPTION
    A path such as C:\flow-ir\business\scripts\x.ps1 outlives the machine and the repository name it was
    written for: when either changes, the code keeps pointing at a directory that no longer exists, and no
    runtime gate notices because nothing else reads the script's own strings.

    Scanned:
      business\scripts\**\*.ps1, business\scripts\**\*.vbs   (code that runs on the target machine)
      business\flows\*.json                                  (definitions that carry paths)

    Allowed, and only allowed, when one of these holds:
      1. the token starts with a root declared in business\config\*.json (for example PAD_ROOT = C:\PAD);
      2. an entry in hardcoded-path-allowlist.json matches this file and this line, and the entry states a
         reason. An entry without a reason is itself invalid: an unexplained exception is how the original
         stale path survived.

    With no business\ layer (the public runner) the gate prints "skip: business layer not present" and
    exits 0, the same contract as check-output-roots.ps1.

    Usage: .\tools\verify\check-hardcoded-paths.ps1 [-RepoRoot <path>]
    Exit codes: 0 clean or skipped / 1 at least one hardcoded path
#>
param(
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) { $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
while ($RepoRoot.Length -gt 3 -and $RepoRoot.EndsWith('\')) { $RepoRoot = $RepoRoot.Substring(0, $RepoRoot.Length - 1) }

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

$businessRoot = Join-Path $RepoRoot 'business'
if (-not (Test-Path -LiteralPath $businessRoot)) {
    Write-Output 'skip: business layer not present'
    exit 0
}

# Latin-1 never fails and maps one byte to one char, so a GBK/UTF-8 file keeps its line structure and its
# ASCII paths stay matchable without guessing the encoding.
function Read-Latin1Lines {
    param([string]$Path)
    $text = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($Path))
    return ($text -split "`n")
}

# ---- allowed roots: every absolute path declared in business\config\*.json ----
$roots = New-Object System.Collections.ArrayList
$configDir = Join-Path $businessRoot 'config'
if (Test-Path -LiteralPath $configDir) {
    foreach ($file in Get-ChildItem -LiteralPath $configDir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        try { $json = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        foreach ($prop in $json.PSObject.Properties) {
            if ($prop.Value -isnot [string]) { continue }
            $value = [string]$prop.Value
            if ($value -match '^[A-Za-z]:\\') {
                $root = $value.TrimEnd('\')
                if (-not ($roots -contains $root)) { [void]$roots.Add($root) }
            }
        }
    }
}

# ---- allowlist: each entry must state why it is allowed ----
$allowPath = Join-Path $RepoRoot 'tools\verify\hardcoded-path-allowlist.json'
$allowEntries = @()
if (Test-Path -LiteralPath $allowPath) {
    try { $allowEntries = @((Get-Content -LiteralPath $allowPath -Raw -Encoding UTF8 | ConvertFrom-Json).entries) } catch { $allowEntries = @() }
}

$violations = New-Object System.Collections.ArrayList
foreach ($entry in $allowEntries) {
    $hasReason = $entry -and ([string]$entry.reason).Trim()
    if (-not $entry -or -not ([string]$entry.file) -or -not ([string]$entry.match) -or -not $hasReason) {
        [void]$violations.Add('ALLOWLIST_ENTRY_INVALID an entry needs file, match and a non-empty reason')
    }
}

# ---- the scan ----
$pathPattern = [regex]'(?<![A-Za-z0-9_])[A-Za-z]:\\'
$tokenPattern = [regex]'^[^\s"'')<>,;]+'

$targets = New-Object System.Collections.ArrayList
$scriptsDir = Join-Path $businessRoot 'scripts'
if (Test-Path -LiteralPath $scriptsDir) {
    foreach ($file in Get-ChildItem -LiteralPath $scriptsDir -Recurse -File -ErrorAction SilentlyContinue) {
        # node_modules holds vendored third-party installers, not code this repository maintains
        if ($file.FullName -match '\\node_modules\\') { continue }
        if ($file.Extension -in @('.ps1', '.vbs')) { [void]$targets.Add($file) }
    }
}
$flowsDir = Join-Path $businessRoot 'flows'
if (Test-Path -LiteralPath $flowsDir) {
    foreach ($file in Get-ChildItem -LiteralPath $flowsDir -File -Filter '*.json' -ErrorAction SilentlyContinue) {
        [void]$targets.Add($file)
    }
}

$scanned = 0
$allowedHits = 0
foreach ($file in $targets) {
    $scanned++
    $relative = $file.FullName.Substring($RepoRoot.Length).TrimStart('\').Replace('\', '/')
    $isJson = ($file.Extension -eq '.json')
    # @() keeps a one-line file a one-element array: a bare string would index as characters
    $lines = @(Read-Latin1Lines $file.FullName)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $haystack = $line
        if ($isJson) { $haystack = $line.Replace('\\', '\') }
        foreach ($match in $pathPattern.Matches($haystack)) {
            $tokenMatch = $tokenPattern.Match($haystack.Substring($match.Index))
            $token = if ($tokenMatch.Success) { $tokenMatch.Value } else { $match.Value }

            $allowedByRoot = $false
            foreach ($root in $roots) {
                if ($token.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                    if ($token.Length -eq $root.Length -or $token[$root.Length] -eq '\') { $allowedByRoot = $true; break }
                }
            }
            if ($allowedByRoot) { $allowedHits++; continue }

            $allowedByEntry = $false
            foreach ($entry in $allowEntries) {
                if (-not $entry -or -not ([string]$entry.reason).Trim()) { continue }
                if ([string]$entry.file -ne $relative) { continue }
                $needle = ([string]$entry.match).Replace('\\', '\')
                if ($token.Contains($needle) -or $haystack.Contains($needle)) { $allowedByEntry = $true; break }
            }
            if ($allowedByEntry) { $allowedHits++; continue }

            $snippet = $token
            if ($snippet.Length -gt 120) { $snippet = $snippet.Substring(0, 120) + '...' }
            [void]$violations.Add(("HARDCODED_PATH {0}:{1}: {2}" -f $relative, ($i + 1), $snippet))
        }
    }
}

if ($violations.Count -gt 0) {
    foreach ($violation in $violations) { Write-Output ("[check-hardcoded-paths] {0}" -f (ConvertTo-AsciiEscape $violation)) }
    Write-Output ("[check-hardcoded-paths] failed: {0} problem(s) across {1} file(s); a drive-letter path must come from config or an explained allowlist entry" -f $violations.Count, $scanned)
    exit 1
}

Write-Output ("[check-hardcoded-paths] passed (files={0}, allowed-hits={1}, roots={2}, allowlist={3})" -f $scanned, $allowedHits, $roots.Count, @($allowEntries).Count)
exit 0
