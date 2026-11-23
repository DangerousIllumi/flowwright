# extract-pad-runs.ps1 — backfill run records for runs started from the PAD console
#
# A run started by clicking Run in the PAD console emits no event this repository can subscribe to,
# so its record has to be read after the fact. The evidence is the run directory PAD keeps:
#
#   %LOCALAPPDATA%\Microsoft\Power Automate Desktop\Console\Scripts\<flowGuid>\Runs\<runId>\
#
# Why RunDefinition.json and not Actions.log: on this machine all 124 run directories carry a
# RunDefinition.json with startTime / endTime / status / workflow.name, while none of their
# Actions.log files carries a run-level summary line (they contain per-action rows only, so the
# last line is the last action, not the outcome). RunDefinition.json is the strictly stronger
# evidence, and using it means no field has to be invented.
#
# rc stays null: PAD records no process exit code for a console run. The status word is kept
# verbatim in status_raw and mapped to the fixed enum by PadRunLog.
#
# Re-running is safe: a record whose run_id is already on file is skipped, never duplicated.
#
# Usage:
#   .\extract-pad-runs.ps1 -Flow 'PAD_SYNC_TEST' -Days 7
#   .\extract-pad-runs.ps1 -Flow 'PAD_SYNC_TEST' -Since 2026-11-01 -DryRun
#   .\extract-pad-runs.ps1 -Flow 'PAD_SYNC_TEST' -ConsoleRoot <dir>   # tests only
#
# Output: one line per run (ASCII only: run id and status word, never the flow name) and a last line
# PAD_EXTRACT_RESULT=<JSON>. Exit code 0 success (including "nothing matched"), 1 failure.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Flow,
    # Only runs that started at or after this time; defaults to now minus -Days
    [datetime]$Since,
    [int]$Days = 7,
    # Root of the log tree; defaults to <repo>\business\logs
    [string]$LogRoot,
    # PAD's run directory root; defaults to the current user's installation
    [string]$ConsoleRoot,
    # Print what would be written and write nothing
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PadRunLog.psm1') -Force

if (-not $PSBoundParameters.ContainsKey('Since')) { $Since = (Get-Date).AddDays(-$Days) }
if (-not $ConsoleRoot) {
    $ConsoleRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\Power Automate Desktop\Console\Scripts'
}

$result = [ordered]@{
    ok = $false; flowMatched = 0; scanned = 0; written = 0; skipped = 0
    unreadable = 0; dryRun = [bool]$DryRun; errors = @()
}
$exitCode = 1

try {
    if (-not (Test-Path -LiteralPath $ConsoleRoot)) {
        throw "CONSOLE_ROOT_MISSING: PAD run directory not found: $ConsoleRoot"
    }
    $runFiles = @(Get-ChildItem -LiteralPath $ConsoleRoot -Recurse `
        -Filter 'RunDefinition.json' -File -ErrorAction SilentlyContinue)
    $result.scanned = $runFiles.Count

    foreach ($file in $runFiles) {
        $rd = $null
        try { $rd = ([IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)) | ConvertFrom-Json }
        catch {
            # A half-written RunDefinition.json belongs to a run in progress; counting it keeps the
            # summary honest instead of silently dropping it
            $result.unreadable++
            continue
        }
        if ([string]$rd.workflow.name -ne $Flow) { continue }
        $started = [datetimeoffset]::MinValue
        if (-not [datetimeoffset]::TryParse([string]$rd.startTime,
                [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::RoundtripKind, [ref]$started)) {
            $result.unreadable++
            continue
        }
        if ($started.LocalDateTime -lt $Since) { continue }
        $result.flowMatched++

        # diagnosticInfo.runId is authoritative; the run directory name is the same value on every
        # observed installation, and is the fallback when the field is absent
        $runId = [string]$rd.diagnosticInfo.runId
        if (-not $runId) { $runId = $file.Directory.Name }

        if ($DryRun) {
            Write-Output ("PAD_EXTRACT_WOULD_WRITE run_id={0} status_raw={1}" -f $runId, $rd.status)
            continue
        }
        $w = Write-RunRecord -Flow $Flow -Source 'pad-console' -StartedAt ([string]$rd.startTime) `
            -FinishedAt ([string]$rd.endTime) -StatusRaw ([string]$rd.status) -RunId $runId `
            -Evidence $file.FullName -LogRoot $LogRoot
        if ($w.skipped) { $result.skipped++ }
        else { $result.written++ }
        Write-Output ("PAD_EXTRACT_RECORD run_id={0} status_raw={1} skipped={2}" -f $runId, $rd.status, $w.skipped)
    }
    $result.ok = $true
    $exitCode = 0
} catch {
    $result.errors += $_.Exception.Message
    Write-Host ("PAD_EXTRACT_FAILED: " + $_.Exception.Message)
}
finally {
    Write-Output ('PAD_EXTRACT_RESULT=' + ($result | ConvertTo-Json -Depth 4 -Compress))
}
exit $exitCode
