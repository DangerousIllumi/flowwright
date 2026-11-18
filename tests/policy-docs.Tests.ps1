# policy-docs.Tests.ps1 — keeps the policy rule names quoted in the docs from drifting away from business\policy.json
#
# business\ is never committed: when the policy file is absent the case prints an explicit SKIP and counts as a pass, so public CI never turns red.

$repo = Split-Path -Parent $PSScriptRoot
$skill = Join-Path $repo 'skills\pad-flow-designer\SKILL.md'
$prompts = Join-Path $repo 'docs\agent-prompts.md'
$policy = Join-Path $repo 'business\policy.json'
$engine = Join-Path $repo 'docs\engine-selection.md'
$admitDoc = Join-Path $repo 'docs\admission-gate.md'
$lang = Join-Path $repo 'docs\doc-language.md'

Describe 'Policy rule documentation consistency' {

    It 'The design SKILL no longer copies the rule table and only points to the policy file' {
        $text = Get-Content -LiteralPath $skill -Raw -Encoding UTF8
        $text | Should Match 'business/policy\.json'
        $text | Should Match 'docs/admission-gate\.md'
        # The SKILL must no longer carry rule-table rows like "| `deny-xxx` |"; rule names are defined only in policy.json
        ([regex]::Matches($text, '\| `(deny-[a-z-]+|ask-[a-z-]+)`')).Count | Should Be 0
    }

    It 'Rule names appearing in the docs all exist in business\policy.json (skipped when the file is missing)' {
        if (-not (Test-Path -LiteralPath $policy)) {
            Write-Host '[skip] business\policy.json 不存在（业务层不入库），跳过规则名比对'
            return
        }
        $policyText = Get-Content -LiteralPath $policy -Raw -Encoding UTF8
        $known = @([regex]::Matches($policyText, '"id"\s*:\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        $docText = Get-Content -LiteralPath $prompts -Raw -Encoding UTF8
        $refs = @([regex]::Matches($docText, '\| `(deny-[a-z-]+|ask-[a-z-]+)`') | ForEach-Object { $_.Groups[1].Value })
        $refs.Count | Should BeGreaterThan 0
        $unknown = @($refs | Where-Object { $known -notcontains $_ })
        ($unknown -join ', ') | Should Be ''
    }
}

Describe 'Web interaction lane documentation' {

    It 'engine-selection.md decides web interaction by DOM availability and names both lanes' {
        $text = Get-Content -LiteralPath $engine -Raw -Encoding UTF8
        $text | Should Match 'Web interaction: ask for the DOM first'
        $text | Should Match '\*\*DOM lane\*\*'
        $text | Should Match '\*\*Recording lane\*\*'
    }

    It 'engine-selection.md lists the three DOM-chain action ids that all generate' {
        $text = Get-Content -LiteralPath $engine -Raw -Encoding UTF8
        $text | Should Match 'WebAutomation\.LaunchEdge\.LaunchEdge'
        $text | Should Match 'WebAutomation\.GoToWebPage\.GoToWebPage'
        $text | Should Match 'WebAutomation\.ExecuteJavascript'
    }

    It 'engine-selection.md keeps coordinate clicking as an explicit last resort with its cost' {
        $text = Get-Content -LiteralPath $engine -Raw -Encoding UTF8
        $text | Should Match 'Last resort: coordinate clicks'
        $text | Should Match 'MouseAndKeyboard\.SendMouseClick\.ClickAt'
        $text | Should Match 'resolution'
    }

    It 'the design SKILL asks whether the DOM can locate a web step before generating it' {
        $text = Get-Content -LiteralPath $skill -Raw -Encoding UTF8
        $text | Should Match 'located through the DOM'
        $text | Should Match 'manual recording instead of generation'
    }

    It 'admission-gate.md no longer offers an allowlist as a selector exemption' {
        $text = Get-Content -LiteralPath $admitDoc -Raw -Encoding UTF8
        $text | Should Not Match 'must be explicitly allowlisted'
        $text | Should Match 'no allowlist and no exemption'
    }

    It 'agent-prompts.md points recorded-element actions at the DOM lane and rejects hand-filled selectors' {
        $text = Get-Content -LiteralPath $prompts -Raw -Encoding UTF8
        $text | Should Match 'neither the generator nor admission accepts a hand-filled selector'
        $text | Should Match 'docs/engine-selection\.md section 3\.1'
        $text | Should Not Match 'unless the user supplies the recorded element selector'
    }
}

Describe 'PAD shell lane documentation' {

    It 'engine-selection.md keeps PAD as a shell and names the script-start action and its outputs' {
        $text = Get-Content -LiteralPath $engine -Raw -Encoding UTF8
        $text | Should Match 'PAD as the shell'
        $text | Should Match 'Scripting\.RunDOSCommand'
        $text | Should Match 'StandardOutput'
        $text | Should Match 'ExitCode'
    }

    It 'engine-selection.md makes the output directory owner explicit and fails before the browser starts' {
        $text = Get-Content -LiteralPath $engine -Raw -Encoding UTF8
        $text | Should Match 'Output directory ownership is declared, not assumed'
        $text | Should Match 'failing with exit code 2 before the browser starts'
        $text | Should Match 'half self-creating and half dependent on a human'
    }

    It 'engine-selection.md and doc-language.md both require ASCII console output for a PAD-consumed script' {
        $engineText = Get-Content -LiteralPath $engine -Raw -Encoding UTF8
        $langText = Get-Content -LiteralPath $lang -Raw -Encoding UTF8
        $engineText | Should Match 'Console output is ASCII only'
        $langText | Should Match 'system ANSI code page'
        $langText | Should Match 'prints ASCII only'
        $langText | Should Match 'lands in a PAD variable print ASCII only'
    }

    It 'the design SKILL asks about the script path, the output directories and the console encoding' {
        $text = Get-Content -LiteralPath $skill -Raw -Encoding UTF8
        $text | Should Match 'output directories created before the run'
        $text | Should Match 'console: ASCII only'
        $text | Should Match 'section 3\.2 of `docs/engine-selection\.md`'
    }

    It 'engine-selection.md keeps the result file protocol and bounds the run' {
        $text = Get-Content -LiteralPath $engine -Raw -Encoding UTF8
        $text | Should Match 'RUNNING n/total'
        $text | Should Match 'OK:` or `FAIL: <code> <reason>'
        $text | Should Match 'RunDOSCommandWithCodePageAndFailOnTimeout'
    }

    It 'engine-selection.md and AGENTS.md point at the script-lane entry template, and the template exists' {
        $engineText = Get-Content -LiteralPath $engine -Raw -Encoding UTF8
        $agentsText = Get-Content -LiteralPath (Join-Path $repo 'AGENTS.md') -Raw -Encoding UTF8
        $engineText | Should Match 'tools/script-entry/entry-template\.js'
        $agentsText | Should Match 'tools/script-entry/'
        (Test-Path -LiteralPath (Join-Path $repo 'tools\script-entry\entry-template.js')) | Should Be $true
    }
}
