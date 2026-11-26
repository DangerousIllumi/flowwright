# Shared declaration helpers for pad-admit and the pre-generation gate.
# Extracted so the early gate and the admission gate use one implementation instead of two parallel ones.

function Test-PropExists($Obj, [string]$Name) {
    if ($null -eq $Obj) { return $false }
    if ($Obj -is [hashtable]) { return $Obj.ContainsKey($Name) }
    return (@($Obj.PSObject.Properties.Name) -contains $Name)
}

# Default task name: the same rule as Get-ScheduleTaskName in pad-schedule, so the two derivations cannot drift apart
function Get-TriggerTaskName([string]$FlowName) {
    $safe = [regex]::Replace([string]$FlowName, '[\\/:*?"<>|\s]', '_').Trim('_')
    if (-not $safe) { return $null }
    return 'flow-ir-' + $safe
}

# Static task-name collision: scan the effective task names declared by other flows under business\flows; a hit means no overwrite
function Find-TriggerTaskCollision {
    param([string]$Repo, [string]$SelfFile, [string]$TaskName)
    $hits = @()
    if (-not $Repo -or -not $TaskName) { return $hits }
    $dir = Join-Path $Repo 'business\flows'
    if (-not (Test-Path -LiteralPath $dir)) { return $hits }
    $self = $null
    if ($SelfFile -and (Test-Path -LiteralPath $SelfFile)) { $self = (Resolve-Path -LiteralPath $SelfFile).Path }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        if ($self -and $f.FullName -eq $self) { continue }
        try { $j = [IO.File]::ReadAllText($f.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { continue }
        if (-not (Test-PropExists $j 'trigger')) { continue }
        $t = $null
        if (Test-PropExists $j.trigger 'task_name') { $t = [string]$j.trigger.task_name }
        elseif ((Test-PropExists $j.trigger 'kind') -and [string]$j.trigger.kind -ne 'manual') {
            $t = Get-TriggerTaskName ([IO.Path]::GetFileNameWithoutExtension($f.Name))
        }
        if ($t -eq $TaskName) { $hits += $f.Name }
    }
    return $hits
}

# Resolve the {{config.<KEY>}} of inputs.dir: read-only; fail hard when it cannot be resolved, never fall back to a literal path
function Resolve-InputDir {
    param([string]$Token, $Config, [string]$ConfigFile)
    $m = [regex]::Match([string]$Token, '^\{\{config\.(\w+)\}\}$')
    if (-not $m.Success) {
        return @{ dir = $null; code = 'INPUT_PATH_LITERAL'
            message = "inputs.dir must be a {{config.<KEY>}} reference, not a literal path: $Token" }
    }
    $key = $m.Groups[1].Value
    if (-not $Config) {
        return @{ dir = $null; code = 'INPUT_CONFIG_UNRESOLVED'
            message = "no config provided; cannot resolve {{config.$key}}; specify it with -ConfigFile" }
    }
    if (-not (Test-PropExists $Config $key) -or -not [string]$Config.$key) {
        return @{ dir = $null; code = 'INPUT_CONFIG_UNRESOLVED'
            message = "config has no usable key $key ($ConfigFile)" }
    }
    return @{ dir = [string]$Config.$key; code = $null; message = $null }
}

# Enumerate the candidates for one inputs entry (dir token + pattern). Returns the raw facts; each caller maps
# them to its own codes, so admission keeps its exact wording while the early gate only reads the count.
function Get-InputCandidates {
    param([string]$DirToken, [string]$Pattern, $Config, [string]$ConfigFile)
    $res = Resolve-InputDir $DirToken $Config $ConfigFile
    if ($res.code) {
        return @{ resolveCode = $res.code; resolveMessage = $res.message; dir = $null; pattern = $Pattern
            dirExists = $false; readable = $false; count = 0; names = @(); error = $null }
    }
    $dir = $res.dir
    $out = @{ resolveCode = $null; resolveMessage = $null; dir = $dir; pattern = $Pattern
        dirExists = $false; readable = $false; count = 0; names = @(); error = $null }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $out }
    $out.dirExists = $true
    try {
        $cands = @(Get-ChildItem -LiteralPath $dir -Filter $Pattern -File -ErrorAction Stop)
    } catch {
        $out.error = $_.Exception.Message
        return $out
    }
    $out.readable = $true
    $out.count = $cands.Count
    $out.names = @($cands | ForEach-Object { $_.Name })
    return $out
}

# Self-produced files wrongly declared as inputs: an inputs entry whose dir or pattern is derived from a
# flow variable ({{variables.X}}) points at a file this flow itself produces, not at an external input.
# The filesystem check in pad-admit (INPUT_FILE_MISSING) only notices at admission time; this static scan
# lets the pre-generation gate name the same mistake before anything is generated.
# Returns one hit per offending entry field: [pscustomobject]@{ node, index, field, value }; empty when clean.
function Find-SelfProducedInputDeclarations {
    param($Flow)
    $hits = @()
    foreach ($n in @($Flow.nodes)) {
        if (-not $n) { continue }
        if (-not (Test-PropExists $n 'inputs')) { continue }
        $list = @($n.inputs)
        for ($i = 0; $i -lt $list.Count; $i++) {
            $it = $list[$i]
            foreach ($field in @('dir', 'pattern')) {
                if (-not (Test-PropExists $it $field)) { continue }
                $raw = $it.$field
                if ($raw -is [string] -and $raw.Contains('{{variables.')) {
                    $hits += [pscustomobject]@{ node = [string]$n.id; index = $i; field = $field; value = $raw }
                }
            }
        }
    }
    return $hits
}

Export-ModuleMember -Function Test-PropExists, Get-TriggerTaskName, Find-TriggerTaskCollision, Resolve-InputDir, Get-InputCandidates, Find-SelfProducedInputDeclarations
