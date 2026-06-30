# B-Swift Phase C — Concrete Plan (open follow-ups)

> **Phase B status: MERGED.** `origin/main` @ `3237ae79` (Phase B code tip `a297382f`).
> **Owner decisions LOCKED 2026-06-30** (david) — see §"Decisions locked". This doc is the
> Phase C plan; no Phase C edits land until reviewed. Source of truth for items:
> `docs/plans/bswift-3b-followups-2026-06-30.md`.

## Follow-up #1 (3a symlinked-default-root) — CONFIRMED TRACKED + RESOLVED, fix verified

**This is codex's HIGH ("`~/Documents/Fae → ~/.ssh` makes auto-approve grant the wrong root").**
It is follow-up **#1** in the tracker, marked ✅ RESOLVED 2026-06-30. It was NOT dropped — but
the prior draft of this plan narrowed to #3/#4/#5 and omitted it, so it's called out here
explicitly. It is higher-severity-in-kind than #4 (a *boundary widening* — granting the wrong
root — not merely a race), so it must stay visible.

**Verification (this session, against primary source):**
- The fix is `FaeWorkspace.requireNotSymlinkAtTip` (`lstat` `S_IFLNK`), wired at **three
  layers**: (1) `FaeWorkspace.provision()` before any marker/provisioning/`set_root`; (2)
  `FaeWorkspace.writeMarker()`; (3) `defaultAwareHandler` at **confirm-time** as
  defense-in-depth (`!FaeWorkspace.isSymlinkAtTip(defaultPath)` in the auto-approve condition).
- `DaemonToolHostSession.ensureDefaultRooted` calls `FaeWorkspace.provision(provider)`
  **before** `setRoot`, so the tip-check precedes root binding on every path.
- The load-bearing assumption holds: the daemon `is_safe_workspace_root`
  (`crates/fae-daemon/src/toolhost/root_confirm.rs:227`) rejects `/`, filesystem roots, the home
  dir **itself**, and system dirs — but **NOT home subdirs** (`~/.ssh` is accepted). So the Swift
  tip-check is genuinely the authority, not redundant.
- Regression coverage shipped and **passed in the Phase B gate run**: `testRoutedReadRejects-
  SymlinkedDefaultRoot` (asserts SSH key material never leaks), `testProvisionRejectsSymlinked-
  WorkspaceRoot`, `testAutoApproveRejectsSymlinkedDefaultRoot`, `testEnsureDefaultRooted-
  RejectsSymlinkedDefaultBeforeDaemon` (all in `DaemonToolHostTests`, 54/0 green).

