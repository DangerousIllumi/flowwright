<#
.SYNOPSIS
    Referenced-path gate: a script a flow starts must still point at something that exists.
.DESCRIPTION
    The other gates read structure: the generator checks actions and parameters, check.js checks the
    generated action lines, eval-flow checks node declarations, pad-admit checks the declaration. None of
    them opens a script that a flow starts. So a helper path that outlived a repository rename stays
    invisible: the flow runs, the helper is never invoked, the result file is never written, and the
    acceptance criterion that would have noticed is marked optional.

    This gate reads exactly one layer:

      1. entry      - script paths referenced by business/flows/*.json. A value counts when it ends in
                      .ps1/.vbs/.py/.bat/.cmd and is %RepoRoot%\..., a drive-letter path, or a path
                      relative to the repository root.
      2. expansion  - each referenced script is opened and its own references are extracted: drive-letter
                      paths, plus literals under business\ on a line that derives them from the script's own
                      location (REPO_ROOT, $PSScriptRoot, GetParentFolderName, WScript.ScriptFullName,
                      %RepoRoot%). That second form is the rename-proof one: the literal stays, the derived
                      base moves, and no other gate notices.
      3. verdict    - a referenced target must exist. A script extension must be an existing file. A data
                      or log path must have an existing parent directory, because the file itself is
                      written at runtime. A path outside the repository and under a root declared in
                      business/config/*.json is deployment state and is counted as covered, not checked:
                      the gate never invents a verdict about a machine it is not running on.
      4. unresolved - a reference that cannot be decided statically ({{variables.X}}, %PadRoot%, $env:,
                      a literal whose base is a variable) is counted and reported in the summary. It is not
                      a violation: the gate reports what it could not see instead of pretending.

    One layer only, existence only, no semantic analysis, no second recursion.

    Usage: .\tools\verify\check-referenced-paths.ps1 [-RepoRoot <path>]
    Exit codes: 0 clean or skipped / 1 at least one referenced target is missing.
    Output is ASCII; non-ASCII characters are printed as \uXXXX escapes.
#>
param(
    [string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

if (-not $RepoRoot) { $RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')) }
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
while ($RepoRoot.Length -gt 3 -and $RepoRoot.EndsWith('\')) { $RepoRoot = $RepoRoot.Substring(0, $RepoRoot.Length - 1) }

$businessRoot = Join-Path $RepoRoot 'business'
if (-not (Test-Path -LiteralPath $businessRoot)) {
    Write-Output 'skip: business layer not present'
    exit 0
}

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

# A UTF-16 script read byte-wise separates every ASCII character with a null byte, so its paths become
# invisible to a byte-preserving read. That is the same kind of blind spot this gate exists to close, so the
# BOM is honoured first; only a file without a BOM is read as Latin-1, which never fails and keeps a
# GBK/UTF-8 file's line structure intact.
function Read-SourceLines {
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        $text = [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
    } elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        $text = [Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
    } elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $text = [Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    } else {
        $text = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
    }
    return ($text -split "`n")
}

function Test-UnderRoot {
    param([string]$Path, [string]$Root)
    if ($Path.Equals($Root, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $Root
    if (-not $prefix.EndsWith('\')) { $prefix += '\' }
    return $Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-RelativePath {
    param([string]$Full)
    return $Full.Substring($RepoRoot.Length).TrimStart('\').Replace('\', '/')
}

function Get-NormalizedPath {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath($Path)
    while ($full.Length -gt 3 -and $full.EndsWith('\')) { $full = $full.Substring(0, $full.Length - 1) }
    return $full
}

# ---- roots the deployment owns: a data path below one of them is not this gate's verdict ----
$configRoots = New-Object System.Collections.ArrayList
$configDir = Join-Path $businessRoot 'config'
if (Test-Path -LiteralPath $configDir) {
    foreach ($file in Get-ChildItem -LiteralPath $configDir -Filter '*.json' -File -ErrorAction SilentlyContinue) {
        try { $json = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        foreach ($prop in $json.PSObject.Properties) {
            if ($prop.Value -isnot [string]) { continue }
            $value = [string]$prop.Value
            if ($value -match '^[A-Za-z]:\\') {
                try { $root = Get-NormalizedPath $value } catch { continue }
                if (-not ($configRoots -contains $root)) { [void]$configRoots.Add($root) }
            }
        }
    }
}

$scriptExtensions = @('.ps1', '.vbs', '.py', '.bat', '.cmd')
$dataExtensions = @('.log', '.txt', '.csv', '.tsv', '.xlsx', '.xls', '.json', '.xml', '.pdf', '.docx')
$scriptExtensionPattern = '(?:ps1|vbs|py|bat|cmd)'
$directoryExtensionPattern = '(?:log|txt|csv|tsv|xlsx|xls|json|xml|pdf|docx|ps1|vbs|py|bat|cmd)'

$script:Root = $RepoRoot
$script:Roots = $configRoots
$script:ScriptExt = $scriptExtensions
$script:DataExt = $dataExtensions
$script:ReferenceCount = 0
$script:UnresolvedCount = 0
$script:CoveredCount = 0
$script:Violations = New-Object System.Collections.ArrayList
$script:SeenReferences = @{}
$script:SeenUnresolved = @{}

function Add-Unresolved {
    param([string]$Where, [string]$Form)
    $key = $Where + '|' + $Form
    if ($script:SeenUnresolved.ContainsKey($key)) { return }
    $script:SeenUnresolved[$key] = $true
    $script:UnresolvedCount++
}

# Resolve a reference literal. Returns @{ Kind = 'path' | 'unresolved'; Path; Reason }.
function Resolve-Reference {
    param([string]$Text)

    $value = $Text.Trim()
    if ($value.Length -ge 2 -and $value.StartsWith('"') -and $value.EndsWith('"')) {
        $value = $value.Substring(1, $value.Length - 2)
    }
    if ($value -match '\{\{') { return @{ Kind = 'unresolved'; Reason = 'template value' } }
    if ($value -match '(?i)%RepoRoot%') {
        $value = [regex]::Replace($value, '(?i)%RepoRoot%', { param($m) $script:Root })
    }
    if ($value -match '%[A-Za-z_][A-Za-z0-9_]*%') { return @{ Kind = 'unresolved'; Reason = '%variable%' } }
    if ($value -match '^[A-Za-z]:\\') { return @{ Kind = 'path'; Path = $value } }
    if ($value -match '^\\\\') { return @{ Kind = 'unresolved'; Reason = 'UNC path' } }

    $relative = $value.TrimStart('\').Replace('/', '\')
    if ($relative -match '^(?i)business\\') {
        return @{ Kind = 'path'; Path = (Join-Path $script:Root $relative) }
    }
    return @{ Kind = 'unresolved'; Reason = 'relative with unknown base' }
}

# Judge one resolved target. Adds a violation, or a covered count, or returns the existing file path.
function Invoke-TargetCheck {
    param(
        [string]$Where,
        [string]$Full
    )

    $insideRepo = Test-UnderRoot $Full $script:Root
    $underConfig = $false
    foreach ($root in $script:Roots) {
        if (Test-UnderRoot $Full $root) { $underConfig = $true; break }
    }
    # A deployment path outside the repository is state on a machine this gate is not running on.
    if (-not $insideRepo -and $underConfig) {
        $script:CoveredCount++
        return $null
    }

    $extension = [IO.Path]::GetExtension($Full).ToLowerInvariant()
    if ($script:ScriptExt -contains $extension) {
        if (-not [IO.File]::Exists($Full)) {
            [void]$script:Violations.Add(("REFERENCE_MISSING {0} -> {1}" -f $Where, $Full))
            return $null
        }
        return $Full
    }
    if ($script:DataExt -contains $extension) {
        $parent = [IO.Path]::GetDirectoryName($Full)
        if ($parent -and -not [IO.Directory]::Exists($parent)) {
            [void]$script:Violations.Add(("REFERENCE_DIR_MISSING {0} -> {1}" -f $Where, $Full))
        }
        return $null
    }
    if (-not [IO.Directory]::Exists($Full)) {
        [void]$script:Violations.Add(("REFERENCE_MISSING {0} -> {1}" -f $Where, $Full))
    }
    return $null
}

function Register-Reference {
    param([string]$Where, [string]$Text)

    $key = $Where + '|' + $Text
    if ($script:SeenReferences.ContainsKey($key)) { return $null }
    $script:SeenReferences[$key] = $true
    $script:ReferenceCount++

    $resolved = Resolve-Reference $Text
    if ($resolved.Kind -ne 'path') {
        Add-Unresolved $Where $resolved.Reason
        return $null
    }
    try { $full = Get-NormalizedPath $resolved.Path } catch {
        Add-Unresolved $Where 'unresolvable path'
        return $null
    }
    return Invoke-TargetCheck $Where $full
}

# ---- flow strings: a value counts when it ends in a script extension ----
function Add-JsonStrings {
    param($Node, $Target)
    if ($null -eq $Node) { return }
    if ($Node -is [string]) { [void]$Target.Add($Node); return }
    if ($Node -is [System.Collections.IEnumerable] -and -not ($Node -is [string])) {
        foreach ($item in $Node) { Add-JsonStrings $item $Target }
        return
    }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $Node.PSObject.Properties) { Add-JsonStrings $prop.Value $Target }
    }
}

$flowLineCache = @{}
# A flow definition is UTF-8. Read it with the same decoding that parsed it, otherwise a non-ASCII file
# name in the raw line cannot be matched against the parsed value and the line number falls back to 1.
function Get-FlowLine {
    param([string]$FlowPath, [string]$Value)
    if (-not $flowLineCache.ContainsKey($FlowPath)) {
        $flowLineCache[$FlowPath] = @([IO.File]::ReadAllLines($FlowPath, [Text.Encoding]::UTF8))
    }
    $lines = $flowLineCache[$FlowPath]
    $escaped = $Value.Replace('\', '\\')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Contains($escaped) -or $lines[$i].Contains($Value)) { return ($i + 1) }
    }
    return 1
}

$flowFiles = @()
$flowsDir = Join-Path $businessRoot 'flows'
if (Test-Path -LiteralPath $flowsDir) {
    $flowFiles = @(Get-ChildItem -LiteralPath $flowsDir -Filter '*.json' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*.requirements.json' -and $_.Name -notlike '*.acceptance.json' })
}

$scriptsToScan = New-Object System.Collections.ArrayList
$analyzedFlows = 0
foreach ($flow in $flowFiles) {
    $flowRelative = Get-RelativePath $flow.FullName
    try { $flowJson = Get-Content -LiteralPath $flow.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
    # business/flows also holds reports that are not definitions (deploy_diff.json); a definition carries
    # a name, so counting anything else as a flow would misstate what was checked.
    if (-not $flowJson.PSObject.Properties['name']) { continue }
    $analyzedFlows++

    $strings = New-Object System.Collections.ArrayList
    Add-JsonStrings $flowJson $strings
    foreach ($raw in $strings) {
        $trimmed = $raw.Trim()
        if ($trimmed -notmatch ('(?i)\.' + $scriptExtensionPattern + '$')) { continue }
        $line = Get-FlowLine $flow.FullName $trimmed
        $where = ('{0}:{1}' -f $flowRelative, $line)
        $found = Register-Reference $where $trimmed
        if ($found -and -not ($scriptsToScan -contains $found)) { [void]$scriptsToScan.Add($found) }
    }
}

# ---- one layer: the referenced scripts' own references ----
$absolutePattern = [regex]('[A-Za-z]:\\[^\s"'';,)\u3000-\u9fff\uff00-\uffef]+')
$derivedPattern = [regex]('(?i)((?:\.\.\\)*business\\[^\s"'';,)\u3000-\u9fff\uff00-\uffef]+\.' + $directoryExtensionPattern + ')')
$quotedRelativePattern = [regex]('"(?:\\|\.\.\\)[^"]*\.' + $directoryExtensionPattern + '"')
$pathExtensionPattern = '\.(?:' + $directoryExtensionPattern + ')'

foreach ($scriptPath in $scriptsToScan) {
    $scriptRelative = Get-RelativePath $scriptPath
    $lines = @(Read-SourceLines $scriptPath)
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $lineNumber = $i + 1
        $line = $lines[$i]
        $where = ('{0}:{1}' -f $scriptRelative, $lineNumber)
        $hasRepoToken = ($line -match '(?i)REPO_ROOT|RepoRoot|PSScriptRoot|ScriptFullName|GetParentFolderName|%RepoRoot%')

        $spans = New-Object System.Collections.ArrayList
        foreach ($match in $absolutePattern.Matches($line)) {
            $token = $match.Value.TrimEnd('.', ',', ')', ']', '}')
            [void]$spans.Add(@($match.Index, ($match.Index + $match.Length)))
            [void](Register-Reference $where $token)
        }

        # The literal is relative on its own; only a line that derives its base from the script's
        # location turns it into a repository path.
        foreach ($match in $derivedPattern.Matches($line)) {
            $insideAbsolute = $false
            foreach ($span in $spans) {
                if ($match.Index -ge $span[0] -and $match.Index -lt $span[1]) { $insideAbsolute = $true; break }
            }
            if ($insideAbsolute) { continue }
            if (-not $hasRepoToken) {
                Add-Unresolved $where 'relative with unknown base'
                continue
            }
            [void](Register-Reference $where $match.Groups[1].Value)
        }

        if ($line -match '\{\{') { Add-Unresolved $where 'template value' }
        if ($line -match '\$env:' -and $line -match $pathExtensionPattern) { Add-Unresolved $where '$env: composition' }

        # A quoted literal rooted in a variable (RESULT_DIR & "\x.txt"): a real reference, but its base is
        # only known at runtime.
        foreach ($match in $quotedRelativePattern.Matches($line)) {
            $inner = $match.Value.Substring(1, $match.Value.Length - 2)
            if ($inner -match '^[A-Za-z]:\\') { continue }
            if ($inner.TrimStart('\') -match '^(?i)business\\') { continue }
            Add-Unresolved $where 'variable-rooted literal'
        }
    }
}

if ($script:Violations.Count -gt 0) {
    foreach ($violation in $script:Violations) {
        Write-Output ("[check-referenced-paths] {0}" -f (ConvertTo-AsciiEscape $violation))
    }
    Write-Output ("[check-referenced-paths] failed: {0} reference(s) point at a target that no longer exists (flows={1}, scripts={2}, references={3}, unresolved={4}); restore the target or derive the path from the repository root" -f $script:Violations.Count, $analyzedFlows, $scriptsToScan.Count, $script:ReferenceCount, $script:UnresolvedCount)
    exit 1
}

Write-Output ("[check-referenced-paths] passed (flows={0}, scripts={1}, references={2}, unresolved={3}, covered={4})" -f $analyzedFlows, $scriptsToScan.Count, $script:ReferenceCount, $script:UnresolvedCount, $script:CoveredCount)
exit 0
