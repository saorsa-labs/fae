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

### Layer-4 routed mutations (write / edit / bash) — F7a (write) + F7b (edit) shipped; F8 (bash) remains

`read` is routed and confinement-complete. `write` (F7a) and `edit` (F7b) are
now routed too (2026-07-01). `bash` remains on the local pipeline (F8 is
future).

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

**F7b — route edit (shipped):** routed `edit` mirrors routed write exactly
(decision/execution split, fd-anchored receipt pre-state, fail-closed outage,
DamageControl skip, upstream approval). TWO edit-specific differences: (1)
**schema translation at the daemon seam** — the Swift `EditTool` uses
`old_string`/`new_string` but the fluers daemon `EditTool` requires
`old_text`/`new_text` (`validate_input` enforces it); `buildDaemonEditInput`
translates at the seam so `call.arguments`/hooks/audit/receipts keep the
Swift-native keys and the daemon gets the keys it needs; (2) **local EditTool
parity fix** — the local tool now rejects empty `old_string` and requires a
unique match (mirroring fluers), so routed vs. legacy edit behave identically
(previously the local tool silently replaced the first of N and accepted empty
`old_string`). `friendlyRoutedEditError` handles edit-logical errors
(not-found/ambiguous) distinctly from backend problems.

- **Policy table + the F7a/F7b corrections:** `docs/plans/bswift-f7f8-routed-damagecontrol-policy-2026-06-30.md`.
- **Resolution record (read-routing, all closed):** `docs/plans/bswift-3b-followups-2026-06-30.md`.
- **Remaining Layer-4 work:** F8 (route `bash` — needs the DamageControl
  catastrophe/confinement split + bash-receipt owner decisions; the hardest).

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
