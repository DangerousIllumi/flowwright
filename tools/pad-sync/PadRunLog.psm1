# PadRunLog.psm1 — the single implementation of the run record (business\logs\<flow>\runs.jsonl)
#
# Why a separate module:
#   "What did one run leave behind" must be answerable in one place, whatever started the run.
#   Four entry points need the same record — the Windows scheduled task (pad-schedule), the batch
#   launcher, the PAD console (after the fact) and an external caller such as CI. Each of them would
#   otherwise invent its own format, and a private format is a format only its author can read.
#
# Contract:
#   - One JSON object per line, appended. The file is history: it is never rewritten and never
#     truncated. One run produces exactly one line; see "one record per run" below.
#   - A field that the caller cannot observe is written as null. It is never defaulted to 0 and never
#     guessed: recording a failure as a success is worse than recording nothing.
#   - Only the outermost party that knows the result writes. A business script writes its result file
#     (RUNNING / OK: / FAIL:), which is overwrite-able current state; it does not write here.
#
# "One record per run": the write happens once, after the process ended, and the file is only ever
#   appended. A caller that measured the start time holds it in memory and passes it to that single
#   write. Nothing writes a "started" line and then a second "finished" line — that would be two
#   records for one run, and editing the first line is forbidden. A run that dies without reaching
#   its writer therefore leaves no record at all; the result file carries its last known state.
#
# Fields (always present, null when unknown):
#   flow          the flow name as the caller knows it
#   source        schedule / pad-console / batch / external (closed set, so values cannot drift)
#   started_at    ISO 8601 with offset, normalised to the local offset
#   finished_at   ISO 8601 with offset, normalised to the local offset
#   rc            process exit code, or null when the entry point has none (PAD console)
#   status        OK / PARTIAL / FAILED / ENV_ERROR / NEEDS_HUMAN / ABORTED, or null when unknown
#   status_raw    the producer's own word (PAD: Succeeded / Failed / Cancelled / NeedsHumanConfirm /
#                 RunTimeout / NotStarted / Unknown), or null when the producer has no such word
#   stage         the producer's own stage word, source-specific — today only pad-sync fills it
#                 (init / admit / lock / static-check / find-designer / inject / publish / trigger /
#                 needs-human-confirm / run / run-timeout / collect / acceptance / done). It is
#                 deliberately NOT a cross-source enum: do not query it across sources, use status
#   run_id        the identifier that lets a re-extraction deduplicate (PAD console runs)
#   evidence      where the record came from: the RunDefinition.json that proved it (pad-console), or the
#                 Workspace revision directory the run used (pad-schedule, so pad-fingerprint can bind a revision
#                 on chains that write no RunDefinition.json)
#
# status mapping table. Losses are deliberate and are recorded in status_raw / stage, never silently
# dropped:
#
#   producer word          status         loss
#   Succeeded              OK             none
#   Failed                 FAILED         none: the flow ran and did not succeed
#   Cancelled              ABORTED        a human stop, a timeout and a PAD shutdown all read the same
#   NeedsHumanConfirm      NEEDS_HUMAN    none
#   RunTimeout             ABORTED        the flow was stopped from outside, it did not fail by itself
#   NotStarted             ABORTED        the flow never ran
#   Unknown                null           the producer itself does not know, and this is a verdict:
#                                         it never falls through to the exit code. pad-sync pairs
#                                         Unknown with ok=$null and then exits 0, so falling through
#                                         would turn "I cannot tell" into OK on an rc=0 run
#
#   A word that is not in this table (pad-sync: Injected / Published) carries no verdict, so it falls
#   through to the exit code. Unknown is in the table and therefore never does.
#
#   exit code, source=batch        0 -> OK, 1 -> PARTIAL, 2 -> ENV_ERROR (batch.js exit-code contract),
#                                  anything else -> ABORTED
#   exit code, source=schedule     0 -> OK, 3 -> NEEDS_HUMAN, 4 -> ABORTED (lock wait timeout),
#                                  5 -> ABORTED (stale calendar). rc=1 is the only ambiguous code:
#                                  pad-sync exits 1 whenever its own result is not ok, and its stage
#                                  says whether that happened before or after the flow started:
#                                    stage after start   -> FAILED
#                                    stage before start  -> ABORTED
#                                    stage null/unknown  -> ABORTED (see the note below)
#   exit code, source=external     0 -> OK, anything else -> ABORTED; a caller that knows the difference
#                                  (some items failed vs never started) passes -Status instead
#   exit code, source=pad-console  never used: PAD records no exit code, so rc is always null
#
# "stage null on rc=1" (schedule). pad-sync prints PAD_SYNC_RESULT, and therefore a stage, on every
#   exit path, so this only happens when the answer is genuinely missing (the child died before
#   printing, or the caller had no way to parse it). The record still says ABORTED rather than null:
#   rc=1 is proof that the run is not OK, and a null status would read as "unknown whether it
#   succeeded", which contradicts the one fact we do have. ABORTED here means exactly "not OK, and
#   not proven to have started" — it never claims OK, and it never claims a completed-but-failed run.
#
# stage words are classified by whether the flow had started running when it stopped. pad-sync prints
#   these; the sets are listed so a new stage word cannot silently land in the wrong bucket (an
#   unknown word is treated like null, i.e. ABORTED, never FAILED).

