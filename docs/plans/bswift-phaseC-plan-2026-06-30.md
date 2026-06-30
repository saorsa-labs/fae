# B-Swift Phase C — Concrete Plan (open follow-ups)

> **Phase B status: MERGED.** `origin/main` @ `3237ae79` (Phase B code tip `a297382f`).
> This doc is the Phase C plan required before any Phase C code edit (advisor gate,
> 2026-06-30). No Phase C edits land until this plan is reviewed.
>
> Source of truth for the items: `docs/plans/bswift-3b-followups-2026-06-30.md`.

## Scope reality (discovered + VERIFIED this session)

### Routed `read` call chain — PROVEN (advisor-required evidence)

1. Swift `DaemonToolHostSession.executeSerializedRoutedRead` → `execute(tool: "read",
   input: ["path": relative])` → frame to daemon.
2. Daemon `transport.rs:404` → `ToolHost::new(...)`.
3. `crates/fae-daemon/src/toolhost/mod.rs:180` → **`LocalSessionEnv::new(root, limits)`**
   — the env **IS** a `LocalSessionEnv` (reads locally in the daemon process; NOT
   client-bridged).
4. `toolhost/mod.rs:184` → `fluers_runtime::tool::mvp_tools_with_limits(...)` builds the
   registry including `read`.
5. `fluers-runtime/src/tool.rs:60` → the `read` tool; `tool.rs:102` → `.read_file(...)`.
6. `fluers-runtime/src/local_env.rs:92` → `LocalSessionEnv::read_file`; **line 99
   `tokio::fs::read_to_string(&resolved)`** — path-based, **no `O_NOFOLLOW`/`openat`** = the TOCTOU.

`session.rs:908 resolve_fs(... "fs.read" ...)` is a **separate** path (the agent's raw fs
access, gap A3b, mediated to `DaemonAgentClient.swift:147`) — **NOT** the routed `read` tool.
So the in-repo `fs.read` client handler is **not** the routed-read fix site.

### Open sites for a workspace `read`

| Path | Open site | Repo | TOCTOU-safe? |
|------|-----------|------|--------------|
| Routed read (daemon up) | **fluers** `local_env.rs:92` `read_file` → `tokio::fs::read_to_string` (`local_env.rs:99`) — **proven above** | **fluers** (cross-repo) | **NO** — path-based (the open HIGH) |
| Daemon-down confined fallback (Swift) | `DaemonToolRouting.readFdAnchored` | fae (in-repo) | **YES** — `O_NOFOLLOW` root + `openat` per component (Phase A) |
| Legacy opted-out read | `ReadTool` → `String(contentsOfFile:)` (`BuiltinTools.swift`) | fae (in-repo) | NO — path-based; **no workspace root** (legacy unconfin­ed by design) |
| Daemon `fs.read` client mediation (agent raw fs) | `DaemonAgentClient.handleServerRequest` case `"fs.read"` → `PathPolicy.validateReadPath` | fae (in-repo) | path-based (separate from the `read` tool) |

**Key scoping insight:** the primary #4 TOCTOU fix (the daemon `read` tool's open) is in the
**fluers** runtime (`/Users/davidirvine/Desktop/Devel/projects/fluers/crates/fluers-runtime/src/local_env.rs`),
a separate project. In-repo Phase C work covers Swift hardening + the non-TOCTOU items;	he daemon-side `read_file` fd-anchoring is a cross-repo coordinated change.

## Phase C item plan (priority order)

### C1 — #4 TOCTOU on daemon read + legacy ReadTool  *(HIGH — do first)*

**Goal:** close the check-then-(re)open race for the daemon `read` tool and the legacy `ReadTool`.

