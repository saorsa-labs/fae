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

## 2. Legacy no-daemon fallback is unconfined (MED — ✅ RESOLVED 2026-06-30, Phase A)

**Implemented.** The fallback is now gated on the daemon-intended flag
(`DaemonToolHostSession.daemonIntended`, threaded from
`FaeConfig.llm.useDaemonEngine` at the `PipelineCoordinator` construction site).
`ToolExecutor` exposes two **explicit, unlabeled** initializers
(`daemonIntendedForToolhostRouting: Bool` OR `daemonToolHostSession:
DaemonToolHostSession`) so ambiguous constructions fail to compile — there is
NO silent default, and no production call site can accidentally opt out.

- **Daemon intended but unreachable** (`useDaemonEngine == true`, the
canonical failure mode for a default-bundled daemon): `DaemonToolRouting.routeRead`
confines the read **locally** — `DaemonToolHostSession.confinedLocalReadFallback`
provisions the default workspace (idempotent, #1-symlink-guarded), then performs
an **fd-anchored** read via `DaemonToolRouting.readFdAnchored` (the open IS the
atomic check-and-use): the root is opened with `O_NOFOLLOW`, the validated path
is walked from that fd with `openat`+`O_NOFOLLOW`, each component is `fstat`-
checked (S_IFDIR for intermediates, S_IFREG for the leaf), and the leaf is read
from its open fd. **No path string is ever re-resolved**, so swapping the
workspace dir for a symlink after provisioning cannot redirect the read (closes
the root-symlink TOCTOU the red-team flagged on the earlier path-based confine).
`O_NONBLOCK` on every open defeats an open-time DoS (a FIFO would otherwise
block the open until a writer arrives). The universal "reads are confined to
`~/Documents/Fae`" invariant therefore holds whether or not the daemon is up,
and the `read` capability is preserved during outages (no regression). The
provisioning side effect fires ONLY in this branch.
  - `approvedRootPath` is NOT mutated (the daemon root guard never ran — this is
a local confinement against the provisioned default, not a daemon-approved root).
  - `.preExistingWithoutMarker` fails closed (no daemon card available to
approve a user-made dir; no silent takeover / read).
  - Symlinked default root is hard-denied by the `O_NOFOLLOW` root open (and,
defense-in-depth, inside `FaeWorkspace.provision`).
- **Daemon explicitly opted out** (`useDaemonEngine == false`, e.g. CI /
pure-MLX, and the dev `JSCDeveloperHarness`): `routeRead` returns `nil` BEFORE
shape validation, so the caller falls through to the local `ReadTool` with the
ORIGINAL args — the legacy UNCONFINED pre-routing read (absolute paths allowed).
No provisioning side effect.
- **Never silent:** both branches `NSLog` which path was taken (ties into #5).

The invariant that is unchanged: when the daemon is **involved** but drops
BEFORE root approval (`executeSerializedRoutedRead`), the read still FAILS
CLOSED — it never reads locally on a locally-computed root that bypasses the
server root guard.

Tests (`DaemonToolHostTests`):
`testReadOptedOutFallsBackToLegacyLocalWhenDaemonDown` (absolute outside read
succeeds, no provisioning),
`testReadIntendedButDownConfinesLocally` (relative-in-workspace succeeds;
absolute + `..` denied),
`testReadIntendedButDownProvisionsWorkspaceMarker` (intended provisions +
marker; missing-file read still denied),
`testReadIntendedButDownPreExistingWithoutMarkerFailsClosed` (user-made dir →
error, no marker write, precious file untouched),
`testReadIntendedButDownRejectsSymlinkedWorkspaceRoot` +
`testReadFdAnchoredRejectsSymlinkedRootDirectly` (symlinked root → ELOOP,
sensitive target never read),
`testReadFdAnchoredRejectsLeafSymlinkEscape` /
`testReadFdAnchoredRejectsIntermediateSymlinkEscape` (openat+O_NOFOLLOW),
`testReadFdAnchoredRejectsFifo` (O_NONBLOCK + S_IFREG),
`testReadFdAnchoredTruncatesMultibyteWithoutDenying` (byte-cap mid-multibyte).

**Why not fail-closed:** `read` is `.low` risk and pre-dates routing; breaking
all reads during a daemon glitch is a worse UX than a confined local read, and
confinement already holds. **Why not unconditional confined-fallback:** it would
provision `~/Documents/Fae` as a side-effect in test suites that don’t inject a
temp provider — the gate avoids that.

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
- **Phase A note (2026-06-30):** the **local fallback** path (follow-up #2,
  daemon intended-but-down) is now **fd-anchored** (`DaemonToolRouting.
  readFdAnchored` — `O_NOFOLLOW` root open + `openat` per component + direct fd
  read), so it is NOT subject to this TOCTOU. This item remains OPEN for the
  **daemon** read path (`confineValidatedReadPath` is still path-based, confined
  against the daemon-RETURNED root) and the legacy **`ReadTool`**
  (`String(contentsOfFile:)`); the daemon's own root canonicalization + the
  pre-existing `is_safe_workspace_root` guard are the current defense there.

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
