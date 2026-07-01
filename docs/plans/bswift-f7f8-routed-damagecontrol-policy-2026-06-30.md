# B-Swift F7/F8 — Routed DamageControl Policy Table (Layer 4: write/edit/bash)

**Status:** Design / decision-table (markdown only — no source changes).
**Date:** 2026-07-01.
**Scope:** Forward-looking policy for when `write` / `edit` / `bash` become
*routed* tools (executed via the daemon substrate, as `read` is today). Today
only `read` is routed (`DaemonToolRouting.routedTools = ["read"]`,
`DaemonToolRouting.swift:65`); write/edit/bash run the full legacy LOCAL
pipeline including DamageControl + receipts.

This doc does **not** schedule routing write/edit/bash. It predicts the
per-step policy so the routing change is a known decision, not a guess.

> ### ✅ HARD GATE — SATISFIED (fluers 0.5.0, pinned `=0.5.0` as of 2026-07-01)
>
> The `read` path is safe because fluers' `read_file`/`read_file_full` are
> fd-anchored (B-Swift #4 / fluers 0.3.1). The mutation paths (`write_file`,
> `exec`, `glob`, `grep`) carried the same TOCTOU class until 0.5.0 — and unlike
> reads, mutations are *irreversible*, so a TOCTOU swap there is data loss, not
> a leaked file.
>
> **Gate closed:** fluers 0.5.0 fd-anchored all four mutation/search paths (the
> same `openat`+`O_NOFOLLOW`+`fstat`-off-opened-fd pattern, plus `mkdirat`-walked
> parents and `st_nlink > 1` rejection on write) and Fae pins `=0.5.0`. Phases
> F7a (write) + F7b (edit) SHIPPED. F8 (bash) remains. See `docs/ACTIVE_WORK.md`.
> The DamageControl predictions in the table + §3 + §5 below were SUPERSEDED by
> the F7a/F7b advisor validation: routed write/edit **skip DamageControl
> entirely** (their rules are confinement-only; the daemon governs confinement;
> catastrophe/`.disaster` rules are bash-only). The confinement/catastrophe
> split is therefore F8/bash-only, not needed for write/edit. The table/prose
> below is the original prediction, retained as the F8 design basis.

---

## 0. Second gate — the daemon `ToolExecuteDangerous` scope (Q7b)

**Discovered 2026-07-01 during F7a orientation.** The fluers fd-anchoring gate
(above) is necessary but **not sufficient**. There is a second, independent
gate inside the daemon that blocks routing **any** dangerous tool (write/edit/
bash) from the Swift app, and it requires an **owner decision** before F7a can
land.

### The mechanism (grounded in source)
- The daemon's per-tool policy `FaeToolPolicy::evaluate` runs a 6-step pipeline
  (`toolhost/policy.rs`). Step 2 calls `fae_control_plane::authorize` with the
  tool's risk scope command. `write`/`edit`/`bash` classify as
  `RiskClass::Write|Edit|Shell` → `scope_command() = "tool.execute_dangerous"`
  (`policy.rs:95`).
- `required_scopes("tool.execute_dangerous") = [Scope::ToolExecuteDangerous]`
  (`control-plane/lib.rs:301`). `authorize` returns `Deny(MissingScope)` if the
  client does not hold that scope (`lib.rs:455`); it returns `ConfirmRequired`
  only when the client **does** hold it (`lib.rs:459`).
- `SwiftFrontend::default_scopes()` (`lib.rs:355`) is **hardcoded** to grant
  `ToolExecuteSafe` but **not** `ToolExecuteDangerous`. The code is explicit:
  scopes "granted explicitly during rollout, not by default", and dangerous is
  "a server-side opt-in — a client-side toggle is not the boundary" (Q7b,
  `lib.rs:374`). There is **no config/runtime flag** that grants the frontend
  the dangerous scope — the only places it is granted to a frontend-shaped
  client are unit tests.
