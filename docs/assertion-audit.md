# 恒真断言审计（否定式断言逐条判定）

范围：`tests/` 下 25 个 Pester 文件（51 处 `Should Not *`）、6 个 `node --test` 文件（9 处）、3 个 pytest 文件（2 处 `pytest.raises`）。
判定口径：被禁止的东西在这条代码路径上是否**真的有可能出现**。分三类：**有效**（能因回归而红）、**恒真**（任何实现状态下都不可能出现，断言永不红）、**几乎恒真**（只有极端情形才会出现，而测试从不构造该情形）。
恒真的处理：换成等价或更强、可证伪的断言，并用**变异测试**证明——在 %TEMP% 的仓库副本里改坏被保护的行为，断言必须变红，副本恢复后必须变绿。

---

## 一、判定为恒真并已修复（5 条）

| # | 文件:行 | 断言原文 | 期望不出现的东西 | 该路径实际输出什么 | 判定 | 改写 |
|---|---|---|---|---|---|---|
| F1 | `tests/pad-verify.Tests.ps1:38`（原） | `$out \| Should Not Match 'VERIFY_SUMMARY'` | 验收检查阶段的汇总标记 | 沙箱里根本没有可运行的 flow+criteria 组合，`build-acceptance.ps1` 永远不会被调用，因此该标记**在任何实现下**都不会出现 | **恒真** | 钉住真实早期错误输出：输出恰好 1 行、结果字段恰好 `ok,error`、`error` 以 `E_FLOW_FILE_REQUIRED` 开头 |
| F2 | `tests/pad-verify.Tests.ps1:52`（原） | `$out \| Should Not Match '"checks"'` | 结果里的 checks 字段 | 同上：验收阶段不可达，`"checks"` 永远不会被打印 | **恒真** | 同 F1（`ok,error` 字段清单断言已覆盖） |
| F3 | `tests/pad-admit.Tests.ps1:425`（原） | `$text \| Should Not Match 'POLICY_'` | POLICY_* 错误码 | POLICY 是唯一产出 `POLICY_*` 的检查，而它只在 flow 读入之后才跑；这条用例的 flow 名让读入永远失败 | **恒真** | 钉住终态：`"summary":{"total":1,"pass":0,"warn":0,"ask":0,"fail":1}`（报告里只有 ADMIT 一项、且是唯一失败） |
| F4 | `tests/pad-release.Tests.ps1:226`（原） | `$out \| Should Not Match 'pytestPassed'` | 测试汇总字段 | 该调用带 `-SkipTests`，唯一能填 `pytestPassed` 的 `Get-TestSummary` 根本不会被调用 | **恒真** | 钉住可观测后果：`"tests":null`（测试汇总连初始化都没发生） |
| F5 | `tests/pad-flow-name.Tests.ps1:86-87`（原） | `Should Not Match 'pad_flow_name'` / `'示例显示名-XYZ'` | `.robin` 里出现该字段名或未消费的顶层值 | 生成器只输出 PAD 语句，任何 JSON 字段名和未消费的顶层值都**不可能**进入 `.robin` | **恒真** | 行为等价且更强：同一份 flow 带 / 不带 `pad_flow_name` 生成的 `.robin` 必须逐字节相同 |

## 二、变异测试（红/绿证据）

全部在 `%TEMP%` 的仓库副本内进行，副本用完即删；真实仓库从未被改动。

| 编号 | 变异内容 | 受影响断言 | 结果 |
|---|---|---|---|
| M1 | `pad-verify.ps1` 的早期错误文案 `E_FLOW_FILE_REQUIRED:` → `E_FLOW_DEFAULTED:` | F1/F2 修复后的断言 | **红**：`[-] empty flows directory: non-zero exit demanding an explicit -FlowFile…`（Expected: `{"ok":false,"error":"E_FLOW_DEFAULTED…`） |
| M1b | `E_FLOW_AMBIGUOUS(candidates=` → `E_FLOW_DEFAULTED_AMBIGUOUS(candidates=` | F1/F2 修复后的歧义用例 | **红**：`[-] multiple flow candidates: non-zero exit reporting the candidate count` |
| M2 | `pad-admit.ps1` 的错误报告里多加一个 POLICY 检查（2 个 check id） | F3 修复后的断言 | **红**：`[-] no -FlowFile and the flow name resolves to nothing: non-zero exit before any admission check` |
| M3 | `flow-to-robin.js` 把 `pad_flow_name` 写进 `.robin` | F5 的字节相同断言 | **红**：`[-] the generator and check.js accept the field without writing it into .robin` |
| M4 | `pad-release.ps1` 去掉 `-SourceRobin` 守卫，让流水线继续走到测试阶段 | F4 修复后的断言 | **红**：`[-] no -SourceRobin and the flow name resolves to nothing: non-zero exit before the execution stage` |

