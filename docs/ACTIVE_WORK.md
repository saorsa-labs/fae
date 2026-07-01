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

### Layer-4 routed mutations (write / edit / bash) — UNBLOCKED, F7a ready

`read` is routed and confinement-complete (fd-anchored, hardlink/symlink
TOCTOU closed, red-team-validated). Routing `write`/`edit`/`bash` was gated on
fluers' mutation/search paths (`write_file`, `exec`, `glob`, `grep`) being
fd-anchored — mutations are irreversible, so a TOCTOU swap there is data loss,
not a leaked file.

**Gate SATISFIED (2026-07-01):** fluers 0.5.0 fd-anchored all four
mutation/search paths (`openat`+`mkdirat`+`O_NOFOLLOW`+`fstat`-off-opened-fd;
the path-based `resolve()` is gone entirely) and Fae pins `=0.5.0`. Phase F7a
(route `write` through the daemon) can now start.

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
