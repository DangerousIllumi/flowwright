<#
.SYNOPSIS
    Workflow-content gate: definitions, configuration, logs and state belong under business/.
.DESCRIPTION
    Scans the given file paths and fails when a workflow artifact type is tracked in the public layer.
    The public layer is everything that is committed; business/ is ignored by .gitignore and blocked by the
    push gate, so a workflow artifact that reaches this list has escaped its home.

    Two conditions fail the gate:
      1. a workflow artifact extension (.robin, .drawio, .xlsx, .xlsm, .accdb, .log) outside business/ and
         outside tests/ (tests keep their own fixtures);
      2. any file under a repository-root workflow directory (flows, config, logs, snapshots, worklog).

    Usage: .\tools\publish\check-workflow-content.ps1 -Files (git ls-files)
    Exit codes: 0 pass, 1 any violation.

    The report stays ASCII so a non-UTF-8 console code page cannot turn the evidence into question marks.
#>
param(
    [string[]]$Files = @()
)

$ErrorActionPreference = 'Stop'

function ConvertTo-RepoRelative {
    param([string]$Path)
    $p = $Path -replace '\\', '/'
    while ($p.StartsWith('./')) { $p = $p.Substring(2) }
    return $p
}

$workflowExtensions = @('.robin', '.drawio', '.xlsx', '.xlsm', '.accdb', '.log')
$rootWorkflowDirectories = @('flows', 'config', 'logs', 'snapshots', 'worklog')

$violations = New-Object System.Collections.ArrayList

foreach ($raw in $Files) {
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }
    $path = ConvertTo-RepoRelative $raw
    $lower = $path.ToLowerInvariant()

    # business/ is the destination, never a violation; tests/ keeps fixtures on purpose.
    if ($lower.StartsWith('business/')) { continue }
    if ($lower.StartsWith('tests/')) { continue }

    $segments = $lower.Split('/')
    if ($segments.Length -gt 1 -and $rootWorkflowDirectories -contains $segments[0]) {
        [void]$violations.Add(("WORKFLOW_DIRECTORY_OUTSIDE_BUSINESS {0}" -f $path))
        continue
    }

    $extension = [IO.Path]::GetExtension($lower)
    if ($workflowExtensions -contains $extension) {
        [void]$violations.Add(("WORKFLOW_ARTIFACT_OUTSIDE_BUSINESS {0}" -f $path))
    }
}

if ($violations.Count -eq 0) {
    Write-Output ("[check-workflow-content] passed ({0} file(s) scanned)" -f $Files.Count)
    exit 0
}

foreach ($violation in $violations) { Write-Output ("[check-workflow-content] {0}" -f $violation) }
Write-Output ("[check-workflow-content] failed: {0} violation(s). Move the file under business/ or, for a produced artifact, record its declared output root in the decision ledger." -f $violations.Count)
exit 1