对照（未变异的副本，全部绿）：`pad-verify.Tests.ps1` 2/2、`pad-release.Tests.ps1` 17/17、`pad-flow-name.Tests.ps1` 6/6。

## 三、判定为有效（可因回归而红）的断言，逐条给变异证据

以下断言**不是**恒真。它们在对应变异下都会变红，所以保持原样、不改。

| 文件:行 | 断言 | 变异 | 结果 |
|---|---|---|---|
| `pad-schedule.Tests.ps1:45` | `Should Not Match 'RunOnly'` | 工作日门控分支同时输出 `-RunOnly` | **红**（`action command: workday calendar mode…`） |
| `pad-schedule.Tests.ps1:61,72,93` | `Should Not Match 'RUN_START'` | 去掉“缺日历”守卫，让运行继续 | **红**（2 条用例：`run entry without a calendar`、`register mode without a calendar`） |
| `pad-schedule.Tests.ps1:113` | `Should Not Match 'CONFIG_MISSING'` | ignore-calendar 路径也打印 `CONFIG_MISSING` | **红** |
| `pad-schedule.Tests.ps1:144,145` | `Should Not Match 'RunIfWorkday'` / `'AllowProd'` | ignore-calendar 模式也输出 `-RunIfWorkday` | **红** |
| `pad-schedule.Tests.ps1:169,174` | `Should Not Match '-LockWaitSec'` | 把 `-LockWaitSec` 写进任务命令 | **红** |
| `pad-schedule.Tests.ps1:267` | 首字节 `Should Not Be 0xEF` | 告警文件带 BOM（PS 5.1 `Add-Content` 行为） | 有效（直接断言首字节） |
| `trigger-registry.Tests.ps1:213` | 哈希 `Should Not Be $base` | time 从 09:00 改 10:00 | 有效（哈希含 time） |
| `trigger-registry.Tests.ps1:226` | `$h2 Should Not Be $h1` | 哈希的 `assisted` 字段被丢弃 | **红**（`assisted is part of specHash…`） |
| `trigger-registry.Tests.ps1:259,274` | `Should Not Match 'RunOnly'` / `'RunIfWorkday'` | 门控分支参数串改 | 有效（与 pad-schedule 同源） |
| `pad-fingerprint.Tests.ps1:561` | `status Should Not Be 'fail'` | legacy 分支改成 `status='fail'` | **红**（2 条 legacy 用例） |
| `pad-fingerprint.Tests.ps1:597,598,618` | 证据 `Should Not Match 'posting\.vbs'` / `'scripts/a\.vbs'` / `'tools/b\.py'` | 证据里列出全部脚本而非只列变化的 | **红**（3 条用例） |
| `pad-rollback.Tests.ps1:67` | `Should Not Be $latest` | 选择器忽略 `-Back` | **红**（3 条用例） |
| `pad-rollback.Tests.ps1:150,151` | `Should Not Match '"stage":"select"'` / `'"stage":"done"'` | 去掉 `-ConfigFile` 守卫 | **红** |
| `pad-release.Tests.ps1:227` | `Should Not Match '"stage":"done"'` | 去掉 `-SourceRobin` 守卫 | **红**（同上 M4） |
| `pad-admit.Tests.ps1:589,591` | 证据 `Should Not Match 'node 8'` / `'node 7'` | 两个块都列出全部节点（重复上报） | **红**（2 条用例） |
| `PadConfigure.Tests.ps1:142,143` | `Should Not Match 'INTERACTIVE_CONFIRM'` / `'CONFIG_WRITTEN'` | 去掉“示例配置缺失”守卫 | **红** |
| `PadConfigure.Tests.ps1:136` | `ExitCode Should Not Be 0` | 直接断言退出码 | 有效 |
| `PadConfigure.Tests.ps1:24` | `Hint Should Not BeNullOrEmpty` | 直接断言提示非空 | 有效 |
| `policy-docs.Tests.ps1:69` | 文档 `Should Not Match 'must be explicitly allowlisted'` | 文档改回旧措辞 | **红** |
| `policy-docs.Tests.ps1:77` | 文档 `Should Not Match 'unless the user supplies…'` | 同上 | **红** |
| `pad-alerts.Tests.ps1:42` | `ts Should Not BeNullOrEmpty` | 时间戳写成空串 | **红**（2 条用例） |
| `output-roots.Tests.ps1:69` | `Should Not Match 'skip:'` | 缺注册表时改成 skip | **红** |
| `eval-flow.Tests.ps1:73` | `Should Not Match 'notes\.json'` | 汇总里报告被跳过的伴随文件 | **红** |
| `drawio-to-flow.test.js:192` | `doesNotMatch(/DRAWIO_ROUNDTRIP_NO_SOURCE_FLOW/)` | 回读总是告警 | **红**（node --test：变异后 10/10 失败，对照 10/10 通过） |
| `check-decisions.test.js` 8 处 | `doesNotMatch` / `ok(!…)` | 见第四节 | 有效 |