**Residual (accepted, same class as #4):** a vanishingly-narrow TOCTOU — swap `~/Documents/Fae`
from real-dir to symlink *after* the confirm-time `isSymlinkAtTip` check passes but *before* the
daemon binds the root. Requires local FS write to `~/Documents` timed to a sub-ms window; an
attacker with that power already has broad reach. **Optional defense-in-depth (candidate, not
required):** add a daemon-side reject list for sensitive home subdirs (`~/.ssh`, `~/.gnupg`,
`~/.config/…`) so the Swift tip-check is not the single point of failure on the routed path.
Track as a possible hardening under the fluers fast-follow (§C1a), not a Phase C blocker.

## Scope reality (discovered + VERIFIED this session)

### Routed `read` call chain — PROVEN

1. Swift `DaemonToolHostSession.executeSerializedRoutedRead` → `execute(tool: "read",
   input: ["path": relative])` → frame to daemon.
2. Daemon `transport.rs:404` → `ToolHost::new(...)`.
3. `crates/fae-daemon/src/toolhost/mod.rs:180` → **`LocalSessionEnv::new(root, limits)`** — the
   env **IS** a `LocalSessionEnv` (reads locally in the daemon process; NOT client-bridged).
4. `toolhost/mod.rs:184` → `fluers_runtime::tool::mvp_tools_with_limits(...)` → registry incl. `read`.
5. `fluers-runtime/src/tool.rs:60` → the `read` tool; `tool.rs:102` → `.read_file(...)`.
6. `fluers-runtime/src/local_env.rs:92` → `LocalSessionEnv::read_file`; **line 99
   `tokio::fs::read_to_string(&resolved)`** — path-based, **no `O_NOFOLLOW`/`openat`** = the TOCTOU.

`session.rs:908 resolve_fs(... "fs.read" ...)` is a **separate** path (agent raw fs access, gap
A3b, mediated to `DaemonAgentClient.swift:147`) — **NOT** the routed `read` tool.

### Open sites for a workspace `read`

| Path | Open site | Repo | TOCTOU-safe? |
|------|-----------|------|--------------|
| Routed read (daemon up) | **fluers** `local_env.rs:92` `read_file` → `tokio::fs::read_to_string` (`:99`) — **proven above** | **fluers** (cross-repo) | **NO** — path-based (open HIGH = #4) |
| Daemon-down confined fallback (Swift) | `DaemonToolRouting.readFdAnchored` | fae (in-repo) | **YES** — `O_NOFOLLOW` root + `openat` (Phase A) |
| Legacy opted-out read | `ReadTool` → `String(contentsOfFile:)` (`BuiltinTools.swift`) | fae (in-repo) | NO — path-based; **no workspace root** (legacy unconfin­ed by design) |
| Daemon `fs.read` client mediation (agent raw fs) | `DaemonAgentClient.handleServerRequest` case `"fs.read"` → `PathPolicy.validateReadPath` | fae (in-repo) | path-based (separate from the `read` tool) |

## Decisions LOCKED (david, 2026-06-30)

1. **#3 hardlinks (C2):** **YES — reject `st_nlink > 1`**, scoped to the routed/confined path
   + the fluers daemon read. **NOT** the legacy rootless `ReadTool`. Authoritative check at the
   **fluers read (fstat the opened fd)**; the Swift `st_nlink` check is early-reject
   defense-in-depth. Specific error copy ("multiple hard links — can't safely confine") so the
   rare false positive is debuggable. This ties #3 and #4 at the same fd.
2. **#5 audit/hooks/timeout (C3):** **do NOT accept daemon-only.** Mirror a Swift audit row +
   fire PreToolUse/PostToolUse plugin hooks + apply the executor timeout. Reason: the PreToolUse
   bypass is a *policy bypass* (a user-configured read hook silently stops applying), not just
   observability; reads can exfiltrate; and `read` is the precedent-setter for Layer 4
   (write/edit/bash route through this same seam). **Shape:** do NOT fully short-circuit the
   pipeline — run routed reads through PreToolUse hooks + audit/analytics start; skip ONLY the
   genuinely-redundant DamageControl (daemon governs) and receipts (no mutation). Daemon
   `audit.jsonl` is a complement, not a substitute.
3. **fluers openat patch (C1a / #4):** **separate coordinated PR; ship in-repo Phase C first;
   #4 tracked mitigated/OPEN.** Don't couple in-repo hardening (#3, #5) to a cross-repo change.
   Commit the fluers `openat`/`O_NOFOLLOW` patch as a near-term fast-follow (not "someday") — it
   belongs on the path every future routed tool uses, and it tracks under the fluers-substrate
   work already in flight (ADR-013 / S19).

## Phase C item plan

### C1 — #4 TOCTOU on daemon read + legacy ReadTool  *(HIGH — split in-repo vs cross-repo)*

- **C1a (cross-repo, fluers) — SEPARATE coordinated PR, fast-follow under ADR-013/S19:** port
  the fd-anchored pattern into `fluers/.../local_env.rs::read_file` (the proven routed-read open
  site): `O_NOFOLLOW` root open + `openat` per component + `fstat` each (S_IFDIR / S_IFREG) +
  read from leaf fd + `O_NONBLOCK` (FIFO DoS) + `EINTR` retry. Mirror Swift
  `DaemonToolRouting.readFdAnchored`. Bump the daemon's fluers pin once merged. **#4 stays
  OPEN (mitigated) in Phase C; marked RESOLVED only when the daemon reads through this path.**
- **C1b (in-repo, Swift):** legacy `ReadTool` has **no workspace root** (opted-out/CI
  unconfin­ed by design). Do **not** silently confine it or break absolute paths. Per decision
  #1, do **not** blanket-apply `st_nlink` here. Options: (i) exact-path leaf hardening only
  (`O_NOFOLLOW` + `fstat` S_IFREG, no root-fd), or (ii) document as accepted residual. Low
  priority — legacy, unconfin­ed, pre-dates routing.
- **C1c (in-repo, Swift):** `confineValidatedReadPath` stays path-based (the open is
  daemon-side). Add the `st_nlink > 1` early-reject here (defense-in-depth; authoritative check
  is the fluers fstat in C1a). Pairs with C2.

### C2 — #3 Hardlink exfiltration  *(MED — LOCKED with C1)*

**Goal:** stop `ln ~/.ssh/id_rsa ~/Documents/Fae/key; read key`.

- **Authoritative (fluers, with C1a):** `fstat` the opened leaf fd, reject `st_nlink > 1`.
- **Early-reject (Swift, with C1c):** `st_nlink > 1` reject at the `confineValidatedReadPath`
  lstat site AND in `readFdAnchored` (fstat off the leaf fd). Specific error:
  `"multiple hard links — can't safely confine: <path>"`.
- **Scope (locked):** routed/confined path + fluers daemon read. **Not** legacy `ReadTool`.

**Validation:** `testReadRejectsHardlinkedSecret` (Swift: hardlinked secret under workspace →
denied, content never returned) + fluers equivalent.

### C3 — #5 Routed reads skip Swift audit / plugin hooks / executor timeout  *(reviewer — LOCKED)*

**Goal:** a daemon-routed read currently returns before DamageControl (step 7) and execute
(step 12), bypassing `SecurityEventLogger`, `ToolAnalytics`, PreToolUse/PostToolUse hooks, and
the 30s executor timeout.

- **Implementation site:** `ToolExecutor`, around the routed-read branch (not pure
  `DaemonToolRouting` unless sinks are explicitly injected).
- **Shape (locked):** run routed reads **through** PreToolUse hooks + audit/analytics start;
  wrap the daemon read round-trip in the executor timeout (cancellation-aware — the operation
  lock already supports cancel). **Skip only** DamageControl (daemon governs) and receipts (no
  mutation). No double approval — the daemon `tool.confirm` is authoritative for `read`.

**Validation:** assert a `SecurityEventLogger` row + `ToolAnalytics` event + PreToolUse hook
fire for a routed read; assert a user-configured PreToolUse read-hook still applies; assert the
timeout cancels a stuck daemon read.

### C4 — #6 Truncation parity  *(LOW)*

Settle the canonical limit at **2000 lines AND 50 KiB bytes** (daemon `read_file(path,
max_lines=2000, max_bytes=50KiB)`; matches `readFdAnchored.localReadByteCap` on the byte side).
Parity test: same large file truncates identically across the three paths under BOTH caps.
Expose `offset`/`limit` only if the daemon read tool gains them (currently none → no arg-drop).

### C5 — #7 Concurrent-caller coverage  *(LOW)*

`executeInDefaultWorkspace` / `execute` aren't operation-lock-protected (only the routed path
is). Add concurrent-caller tests proving the only live production caller (routed, lock-
protected) is safe under contention; document that a new concurrent live caller must route
through the lock or make `DaemonSocketConnection.roundTrip` atomic. No code change unless a
second live caller appears.

### C6 — #9 Routed-read error copy UX  *(LOW — reviewer)*

Map `ReadExecutionOutcome` denials / `failClosed` / `fallbackLocally` errors to Fae's narration
voice once the daemon read path becomes default. Copy pass; no safety change.

### C7 — #10 Root-prompt before not-found  *(LOW — reviewer)*

A `read` of a non-existent file still drives `ensureDefaultRooted()` before returning not-found
(UX friction, NOT safety). No safe short-circuit on a cold read (a local existence probe against
a locally-computed root re-opens the root-inference footgun). Mitigation is UX/copy only;
document as accepted residual if the owner declines.

## Ordering + gates (in-repo ships first)

1. **C3 (#5 audit/hooks/timeout)** — highest-leverage in-repo item (precedent-setter for Layer
   4; policy-bypass fix). Reviewer + advisor gate.
2. **C2 (#3 hardlinks, Swift early-reject) + C1c** — paired `st_nlink` early-reject; red-team.
3. **C4 / C5** (parity + concurrency) — tests only, low risk.
4. **C6 / C7** (UX copy) — copy pass.
5. **C1a (fluers openat) — separate coordinated PR, fast-follow under ADR-013/S19.** Not on the
   in-repo Phase C critical path; #4 tracked mitigated/OPEN until it lands.

**Cross-repo:** C1a is independent of C2/C3 — do not couple. In-repo Phase C ships without it.

## First implementation slice (tests/discovery first — per advisor)

Before C2/C3 **code**, land as tests/discovery:
- the call-chain proof above (captured);
- hardlink regression tests (Swift `readFdAnchored` + `confineValidatedReadPath`) asserting a
  hardlinked secret is denied once the `st_nlink` policy lands;
- truncation-parity tests (2000 lines AND 50 KiB bytes) across the three read paths;
- a routed-read audit/hook regression skeleton (asserts the row/hook fire once C3 lands).

Then code C3 → C2/C1c. **#4 is NOT marked RESOLVED until fluers `local_env.rs:92-99` is
fd-anchored (C1a, separate PR).**

Every item: update `bswift-3b-followups-2026-06-30.md` to RESOLVED with commit SHA + test
evidence (note: #1 already RESOLVED + verified). Phase merge gate = Rust fmt/clippy/check/test +
Swift build + targeted Phase C tests + full suite (minus the documented
`VocabularyHarvestTests` Contact-XPC environmental hang) + code-review + red-team + advisor.
