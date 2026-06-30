# B-Swift Layer 3b — Follow-up Hardening Tracker

> **Status:** 3b (read-only daemon routing slice) merged with the in-scope
> concurrency + confinement fixes. This file tracks the hardening items that
> were explicitly **deferred** (reviewer + codex + advisor triage: not merge
> blockers for the minimal `read` slice, but required before the daemon read
> path becomes the default / before dangerous tools route).

Owner: david@saorsalabs.com · Scope owner decision required for each.

## 1. 3a symlinked-default-root auto-approve (HIGH — ✅ RESOLVED 2026-06-30)

**Fixed.** Verified against the real server guard (`crates/fae-daemon/src/
toolhost/root_confirm.rs::is_safe_workspace_root`): it rejects the home dir
itself but NOT home subdirs (it must allow `~/Documents/Fae`, also a home
subdir). So a symlink `~/Documents/Fae → ~/.ssh` defeated the guard — the daemon
rooted into `~/.ssh` and a routed `read id_rsa` would exfiltrate SSH keys.

Swift-side hardening (load-bearing, not redundant): `FaeWorkspace.provision`
and `writeMarker` now `requireNotSymlinkAtTip` (`lstat` `S_IFLNK`) before any
marker/provisioning/`set_root`, throwing `FaeWorkspaceError.symlinkedWorkspaceRoot`;
`defaultAwareHandler` adds the same check as defense-in-depth. Only the default
root's TIP is checked (ancestor symlinks like macOS `/tmp → /private/tmp` are
fine — the daemon canonicalizes and guards those). Tests:
`testProvisionRejectsSymlinkedWorkspaceRoot`,
`testAutoApproveRejectsSymlinkedDefaultRoot`,
`testEnsureDefaultRootedRejectsSymlinkedDefaultBeforeDaemon`,
`testRoutedReadRejectsSymlinkedDefaultRoot` (asserts the key material never
leaks).

Original hazard (for the record): if `~/Documents/Fae` was a symlink to
`~/.ssh`, the 3a auto-approve followed it (canonical-EXACT compared the
*resolved* path, so the symlinked default still matched itself), and Fae rooted
into the symlink target (`~/.ssh`). 3b made this reachable via a routed read.
- **Owner call:** hard-reject symlinked default, or allow-with-warning?

## 2. Legacy no-daemon fallback is unconfined (MED — ✅ DECISION MADE 2026-06-30, implementation tracked)

**Decision (owner, 2026-06-30): the daemon IS default-bundled** (`llm.useDaemonEngine`
defaults to `true`; `FaeConfig.LlmConfig` comment: “the bundled
`Contents/MacOS/fae-daemon` makes this work out of the box”). So the no-daemon
state is not a rare pre-bundling edge — it is a **live failure mode** (failed
start, missing model, daemon crash → `FaeCore` clears endpoints → reads fall
through). “Advertised confinement + silent unconfined escape” is therefore a
real trap, not a theoretical one.

**Chosen policy: gate the fallback on the daemon-intended flag.**
- When the daemon is the intended runtime (`useDaemonEngine == true`) but is
  momentarily unreachable ⇒ the routed `read` is **confined locally** to the
  workspace (provision the default root locally — idempotent, #1-symlink-guarded
  — confine the shape-validated path against it, read the canonical path via
  `ReadTool`). Confinement becomes a **universal invariant** (“reads are
  confined to `~/Documents/Fae`” holds whether or not the daemon is up), and the
  `read` capability is preserved during daemon outages (no regression).
- When the daemon is explicitly opted out (`useDaemonEngine == false`, e.g. CI /
  pure-MLX mode) ⇒ keep the **legacy local unconfined** read (pre-3b behavior).
  This branch is what avoids the provisioning side-effect leaking into
  non-injecting test suites.
- Never silent: the branch taken is logged (ties into #5 — the Swift audit gap).

**Why not fail-closed:** `read` is `.low` risk and pre-dates routing; breaking
all reads during a daemon glitch is a worse UX than a confined local read, and
confinement already holds. **Why not unconditional confined-fallback:** it would
provision `~/Documents/Fae` as a side-effect in test suites that don’t inject a
temp provider — the gate avoids that.

**Implementation (tracked, lands in a fresh session with an advisor scope
review):**
- Thread the daemon-intended flag onto the routing seam (read
  `useDaemonEngine` via the session/config, or a new `toolhost.routeReads`).
- In `DaemonToolRouting.routeRead`, replace the unconditional `nil`-return with:
  intended-and-down → local confined read (reuse `confineValidatedReadPath`
  against the provisioned provider root + `readLocally`); opted-out → `nil`
  (legacy fallthrough).
- Tests: intended-and-down confines (reads a workspace file locally, denies an
  escape); opted-out stays legacy; provisioning side-effect only fires in the
  intended branch.

Original hazard (for the record): with no daemon published, a routed `read`
fell through to the local `ReadTool` with the ORIGINAL (unconfined) path — not a
regression (`read` was always local + `.low` risk), but a trap once confinement
is advertised.

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

## 8. Operation-lock cancelled-waiter (MEDIUM — ✅ RESOLVED 2026-06-30)

**Fixed** in `01ab6b9a` → follow-up commit. `acquireToolHostOperationLock()` is
now cancellation-aware: it parks via `withTaskCancellationHandler` over a
one-shot `ToolHostOperationWaiter` (lock-guarded `arm`/`cancel`/`resumeLock`),
re-checks `Task.isCancelled` after acquiring (closes the release-wins-over-
cancel race), and returns a `.cancelled` outcome so the caller runs no zombie
daemon work and retains no lock. Regression test:
`testCancelledReadWaiterDoesNotRunZombieWorkOrStarveLock` (a parked read
returns `.cancelled`; a later read acquires on the same connection).

Original hazard (for the record): the prior `withCheckedContinuation` lock never
resumed on cooperative cancellation → a cancelled waiter stayed parked until the
holder released it, then ran the full root+confine+execute daemon round-trip
(zombie work the caller abandoned) and starved the lock.

## 9. Routed-read error copy is technical / not user-facing (LOW — reviewer)

- Routed-read denials and daemon failures surface raw technical strings to the
  conversation (e.g. `"read path escapes the workspace root"`,
  `"Daemon read failed: …"`, `"Daemon unavailable before the workspace root
  was approved…"`). Fine for the dev surface; not the friendly copy Fae's voice
  normally uses. Decide on a UX pass that maps routed-read outcomes to
  user-facing narration once the daemon read path is the default.

## 10. Root-prompt before not-found (LOW — reviewer, post-merge review)

- Root-binding-order is load-bearing for safety (confinement MUST use the
  daemon-returned root, never a locally-computed one — see #8's fix context),
  but its ordering has a UX cost: a `read` of a **non-existent** file still
  drives the `ensureDefaultRooted()` handshake (provision + the
  `workspace.confirm_root` round-trip) BEFORE confinement discovers the file
  doesn't exist and returns not-found. So a typo'd path can surface the
  root-approval card (or, on the default Fae-owned root, do the provisioning
  side effect) only to then say "file not found."
- **Not a safety issue** (the not-found result is still correct, and the root is
  the Fae-owned default), just friction. A preflight existence hint could short-
  circuit, but any such check MUST run AFTER the daemon root is bound (a local
  existence probe against a locally-computed root would re-open the
  root-inference footgun) — so it can't actually skip the handshake on the first
  cold read. Realistic mitigation is UX/copy, not a safety change.