## 四、判定为「几乎恒真」、**不擅自改**（待确认）

| 文件:行 | 断言 | 为什么只是几乎恒真 | 需要你决定什么 |
|---|---|---|---|
| `trigger-registry.Tests.ps1:505` | `$h2 \| Should Not Be $h1`（days 变化 → 哈希变化） | days 虽写进了规范哈希，但 `daysDeclared` 为 false 时 days 会被规范化成同一组周一至周五，所以**只有显式声明与省略声明不同**时哈希才真的变。把哈希里的 `days` 固定为 `@()` 的变异**没有**让这条变红（37/37 仍绿）——这条断言目前只在“声明 days”这一种输入下才具备区分力，测试恰好只覆盖了那一种 | 是否要补一条“显式声明 mon..fri 与省略 days 的哈希不同”的用例（这正是 `scheduleKind` 存在的理由），把它从“几乎恒真”变成“有效” |
| `pad-schedule.Tests.ps1:267` | 告警 JSONL 首字节 `Should Not Be 0xEF` | 有效（直接断言字节），但依赖 PS 5.1 的 `Add-Content` 默认写 BOM；PS 7 不写，PS 7 下会**假性通过** | 是否要在测试里标注“此断言只对 PS 5.1 有意义” |
| `check-decisions.test.js` 中 `doesNotMatch(/violation/)`、`/DECISION_NOT_USER_APPROVED/`、`/RISK_NODE_DECISION_NOT_RISK/` | “报告里不含某个词” | 有效：被禁止的码在对应 fixture 下**确实**会出现（把闸门改松就会打出来） | 无需改动 |
| `check-decisions.test.js` 中 `doesNotMatch(/skip:/)`、`doesNotMatch(/warn:/)`、`doesNotMatch(/failed:/)` | “报告里不含另一种模式的措辞” | 有效：模式的措辞是实现写死的，闸门改动会立刻暴露 | 无需改动 |
| `check-decisions.test.js` 中两处 `assert.ok(!/[\u0080-\uFFFF]/…)` | 输出里没有裸的非 ASCII 字符 | 有效：闸门不转义就会写出裸中文 | 已在本轮调整断言顺序（先查裸字符、再查可打印 ASCII），使“转义”这条断言真正可能失败——原顺序里 helper 的可打印 ASCII 守卫会先失败，裸字符检查永远轮不到它，属于“第二个断言永远轮不到”的隐性恒真 |

## 五、结论：零星还是系统性？

**是零星，但集中在一个可识别的模式上。**

- 全仓 62 条否定式断言中，**恒真 5 条**（约 8%），**几乎恒真 1 条**，其余 56 条有效。
- 5 条恒真**不是随机的**，它们共享同一个形状：**断言的对象是一个在当前测试路径下不可达的产物**——
  - “验收阶段不会打印 `VERIFY_SUMMARY` / `"checks"`”，但验收阶段根本不可达（F1、F2）；
  - “不会打印 `POLICY_`”，但 POLICY 阶段根本不可达（F3）；
  - “不会打印 `pytestPassed`”，但 `Get-TestSummary` 根本不会被调用（F4）；
  - “`.robin` 里不会出现 `pad_flow_name`”，但生成器只输出 PAD 语句，任何 JSON 字段都不可能出现（F5）。
- 共同成因是：**测试构造的场景只走到第一道门，断言却去检查第二道门的产物**。它不是“断言写错了字符串”，而是“断言挂在了错误的路径上”，所以这类断言在任何实现下都恒真——改实现、改字符串都不会让它变红。
- 判断这类问题**不能只看断言文本**：5 条里有 4 条的文本看起来完全合理（`Should Not Match 'POLICY_'` 读起来就是一条正常的负断言）。唯一的识别信号是问“这条路径上被禁止的东西有没有可能真的出现”。
- 因此结论是：**不是系统性铺开，而是同一个设计习惯（用负断言检查下游产物）在“早退路径测试”里必然踩中**。凡是有“流程在第一道门就退出”的测试，就容易写出这种断言。5 条恒真全部出现在这一类用例里，56 条有效断言则分布在正常路径上。

## 六、附带发现并已修正的编码问题

审计子 agent 编辑了 4 个 `.ps1` 文件（`pad-admit` / `pad-flow-name` / `pad-release` / `pad-verify`），编辑过程剥掉了 **UTF-8 BOM**，违反仓库硬规则（`.ps1` 必须 UTF-8 with BOM）。已全部按原字节内容补回 BOM，并逐文件校验首三字节 `EF BB BF`。
