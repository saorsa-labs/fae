# ADR-013 Vision A — Slice A3 scope: protocol surface + session-root + confirmation channel

> **Status:** SCOPE rev 3 — **owner-blessed for the A3-Rust slice** (2026-06-29).
> Implementation of the Rust half may proceed; A3-Swift is held until A3-Rust
> semantics are merged + green.
>
> Rev 2 incorporated the oracle scope review (`93ddbada`, NOT READY → fixed):
> BLOCKER-1 (client-side deadlock), MAJOR-1..5, MINOR-1. **Rev 3 folds the
> owner's structural decisions and locks provenance.**
>
> ## Provenance (recorded per the standing rule)
>
> **Owner-decided (structural — three items):**
> 1. **BLOCKER-1 is a hard requirement:** every `toolhost.execute` caller MUST use
>    the server-request-aware `roundTrip` (`DaemonLLMEngine.swift:517`), never the
>    plain `:496` (which skips the `tool.confirm` frame and deadlocks the daemon).
>    Daemon-side spawn + regression test land in A3-Rust; the client-side-aware-
>    path regression lands in A3-Swift.
> 2. **A3 is split: A3-Rust first, A3-Swift follows.** A3-Rust = daemon command
>    + per-session root + `tool.confirm` semantics + close-cancels lifecycle +
>    60s/single-in-flight bounds, fully Rust-tested via a fake client (incl. the
>    BLOCKER-1 daemon-side deadlock regression). No Swift in A3-Rust.
> 3. **A3-Swift does not start until A3-Rust semantics are merged and green.**
>
> **Reviewer-recommended (accepted as defaults; not separately owner-signed):**
> - **Q1** command name = `toolhost.execute`.
> - **Q2** root = per-session ephemeral, **created at session start** (eager, not
>    lazy), **torn down on close** (explicit lifetime).
> - **Q3** confirm snippets = **redacted/minimal** — path + byte counts + hash;
>    **never echo file contents**.
> - **Q4** 60s timeout + single-in-flight-per-connection + close-cancels-and-
>    awaits-before-root-drop.
> - **Q8** the §2.1 routing table (portable→daemon, macOS-native→Swift,
>    networked→denied).
>
> **Still open (defer to A3-Swift, joint with Swift):** Q5 (wire method —
> `tool.confirm` used provisionally in Rust; revisit if Swift prefers
> `permission.request`), Q6 (minimal Swift handler vs defer UX), Q7
> (SwiftFrontend `ToolExecuteSafe` default / `ToolExecuteDangerous` opt-in).
> **Authority:** ADR-013 (Accepted) → A2-body merged (`135dafd1`, scope rev 4).
> **Depends on:** A0 ✅, A1 ✅, A2-pre (fluers v0.3.0) ✅, A2-body ✅.
> **Provenance discipline:** only owner-explicitly-accepted items get "owner-
> signed"; everything else is "reviewer-recommended" until the owner signs
> (per the A2 merge correction `e94bc7a3`).

## 1. The central discovery — A3 is much smaller than the kickoff implied

The kickoff listed "build the confirmation channel generically" as a major task.
**That channel already exists, is tested, and is generic:**
[`ServerRequester`](../../crates/fae-daemon/src/server_request.rs) implements
daemon→client request/reply over the same NDJSON socket:
`{v, server_request_id, method, params}` → `{v, server_request_id, result}`,
with `transport.rs:156-159` routing replies via `requester.resolve()`. The
existing `permission.request` / `fs.read` / `fs.write` mediation
(`session.rs:955-1010`) is the **exact** precedent — including the fail-safe
mapping (disconnect/malformed → `Cancelled`/deny).

