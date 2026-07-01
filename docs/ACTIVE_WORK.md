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

### Layer-4 routed mutations (write / edit / bash) — fluers gate closed; F7a blocked on Q7b scope decision

`read` is routed and confinement-complete (fd-anchored, hardlink/symlink
TOCTOU closed, red-team-validated). Two independent gates stand between now
and routing `write`/`edit`/`bash`:

1. **fluers fd-anchoring (the HARD GATE) — SATISFIED (2026-07-01):** fluers
   0.5.0 fd-anchored all four mutation/search paths (`openat`+`mkdirat`+
   `O_NOFOLLOW`+`fstat`-off-opened-fd; the path-based `resolve()` is gone
   entirely). Fae pins `=0.5.0`.

2. **Daemon `ToolExecuteDangerous` scope (Q7b) — BLOCKED on owner decision.**
   F7a orientation (2026-07-01) found a second, independent gate the F7/F8 doc
   did not anticipate. The daemon's per-tool policy (`FaeToolPolicy`) calls
   `fae_control_plane::authorize` with `tool.execute_dangerous` for write/edit/
   bash (`toolhost/policy.rs:95`). `SwiftFrontend::default_scopes()`
   (`control-plane/lib.rs:355`) is hardcoded to grant `ToolExecuteSafe` but
   **not** `ToolExecuteDangerous` ("granted explicitly during rollout, not by
   default"; "server-side opt-in — a client-side toggle is not the boundary").
   With no config/runtime flag to grant it, a routed write from the Swift app is
   `Deny(MissingScope)` at `policy.rs` step 2 — **before** any `tool.confirm`
   card fires (the card is wired via `DaemonAgentClient.handleToolConfirm`, but
   it only runs once the scope is held). Resolving Q7b unblocks F7a/F7b/F8
   together (write/edit/bash are all `dangerous`). See the F7/F8 doc §0.

- **Policy table + owner decisions (the F7a/F7b/F8 plan):** `docs/plans/bswift-f7f8-routed-damagecontrol-policy-2026-06-30.md`.
- **Resolution record (read-routing, all closed):** `docs/plans/bswift-3b-followups-2026-06-30.md`.

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
