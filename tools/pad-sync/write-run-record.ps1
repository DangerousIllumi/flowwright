# write-run-record.ps1 — entry point for "somebody outside this repository started the flow"
#
# Appends one run record to business\logs\<flow>\runs.jsonl through PadRunLog, so a batch launcher,
# CI or another program does not have to reimplement the format. The scheduled task calls the module
# directly (it is inside the repository); everything else calls this script.
#
# What the caller must supply is exactly what it observed. What it did not observe is omitted and
# lands in the record as null — never as 0.
#
#   -StartedAt    the time the process was launched (ISO 8601); empty means "not measured"
#   -FinishedAt   the time the process ended; omitted means "the moment this record was written",
#                 which is correct when the caller invokes this script right after the process exits
#   -Rc           process exit code; omitted means "this entry point has none"
#   -Status       OK / PARTIAL / ENV_ERROR / NEEDS_HUMAN / ABORTED; omitted means "derive from
#                 -StatusRaw first, then -Rc"
#   -StatusRaw    the producer's own word (Succeeded / Failed / Cancelled / ...); stored verbatim
#   -RunId        identifier used to deduplicate; a second call with the same id writes nothing
#
# Exit codes: 0 written (or already present), 1 the record could not be written.
# Stdout: one machine line PAD_RUNRECORD_RESULT=<JSON>; -Quiet prints nothing on success.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Flow,
    [Parameter(Mandatory = $true)][string]$Source,
    [string]$StartedAt = '',
    [string]$FinishedAt = '',
    [Nullable[int]]$Rc,
    [string]$Status,
    [string]$StatusRaw,
    [string]$RunId,
    [string]$Evidence,
    [string]$LogRoot,
    [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PadRunLog.psm1') -Force

try {
    # The script is called at the end of the run, so "now" is the finish time when none was measured
    $finished = $FinishedAt
    if (-not $finished) { $finished = [DateTimeOffset]::Now.ToString('o') }
    $result = Write-RunRecord -Flow $Flow -Source $Source -StartedAt $StartedAt -FinishedAt $finished `
        -Rc $Rc -Status $Status -StatusRaw $StatusRaw -RunId $RunId -Evidence $Evidence -LogRoot $LogRoot
} catch {
    Write-Host ("RUNRECORD_FAILED: " + $_.Exception.Message)
    exit 1
}

if (-not $Quiet) {
    Write-Output ('PAD_RUNRECORD_RESULT=' + ([ordered]@{
        skipped = [bool]$result.skipped
        path    = $result.path
    } | ConvertTo-Json -Compress))
}
exit 0