- Net: a routed write from the Swift app is `Deny(MissingScope)` at `policy.rs`
  step 2 — **before** the `tool.confirm` card fires. The confirm card itself IS
  wired (`DaemonAgentClient.handleToolConfirm` surfaces the daemon's bounded,
  redacted prompt and replies `{approved, call_id}`), but it only runs once the
  scope is held.

### Why F7a is NOT "mirror the read-routing pattern"
Mirroring `executeRoutedRead` would compile and route, but every routed write
would be denied at the scope gate — a known-failing path. F7a's real
prerequisite is the owner deciding the dangerous-scope policy, not Swift
routing code.

### Owner decision required (do NOT implement without a call)

**RESOLVED 2026-07-01 — owner chose option (a):** grant `SwiftFrontend` the
`ToolExecuteDangerous` scope by adding it to `default_scopes()`
(`control-plane/lib.rs:355`, commit `2c22322d`). The per-call `tool.confirm`
card (A3, already wired) is the human-in-the-loop boundary — granting the scope
lets the governed path run, it does not bypass approval. F7a (route write)
shipped on this basis (`c4ad79cf`).

The original options were:
- **(a) Add it to `SwiftFrontend::default_scopes()`** ✅ chosen.
- **(b) Config-gated opt-in** — a `config.toml` flag the owner sets.
- **(c) Defer** — keep write/edit/bash on the local Swift pipeline.

Resolving this unblocked all of Layer 4 at the scope level (write/edit/bash share
the `dangerous` classification). Once decided, the Swift F7a work was
well-scoped: `WriteRoutePlan` + `planWriteRoute`/`routeWrite` +
`executeSerializedRoutedWrite` + `executeRoutedWrite` (PreToolUse → fd-anchored
pre-state capture inside the locked daemon op → timeout-wrapped daemon write →
PostToolUse → audit → receipt + narration), mirroring `executeRoutedRead` with
the mutation steps added. The `tool.confirm` card needed no new Swift work
(already wired + covered by `testAwareRoundTripAnswersToolConfirmBeforeResponse`).

