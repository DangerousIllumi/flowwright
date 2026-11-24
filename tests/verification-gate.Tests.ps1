# verification-gate.Tests.ps1 — the hold-out set and the verdict gate (Pester 3.4)
#
# Covers: the set passes on this repository, a missing set fails, a case without an expectation fails, an id
#         that does not match its file fails, an unknown category fails, a generator that reads the set fails,
#         a coherent verdict=pass passes, and every contradiction inside a pass is rejected (missing report,
#         verdict=fail, failed acceptance, an adversarial bug, an unrecorded gap, a case that does not exist),
#         plus provenance and environment: a hand-written report and a runner hash mismatch are rejected, a
#         missing environment_verified is incomplete, and false passes with a warning; and skips: a skip
#         without a reason, or one not registered in known_limitations, is rejected.

$script:SetScript = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\verify\check-adversarial-set.ps1')).Path
$script:ReportScript = (Resolve-Path (Join-Path $PSScriptRoot '..\tools\verify\check-test-report.ps1')).Path
$script:Repo = Split-Path -Parent $PSScriptRoot

function New-TempRepo {
    $root = Join-Path $env:TEMP ('flowwright-verify-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    return $root
}

function Remove-TempRepo {
    param([string]$Root)
    if ($Root -and (Test-Path -LiteralPath $Root)) {
        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Write-RepoFile {
    param([string]$Root, [string]$Relative, [string]$Text)
    $path = Join-Path $Root $Relative
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($path, $Text, (New-Object Text.UTF8Encoding($false)))
}

function Invoke-SetGate {
    param([string]$Root)
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:SetScript -RepoRoot $Root 2>&1
    return @{ Code = $LASTEXITCODE; Text = ($output -join "`n") }
}

function Invoke-ReportGate {
    param([string]$Report, [string]$Root)
    $output = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:ReportScript -ReportFile $Report -RepoRoot $Root 2>&1
    return @{ Code = $LASTEXITCODE; Text = ($output -join "`n") }
}

$script:GoodCase = '{"id":"input/ok","category":"input","given":"g","when":"w","expected":{"exit_code":2},"why":"y"}'

function New-ReportRepo {
    $root = New-TempRepo
    Write-RepoFile $root 'tests\adversarial\input\ok.json' $script:GoodCase
    return $root
}

function New-Report {
    param([string]$Root, [string]$Json)
    $path = Join-Path $Root 'report.json'
    [IO.File]::WriteAllText($path, $Json, (New-Object Text.UTF8Encoding($false)))
    return $path
}

# A valid runner object: the generator has to exist at the expected path and the hash has to match it.
function New-RunnerJson {
    param([string]$Root)
    $src = Join-Path $script:Repo 'tools\verify\run-test-report.ps1'
    $dst = Join-Path $Root 'tools\verify\run-test-report.ps1'
    $dir = Split-Path -Parent $dst
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Copy-Item -LiteralPath $src -Destination $dst -Force
    $hash = (Get-FileHash -LiteralPath $dst -Algorithm SHA256).Hash.ToLowerInvariant()
    return '{"path":"tools/verify/run-test-report.ps1","sha256":"' + $hash + '","run_id":"r1","generated_at":"2026-11-23T00:00:00+08:00"}'
}

Describe 'Adversarial set gate' {

    It 'passes on this repository with all five categories represented' {
        $result = Invoke-SetGate $script:Repo
        $result.Code | Should Be 0
        $result.Text | Should Match 'passed \(cases=8, categories=5\)'
    }

    It 'fails when the hold-out set is absent' {
        $root = New-TempRepo
        try {
            $result = Invoke-SetGate $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'ADVERSARIAL_SET_MISSING'
        } finally { Remove-TempRepo $root }
    }

    It 'fails on a case without an expected outcome' {
        $root = New-TempRepo
        try {
            Write-RepoFile $root 'tests\adversarial\input\no-expectation.json' '{"id":"input/no-expectation","category":"input","given":"g","when":"w","why":"y"}'
            $result = Invoke-SetGate $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'CASE_WITHOUT_EXPECTATION input\\no-expectation\.json'
        } finally { Remove-TempRepo $root }
    }

    It 'fails when the id does not match the file name' {
        $root = New-TempRepo
        try {
            Write-RepoFile $root 'tests\adversarial\input\renamed.json' '{"id":"input/old-name","category":"input","given":"g","when":"w","expected":{"exit_code":2},"why":"y"}'
            $result = Invoke-SetGate $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'CASE_ID_MISMATCH input\\renamed\.json'
        } finally { Remove-TempRepo $root }
    }

    It 'fails on a category folder that is not one of the five' {
        $root = New-TempRepo
        try {
            Write-RepoFile $root 'tests\adversarial\weird\case.json' '{"id":"weird/case","category":"weird","given":"g","when":"w","expected":{"exit_code":2},"why":"y"}'
            $result = Invoke-SetGate $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'UNKNOWN_CATEGORY tests\\adversarial\\weird'
        } finally { Remove-TempRepo $root }
    }

    It 'fails when the generator reads the set' {
        $root = New-TempRepo
        try {
            Write-RepoFile $root 'tests\adversarial\input\ok.json' $script:GoodCase
            Write-RepoFile $root 'tools\pad-robin\generator.js' 'var spec = require("./nothing"); fs.readFileSync("tests/adversarial/input/ok.json");'
            $result = Invoke-SetGate $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'ADVERSARIAL_READ_BY_GENERATOR tools\\pad-robin\\generator\.js line 1'
        } finally { Remove-TempRepo $root }
    }
}

Describe 'Verdict gate' {

    It 'passes a coherent verdict=pass report' {
        $root = New-ReportRepo
        try {
            $runner = New-RunnerJson $root
            $report = New-Report $root ('{"runner":' + $runner + ',"generated_at":"2026-11-23","verdict":"pass","environment_verified":true,"acceptance":[{"id":"A1","result":"pass","evidence":"exit 0"}],"adversarial":[{"case":"input/ok","result":"pass","evidence":"exit 2"}],"known_limitations":[]}')
            $result = Invoke-ReportGate $report $root
            $result.Code | Should Be 0
            $result.Text | Should Match 'verdict=pass \(acceptance=1, adversarial=1, gaps=0\)'
        } finally { Remove-TempRepo $root }
    }

    It 'blocks a task with no report at all' {
        $root = New-ReportRepo
        try {
            $result = Invoke-ReportGate (Join-Path $root 'missing.json') $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'VERDICT_NOT_PASS'
        } finally { Remove-TempRepo $root }
    }

    It 'blocks verdict=fail and verdict=blocked' {
        $root = New-ReportRepo
        try {
            $fail = New-Report $root '{"runner":"agent(T)","verdict":"fail","acceptance":[],"adversarial":[]}'
            $result = Invoke-ReportGate $fail $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'VERDICT_NOT_PASS verdict=fail'
            $blocked = New-Report $root '{"runner":"agent(T)","verdict":"blocked","acceptance":[],"adversarial":[]}'
            $result = Invoke-ReportGate $blocked $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'VERDICT_NOT_PASS verdict=blocked'
        } finally { Remove-TempRepo $root }
    }

    It 'blocks a pass that contradicts a failed acceptance item' {
        $root = New-ReportRepo
        try {
            $report = New-Report $root '{"runner":"agent(T)","verdict":"pass","acceptance":[{"id":"A1","result":"pass"},{"id":"A2","result":"fail"}],"adversarial":[{"case":"input/ok","result":"pass"}]}'
            $result = Invoke-ReportGate $report $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'ACCEPTANCE_NOT_PASS A2 result=fail'
        } finally { Remove-TempRepo $root }
    }

    It 'blocks a pass that hides an adversarial bug' {
        $root = New-ReportRepo
        try {
            $report = New-Report $root '{"runner":"agent(T)","verdict":"pass","acceptance":[{"id":"A1","result":"pass"}],"adversarial":[{"case":"input/ok","result":"bug"}]}'
            $result = Invoke-ReportGate $report $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'ADVERSARIAL_BUG input/ok'
        } finally { Remove-TempRepo $root }
    }

    It 'blocks a gap that is not recorded as a known limitation' {
        $root = New-ReportRepo
        try {
            $report = New-Report $root '{"runner":"agent(T)","verdict":"pass","acceptance":[{"id":"A1","result":"pass"}],"adversarial":[{"case":"input/ok","result":"gap"}],"known_limitations":[]}'
            $result = Invoke-ReportGate $report $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'GAP_NOT_RECORDED input/ok'
        } finally { Remove-TempRepo $root }
    }

    It 'blocks a pass that cites a case which does not exist' {
        $root = New-ReportRepo
        try {
            $report = New-Report $root '{"runner":"agent(T)","verdict":"pass","acceptance":[{"id":"A1","result":"pass"}],"adversarial":[{"case":"input/invented","result":"pass"}]}'
            $result = Invoke-ReportGate $report $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'ADVERSARIAL_CASE_NOT_FOUND input/invented'
        } finally { Remove-TempRepo $root }
    }

    It 'blocks a report that verified nothing' {
        $root = New-ReportRepo
        try {
            $report = New-Report $root '{"verdict":"pass","acceptance":[],"adversarial":[]}'
            $result = Invoke-ReportGate $report $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'REPORT_INCOMPLETE no runner'
            $result.Text | Should Match 'REPORT_INCOMPLETE no acceptance item'
            $result.Text | Should Match 'REPORT_INCOMPLETE no adversarial result'
        } finally { Remove-TempRepo $root }
    }

    It 'blocks a hand-written pass report that cannot name its generator' {
        $root = New-ReportRepo
        try {
            $report = New-Report $root '{"generated_at":"2026-11-23","verdict":"pass","environment_verified":true,"acceptance":[{"id":"A1","result":"pass","evidence":"looks fine"}],"adversarial":[{"case":"input/ok","result":"pass","evidence":"looks fine"}],"known_limitations":[]}'
            $result = Invoke-ReportGate $report $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'RUNNER_UNVERIFIED no runner provenance'
        } finally { Remove-TempRepo $root }
    }

    It 'blocks a report whose runner hash does not match the generator' {
        $root = New-ReportRepo
        try {
            $runner = (New-RunnerJson $root) -replace '"sha256":"[0-9a-f]+"', ('"sha256":"' + ('0' * 64) + '"')
            $report = New-Report $root ('{"runner":' + $runner + ',"generated_at":"2026-11-23","verdict":"pass","environment_verified":true,"acceptance":[{"id":"A1","result":"pass","evidence":"exit 0"}],"adversarial":[{"case":"input/ok","result":"pass","evidence":"exit 2"}]}')
            $result = Invoke-ReportGate $report $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'RUNNER_UNVERIFIED runner hash does not match'
        } finally { Remove-TempRepo $root }
    }

    It 'blocks a pass that does not say whether the environment was verified' {
        $root = New-ReportRepo
        try {
            $runner = New-RunnerJson $root
            $report = New-Report $root ('{"runner":' + $runner + ',"generated_at":"2026-11-23","verdict":"pass","acceptance":[{"id":"A1","result":"pass","evidence":"exit 0"}],"adversarial":[{"case":"input/ok","result":"pass","evidence":"exit 2"}]}')
            $result = Invoke-ReportGate $report $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'REPORT_INCOMPLETE no environment_verified'
        } finally { Remove-TempRepo $root }
    }

    It 'passes verified logic with an unverified environment, and warns about it' {
        $root = New-ReportRepo
        try {
            $runner = New-RunnerJson $root
            $report = New-Report $root ('{"runner":' + $runner + ',"generated_at":"2026-11-23","verdict":"pass","environment_verified":false,"acceptance":[{"id":"A1","result":"pass","evidence":"exit 0"}],"adversarial":[{"case":"input/ok","result":"pass","evidence":"exit 2"}]}')
            $result = Invoke-ReportGate $report $root
            $result.Code | Should Be 0
            $result.Text | Should Match 'verdict=pass'
            $result.Text | Should Match 'WARNING logic verified, environment not verified \(environment_verified=false\)'
        } finally { Remove-TempRepo $root }
    }

    It 'blocks a skipped item with no reason' {
        $root = New-ReportRepo
        try {
            $runner = New-RunnerJson $root
            $report = New-Report $root ('{"runner":' + $runner + ',"verdict":"pass","environment_verified":true,"acceptance":[{"id":"A1","result":"pass","evidence":"exit 0"}],"skipped":[{"id":"logstate-09","type":"logState"}],"adversarial":[{"case":"input/ok","result":"pass","evidence":"exit 2"}],"known_limitations":[]}')
            $result = Invoke-ReportGate $report $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'SKIPPED_UNTRACED logstate-09 has no reason'
        } finally { Remove-TempRepo $root }
    }

    It 'blocks a skip that is not registered as a known limitation' {
        $root = New-ReportRepo
        try {
            $runner = New-RunnerJson $root
            $report = New-Report $root ('{"runner":' + $runner + ',"verdict":"pass","environment_verified":true,"acceptance":[{"id":"A1","result":"pass","evidence":"exit 0"}],"skipped":[{"id":"logstate-09","type":"logState","reason":"the log needs a manual dialog"}],"adversarial":[{"case":"input/ok","result":"pass","evidence":"exit 2"}],"known_limitations":[]}')
            $result = Invoke-ReportGate $report $root
            $result.Code | Should Be 1
            $result.Text | Should Match 'SKIPPED_UNTRACED logstate-09 is not registered in known_limitations'
        } finally { Remove-TempRepo $root }
    }

    It 'passes a traced skip: reason present and registered' {
        $root = New-ReportRepo
        try {
            $runner = New-RunnerJson $root
            $report = New-Report $root ('{"runner":' + $runner + ',"verdict":"pass","environment_verified":true,"acceptance":[{"id":"A1","result":"pass","evidence":"exit 0"}],"skipped":[{"id":"logstate-09","type":"logState","reason":"the log needs a manual dialog"}],"adversarial":[{"case":"input/ok","result":"pass","evidence":"exit 2"}],"known_limitations":["skipped:logstate-09: the log needs a manual dialog"]}')
            $result = Invoke-ReportGate $report $root
            $result.Code | Should Be 0
            $result.Text | Should Match 'verdict=pass'
        } finally { Remove-TempRepo $root }
    }
}

Describe 'Stale optional exemption' {

    It 'prints a warning for a stale exemption without changing the verdict' {
        $root = New-ReportRepo
        try {
            $runner = New-RunnerJson $root
            $report = New-Report $root ('{"runner":' + $runner + ',"verdict":"pass","environment_verified":true,"acceptance":[{"id":"fileexists-01","result":"pass","evidence":"fileExists: present"}],"adversarial":[{"case":"input/ok","result":"pass","evidence":"exit 2"}],"warnings":[{"code":"OPTIONAL_EXEMPTION_STALE","id":"fileexists-01","message":"fileexists-01 passed in this run, drop optional/optional_reason"}]}')
            $result = Invoke-ReportGate $report $root
            $result.Code | Should Be 0
            $result.Text | Should Match 'verdict=pass'
            $result.Text | Should Match 'WARNING optional exemption stale: fileexists-01 passed in this run'
        } finally { Remove-TempRepo $root }
    }

    It 'makes the generator report an optional check that passed for real' {
        $root = New-TempRepo
        try {
            Copy-Item -Path (Join-Path $script:Repo 'tools') -Destination $root -Recurse -Force
            Copy-Item -Path (Join-Path $script:Repo 'tests') -Destination $root -Recurse -Force
            Write-RepoFile $root 'tests\harness\cases.json' '{"entry":"tests/harness/entry/mini-entry.js","implemented":["input/missing-input-file"]}'

            $padRoot = Join-Path $root 'padroot'
            New-Item -ItemType Directory -Path $padRoot -Force | Out-Null
            [IO.File]::WriteAllText((Join-Path $padRoot 'exists.txt'), 'x', (New-Object Text.UTF8Encoding($false)))

            $flow = @{
                name       = 'opt-stale'
                acceptance = @{ checks = @(@{
                    name            = 'existing product'
                    type            = 'fileExists'
                    path            = '{{PAD_ROOT}}\exists.txt'
                    optional        = $true
                    optional_reason = 'kept as a waiver until the product reappears'
                }) }
            } | ConvertTo-Json -Depth 8
            Write-RepoFile $root 'business\flows\opt-stale.json' $flow
            Write-RepoFile $root 'business\config\opt-stale.json' (ConvertTo-Json @{ PAD_ROOT = $padRoot })

            $generator = Join-Path $root 'tools\verify\run-test-report.ps1'
            $generated = & powershell -NoProfile -ExecutionPolicy Bypass -File $generator -FlowName opt-stale -RunId r1 -Since '2026-01-01T00:00:00+08:00' -EnvironmentVerified true 2>&1
            $generateCode = $LASTEXITCODE
            $generatedText = ($generated -join "`n")
            $generateCode | Should Be 0
            $generatedText | Should Match 'OPTIONAL_EXEMPTION_STALE fileexists-01: passed in this run, drop optional/optional_reason'

            $reportPath = Join-Path $root 'business\logs\opt-stale\test-report-r1.json'
            $reportJson = Get-Content -LiteralPath $reportPath -Raw -Encoding UTF8 | ConvertFrom-Json
            @($reportJson.warnings)[0].code | Should Be 'OPTIONAL_EXEMPTION_STALE'
            @($reportJson.warnings)[0].id | Should Be 'fileexists-01'

            $result = Invoke-ReportGate $reportPath $root
            $result.Code | Should Be 0
            $result.Text | Should Match 'verdict=pass'
            $result.Text | Should Match 'WARNING optional exemption stale: fileexists-01'
        } finally { Remove-TempRepo $root }
    }
}
