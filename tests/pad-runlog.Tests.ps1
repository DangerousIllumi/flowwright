# pad-runlog.Tests.ps1 — run record writer, its CLI and the PAD console extractor (Pester 3.4)
#
# Covers: the field set is always complete and unknown values stay null, the status enum mapping
#         (including the losses it declares), ISO 8601 timestamps, one record per run, run_id
#         deduplication, the CLI contract, and the extractor reading RunDefinition.json.

Import-Module (Join-Path $PSScriptRoot '..\tools\pad-sync\PadRunLog.psm1') -Force
$script:Module = Join-Path $PSScriptRoot '..\tools\pad-sync\PadRunLog.psm1'
$script:Cli = Join-Path $PSScriptRoot '..\tools\pad-sync\write-run-record.ps1'
$script:Extractor = Join-Path $PSScriptRoot '..\tools\pad-sync\extract-pad-runs.ps1'

function New-LogRoot { return (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) }
function Read-Records([string]$Root, [string]$Flow) {
    $file = Join-Path (Join-Path $Root $Flow) 'runs.jsonl'
    return @([IO.File]::ReadAllLines($file, [Text.Encoding]::UTF8) | Where-Object { $_.Trim() })
}

Describe 'run record: field set' {

    It 'always writes every field and leaves what it cannot observe null' {
        $root = New-LogRoot
        $w = Write-RunRecord -Flow 'F' -Source 'external' -LogRoot $root
        $rec = $w.record
        $names = @($rec.Keys)
        foreach ($k in @('flow', 'source', 'started_at', 'finished_at', 'rc', 'status', 'status_raw', 'stage', 'run_id', 'evidence')) {
            ($names -contains $k) | Should Be $true
        }
        $rec.flow | Should Be 'F'
        $rec.source | Should Be 'external'
        $rec.started_at | Should Be $null
        $rec.finished_at | Should Be $null
        $rec.rc | Should Be $null
        $rec.status | Should Be $null
        $rec.status_raw | Should Be $null
        $rec.stage | Should Be $null
        $rec.run_id | Should Be $null
        $rec.evidence | Should Be $null
    }

    It 'appends one line per record and never rewrites the file' {
        $root = New-LogRoot
        Write-RunRecord -Flow 'F' -Source 'external' -Rc 0 -LogRoot $root | Out-Null
        Write-RunRecord -Flow 'F' -Source 'external' -Rc 1 -LogRoot $root | Out-Null
        $lines = Read-Records $root 'F'
        $lines.Count | Should Be 2
        ($lines[0] | ConvertFrom-Json).rc | Should Be 0
        ($lines[1] | ConvertFrom-Json).rc | Should Be 1
    }

    It 'writes JSONL without a BOM so line-by-line parsing works' {
        $root = New-LogRoot
        $w = Write-RunRecord -Flow 'F' -Source 'schedule' -Rc 0 -LogRoot $root
        # PS 5.1's Add-Content emits a BOM on the first write; this pins the deliberate absence
        ([IO.File]::ReadAllBytes($w.path))[0] | Should Not Be 0xEF
    }

    It 'builds the directory from the flow name but keeps the original flow value' {
        $root = New-LogRoot
        $w = Write-RunRecord -Flow 'a/b:c' -Source 'external' -LogRoot $root
        $w.path | Should Be (Join-Path (Join-Path $root 'a_b_c') 'runs.jsonl')
        (@(Read-Records $root 'a_b_c')[0] | ConvertFrom-Json).flow | Should Be 'a/b:c'
    }

    It 'rejects an unknown source and an unknown status with a stable code' {
        $root = New-LogRoot
        { Write-RunRecord -Flow 'F' -Source 'guess' -LogRoot $root } | Should Throw
        try { Write-RunRecord -Flow 'F' -Source 'guess' -LogRoot $root } catch { $_.Exception.Message | Should Match 'RUNRECORD_BAD_SOURCE' }
        try { Write-RunRecord -Flow 'F' -Source 'external' -Status 'SUCCESS' -LogRoot $root } catch { $_.Exception.Message | Should Match 'RUNRECORD_BAD_STATUS' }
        try { Write-RunRecord -Flow '  ' -Source 'external' -LogRoot $root } catch { $_.Exception.Message | Should Match 'RUNRECORD_BAD_FLOW' }
    }
}