$script:RunRecordSources = @('schedule', 'pad-console', 'batch', 'external')
$script:RunRecordStatuses = @('OK', 'PARTIAL', 'FAILED', 'ENV_ERROR', 'NEEDS_HUMAN', 'ABORTED')
# pad-sync stages that are only reached once the flow is running
$script:RunRecordStagesAfterStart = @('run', 'run-timeout', 'collect', 'acceptance', 'done')
# pad-sync stages that are only reached before the flow is running
$script:RunRecordStagesBeforeStart = @('init', 'admit', 'lock', 'static-check', 'find-designer',
    'inject', 'publish', 'trigger', 'needs-human-confirm')

function Get-RunRecordSources {
    return $script:RunRecordSources
}

function Get-RunRecordStatuses {
    return $script:RunRecordStatuses
}

# Map "what the producer said" onto the fixed status enum, following the table in the header.
# A producer word wins over an exit code: it is the more specific evidence — except when a non-zero
# exit code would be recorded as OK. That pair contradicts itself, and claiming success after a
# non-zero exit is the one mistake this record must never make, so the status stays null.
# A word that is not in the table carries no information, so it falls through to the exit code —
# except Unknown, which is itself a verdict ("no verdict") and stays null whatever the exit code says.
function ConvertTo-RunRecordStatus {
    param(
        [string]$Source,
        # pad-sync only; other sources have no stage word and the value is ignored
        [string]$Stage,
        [Nullable[int]]$Rc,
        [string]$StatusRaw
    )
    if ($StatusRaw) {
        if ($StatusRaw -eq 'Unknown') { return $null }
        $fromRaw = $null
        switch ($StatusRaw) {
            'Succeeded'         { $fromRaw = 'OK' }
            'Failed'            { $fromRaw = 'FAILED' }
            'Cancelled'         { $fromRaw = 'ABORTED' }
            'NeedsHumanConfirm' { $fromRaw = 'NEEDS_HUMAN' }
            'RunTimeout'        { $fromRaw = 'ABORTED' }
            'NotStarted'        { $fromRaw = 'ABORTED' }
            default             { $fromRaw = $null }
        }
        if ($null -ne $Rc -and $Rc -ne 0 -and $fromRaw -eq 'OK') { return $null }
        if ($fromRaw) { return $fromRaw }
    }
    if ($null -eq $Rc) { return $null }
    if ($Rc -eq 0) { return 'OK' }
    switch ($Source) {
        'batch' {
            if ($Rc -eq 1) { return 'PARTIAL' }
            if ($Rc -eq 2) { return 'ENV_ERROR' }
            return 'ABORTED'
        }
        'schedule' {
            if ($Rc -eq 3) { return 'NEEDS_HUMAN' }
            # rc=1 is the ambiguous code: the stage says whether the flow had started
            if ($Rc -eq 1) {
                if ($Stage -and $script:RunRecordStagesAfterStart -contains $Stage) { return 'FAILED' }
                return 'ABORTED'
            }
            return 'ABORTED'
        }
        # external and pad-console: a non-zero exit code is a non-success, nothing finer is claimed
        default { return 'ABORTED' }
    }
}

# Normalise a timestamp to ISO 8601 round-trip form with an explicit offset, converted to the local
# offset so every record on one machine shares one format and compares lexicographically.
# An empty value stays null (the caller could not observe it). A non-empty value that does not parse
# is a caller bug and fails loudly: silently writing null would hide a broken timestamp forever.
function ConvertTo-RunRecordTime {
    param([string]$Value)
    if (-not $Value -or -not $Value.Trim()) { return $null }
    $parsed = [datetimeoffset]::MinValue
    $ok = [datetimeoffset]::TryParse($Value.Trim(),
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)
    if (-not $ok) {
        throw "RUNRECORD_BAD_TIME: not an ISO 8601 time: '$Value'"
    }
    return $parsed.ToLocalTime().ToString('o')
}

