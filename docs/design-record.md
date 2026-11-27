# Design record (`<name>.design.json`)

A design record turns the design conversation into a reviewable artifact. It lives next to the flow at
`business/flows/<name>.design.json` and is checked by:

```powershell
node tools\verify\check-design.js business\flows\<name>.design.json --flow business\flows\<name>.json
node tools\verify\check-design.js --flow business\flows\<name>.json   # skips when the record is absent
```

The second form derives `<name>.design.json` and exits 0 with `skip` when the record does not exist, so a
repository without design records keeps building.

## Shape

```json
{
  "flow": "business/flows/<name>.json",
  "requirements": [
    { "id": "R1", "text": "Read the source file before writing anything" },
    { "id": "R2", "text": "Write the result to the target file" }
  ],
  "mapping": [
    { "clause": "R1", "nodes": ["1"], "acceptance": ["source-read"] },
    { "clause": "R2", "nodes": ["2"], "acceptance": ["target-file-written"] }
  ],
  "lane": {
    "choice": "pad",
    "reason": "The step needs a click in a desktop application with no API"
  },
  "failure_paths": [
    { "node": "3", "kind": "branch", "on_failure": "node 4 shows the error and exits" }
  ],
  "state_markers": [
    { "name": "RunStamp", "kind": "run-timestamp-dir", "where": "node 2 params.OutputDir" }
  ],
  "rejected_alternatives": [
    { "option": "py entry script", "reason": "The application has no API, so the script would still need PAD" }
  ]
}
```

Required fields: `requirements`, `mapping`, `lane`, `failure_paths`, `state_markers`,
`rejected_alternatives`. `flow` is optional but recommended; when present the checker resolves it and
cross-checks node ids.

## What the checker proves

- Every requirement clause id appears in at least one `mapping[].clause`; an unmapped clause is reported by
  id (`CLAUSE_UNMAPPED: R2 "..."`).
- Every mapping entry points at a known clause and has at least one node or acceptance id.
- `lane.choice` is `pad`, `ps1` or `py`, and `lane.reason` is not empty.
- Every `failure_paths[]` entry names a node, a known `kind` (`branch` / `guard` / `early-exit`) and a handling
  description.
- Every `state_markers[]` entry names a marker, a known `kind` and where it is used.
- Every `rejected_alternatives[]` entry records both the option and why it was rejected.
- When a flow is available: mapped node ids and failure-path node ids exist, and every external-call node
  (`Outlook.*`, `Excel.*`, `SAP.*`, `FTP.*`, `Web.*`, `WebAutomation.*`, `Scripting.Run*`) has a
  `failure_paths` entry.

## What it does not prove

- That the clause text is the user's real requirement.
- That the chosen lane is the best lane.
- That the declared failure handling actually runs.
- That the flow produces the correct business result.

The structural half of "every external call has a failure branch" is checked by the `failurePath` op in
`tools/pad-robin/eval-flow.js`; the design record records the intent, and the op checks the flow shape. They
can disagree, and neither replaces a real run in the target environment.