Describe 'run record: status enum' {

    # The mapping table in the module header is the contract; this is its executable copy
    It 'maps the PAD status words onto the fixed enum' {
        (ConvertTo-RunRecordStatus -Source 'pad-console' -StatusRaw 'Succeeded') | Should Be 'OK'
        (ConvertTo-RunRecordStatus -Source 'pad-console' -StatusRaw 'Failed') | Should Be 'FAILED'
        (ConvertTo-RunRecordStatus -Source 'pad-console' -StatusRaw 'Cancelled') | Should Be 'ABORTED'
        (ConvertTo-RunRecordStatus -Source 'pad-console' -StatusRaw 'NeedsHumanConfirm') | Should Be 'NEEDS_HUMAN'
        (ConvertTo-RunRecordStatus -Source 'schedule' -StatusRaw 'RunTimeout') | Should Be 'ABORTED'
        (ConvertTo-RunRecordStatus -Source 'schedule' -StatusRaw 'Unknown') | Should Be $null
        (ConvertTo-RunRecordStatus -Source 'pad-console' -StatusRaw 'SomethingNew') | Should Be $null
    }

    It 'never turns status_raw=Unknown into OK when the exit code is 0' {
        # pad-sync sets status=Unknown together with ok=$null and then exits 0: falling through to
        # "rc=0 -> OK" would record a run PAD could not judge as a success
        (ConvertTo-RunRecordStatus -Source 'schedule' -StatusRaw 'Unknown' -Rc 0) | Should Be $null
        (ConvertTo-RunRecordStatus -Source 'pad-console' -StatusRaw 'Unknown') | Should Be $null
        $root = New-LogRoot
        $w = Write-RunRecord -Flow 'F' -Source 'schedule' -Rc 0 -StatusRaw 'Unknown' -LogRoot $root
        $w.record.status | Should Be $null
        $w.record.status_raw | Should Be 'Unknown'
        $w.record.rc | Should Be 0
    }

    It 'offers exactly six statuses, so a reader can query across sources' {
        $statuses = @(Get-RunRecordStatuses)
        $statuses.Count | Should Be 6
        foreach ($s in @('OK', 'PARTIAL', 'FAILED', 'ENV_ERROR', 'NEEDS_HUMAN', 'ABORTED')) {
            ($statuses -contains $s) | Should Be $true
        }
    }

    It 'splits schedule rc=1 by stage: after the flow started means FAILED, before it means ABORTED' {
        # pad-sync reaches these stages only once the flow is running
        foreach ($stage in @('run', 'run-timeout', 'collect', 'acceptance', 'done')) {
            (ConvertTo-RunRecordStatus -Source 'schedule' -Rc 1 -Stage $stage) | Should Be 'FAILED'
        }
        # ...and these only before it starts
        foreach ($stage in @('init', 'admit', 'lock', 'static-check', 'find-designer', 'inject', 'publish', 'trigger', 'needs-human-confirm')) {
            (ConvertTo-RunRecordStatus -Source 'schedule' -Rc 1 -Stage $stage) | Should Be 'ABORTED'
        }
    }

    It 'keeps schedule rc=1 ABORTED when the stage is missing or unknown, and never guesses FAILED' {
        (ConvertTo-RunRecordStatus -Source 'schedule' -Rc 1) | Should Be 'ABORTED'
        (ConvertTo-RunRecordStatus -Source 'schedule' -Rc 1 -Stage 'something-new') | Should Be 'ABORTED'
        # stage is pad-sync's word; another source carrying one must not change its mapping
        (ConvertTo-RunRecordStatus -Source 'batch' -Rc 3 -Stage 'run') | Should Be 'ABORTED'
    }

    It 'stores the stage verbatim, null when the producer has none' {
        $root = New-LogRoot
        $w = Write-RunRecord -Flow 'F' -Source 'schedule' -Rc 1 -StatusRaw 'Failed' -Stage 'acceptance' -LogRoot $root
        $w.record.stage | Should Be 'acceptance'
        $w.record.status | Should Be 'FAILED'
        (@(Read-Records $root 'F')[0] | ConvertFrom-Json).stage | Should Be 'acceptance'
        (Write-RunRecord -Flow 'F' -Source 'batch' -Rc 0 -LogRoot $root).record.stage | Should Be $null
    }

    It 'maps exit codes per source, and never invents a status without one' {
        (ConvertTo-RunRecordStatus -Source 'batch' -Rc 0) | Should Be 'OK'
        (ConvertTo-RunRecordStatus -Source 'batch' -Rc 1) | Should Be 'PARTIAL'
        (ConvertTo-RunRecordStatus -Source 'batch' -Rc 2) | Should Be 'ENV_ERROR'
        (ConvertTo-RunRecordStatus -Source 'batch' -Rc 9) | Should Be 'ABORTED'
        (ConvertTo-RunRecordStatus -Source 'schedule' -Rc 3) | Should Be 'NEEDS_HUMAN'
        (ConvertTo-RunRecordStatus -Source 'schedule' -Rc 4) | Should Be 'ABORTED'
        (ConvertTo-RunRecordStatus -Source 'schedule' -Rc 5) | Should Be 'ABORTED'
        (ConvertTo-RunRecordStatus -Source 'external' -Rc 0) | Should Be 'OK'
        (ConvertTo-RunRecordStatus -Source 'external' -Rc 2) | Should Be 'ABORTED'
        # PAD console runs have no exit code at all; a null rc must stay a null status
        (ConvertTo-RunRecordStatus -Source 'pad-console') | Should Be $null
    }

    It 'refuses to record OK when the exit code says otherwise' {
        $root = New-LogRoot
        $w = Write-RunRecord -Flow 'F' -Source 'schedule' -Rc 1 -StatusRaw 'Succeeded' -LogRoot $root
        $w.record.status | Should Be $null
        # ...but the producer's own word is still kept, so the contradiction is visible
        $w.record.status_raw | Should Be 'Succeeded'
    }

    It 'lets the producer word win over the exit code when they agree' {
        $root = New-LogRoot
        $w = Write-RunRecord -Flow 'F' -Source 'schedule' -Rc 0 -StatusRaw 'Succeeded' -LogRoot $root
        $w.record.status | Should Be 'OK'
    }
}

