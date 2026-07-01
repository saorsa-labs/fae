# Active Work

The single source of truth for what's currently live and what's blocked.
Everything else in `docs/` is either a permanent record (ADRs, specs) or
historical (archive). If work isn't listed here, it's done or not started.

## Canonical checkouts

- **Fae:** one checkout at `~/Desktop/Devel/projects/fae`, on `main`, tracking
  `origin/main`. No long-lived feature branches — branch, merge, delete.
- **fluers:** one checkout at `~/Desktop/Devel/projects/fluers`, on `main`,
  tracking `origin/main`. Fae consumes fluers via exact crates.io pins
  (`=0.5.0` at time of writing), not git.

## Live work

### Layer-4 routed mutations (write / edit / bash) — F7a (write) + F7b (edit) + F8 (bash) shipped; Layer 4 complete

`read`, `write`, `edit`, AND `bash` are all routed through the governed daemon
(2026-07-01). Layer 4 is complete.

**Q7b resolved (owner chose option a):** `SwiftFrontend::default_scopes()` now
holds `Scope::ToolExecuteDangerous` (`control-plane/lib.rs:355`), so
write/edit/bash can route through the governed daemon. The per-call boundary is
the owner `tool.confirm` card (A3), surfaced via
`DaemonAgentClient.handleToolConfirm` — granting the scope lets the governed
path RUN, it does not bypass human approval. The daemon's `FaeToolPolicy` still
re-checks scope + path/damage/egress per call.

**F7a — route write (shipped, `c4ad79cf`):** routed write goes through the
daemon with fail-closed outage semantics (no local write fallback — mutations
are irreversible). Receipt pre-state is captured INSIDE the serialized daemon
operation (under the operation lock, after root approval, via an fd-anchored
full read `readFdAnchoredPreState`) and threaded through the outcome to the
receipt — NOT the path-based `capturePreStateForTool` (which would reopen the
TOCTOU class F7a closed). DamageControl is skipped (daemon governs write
confinement; catastrophe rules are bash-only, deferred to F8). Approval is
upstream (`ToolRoutingHelpers.swift:84`), not an executor step.

**F8 — route bash (shipped):** routed `bash` mirrors write/edit's
routing/timeout/receipt shape but with TWO decisive differences from F7a/F7b,
both from owner decisions + a sandbox-reach audit:

1. **DamageControl is NOT skipped (unlike write/edit).** The audit (Decision 2
   = ii) confirmed the fluers daemon bash is explicitly *not* an OS-level sandbox
   (`local_env.rs:1-13`: no chroot/landlock/UID separation). `LocalSessionEnv
   ::exec` (`local_env.rs:458-497`) runs `sh -c <command>` with an fd-anchored
   **cwd** only — the child has **full user-FS reach** (can `cd /; rm -rf …`).
   The daemon runs as the user's UID, so its reach = `~`, `~/Documents`,
   `~/Library` — identical to local Swift bash. Therefore Swift's full bash
   DamageControl branch (`zeroAccessPaths` + `noDeletePaths` + `bashRules`, e.g.
   `rm -rf ~/Documents`, `curl|bash`) is **non-redundant** and MUST run Swift-side
   before routing. The daemon's own `damage.rs` (`is_catastrophic_command` /
   `is_workspace_wipe`, `policy.rs:312-316`) covers a DIFFERENT scope
   (system-wide `rm -rf /`/`mkfs`/`dd`/`shutdown` + workspace-wipe under
   `DurableWorkspace`) — complementary defense-in-depth, not a replacement. No
   new rules needed (coverage already matches reach); no confinement/catastrophe
   split needed (the whole bash branch stays).
2. **Receipts are coarse (Decision 1 = a).** Routed bash keeps the current
   best-effort receipt: pattern-match the command for a `>`/`>>` redirect target,
   snapshot that file, else no pre-state. Undo for arbitrary `rm`/pipelines is
   infeasible regardless — that's what DamageControl is for. The coarse capture
   is routed-aware: a relative redirect resolves against the daemon-approved
   root (NOT the Swift process cwd); an absolute path or no detectable target
   preserves the current behavior. This is undo material, not a confinement
   boundary.

Fail-closed outage semantics identical to write/edit (no local bash fallback —
bash mutations are irreversible). Approval upstream; `tool.confirm` answered on
the existing connection. Local-vs-routed parity verified (both use minimal
constrained env; both run the same DamageControl rules).

### fluers — current pin `=0.5.0`

- **0.5.0** — fd-anchored `write_file`/`exec`/`glob`/`grep` (mkdirat-walk parents
  + `fstat` `st_nlink` check + write/`ftruncate` off the SAME fd; the path-based
  `resolve()` is gone entirely). Closes the Layer-4 mutation TOCTOU — the HARD
  GATE for routing mutations. Hardlinks (`st_nlink > 1`) are now rejected on
  read AND write. macOS: exec cwd / grep root resolve via `F_GETPATH`, not
  `/dev/fd/N`.
- **0.4.0** — generic `ToolPolicy` trait (content-aware governance hook, default
  allow-all; foundation for Layer-4 governance) + generic `edit` tool +
  non-truncating `read_file_full`.
- **0.3.1** — fd-anchored local read (`openat`+`O_NOFOLLOW`+`fstat`; closes the
  daemon-read TOCTOU, B-Swift C1a / #4).

### Collaborate skill — merged

The `collaborate` skill (connect to other Fae/humans/agents over x0x) is merged
to `main`. Design: `docs/plans/fae-collaborate-skill-design-2026-06-29.md`.

## Out of scope (flagged, not active)

- **Swift legacy mutation paths** (`EditTool`/`WriteTool`) still path-based —
  separate from read-routing; folds into Layer-4 when mutations route.
- **Pre-existing clippy tech debt** in `fae-acp`/`fae-engine` (`expect()`/`panic`
  in non-test code) — predates this work; fix per-crate when touched.
