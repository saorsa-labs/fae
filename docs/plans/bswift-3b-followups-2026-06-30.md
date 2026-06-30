# B-Swift Layer 3b — Follow-up Hardening Tracker

> **Status:** 3b (read-only daemon routing slice) merged with the in-scope
> concurrency + confinement fixes. This file tracks the hardening items that
> were explicitly **deferred** (reviewer + codex + advisor triage: not merge
> blockers for the minimal `read` slice, but required before the daemon read
> path becomes the default / before dangerous tools route).

Owner: david@saorsalabs.com · Scope owner decision required for each.

## 1. 3a symlinked-default-root auto-approve (HIGH — in 3a `FaeWorkspace`)

- If `~/Documents/Fae` is itself a symlink to e.g. `~/.ssh`, the 3a
  `defaultAwareHandler` auto-approve follows it (canonical-EXACT compares the
  *resolved* path, so a symlinked default still matches itself — but the *dir*
  Fae roots into is the symlink target).
- 3b makes this reachable via a routed read. Needs verification + `lstat`-based
  hardening in the 3a provisioning/auto-approve path (reject a default root
  whose own path is a symlink, or surface the real card).
- **Owner call:** hard-reject symlinked default, or allow-with-warning?

## 2. Legacy no-daemon fallback is unconfined (MED — deliberate, revisit when daemon is default-bundled)

- With no daemon published, a routed `read` falls through to the local
  `ReadTool` with the ORIGINAL (unconfined) path. `read` is `.low` risk and was
  always local — **not a regression** — but "advertised confinement + silent
  unconfined fallback" is a trap once users expect confinement.
- **Owner call:** once the daemon is bundled by default, either (a) confine the
  local fallback to the workspace too, or (b) gate the legacy path behind a dev
  flag. Until then, the behavior is documented in `DaemonToolRouting.routeRead`.

## 3. Hardlinks defeat path confinement (MED — inherent)

- `ln ~/.ssh/id_rsa ~/Documents/Fae/key; read key` routes: the hardlink is a
  regular file under the workspace, passes confinement, and reads the sensitive
  target. Inherent to path-based confinement (the daemon shares it).
- **Options:** reject `st_nlink > 1` (strict; false positives on legitimately
  hard-linked workspace files), or document explicitly as accepted residual.
- **Owner call:** policy + whether the daemon side should also enforce.

## 4. TOCTOU on final-file read + `O_NOFOLLOW` (HIGH — belongs in fluers/daemon + `ReadTool`)

- Generic check-then-(re)open race between Swift confinement and the actual
  read (daemon `local_env.rs` open, and the local `ReadTool`'s
  `String(contentsOfFile:)`). The Swift-side confinement raises the bar; it does
  not eliminate the race.
- **Fix location:** fluers runtime (`local_env.rs`: `O_NOFOLLOW` / `openat`
  under root) for the daemon path; `ReadTool` for the local path. **Out of scope
  for this Swift slice.**

## 5. Routed reads skip Swift audit / plugin hooks / executor timeout (reviewer + codex)

- A daemon-routed read returns before DamageControl (step 7) and the execute
  step (12), so it bypasses: Swift `SecurityEventLogger`, `ToolAnalytics`,
  PreToolUse/PostToolUse plugin hooks, and the 30s executor timeout. The daemon
  has its own `audit.jsonl`, but the Swift-side audit/policy gap is real.
- **Owner call:** is daemon-side audit sufficient for `read`, or mirror a Swift
  audit row for routed reads? Apply the executor timeout to the routed path?

## 6. Truncation parity (LOW)

- Daemon `read` truncates at 2000 lines / 50 KiB; local `ReadTool` truncates at
  50k chars. `offset`/`limit` aren't exposed by the Swift `read` tool, so no
  arg-drop — but a routed read can return a different truncation than a local
  one for the same large file. Add a parity test + decide the canonical limit.

## 7. Concurrent-caller coverage for `executeInDefaultWorkspace` / `execute` (LOW)

- The 3b operation lock serializes the **routed** path
  (`executeSerializedRoutedRead`). The 3a public methods
  (`executeInDefaultWorkspace`, `execute`) are NOT lock-protected — they're
  safe for sequential/test callers, and the only live production caller is the
  routed path (which holds the lock). If a future concurrent live caller is
  added to those methods, either route it through the lock or make
  `DaemonSocketConnection`'s server-request-aware `roundTrip` atomic.

## 8. Operation-lock cancelled-waiter (MEDIUM — reviewer, post-merge review)

- `acquireToolHostOperationLock()` parks a waiter in
  `withCheckedContinuation`, which does NOT resume on cooperative cancellation.
  If a routed-read Task is cancelled while parked (pipeline barge-in, a
  cancelled parent TaskGroup, a higher-level turn cancellation), the waiter
  stays parked. When the holder releases, it resumes the **cancelled** waiter,
  which then runs the full root+confine+execute daemon round-trip — zombie work
  the caller already abandoned — AND holds the lock during it, starving other
  readers. The waiter slot also leaks if never resumed.
- **Fix shape:** a cancel-aware acquire (`withTaskCancellationHandler` + a
  per-waiter id so the sync `onCancel` can remove the parked continuation from
  the actor array, then throw `CancellationError`). Notably trickier than a
  naïve ~10-liner because the cancel handler is sync and the waiter array is
  actor-isolated — needs a small id/registry. Worth doing while the concurrency
  code is fresh, but deferred to avoid a safety-critical-concurrency change +
  full re-gate during the merge.

## 9. Routed-read error copy is technical / not user-facing (LOW — reviewer)

- Routed-read denials and daemon failures surface raw technical strings to the
  conversation (e.g. `"read path escapes the workspace root"`,
  `"Daemon read failed: …"`, `"Daemon unavailable before the workspace root
  was approved…"`). Fine for the dev surface; not the friendly copy Fae's voice
  normally uses. Decide on a UX pass that maps routed-read outcomes to
  user-facing narration once the daemon read path is the default.