Describe 'run record: the schedule entry forwards the stage' {

    It 'takes stage from PAD_SYNC_RESULT, so rc=1 lands as FAILED when the flow had started' {
        # Copy the whole pad-sync folder into the test drive: the record path is derived from the
        # module's own location, so the copy writes under <testdrive>\business\logs and never touches
        # the real business log tree
        $copy = Join-Path $TestDrive ('tools-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $copy 'pad-sync') -Force | Out-Null
        Copy-Item (Join-Path $PSScriptRoot '..\tools\pad-sync\*') (Join-Path $copy 'pad-sync') -Force

        $calendar = Join-Path $TestDrive 'workday-calendar.xlsx'
        [IO.File]::WriteAllBytes($calendar, [byte[]](1, 2, 3))
        $probe = Join-Path $TestDrive 'probe_workday.py'
        [IO.File]::WriteAllText($probe, "print('WORKDAY=1')`nprint('CALENDAR_OK=1')`n",
            (New-Object Text.UTF8Encoding($false)))
        # A stub shaped like the real child: the flow ran and a PAD action failed
        $stub = Join-Path $TestDrive 'stub-pad-sync.ps1'
        [IO.File]::WriteAllText($stub,
            'Write-Output ''PAD_SYNC_RESULT={"ok":false,"stage":"run","status":"Failed"}''; exit 1',
            (New-Object Text.UTF8Encoding($true)))

        $python = (Get-Command python -ErrorAction SilentlyContinue).Source
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $copy 'pad-sync\pad-schedule.ps1') `
            -FlowName 'PAD_SYNC_TEST' -RunIfWorkday -CalendarPath $calendar -PythonExe $python `
            -WorkdayScript $probe -PadSyncPath $stub 2>&1 | Out-String
        # The exit code still comes from the child: adding the record changed no status semantics
        $LASTEXITCODE | Should Be 1

        # PadRunLog derives the log root from its own location: two levels up from <copy>\pad-sync
        $file = Join-Path $TestDrive 'business\logs\PAD_SYNC_TEST\runs.jsonl'
        (Test-Path -LiteralPath $file) | Should Be $true
        $rec = @([IO.File]::ReadAllLines($file, [Text.Encoding]::UTF8) | Where-Object { $_.Trim() })[0] | ConvertFrom-Json
        $rec.source | Should Be 'schedule'
        $rec.rc | Should Be 1
        $rec.stage | Should Be 'run'
        $rec.status_raw | Should Be 'Failed'
        $rec.status | Should Be 'FAILED'
        [string]$rec.started_at | Should Match '^20\d\d-\d\d-\d\dT.*\+08:00$'
    }
}