- **C1a (cross-repo, fluers) — the primary daemon-side fix:** port the fd-anchored pattern
  into `fluers/crates/fluers-runtime/src/local_env.rs::read_file` (the **proven** routed-read
  open site, call chain above): open the root with `O_NOFOLLOW`, walk each component with
  `openat(.., O_NOFOLLOW)`, `fstat` each (S_IFDIR intermediate / S_IFREG leaf), read from the
  leaf fd. Mirror Swift `DaemonToolRouting.readFdAnchored`. Add `O_NONBLOCK` (FIFO open-time
  DoS) + `EINTR` retry. Coordinate as a fluers PR; bump the daemon's fluers pin once merged.
  **#4 is NOT marked RESOLVED until this lands and the daemon reads through the fd-anchored path.**
- **C1b (in-repo, Swift):** legacy `ReadTool` (`BuiltinTools.swift`) has **no workspace root**
  (it is the opted-out/CI unconfin­ed path by design). Do **not** silently confine it or break
  absolute paths. Two options (owner pick): (i) exact-path leaf hardening only — open the leaf
  with `O_NOFOLLOW`, `fstat` S_IFREG + `st_nlink` reject, no root-fd/openat (no trusted root);
  or (ii) document as accepted residual (legacy, unconfin­ed, low-risk, pre-dates routing).
- **C1c (in-repo, Swift):** `confineValidatedReadPath` stays path-based (the open is
  daemon-side), but add the `st_nlink > 1` reject here too (see C2 — shared check).

**Validation:** extend `DaemonToolHostTests` with a swap-after-confine race regression
(best-effort deterministic via the existing fake daemon); in fluers, extend
`local_env.rs` tests with symlink-leaf/intermediate/FIFO/hardlink rejects. Red-team the
daemon path again (the prior red-team flagged this exact HIGH).

### C2 — #3 Hardlink exfiltration  *(MED — pairs with C1)*

**Goal:** stop `ln ~/.ssh/id_rsa ~/Documents/Fae/key; read key`.

- **Policy (owner decision needed):** reject `st_nlink > 1` on the read path, OR document as
  accepted residual. **Recommendation:** reject `st_nlink > 1` — the workspace is a text
  surface; legitimately-hardlinked workspace files are rare and the false-positive cost is a
  clearer error, not data loss. Apply identically in `readFdAnchored` (fstat off the leaf fd),
  `confineValidatedReadPath` (lstat site), and fluers `read_file` (post-open fstat).
- **Note:** the daemon shares this hazard; the `st_nlink` check belongs wherever the real open
  happens (so it lands with C1a in fluers, and C1c in Swift).

**Validation:** `testReadRejectsHardlinkedSecret` (Swift) + fluers equivalent.

### C3 — #5 Routed reads skip Swift audit / plugin hooks / executor timeout  *(reviewer)*

**Goal:** a daemon-routed read currently returns before DamageControl (step 7) and the execute
step (12), so it bypasses `SecurityEventLogger`, `ToolAnalytics`, PreToolUse/PostToolUse hooks,
and the 30s executor timeout.

- **Plan (lives in `ToolExecutor` around the routed-read branch, NOT in pure
  `DaemonToolRouting` unless sinks are explicitly injected):** emit a Swift audit row
  (`SecurityEventLogger` + `ToolAnalytics`) for routed reads (read-only, no double approval —
  the daemon `tool.confirm` is authoritative for `read`), and wrap the daemon read round-trip
  in the executor timeout (cancellation-aware — the operation lock already supports cancel).
- **Decision (owner):** is daemon-side `audit.jsonl` sufficient for `read`, or mirror a Swift
  row? **Recommendation:** mirror a Swift row — keeps the unified audit surface and the plugin
  hook contract for all tools, including routed ones.

**Validation:** assert a `SecurityEventLogger` row + `ToolAnalytics` event fires for a routed
read; assert the timeout cancels a stuck daemon read.

### C4 — #6 Truncation parity  *(LOW)*

**Goal:** daemon `read` truncates at 2000 lines / 50 KiB; local `ReadTool` at 50k chars;
`readFdAnchored` at 50 KiB bytes.