### Corrections to the original F7a plan (found during orientation, advisor-validated 2026-07-01)
1. **Approval is upstream, not executor-local.** `requiresApproval` is consumed
   at `Pipeline/ToolRoutingHelpers.swift:84`, not in `executeInner`. Routed
   write inherits upstream approval automatically; **do not** add an approval
   step to `executeRoutedWrite` (decision #1 from §6 is moot for F7a).
2. **DamageControl split is F8/bash, not F7a/write.** `DamageControlPolicy`'s
   write/edit rules (`zeroAccessPaths`, `readOnlyPaths`) are confinement; the
   `.disaster` catastrophe rules are bash-only. The daemon governs confinement
   for routed writes, so routed write skips DamageControl exactly like routed
   read (decision #3 from §6 is moot for F7a). Defer `evaluateConfinement`/
   `evaluateCatastrophe` to F8.
3. **Write daemon-outage = fail closed.** No confined local write fallback (the
   legacy `WriteTool` is path-based; a Swift fd-anchored write would duplicate
   the hard-gate work and widen risk). Preserve `.legacyLocal` only for explicit
   daemon opt-out (`!reachable && !daemonIntended`); intended-but-down fails
closed.

---

## 1. Current state (grounded in source)

### The local pipeline (non-routed tools), `ToolExecutor.executeInner`
Step numbers from `ToolExecutor.swift:9-15, 324-488`:

| # | Step | Site |
|---|---|---|
| 1-5 | deterministic gates (tool exists, read-only mode, schema, approval shape, route plan) | `:298` "deterministic gates (1-5)" |
| 7 | **DamageControlPolicy.evaluate** → allow / `.block(reason)` | `:324-348` |
| 8 | execution-argument augmentation | `computeExecutionArguments` |
| 10 | PreToolUse plugin hooks (can block) | `runPreToolUseHooks` |
| 12 | execute (the tool's `.execute(input:)`) | local `ReadTool`/`WriteTool`/… |
| 13 | PostToolUse plugin hooks (informational) | `runPostToolUseHooks` |
| 14 | analytics + security log | `recordToolOutcome` |
| 15 | **action receipt** (pre-state captured at `:417`, recorded at `:488`) | `ReceiptStore` |

### The routed-read pipeline (current), `ToolExecutor.executeRoutedRead`
Mirrors steps 8/10/12/13/14 — PreToolUse → timeout-wrapped execute → PostToolUse
→ audit/analytics (`ToolExecutor.swift:532-607`). **Skips step 7 (DamageControl)
and step 15 (receipts)**, per the owner-locked #5 decision: the daemon governs
confinement (DamageControl's *confinement* role is moot for a daemon-routed
read), and read is non-mutating (no receipt material). See
`bswift-3b-followups-2026-06-30.md` #5.

### DamageControlPolicy mutating-tool cases
`DamageControlPolicy.swift:301-305` extracts a path per tool kind
(`read`/`write,edit`/`bash`); `:230` gates `["read","write","edit","bash"]`;
`:134` blocks "Deletion of a major user folder (Documents or Desktop) —
irreversible data loss." So DamageControl has **two distinct roles**:
- **confinement** (path rules, symlink/escape rejection) — for `read` this is
  what the daemon now governs.
- **catastrophe / blast-radius** (irreversible-delete, destructive bash) — this
  applies to *mutations* and is NOT a confinement concern.

### Mutating-tool approval/risk
`BuiltinTools.swift:47-48, 83-84, 137-138`: `write`/`edit`/`bash` are all
`requiresApproval = true`, `riskLevel = .high` (vs `read` `.low`, no approval).

### Receipts
`ToolExecutor.swift:47-48, 155-157, 417, 488`: `ReceiptStore` captures
**pre-state** for undo/reversibility BEFORE execute (`:417`) and records the
receipt AFTER (`:488`). This is mutation-audit material — it does not exist for
reads.

---

## 2. Decision table — pipeline step × routed tool

Cells: **APPLY** (run unchanged) / **SKIP** (do not run) /
**CONDITIONAL** (see notes). " routed read" column is the current behaviour,
for reference.

| Step | routed read (current) | routed write | routed edit | routed bash |
|---|---|---|---|---|
| 1-5 deterministic gates | APPLY | APPLY | APPLY | APPLY |
| **approval** (`requiresApproval`) | n/a (read=.low) | **APPLY** (Swift-side, pre-execute) | **APPLY** | **APPLY** |
| **7. DamageControl** — *confinement* role | SKIP (daemon governs) | SKIP (daemon governs path confinement) | SKIP (daemon governs) | SKIP (bash has no single path; daemon governs cwd/fs reach) |
| **7. DamageControl** — *catastrophe/blast-radius* role | n/a (read can't delete) | ~~APPLY~~ **SKIP** (write rules are confinement-only; catastrophe is bash-only → F8) | ~~APPLY~~ **SKIP** (edit rules are confinement-only; catastrophe is bash-only → F8) | **APPLY** (destructive-pattern rules) |
| execution-arg augmentation | APPLY (no-op seam) | APPLY | APPLY | APPLY |
| PreToolUse hooks | APPLY | APPLY | APPLY | APPLY |
| execute (daemon round-trip) | APPLY | APPLY | APPLY | APPLY |
| PostToolUse hooks | APPLY | APPLY | APPLY | APPLY |
| audit/analytics (step 14) | APPLY | APPLY | APPLY | APPLY |
| **receipts** (step 15) | SKIP (non-mutating) | **APPLY** (pre-state + record) | **APPLY** (pre-state + record) | **CONDITIONAL** (see §3) |

**Net change vs routed-read:** the original prediction was that mutating tools
bring back DamageControl's catastrophe role + receipts. **Actual outcome
(F7a/F7b validation):** routed write/edit bring back **only receipts** — they
skip DamageControl entirely (their `DamageControlPolicy` rules are confinement,
governed by the daemon; the `.disaster` rules are bash-only). Bash (F8) is the
only routed mutation that needs DamageControl's catastrophe role, so the
confinement/catastrophe split is F8/bash-only. Approval is new relative to read.

---

## 3. Per-tool notes

### Approval (`requiresApproval = true`)
Approval is a **Swift-side, pre-execute** gate (it's a user prompt, not a
daemon capability). It must run in `executeRoutedWrite/Edit/Bash` BEFORE the
daemon round-trip — the daemon executing a mutation the user hasn't approved
would be a policy bypass. The routed-read seam (`executeRoutedRead`) currently
has no approval step; the mutating variants add one before PreToolUse hooks.

**OPEN (owner decision):** does daemon-execution change the approval UX? E.g.
the approval card may need to show the *daemon-resolved* canonical target (not
the raw arg), so the user approves the real on-disk path. This is a UX call,
not a safety call (the daemon confines regardless).

### DamageControl — split the two roles

**ACTUAL OUTCOME (F7a/F7b validation, supersedes the original prediction
below):** routed write/edit **skip DamageControl entirely**. Inspection of
`DamageControlPolicy.swift` showed the write/edit rules (`zeroAccessPaths`,
`readOnlyPaths`) are confinement, and the `.disaster` rules (`:134`) match only
deletion/bash patterns write/edit can't produce. So there is no catastrophe
rule to apply for write/edit, and the split is **not needed** for them — it is
deferred to F8/bash (the only routed mutation with real catastrophe rules:
destructive shell patterns). Routed write/edit were shipped without any
DamageControl step; the daemon governs confinement.

**Original prediction (retained as the F8 design basis):** the #5 skip was
justified by "daemon governs confinement." That holds for mutating tools'
**confinement** role (path rules, escape rejection — the daemon anchors writes
the same way it anchors reads). But DamageControl's **catastrophe/blast-radius**
role (`:134` irreversible-delete, destructive bash patterns) is independent of
confinement: the daemon executing `rm -rf ~/Documents` is catastrophic whether
or not the path is "confined." So **bash** (F8) keeps DamageControl's
catastrophe rules.

**Recommendation (F8 only):** split `DamageControlPolicy.evaluate` into
`evaluateConfinement` (skippable for routed) and `evaluateCatastrophe`
(always-run). Routed **bash** calls only `evaluateCatastrophe`. This is a
source change deferred to F8 — not needed for write/edit (shipped without it).

### Receipts
Write/edit are unambiguous mutations → **APPLY** receipts (pre-state capture +
record), exactly as the local pipeline does today (`:417`, `:488`). The daemon
performing the write does not remove Swift's need for an undo/reversibility
trail.

**Bash is CONDITIONAL:** `capturePreStateForTool` (`:417`) currently has no
general way to snapshot "the system state before an arbitrary bash command."
Bash receipts today are best-effort / coarse. **OPEN (owner decision):** for
routed bash, do we (a) keep the current coarse bash-receipt behaviour, (b)
require a daemon-side snapshot, or (c) gate bash receipts on known-reversible
command classes? This is the least-settled item.

---

## 4. Precedent constraints from #5 (the routed-read seam)

The routed-mutating variants must reuse the **same shared infrastructure** the
#5 routed-read established, so there is no copy/paste pipeline:

- **Decision/execution split** (`DaemonToolRouting.ReadRoutePlan` +
  `planReadRoute` / `routeRead(_:plan:)`): mutating routing should add a
  parallel `WriteRoutePlan` / `EditRoutePlan` / `BashRoutePlan` (or generalize)
  with the route fixed before any side effect (no policy race — the #5 lesson).
- **Shared helpers** (`ToolExecutor.swift`):
  `runPreToolUseHooks` / `runPostToolUseHooks` / `recordToolOutcome` /
  `computeExecutionArguments` — used by BOTH local + routed-read today; the
  mutating variants MUST use these too (no duplicate hook/audit logic).
- **Protocol seams** (`ToolAnalyticsRecording` / `PluginHookRunning`; concrete
  actors conform) — the mutating variants inject the same way (spy-injected
  tests).
- **Timeout + cancellation** (`executeRoutedRead`'s `withThrowingTaskGroup` +
  the cancellation-aware daemon socket from F2) — mutating routed tools get the
  SAME timeout wrapping; a wedged daemon write must not hold the operation lock.
- **`#if FAE_TEST_SEAMS`** — any new test-seam setter for the mutating variants
  is compiled out of release (the F4 rule).

---

## 5. Recommended phased path

Do NOT route all three mutating tools at once. Route **`write` first** (simplest
mutation, clearest receipt story), then `edit`, then `bash` (hardest — receipts
+ blast-radius both unsettled).

### Phase F7a — route `write` (SHIPPED 2026-07-01, `c4ad79cf`)
- `WriteRoutePlan` + `planWriteRoute`/`routeWrite` shipped; `routedTools` = {read, write}.
- **Hard gate satisfied:** the fluers `write_file` fd-anchoring TOCTOU (the
  original blocker — flagged OPEN above) was closed by fluers 0.5.0 before
  routing landed.
- **Actual pipeline:** upstream approval (`ToolRoutingHelpers.swift:84`) →
  PreToolUse hooks → timeout-wrapped daemon write → PostToolUse hooks → audit/
  analytics → receipt (fd-anchored pre-state, captured under the operation lock
  after root approval via `readFdAnchoredPreState`).
- **DamageControl SKIPPED entirely** — the advisor validation found the write
  rules (`zeroAccessPaths`/`readOnlyPaths`) are confinement-only and the
  `.disaster` rules are bash-only. The daemon governs confinement. (The original
  prediction — "DamageControl catastrophe only" + "split `evaluate`" — was
  superseded; the confinement/catastrophe split is deferred to F8/bash.)
- **Fail-closed** on daemon outage (no local write fallback — mutations are
  irreversible).

### Phase F7b — route `edit` (SHIPPED 2026-07-01)
Same shape as write; `edit` is read-before-write, so its pre-state receipt is
the original file content (clean). Adds an `EditRoutePlan`. Two edit-specific
differences from F7a, both resolved in the implementation:
1. **Schema translation at the daemon seam** — Swift `EditTool` uses
   `old_string`/`new_string`; fluers daemon `EditTool` requires `old_text`/
   `new_text` (`validate_input` enforces it). `DaemonToolRouting
   .buildDaemonEditInput` does the translation inside
   `executeSerializedRoutedEdit`, so `call.arguments`/hooks/audit/receipts keep
   the Swift-native keys and the daemon receives `old_text`/`new_text`. Unit-
tested (`testEditSchemaTranslatesOldNewStringToOldNewText`).
2. **Local EditTool parity fix** — the local tool now rejects empty
   `old_string` and requires a unique match (mirroring fluers), so routed vs.
   legacy edit behave identically (previously it silently replaced the first of
   N and accepted empty `old_string`).
`friendlyRoutedEditError` handles edit-logical errors (not-found/ambiguous)
distinctly from backend problems.

### Phase F8 — route `bash`
Hardest. Requires the bash-receipt owner decision (§3) and destructive-pattern
DamageControl catastrophe rules for routed execution. Likely lands LAST and may
keep some bash patterns on the local pipeline even after routing (hybrid).

---

## 6. Open owner decisions (do NOT implement without a call)

1. **Approval UX for daemon-executed mutations:** show daemon-resolved canonical
   target on the approval card? (§3.)
2. **Bash receipts for routed execution:** coarse / daemon-snapshot /
   reversible-class-gated? (§3.)
3. **DamageControl split timing:** do the `evaluateConfinement`/
   `evaluateCatastrophe` split as part of F7a, or leave confinement-eval in place
   for routed mutating tools (harmless redundancy) until a later cleanup?
4. **DamageControl catastrophe rules for routed bash:** are the current
   destructive-pattern rules (`DamageControlPolicy.swift` bash branch) sufficient
   for daemon-side execution, or does the daemon's broader reach need tighter
   rules?

---

## 7. What this doc is NOT

- Not a schedule. Routing write/edit/bash is not approved by this doc.
- Not a confinement design. Confinement for mutating tools is the daemon's job
  (anchored writes), once the fluers write/exec TOCTOU is closed (#4 residual).
- Not a receipts redesign. It identifies bash receipts as the open question and
  defers it.