Describe 'run record: timestamps' {

    It 'normalises to ISO 8601 with an explicit offset, keeping sub-second precision' {
        $root = New-LogRoot
        $w = Write-RunRecord -Flow 'F' -Source 'schedule' -StartedAt '2026-11-22T22:00:01.1234567+08:00' `
            -FinishedAt '2026-11-22T22:05:02+08:00' -Rc 0 -LogRoot $root
        $w.record.started_at | Should Match '^2026-11-22T22:00:01\.1234567\+08:00$'
        $w.record.finished_at | Should Be '2026-11-22T22:05:02.0000000+08:00'
    }

    It 'keeps an empty timestamp null and refuses a value that is not a time' {
        $root = New-LogRoot
        $w = Write-RunRecord -Flow 'F' -Source 'external' -StartedAt '' -LogRoot $root
        $w.record.started_at | Should Be $null
        try { Write-RunRecord -Flow 'F' -Source 'external' -StartedAt '22:00:01' -LogRoot $root } catch {
            $_.Exception.Message | Should Match 'RUNRECORD_BAD_TIME'
        }
    }

    It 'orders records written on one machine lexicographically' {
        $root = New-LogRoot
        Write-RunRecord -Flow 'F' -Source 'external' -StartedAt '2026-11-22T09:00:00+08:00' -Rc 0 -LogRoot $root | Out-Null
        Write-RunRecord -Flow 'F' -Source 'external' -StartedAt '2026-11-22T10:00:00+08:00' -Rc 0 -LogRoot $root | Out-Null
        $records = Read-Records $root 'F' | ForEach-Object { $_ | ConvertFrom-Json }
        ([string]$records[0].started_at) -lt ([string]$records[1].started_at) | Should Be $true
    }
}

Describe 'run record: one record per run' {

    It 'skips a second record with the same run_id instead of duplicating it' {
        $root = New-LogRoot
        $first = Write-RunRecord -Flow 'F' -Source 'pad-console' -RunId 'r-1' -StatusRaw 'Succeeded' -LogRoot $root
        $first.skipped | Should Be $false
        $second = Write-RunRecord -Flow 'F' -Source 'pad-console' -RunId 'r-1' -StatusRaw 'Succeeded' -LogRoot $root
        $second.skipped | Should Be $true
        (Read-Records $root 'F').Count | Should Be 1
        # A different run id is a different run and must still be written
        (Write-RunRecord -Flow 'F' -Source 'pad-console' -RunId 'r-2' -StatusRaw 'Succeeded' -LogRoot $root).skipped | Should Be $false
        (Read-Records $root 'F').Count | Should Be 2
    }
}

Describe 'run record: command-line entry point' {

    It 'writes one record and prints a machine-readable result line' {
        $root = New-LogRoot
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Cli `
            -Flow 'F' -Source 'external' -StartedAt '2026-11-22T09:00:00+08:00' -Rc 0 -LogRoot $root 2>&1
        $LASTEXITCODE | Should Be 0
        ($out -join "`n") | Should Match 'PAD_RUNRECORD_RESULT='
        $rec = @(Read-Records $root 'F')[0] | ConvertFrom-Json
        $rec.status | Should Be 'OK'
        # finished_at is filled with "now" when the caller did not measure it
        [string]$rec.finished_at | Should Match '\+08:00$'
    }

    It 'prints nothing on success with -Quiet' {
        $root = New-LogRoot
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Cli `
            -Flow 'F' -Source 'batch' -Rc 2 -LogRoot $root -Quiet 2>&1
        $LASTEXITCODE | Should Be 0
        @($out | Where-Object { $_ -and $_.Trim() }).Count | Should Be 0
        ((@(Read-Records $root 'F')[0]) | ConvertFrom-Json).status | Should Be 'ENV_ERROR'
    }

    It 'exits 1 with a stable code when the record cannot be written' {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Cli `
            -Flow 'F' -Source 'schedule' -StartedAt 'not-a-time' -LogRoot (New-LogRoot) 2>&1
        $LASTEXITCODE | Should Be 1
        ($out -join "`n") | Should Match 'RUNRECORD_FAILED'
        ($out -join "`n") | Should Match 'RUNRECORD_BAD_TIME'
    }
}