- **Plan:** settle the canonical limit at **2000 lines AND 50 KiB bytes** (the daemon `read`
  tool's `read_file(path, max_lines=2000, max_bytes=50KiB)`; matches `readFdAnchored.
  localReadByteCap` on the byte side). Add a parity test that the same large file truncates
  identically across the three paths (routed / fd-anchored fallback / legacy ReadTool) under
  BOTH the line cap and the byte cap. Expose `offset`/`limit` only if the daemon read tool
  gains them (currently none → no arg-drop).

### C5 — #7 Concurrent-caller coverage  *(LOW)*

**Goal:** `executeInDefaultWorkspace` / `execute` aren't operation-lock-protected (only the
routed path is).

- **Plan:** add concurrent-caller tests proving the only live production caller (the routed
  path, lock-protected) is safe under contention; document the invariant that a new concurrent
  live caller must either route through the lock or make `DaemonSocketConnection.roundTrip`
  atomic. No code change unless a second live caller is introduced.

### C6 — #9 Routed-read error copy UX  *(LOW — reviewer)*

**Goal:** routed-read denials surface raw technical strings.

- **Plan:** map `ReadExecutionOutcome` denials / `failClosed` / `fallbackLocally` errors to
  Fae's user-facing narration voice once the daemon read path becomes default. Low-risk copy
  pass; no safety change.

### C7 — #10 Root-prompt before not-found  *(LOW — reviewer)*

**Goal:** a `read` of a non-existent file still drives `ensureDefaultRooted()` before
returning not-found (UX friction, NOT a safety issue).

- **Plan:** no safe way to short-circuit the handshake on a cold read (a local existence probe
  against a locally-computed root would re-open the root-inference footgun). Mitigation is
  UX/copy only (e.g. suppress the provisioning card side-effect chatter for a subsequent
  not-found). Document as accepted residual if the owner declines the copy pass.

## Owner decisions REQUIRED before implementation (escalate to david)

These are policy calls, not engineering mechanics — they must not be made unilaterally:

1. **#3 hardlinks (C2):** reject `st_nlink > 1` on **routed/confined workspace reads + the
   fluers daemon read** (recommendation). Do **not** blanket-apply to legacy `ReadTool` without
   owner approval (it has no workspace root; see C1b options).
2. **#5 audit (C3):** mirror a Swift audit row + apply the executor timeout + plugin hooks to
   routed reads (recommendation), vs. accept daemon-side `audit.jsonl` as sufficient.
3. **Cross-repo fluers patch (C1a):** is it **mandatory for Phase C completion** (Phase C not
   done until the daemon reads fd-anchored), or tracked as a **separate coordinated PR** so
   in-repo Phase C can ship first? This determines whether #4 can be marked RESOLVED in Phase C.

## Ordering + gates

1. **C1 + C2 together** (the open HIGH + its paired hardlink policy) — red-team mandatory.
2. **C3** (audit/timeout gap) — reviewer + advisor.
3. **C4 / C5** (parity + concurrency) — tests only, low risk.
4. **C6 / C7** (UX copy) — owner decision, copy pass.

Cross-repo dependency: **C1a (fluers) gates the daemon-side TOCTOU closure.** Start it early /
in parallel; the in-repo C1b/C1c + C2 can proceed independently.

## First implementation slice (tests/discovery only — per advisor)

Before any C1/C2 **code**, land as tests/discovery:
- the exact call-chain proof above (already captured here);
- hardlink regression tests (Swift `readFdAnchored` + `confineValidatedReadPath` + fluers
  `local_env.rs`) asserting a hardlinked secret is denied once the `st_nlink` policy is chosen;
- truncation-parity tests (2000 lines AND 50 KiB bytes) across the three read paths.

Then code C1/C2. **#4 is NOT marked RESOLVED until the actual final open site
(fluers `local_env.rs:92-99`) is fd-anchored.**

Every item: update `bswift-3b-followups-2026-06-30.md` to RESOLVED with the commit SHA + test
evidence. Phase merge gate = Rust fmt/clippy/check/test + Swift build + targeted Phase C tests
+ full suite (minus the documented `VocabularyHarvestTests` Contact-XPC environmental hang) +
code-review + red-team + advisor.
