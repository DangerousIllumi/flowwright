# Data source declaration: `file` or `sql`, fixed at design time

> This document answers one question: **where a step gets its data from, and at which point that is decided.**
> It is a specification, not machinery: nothing in the toolchain enforces it yet (section 6).

## 1. Two values, one per step

Every step that reads input declares exactly one source kind:

| `source` | Means | Reads through |
|---|---|---|
| `file` | The data arrives as a workbook, CSV, or another file on disk | A file parser (`py`, section 3.2 of [`engine-selection.md`](engine-selection.md)) |
| `sql` | The data is queried from a database | A database driver and a declared connection |

The value is a property of the step's design record, not a runtime argument. A step carries one value; a flow
carries one value per data-reading step. There is no `auto`, no empty default, and no third value. Code that
needs to know the kind reads it from the frozen design record, never from a probe of the environment.

Identifiers, the enum values, and any exit codes stay English; see [`doc-language.md`](doc-language.md).

## 2. Only `file` is implemented today

`source: sql` is a reserved value, not a working path: the repository contains no database driver, no connection
configuration and no query runner. Every data-reading script in the tree takes a file path. Implementing `sql`
means adding an adapter plus the decisions below, not flipping a switch.

Stating this here matters because a spec that lists two values invites the reader to assume both work. They do
not, and a design that declares `source: sql` today must be rejected at the gate rather than discovered at run
time.

## 3. The choice is frozen at G1

**G1 is the design gate**: the point where the flow's spec and acceptance criteria are frozen and generation
begins. The source kind is one of the answers frozen there, together with the lane, the idempotency key and the
failure semantics.

Three rules follow:

1. **Decided before generation, not during a run.** The design record states the kind; the generated script is
   written for that kind.
2. **Recorded in the decision ledger.** The entry lands in `business/decisions.jsonl` with a `scope` and a real
   `decided_by`, so a later reader can answer "why this kind" without replaying the conversation.
3. **Not chosen automatically at run time.** No fallback from one kind to the other, no "try the database first",
   no sniffing the input to decide. A run that picked its own source would produce a log nobody can interpret.

### Why runtime auto-selection is forbidden

The two kinds fail for different reasons, and the operator's next action differs:

| Failure | Kind that produces it | What the operator must do |
|---|---|---|
| File missing, sheet renamed, columns moved | `file` | Fix the input or the configuration, then rerun |
| Credentials expired, permission denied, host unreachable | `sql` | Refresh access, or ask someone who can; rerunning changes nothing |

Auto-selection collapses both into one "could not fetch data" message. The operator then cannot tell whether to
edit a file or chase a credential, and the exit code can only encode one of the two. The same collapse hides a
second, worse case: a `sql` step silently falling back to a stale file on disk, producing a result that looks
successful and is out of date.

Keeping the kind static is what lets failure semantics stay separate — environment error versus a human needed —
as required by the exit-code contract shared by entry scripts.

## 4. Changing the kind is a change request

A flow that must move from `file` to `sql` gets a new ledger row that supersedes the old one; the spec and the
acceptance criteria are re-frozen at G1 afterwards. Editing the value in place would leave no record of why the
earlier design assumed a file, which is exactly the question asked after an incident.

## 5. What a step may not do

- Read the kind from a command-line flag that the caller may vary between runs.
- Try one kind and fall back to the other on any error.
- Infer the kind from the file extension, the presence of a connection string, or an environment variable.
- Treat "no data returned" as a reason to switch kinds.

## 6. Not implemented

Nothing checks this rule today: there is no `design-spec` schema, no gate that reads a spec, and no template that
carries a `source` field. This document is the rule the gate will apply once that machinery exists. Until then the
rule binds the design conversation, and a reviewer checks it by reading the design record.

The first implementation to build is `file`, because that is the only kind the tree can run. Adding `sql` needs,
at minimum: a declared connection contract (where the secret lives, how it is rotated), a distinct exit code for
an authentication failure, and an acceptance check that a query result is non-empty rather than merely present.