Describe 'run record: PAD console extractor' {

    # Builds the directory shape PAD uses: Scripts\<flowGuid>\Runs\<runId>\RunDefinition.json
    function New-PadRun([string]$Root, [string]$RunId, [string]$Flow, [string]$Status,
        [string]$Start, [string]$End) {
        $dir = Join-Path $Root (Join-Path (Join-Path 'script-guid' 'Runs') $RunId)
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $body = [ordered]@{
            startTime = $Start; endTime = $End; status = $Status
            workflow = [ordered]@{ workflowId = 'script-guid'; name = $Flow }
            diagnosticInfo = [ordered]@{ runId = $RunId; runMode = 'Console' }
        } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText((Join-Path $dir 'RunDefinition.json'), $body, (New-Object Text.UTF8Encoding($false)))
        return $dir
    }

    It 'writes records from RunDefinition.json with rc null and the raw word kept' {
        $console = New-LogRoot
        $logRoot = New-LogRoot
        New-PadRun $console 'run-a' 'Flow A' 'Succeeded' '2026-11-22T09:00:00.1234567Z' '2026-11-22T09:01:00.1Z' | Out-Null
        New-PadRun $console 'run-b' 'Flow A' 'Cancelled' '2026-11-22T10:00:00Z' '2026-11-22T10:00:30Z' | Out-Null
        New-PadRun $console 'run-c' 'Flow B' 'Failed' '2026-11-22T11:00:00Z' '2026-11-22T11:00:05Z' | Out-Null

        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Extractor `
            -Flow 'Flow A' -Since '2026-11-01' -ConsoleRoot $console -LogRoot $logRoot 2>&1
        $LASTEXITCODE | Should Be 0
        $summary = ([regex]::Match(($out -join "`n"), 'PAD_EXTRACT_RESULT=(\{.*\})').Groups[1].Value | ConvertFrom-Json)
        $summary.scanned | Should Be 3
        $summary.flowMatched | Should Be 2
        $summary.written | Should Be 2
        $summary.unreadable | Should Be 0

        $records = Read-Records $logRoot 'Flow A' | ForEach-Object { $_ | ConvertFrom-Json }
        $records.Count | Should Be 2
        $records[0].source | Should Be 'pad-console'
        $records[0].rc | Should Be $null
        $records[0].status | Should Be 'OK'
        $records[0].status_raw | Should Be 'Succeeded'
        $records[0].run_id | Should Be 'run-a'
        $records[0].evidence | Should Match 'RunDefinition\.json$'
        [string]$records[0].started_at | Should Match '\+08:00$'
        $records[1].status | Should Be 'ABORTED'
        $records[1].status_raw | Should Be 'Cancelled'
    }

    It 'is idempotent: a second extraction skips every run already on file' {
        $console = New-LogRoot
        $logRoot = New-LogRoot
        New-PadRun $console 'run-a' 'Flow A' 'Succeeded' '2026-11-22T09:00:00Z' '2026-11-22T09:01:00Z' | Out-Null
        & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Extractor `
            -Flow 'Flow A' -Since '2026-11-01' -ConsoleRoot $console -LogRoot $logRoot 2>&1 | Out-Null
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Extractor `
            -Flow 'Flow A' -Since '2026-11-01' -ConsoleRoot $console -LogRoot $logRoot 2>&1
        $LASTEXITCODE | Should Be 0
        $summary = ([regex]::Match(($out -join "`n"), 'PAD_EXTRACT_RESULT=(\{.*\})').Groups[1].Value | ConvertFrom-Json)
        $summary.written | Should Be 0
        $summary.skipped | Should Be 1
        (Read-Records $logRoot 'Flow A').Count | Should Be 1
    }

    It 'honours the time window and -DryRun' {
        $console = New-LogRoot
        $logRoot = New-LogRoot
        New-PadRun $console 'old-run' 'Flow A' 'Succeeded' '2020-01-01T09:00:00Z' '2020-01-01T09:01:00Z' | Out-Null
        New-PadRun $console 'new-run' 'Flow A' 'Succeeded' '2026-11-22T09:00:00Z' '2026-11-22T09:01:00Z' | Out-Null
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Extractor `
            -Flow 'Flow A' -Since '2026-11-01' -ConsoleRoot $console -LogRoot $logRoot -DryRun 2>&1
        $LASTEXITCODE | Should Be 0
        ($out -join "`n") | Should Match 'PAD_EXTRACT_WOULD_WRITE'
        ($out -join "`n") | Should Match 'new-run'
        ($out -join "`n") | Should Not Match 'old-run'
        (Test-Path (Join-Path $logRoot 'Flow A')) | Should Be $false
    }

    It 'keeps stdout ASCII so a PAD variable never receives a mangled flow name' {
        $console = New-LogRoot
        $logRoot = New-LogRoot
        # A flow name in Chinese must not leak into the console lines
        New-PadRun $console 'run-a' '示例流程' 'Succeeded' '2026-11-22T09:00:00Z' '2026-11-22T09:01:00Z' | Out-Null
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Extractor `
            -Flow '示例流程' -Since '2026-11-01' -ConsoleRoot $console -LogRoot $logRoot 2>&1
        $LASTEXITCODE | Should Be 0
        [regex]::IsMatch(($out -join "`n"), '[^\x00-\x7F]') | Should Be $false
        ((@(Read-Records $logRoot '示例流程')[0]) | ConvertFrom-Json).status | Should Be 'OK'
    }

    It 'fails with a stable code when the PAD run directory does not exist' {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:Extractor `
            -Flow 'Flow A' -ConsoleRoot (Join-Path $TestDrive 'no-such-root') -LogRoot (New-LogRoot) 2>&1
        $LASTEXITCODE | Should Be 1
        ($out -join "`n") | Should Match 'CONSOLE_ROOT_MISSING'
    }
}