**So A3 does NOT build new transport.** It reuses `ServerRequester` for
`toolhost.execute` confirmations, exactly as the kickoff demanded ("coordinate;
don't fork it"). This removes the riskiest, most novel part of the slice.

## 2. What A3 actually is (four sub-slices — A3-Rust scope shown)

**A3-Rust (this hand-back):**
1. **`toolhost.execute` wire command** wrapping A2's `ToolHost::execute`, in the
   dispatch table. Two-tier auth (§4). Spawned like `agent.prompt` (§3).
2. **Per-session ephemeral session-root** (Q2 resolved, §5) — eager at session
   start, torn down on close; structural owning guard (never caller convention).
3. **`tool.confirm` flow** via `ServerRequester` for dangerous tools (§6) —
   converts §4.1 `ConfirmRequired→Deny` into `ConfirmRequired→tool.confirm→
   proceed/deny`. Internal-evaluator refactor (§6.1) + path/damage-before-
   confirm (§6.2) + bounded redacted payload (§6.3) + reply schema (§6.4) +
   60s/single-in-flight/close-cancels (§6.5).
4. **Dangerous-tool pipeline tests** now reachable (§7) — write/edit path,
   bash damage, end-to-end through the confirm channel — **via a fake client**
   (no Swift in A3-Rust).

**A3-Swift (follows, after A3-Rust merged+green):** the real `tool.confirm`
handler + routing (§2.1) + SwiftFrontend scope provisioning (Q7) + the
client-side-aware-roundtrip regression (BLOCKER-1 client half) + UX.

**Out of A3 (unchanged):** the real 3-gate egress adapter (A2.5/P7 — networked
tools keep denying via `DisabledGate`); SkillHost (A2.5); Vision B.

## 2.1 Swift routing boundary (oracle MAJOR-5 — required)

The kickoff task 4 (Swift routing) needs a concrete boundary. A3 defines the
**dispatch table at the Swift side** for which model-emitted tool calls route
where (OPEN-Q8 for the exact split; lean below):

| Tool class | Routes to | Why |
|---|---|---|
| Portable native (`read`/`write`/`edit`/`bash`/`glob`/`grep`) | daemon `toolhost.execute` (server-request-aware round trip, §3.1) | governed by FaeToolPolicy + the §6 confirmation |
| macOS-native (EventKit/camera/computer-use, future) | Swift, in-process | needs privileged OS APIs the daemon can't reach; stays Swift-native |
| Networked (`web_search`/`fetch_url`) | denied in A3 (`DisabledGate`) | egress adapter is A2.5/P7 |

- A3 lands the daemon command + the `tool.confirm` Swift handler (minimal: a
  yes/no sheet rendering the bounded payload, §6.3/§6.4) so the end-to-end proof
  (A4) can run. The polished approval card is a follow-on (OPEN-Q6).
- The routing helper that performs the **server-request-aware** call is the ONE
  chokepoint every portable-tool caller must use (BLOCKER-1 — the plain
  `roundTrip` path is forbidden for `toolhost.execute`).

## 3. `toolhost.execute` must be SPAWNED, not awaited inline

**The load-bearing daemon-side constraint.** If the handler awaits
`requester.request("tool.confirm", …)` inline in the transport read loop, the
client's reply frame cannot be read → **deadlock**. This is the same reason
`agent.prompt` is spawned today (`transport.rs:160-180`).

A3 mirrors that special-case: detect `"toolhost.execute"`, clone the
`ServerRequester`, spawn the command onto a task, respond via `sink` when done.
The read loop keeps draining `{server_request_id, result}` replies and routing
them via `requester.resolve()`. **No new daemon-side deadlock surface.**

### 3.1 The symmetric client-side deadlock (oracle BLOCKER-1 — load-bearing)

The daemon-side spawn is necessary but NOT sufficient. **Every Swift caller of
`toolhost.execute` MUST use the server-request-aware round trip**
(`roundTrip(frame:expectRequestID:onServerRequest:)`, `DaemonLLMEngine.swift:517`),
NOT the plain `roundTrip(frame:expectRequestID:)` (`DaemonLLMEngine.swift:496`,
which skips non-matching frames via `maxSkippedLines: 200`). If a caller uses
the plain path, the Swift reader consumes/skips the `tool.confirm` frame
without replying, while the daemon's `ServerRequester::request()` waits forever
→ **client-side hang**, symmetric to the daemon deadlock.

This is as load-bearing as the daemon spawn. A3 mandates the aware path for
**all** `toolhost.execute` callers + a regression test (`toolhost_execute_caller_
uses_server_request_aware_roundtrip`).

## 4. Two-tier auth (envelope + inner policy)

- **Outer (command envelope):** add `toolhost.execute` to control-plane
  `required_scopes` mapping to `Scope::ToolExecuteSafe`. This is the permission
  to *call the host at all* — a client without it is denied at the wire, before
  any tool runs. (OPEN-Q1: exact command name. Lean: `toolhost.execute`, per
  scope rev 3 OPEN-Q3 lean — keeps "execute" distinct from the broker
  `tool.execute_*` semantics.)
- **Inner (per-tool policy):** unchanged from A2 — `FaeToolPolicy` still maps
  each tool to `tool.execute_safe`/`tool.execute_dangerous` and runs
  authorize + path/damage/egress. The outer scope is necessary but not
  sufficient; the inner policy is the real governance.

**Why two tiers:** the outer scope is a coarse "may this client use the daemon
tool host at all" gate (one wire-permission). The inner policy is the
per-call, per-tool governance (scope + path + damage + egress + audit). Folding
them would either weaken the inner policy or make the wire check redundant.
Mirrors how `agent.run` has an outer `AgentExecute` scope AND inner per-turn
egress gates.

### 4.1 Swift scope provisioning (oracle MAJOR-1 — required decision)

**Verified gap:** `SwiftFrontend::default_scopes()` (`control-plane lib.rs:334`)
includes `StatusRead`/`ConversationWrite`/`AudioCapture`/`AgentExecute` etc. but
**NOT** `ToolExecuteSafe` or `ToolExecuteDangerous` (the test at `lib.rs:362`
even asserts their absence). As written, real Swift turns would be **denied at
the outer gate**, and dangerous tools could never reach confirmation.

A3 must add an explicit provisioning decision (OPEN-Q7):
- **Lean:** add `ToolExecuteSafe` to `SwiftFrontend::default_scopes()` (the
  envelope permission for `toolhost.execute`); keep `ToolExecuteDangerous`
  **opt-in** (granted only when an owner enables dangerous tools — e.g. a
  settings toggle — so confirmation is the default path, not auto-proceed).
- A client may hold the dangerous scope but still hit `ConfirmRequired` (the
  inner policy + the §6 confirmation flow); the scope just makes the
  confirmation reach it rather than `MissingScope`-deny.
- Tests: `swift_frontend_default_has_safe_scope`;
  `dangerous_scope_is_opt_in_not_default`.

## 5. Session-root: structural lifecycle (OPEN-Q3 resolved)

**The sandbox boundary is security-load-bearing** (kickoff emphasis). A3 creates
a `ToolHostSessionRoot` guard that owns a private ephemeral temp dir and
**deletes it on drop/close**. The `ToolHost` borrows the root path; it never
owns the guard (so the root can't be deleted under the host).

Lifecycle:
- **Created at session start** (eager, not lazy — owner Q2): when an
  authenticated connection is established, before any `toolhost.execute`. An
  explicit lifetime (created on open, torn down on close) is clearer to reason
  about than lazy-on-first-call and avoids a create-on-the-hot-path branch.
- **Per-connection/per-client**, never shared across connections, never the
  user's home/project dir.
- **Torn down on close** (the guard is dropped) — AFTER close cancels + awaits
  in-flight spawned tasks (§5.1). A best-effort cleanup; a crashed daemon leaves
  the temp dir (OS temp reaps it).
- The root path is passed to `ToolHost::with_wiring` as the `LocalSessionEnv`
  root; `LocalSessionEnv`'s canonicalize + `starts_with` containment still
  applies (defense-in-depth, unchanged).

**Reject:** passing an arbitrary `cwd` / home / project dir as the root. Those
are caller-convention escapes; A3 makes the boundary structural.

### 5.1 Ownership vs spawned tasks (oracle MAJOR-2 — load-bearing)

Because `toolhost.execute` is spawned (§3), an in-flight task can outlive the
connection that issued it unless explicitly cancelled. **A plain `TempDir`
guard dropped on connection-close would race the spawned task** (task reads/writes
the root after the guard deletes it). A3 resolves this with ONE of:
- **(a) Connection close cancels + awaits in-flight tasks BEFORE dropping the
  root** (cleanest; the root outlives every task it spawned). **Lean.**
- (b) The root is held by an `Arc<ToolHostSession>` cloned into each spawned
  task, so the dir is deleted only when the last reference drops (task + conn).

Either makes the root's lifetime ≥ the task's. A3 picks (a): the spawned task's
`JoinHandle` is tracked per-connection and aborted+awaited on close, then the
root guard drops. Documented + tested (`root_outlives_in_flight_task`).

## 6. The confirmation flow (reuses ServerRequester, §1)

### 6.1 Refactor A2 policy into an internal evaluator (advisor #4 — load-bearing)

A2's `FaeToolPolicy::check()` returns `PolicyVerdict::{Allow, Deny}` and **never
`Confirm`** (the §4.1 trap: fluers' loop treats `Confirm` as allow-with-log, so
emitting it would be a silent-allow bypass if anyone wired `FaeToolPolicy` into
`run_agent`).

A3 **preserves that invariant.** Refactor (oracle MINOR-1: the evaluator is
`async` — the egress gate at step 5 is async):
```rust
// internal, richer — the real decision logic (async: egress check awaits)
enum EvaluateOutcome { Allow, Deny(String), NeedsConfirmation { reason, tool, risk } }
async fn evaluate(...) -> EvaluateOutcome { /* the §6.2 pipeline */ }

// public fluers trait contract — stays fail-closed (sync-looking via async_trait)
impl ToolPolicy for FaeToolPolicy {
    async fn check(...) -> PolicyVerdict {
        match evaluate(...).await {
            Allow => Allow,
            Deny(r) => Deny(r),
            NeedsConfirmation { .. } => Deny("confirmation_required_via_loop_bypass"), // §4.1
        }
    }
}
```
`ToolHost::execute` (A3's governed path) uses the internal `evaluate()`:
`NeedsConfirmation` → ask via `ServerRequester` → approve→audit→execute OR
deny/cancel→audit. The public `ToolPolicy::check()` path is **only** reached if
someone wires `FaeToolPolicy` into fluers `run_agent` (Vision B territory) — and
there it stays fail-closed.

### 6.2 Run path/damage BEFORE asking confirmation (advisor #5 — load-bearing)

A2's pipeline denies dangerous tools at `ConfirmRequired` (step 2) **before**
path (step 3) / damage (step 4) — so those gates were unreachable through the
pipeline (A2 unit-tested the logic only). A3's `evaluate()` fixes the order:
1. classify; 2. authorize → `Allow`/`Deny`/`NeedsConfirmation`;
3. **path check** (run regardless — a `../escape` write denies before asking);
4. **damage check** (run regardless — catastrophic `bash` denies before asking);
5. egress (networked — still `DisabledGate` in A3); 6. if `NeedsConfirmation`
flagged at step 2, **now** ask; 7. allow+audit (fail-closed).

This makes path/damage **load-bearing before confirmation** for the first time:
a `write` to `../escape` denies without ever prompting the owner. Required A3
tests (§7).

### 6.3 The confirmation payload is bounded + redacted (advisor #7, owner Q3)

**Never** send arbitrary tool input JSON as confirmation text (injection /
oversized / leaky), and **never echo file contents** (owner Q3 — redacted/
minimal). Per-tool allowlisted summary:
- `write`/`edit`: `path` + old/new **byte counts** + a **hash** of old/new
  content (NO content/snippet/diff — owner Q3 redacted).
- `bash`: bounded command string (first N chars; the command IS the action, so
  a truncated echo is unavoidable for the owner to decide — bounded, not raw).
- All: `tool`, `call_id`, `risk_class`, `reason`.

Fail-closed on: malformed reply, disconnect, timeout (§6.5).

### 6.4 The `tool.confirm` reply schema (oracle MAJOR-4 — required)

The reply shape is explicitly defined, mirroring `permission.request`'s
fail-safe parser (`session.rs:1004`):

```jsonc
// daemon → client (request params): bounded payload above
// client → daemon (reply result):
{ "approved": true, "call_id": "<echoed>" }   // ONLY this approves
{ "approved": false, "call_id": "<echoed>" }   // explicit deny
// missing/wrong-type/"error"/cancelled/timeout → DENY (fail-closed)
```

Rules: only `approved == true` proceeds. **Everything else denies** (missing,
wrong type, `error` field, cancelled, malformed). `call_id` is echoed
**defensively** (if present and mismatched → deny, guards against reply
mis-routing). The exact parser is unit-tested (`tool_confirm_reply_parser`).

### 6.5 Timeout / in-flight cap (oracle MAJOR-3 — required)

`ServerRequester`'s pending map is unbounded (`server_request.rs:37`); an
abandoned confirmation (client never replies, connection half-open) leaks a
parked oneshot forever. A3 adds (all three):
1. **Bounded server-side timeout** (OPEN-Q4 revised): a confirmation must
   resolve within T (lean: 60s) or the daemon treats it as a deny + audits
   `confirm_timeout`. The owner's prompt is still the UX; this bounds resource
   leak + a hung connection.
2. **Single in-flight confirmation per connection**: a second `toolhost.execute`
   needing confirm while one is pending → deny `confirm_already_pending` (avoids
   a queue of stacked prompts + bounded pending-map growth).
3. **Connection-close cancellation**: on close, all pending confirmations are
   resolved as `Disconnected` (fail-closed) and the spawned tasks aborted (§5.1).

Tested: `confirm_timeout_denies_and_audits`;
`second_confirm_while_pending_denies`.

### 6.6 The wire method (OPEN-Q5)

Lean: a **new** `tool.confirm` method (not reusing `permission.request`) — it
carries the tool-shaped bounded payload, and Swift can render a tool-specific
card. But the *transport* is identical (`ServerRequester::request`). If Swift
already has a generic approval card that fits, reuse `permission.request`
(OPEN-Q5 — decide with the Swift side).

## 7. Test plan (A3)

**Two-tier auth:**
- `no_safe_scope_denied_at_wire` — outer scope missing → denied before dispatch.
- `safe_only_inner_policy_denies_dangerous` — safe scope + `write` → inner
  `MissingScope` deny + audit (no prompt).
- `safe_dangerous_confirm_approve_executes` — both scopes + approve → executes.
- `safe_dangerous_confirm_deny_blocks` — both scopes + deny/disconnect → denied.

**Path/damage before confirmation (§6.2):**
- `write_path_escape_denies_without_prompting` — `../escape` write → deny, **no
  confirm round-trip issued** (assert the requester was never called).
- `bash_catastrophic_denies_without_prompting` — `rm -rf /` → deny, no prompt.
- `benign_write_prompts_then_approves` — clean `write` → prompt → approve → runs.

**Confirmation semantics:**
- `confirm_disconnect_fails_closed` — requester disconnect → denied + audited.
- `confirm_malformed_reply_fails_closed` — bad JSON reply → denied + audited.
- `confirm_payload_is_bounded` — assert no arbitrary input leaks into the
  `tool.confirm` params (allowlist).
- `tool_confirm_reply_parser` — only `{approved:true}` proceeds; everything
  else denies; mismatched echoed `call_id` denies (oracle MAJOR-4).
- `confirm_timeout_denies_and_audits` — T elapsed with no reply → deny + audit
  `confirm_timeout` (oracle MAJOR-3).
- `second_confirm_while_pending_denies` — a second confirm while one is
  pending → deny `confirm_already_pending` (oracle MAJOR-3).
- `connection_close_cancels_pending_confirm` — close resolves pending as
  `Disconnected` + aborts the spawned task (oracle MAJOR-3/MAJOR-2).

**Client-side (oracle BLOCKER-1):**
- `toolhost_execute_caller_uses_server_request_aware_roundtrip` — the Swift
  routing helper uses `onServerRequest:` (regression: never the plain path).

**Session-root (§5):**
- `root_is_ephemeral_and_deleted_on_close` — a connection's root is created +
  torn down; not shared with a second connection.
- `root_is_not_cwd_or_home` — the root is under the OS temp dir, never
  `current_dir` or `home`.
- `root_outlives_in_flight_task` — close cancels+awaits spawned tasks BEFORE
  dropping the root (no read/write-after-delete race) (oracle MAJOR-2).

**`ToolPolicy::check()` stays fail-closed (§6.1):**
- `loop_path_confirm_required_maps_to_deny` — mutation guard: the public
  `check()` returns `Deny` for a `NeedsConfirmation` tool, never `Confirm`.

**Spawned-handler (§3):**
- `toolhost_execute_does_not_deadlock_read_loop` — a confirm round-trip
  completes while the connection keeps accepting other frames.

## 8. Open questions

**Resolved (reviewer-recommended, owner-accepted as defaults):**
- **Q1** ✅ command name = `toolhost.execute`.
- **Q2** ✅ root = per-session ephemeral, eager at session start, torn down on close.
- **Q3** ✅ confirm snippets = redacted/minimal (path + byte counts + hash; no
  file contents).
- **Q4** ✅ 60s timeout + single-in-flight-per-connection + close-cancels-and-
  awaits-before-root-drop.
- **Q8** ✅ §2.1 routing table.

**Open (defer to A3-Swift, joint with Swift):**
- **Q5:** wire method — `tool.confirm` (used provisionally in A3-Rust) vs reuse
  `permission.request`. Decide with Swift.
- **Q6:** minimal Swift handler (yes/no sheet) vs defer all UX. Lean: minimal.
- **Q7:** SwiftFrontend provisioning — `ToolExecuteSafe` default,
  `ToolExecuteDangerous` opt-in (owner toggle).

## 9. Risks

- **Daemon-side read-loop deadlock** (§3) if `toolhost.execute` is awaited
  inline. Mitigated by mirroring the proven `agent.prompt` spawn pattern + a
  dedicated test.
- **Client-side deadlock** (oracle BLOCKER-1) if a Swift caller uses the plain
  `roundTrip` for `toolhost.execute`. Mitigated by mandating the
  server-request-aware path + a regression test (§3.1).
- **Read/write-after-delete on the root** (oracle MAJOR-2) if a spawned task
  outlives the connection's root guard. Mitigated by close-cancels-and-awaits
  before root drop (§5.1).
- **Re-opening the §4.1 trap** if `FaeToolPolicy::check()` ever emits `Confirm`.
  Mitigated by the internal-evaluator refactor (§6.1) + a mutation guard.
- **Confirmation payload leak** if arbitrary input is sent. Mitigated by the
  bounded allowlist (§6.3) + a payload-shape test.
- **Confirmation resource leak** (oracle MAJOR-3) from abandoned requests.
  Mitigated by timeout + single-in-flight + close-cancels (§6.5).
- **Real Swift turns denied** (oracle MAJOR-1) if tool scopes aren't granted.
  Mitigated by the provisioning plan (§4.1).
- **Session-root escape** if the guard is bypassed or the root is caller-chosen.
  Mitigated by the structural owning-guard (§5) + `LocalSessionEnv` containment.
- **Path/damage gates still bypassable for safe tools** — no: safe tools
  (read/glob/grep) run path checks at step 3 regardless; only dangerous tools
  were short-circuited, and §6.2 fixes that.
- **Swift coordination** — the `tool.confirm` handler must exist for the
  end-to-end proof. A3 lands a minimal Rust-tested path + a minimal Swift stub;
  the polished UX is follow-on (OPEN-Q6).

## 10. Acceptance (A3 done when)

1. `toolhost.execute` is a spawned wire command with two-tier auth; raw
   `Tool::execute` stays private.
2. **Every** `toolhost.execute` caller uses the server-request-aware round trip
   (oracle BLOCKER-1); the plain path is forbidden + regression-tested.
3. The session-root is a structural owning-guard, per-connection, ephemeral,
   never cwd/home, and outlives its spawned tasks (close-cancels-and-awaits
   before drop; oracle MAJOR-2).
4. Dangerous tools (`write`/`edit`/`bash`) proceed ONLY through a
   `ServerRequester` confirmation; path/damage run first (§6.2).
5. `FaeToolPolicy::check()` still never emits `Confirm` (mutation-guarded).
6. Confirmations are bounded: timeout + single-in-flight-per-connection +
   close-cancels; the `tool.confirm` reply parser is fail-closed (oracles
   MAJOR-3/MAJOR-4).
7. Swift is provisioned for tool scopes (oracle MAJOR-1): `ToolExecuteSafe`
   default, `ToolExecuteDangerous` opt-in.
8. The test plan (§7) passes, incl. no-prompt-on-escape, fail-closed-disconnect,
   bounded-payload, root-outlives-task, and the client-side-aware-roundtrip tests.
9. Gates green; boundary guards intact; no `fae.db` writes.