# File names come from a PAD workflow name, which may legally contain path separators.
# Only the characters Windows forbids in a directory name are replaced; the flow field keeps the
# original name, so the record and the directory can still be matched by eye.
function ConvertTo-RunRecordDirectoryName {
    param([string]$Flow)
    $safe = [regex]::Replace([string]$Flow, '[\\/:*?"<>|]', '_').Trim()
    if (-not $safe) {
        throw 'RUNRECORD_BAD_FLOW: flow name is empty; cannot build the record path'
    }
    return $safe
}

function Test-RunRecordRunIdExists {
    param([string]$File, [string]$RunId)
    if (-not $RunId -or -not (Test-Path -LiteralPath $File)) { return $false }
    foreach ($line in [IO.File]::ReadAllLines($File, [Text.Encoding]::UTF8)) {
        if (-not $line.Trim()) { continue }
        try { $record = $line | ConvertFrom-Json } catch { continue }
        if ([string]$record.run_id -eq $RunId) { return $true }
    }
    return $false
}

# Append one record. Returns [ordered]@{ skipped; path; record }:
#   skipped = $true only when a record with the same run_id is already on file (idempotent re-extract);
#   nothing is written in that case.
function Write-RunRecord {
    param(
        [Parameter(Mandatory = $true)][string]$Flow,
        [Parameter(Mandatory = $true)][string]$Source,
        [string]$StartedAt,
        [string]$FinishedAt,
        [Nullable[int]]$Rc,
        # Explicit enum value; when omitted it is derived by ConvertTo-RunRecordStatus
        [string]$Status,
        # The producer's own word; feed to the mapping table (also stored verbatim as status_raw)
        [string]$StatusRaw,
        # The producer's own stage word (pad-sync only); stored verbatim and used to split rc=1
        [string]$Stage,
        [string]$RunId,
        [string]$Evidence,
        # Root of the log tree; defaults to <repo>\business\logs. Only tests and a caller outside this
        # repository pass something else.
        [string]$LogRoot
    )
    if (-not $Flow -or -not $Flow.Trim()) {
        throw 'RUNRECORD_BAD_FLOW: flow name is empty; cannot build the record path'
    }
    if ($script:RunRecordSources -notcontains $Source) {
        throw "RUNRECORD_BAD_SOURCE: unknown source '$Source' (expected: $($script:RunRecordSources -join ', '))"
    }

    $statusValue = $Status
    if (-not $statusValue) {
        $statusValue = ConvertTo-RunRecordStatus -Source $Source -Stage $Stage -Rc $Rc -StatusRaw $StatusRaw
    }
    if ($statusValue -and $script:RunRecordStatuses -notcontains $statusValue) {
        throw "RUNRECORD_BAD_STATUS: unknown status '$statusValue' (expected: $($script:RunRecordStatuses -join ', '))"
    }

    if (-not $LogRoot) {
        $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
        $LogRoot = Join-Path $repoRoot 'business\logs'
    }
    $dir = Join-Path $LogRoot (ConvertTo-RunRecordDirectoryName $Flow)
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $file = Join-Path $dir 'runs.jsonl'

    # Append-only means a repeated extraction must not duplicate the same run
    if (Test-RunRecordRunIdExists -File $file -RunId $RunId) {
        return [ordered]@{ skipped = $true; path = $file; record = $null }
    }

    # Every field is always present; the ones this entry point cannot observe stay null
    $rec = [ordered]@{
        flow        = $Flow
        source      = $Source
        started_at  = ConvertTo-RunRecordTime $StartedAt
        finished_at = ConvertTo-RunRecordTime $FinishedAt
        rc          = $(if ($null -eq $Rc) { $null } else { [int]$Rc })
        status      = $(if ($statusValue) { $statusValue } else { $null })
        status_raw  = $(if ($StatusRaw) { $StatusRaw } else { $null })
        stage       = $(if ($Stage) { $Stage } else { $null })
        run_id      = $(if ($RunId) { $RunId } else { $null })
        evidence    = $(if ($Evidence) { $Evidence } else { $null })
    }

    # Do not use Add-Content: the first write in PS 5.1 adds a BOM, which breaks line-by-line JSONL parsing
    [IO.File]::AppendAllText($file, (($rec | ConvertTo-Json -Depth 4 -Compress) + "`n"),
        (New-Object Text.UTF8Encoding($false)))
    return [ordered]@{ skipped = $false; path = $file; record = $rec }
}

Export-ModuleMember -Function Get-RunRecordSources, Get-RunRecordStatuses, ConvertTo-RunRecordStatus,
    ConvertTo-RunRecordTime, ConvertTo-RunRecordDirectoryName, Test-RunRecordRunIdExists, Write-RunRecord
