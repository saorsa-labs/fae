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

## 3. Hardlinks defeat path confinement (MED — ✅ RESOLVED 2026-06-30, `01924ff7`)

- `ln ~/.ssh/id_rsa ~/Documents/Fae/key; read key` routes: the hardlink is a
  regular file under the workspace, passes confinement, and reads the sensitive
  target. Inherent to path-based confinement (the daemon shares it).
- **Options:** reject `st_nlink > 1` (strict; false positives on legitimately
  hard-linked workspace files), or document explicitly as accepted residual.
- **Owner call (LOCKED 2026-06-30):** reject `st_nlink > 1` on the
  routed/confined path + the fluers daemon read. Swift checks are early-reject
  defense-in-depth; the authoritative check is the fluers post-open `fstat`
  (C1a, follow-up #4 fast-follow).
- **Resolved (`01924ff7`, C2):** added `st_nlink > 1` reject at both Swift
  read-confinement sites — `readFdAnchored` (fstat off the OPENED leaf fd, no
  path re-resolution) and `confineValidatedReadPath` (path-based `lstat`
  early-reject). Specific error copy (`"multiple hard links — can't safely
  confine: <path>"`) so the rare false positive is debuggable. Scope: routed/
  confined path only — NOT the legacy rootless `ReadTool`.
- **Evidence:** `testReadFdAnchoredRejectsHardlinkedSecret` +
  `testConfineRejectsHardlinkedSecret` (TDD: proved the vuln first, then the
  fix). Targeted 113/0; full 3506/0 (`--skip VocabularyHarvestTests`);
  `swift build` + `swift build -c release` clean.
- **Residual (accepted):** a transient `st_nlink` defeat (drop the extra link
  before the check; the inode keeps the content with `nlink==1`) is
  defense-in-depth — the authoritative stop is the fluers post-open `fstat`
  (#4/C1a).

## 4. TOCTOU on final-file read + `O_NOFOLLOW` (HIGH — ✅ RESOLVED: daemon path + legacy `ReadTool`)

- Generic check-then-(re)open race between Swift confinement and the actual read.
- **Daemon read path — ✅ RESOLVED (fluers `addb66e`, 2026-06-30, B-Swift C1a fast-follow):**
  the authoritative fluers daemon read (`LocalSessionEnv::read_file` +
  `read_file_full` in `crates/fluers-runtime/src/local_env.rs`) is now
  **fd-anchored**. It holds an fd over the canonical root (`root_fd: OwnedFd`,
  opened `O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC`) and walks the relative path via
  `openat(O_NOFOLLOW)` per component (symlink → `ELOOP`); the leaf is `fstat`'d
  on the SAME fd it reads — rejecting non-regular files and `st_nlink > 1`
  (hardlink, mirrors C2/#3). Closes the path-based TOCTOU that
  `confineValidatedReadPath` + `tokio::fs::read_to_string` had. Implemented with
  `rustix` (the crate is `#![forbid(unsafe_code)]`, which rules out `nix`'s
  `RawFd`-returning API). Published to fluers `origin/main`
  (`1a3f75a → addb66e`); branch `c1a/fd-anchored-read`.
  - **Evidence:** 23/0 `local_env` tests (7 new: symlink-leaf inside/outside
    root, intermediate symlink dir, hardlink — covering BOTH `read_file` and
    `read_file_full`; nested-read regression guard); 47/0 `fluers-runtime`
    crate; `cargo fmt` clean; `clippy -p fluers-runtime --lib -D warnings -D
    clippy::{panic,unwrap_used,expect_used}` rc=0; `clippy --workspace
    --all-targets` rc=0; `cargo check --workspace --all-targets` rc=0;
    `cargo test --workspace` green.
- **Downstream — ✅ DONE (released fluers 0.3.1, 2026-07-01):** fluers was
  released to crates.io as `fluers-core`/`fluers-runtime` **0.3.1** (first
  crates.io release; the prior `v0.3.0` marker tag pointed at the pre-fix
  commit `1a3f75a` and was never published). Published via the new
  `saorsa-labs/fluers` `Release` GitHub Actions workflow (org `CRATES_IO_TOKEN`
  secret), tag `v0.3.1`. Fae now consumes the **released** crates via exact
  crates.io pins (`=0.3.1`) in `crates/Cargo.toml`; the prior git-rev pin
  (`rev=1a3f75a`, pre-fix) is gone from `Cargo.lock` (verified: zero
  `git+https://github.com/saorsa-labs/fluers` sources). `fae-daemon` resolves
  the C1a fd-anchor fix from the registry; `cargo check -p fae-daemon
  --all-targets` + workspace check + clippy green.
- **Legacy rootless `ReadTool` — ✅ RESOLVED (Swift-side, B-Swift #4):** the
  local `ReadTool`'s path-based `FileManager.fileExists` + `String(
  contentsOfFile:)` (check-then-reopen TOCTOU; followed symlinks at every
  component) is replaced by `DaemonToolRouting.readRootlessFdAnchored(
  absolutePath:)`: `open(path, O_NOFOLLOW)` follows INTERMEDIATE symlinks
  (so macOS `/tmp → /private/tmp` and home-dir symlinks still resolve) but
  rejects a LEAF symlink with `ELOOP`; the read happens off the OPENED fd
  (atomic check+use, no path re-resolution). `fstat` rejects non-regular
  entries (FIFO/dir/socket/device). The redundant `fileExists` pre-check is
  dropped (the open IS the atomic existence check).
  - **Intentionally NOT a workspace-root walk (`readFdAnchored`):** anchoring
    from `/` would reject every intermediate symlink (breaking `/tmp`,
    `/var`, `/etc` on macOS) and mishandle `..`. `open(path, O_NOFOLLOW)` is
    the correct primitive for a rootless read.
  - **Intentionally NO `st_nlink > 1` (hardlink) rejection:** owner LOCKED #3
    hardlink rejection to the routed/confined path + fluers daemon only.
    Hardlink rejection is a CONFINEMENT measure; the rootless `ReadTool` is
    unconfined by design, so this fix closes the LEAF TOCTOU only — it does
    NOT add workspace confinement.
  - **Evidence:** 5 new tests (regular absolute read; leaf-symlink reject
    via helper + end-to-end via `ReadTool().execute`; intermediate-symlink-
    dir FOLLOWS — locks the macOS design; FIFO reject). No hardlink test
    (by design). Full Swift suite 3511/0 (5 pre-existing skips);
    `swift build` clean.
  - Reuses the hardened `readLeaf` (EINTR retry, multibyte-UTF-8-safe
    truncation) from `readFdAnchored`; legacy 50k-char cap/`[truncated]`
    marker still applied to the fd-reader text; cross-path truncation
    parity remains follow-up #6.
- **Local fallback path (follow-up #2):** already fd-anchored since Phase A
  (`DaemonToolRouting.readFdAnchored`) — unchanged.
- **Residual (separate from #4's read-only scope):**
  - fluers: `write_file` / `exec` / `glob` / `grep` in `LocalSessionEnv`
    still use path-based `resolve()` and share the TOCTOU class.
  - Swift legacy mutation paths: `EditTool`'s read-before-write
    (`String(contentsOfFile:)`) and `WriteTool`'s path-based write remain
    path-based. These are mutation, not read, and are out of #4's read-only
    scope; tracked separately.

## 5. Routed reads skip Swift audit / plugin hooks / executor timeout (✅ RESOLVED 2026-06-30, `7332e95f`)

- A daemon-routed read returns before DamageControl (step 7) and the execute
  step (12), so it bypasses: Swift `SecurityEventLogger`, `ToolAnalytics`,
  PreToolUse/PostToolUse plugin hooks, and the 30s executor timeout. The daemon
  has its own `audit.jsonl`, but the Swift-side audit/policy gap is real.
- **Owner call (LOCKED 2026-06-30):** do NOT accept daemon-only audit. Mirror
  the Swift audit (`SecurityEventLogger` + `ToolAnalytics`) + fire
  PreToolUse/PostToolUse hooks + apply the executor timeout. Skip only
  DamageControl (daemon governs) and receipts (no mutation). A PreToolUse bypass
  is a policy bypass, not just an observability gap; `read` is the Layer 4
  precedent-setter (write/edit/bash route through the same seam).
- **Resolved (`7332e95f`, C3):** split routing DECISION from EXECUTION
  (`ReadRoutePlan` + `planReadRoute` decision / `routeRead(_:plan:)` execution)
  so the route is fixed before any side effect (no policy race). The new
  `executeRoutedRead` branch mirrors PreToolUse hooks → timeout → PostToolUse
  hooks → audit/analytics, skipping ONLY DamageControl + receipts. Shared
  helpers (`runPreToolUseHooks`/`runPostToolUseHooks`/`recordToolOutcome`/
  `computeExecutionArguments`) used by BOTH pipelines (no copy/paste).
  Protocol seams (`ToolAnalyticsRecording`/`PluginHookRunning`; concrete actors
  conform) enable spy-injected tests.
- **Review-driven fixes folded in (`7332e95f`):**
  - **M1** routed error catch now returns `latencyMs` (was `nil`).
  - **S1** routed PreToolUse uses `computeExecutionArguments` (Layer 4 precedent).
  - **F5** deleted the legacy 2-arg `routeRead(_:session:)->ToolResult?` wrapper
    (ran no hooks/audit/timeout; would resurrect the bypass).
  - **F2** the executor timeout now actually cancels the daemon `roundTrip`:
    `DaemonSocketConnection` reads are cancellation-aware (short 1s `SO_RCVTIMEO`
    poll + monotonic `CLOCK_MONOTONIC` 600s overall deadline + a lock-guarded
    cancellation flag polled in `readLineLocked`; `onCancel` only sets the flag —
    no double-resume). A wedged daemon can no longer hold the operation lock for
    600s.
  - **F4** test-seam setters compiled out of release (`FAE_TEST_SEAMS` via
    `.define(_, .when(configuration: .debug))`); verified 0 symbols in the
    release binary.
- **Evidence:** 7 routed-read tests (PreToolUse-block-before-closure,
  PostToolUse-fire-with-output, audit+analytics on success AND error, timeout
  @0.4s w/ latencyMs assertion, legacy opt-out fall-through,
  confined-fallback-through-pipeline) + F2
  `testRoundTripCancellationUnblocksPromptlyFromSilentPeer` (cancel unblocks in
  ~1.0s, not 600s). Targeted 113/0; full 3506/0 (`--skip VocabularyHarvestTests`);
  `swift build` + `swift build -c release` clean; F4 release-symbol proof (0).
- **Red-team + code-review:** both SHIP-WITH-FIXES → SHIP after the fixes. The
  cross-repo fluers `openat`/`O_NOFOLLOW` residual (follow-up #4, C1a) has
  since **landed and shipped**: fluers `0.3.1` (crates.io) fd-anchors the
  authoritative daemon read, and Fae consumes it via `=0.3.1` (see #4).

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
