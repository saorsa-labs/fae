# Active Work

The single source of truth for what's currently live and what's blocked.
Everything else in `docs/` is either a permanent record (ADRs, specs) or
historical (archive). If work isn't listed here, it's done or not started.

## Canonical checkouts

- **Fae:** one checkout at `~/Desktop/Devel/projects/fae`, on `main`, tracking
  `origin/main`. No long-lived feature branches — branch, merge, delete.
- **fluers:** one checkout at `~/Desktop/Devel/projects/fluers`, on `main`,
  tracking `origin/main`. Fae consumes fluers via exact crates.io pins
  (`=0.4.0` at time of writing), not git.

## Live work

### Layer-4 routed mutations (write / edit / bash) — BLOCKED on a hard gate

`read` is routed and confinement-complete (fd-anchored, hardlink/symlink
TOCTOU closed, red-team-validated). Routing `write`/`edit`/`bash` is **blocked**
until the fluers mutation paths (`write_file`, `exec`, `glob`, `grep`) are
fd-anchored with the same `openat`+`O_NOFOLLOW`+`fstat`-off-opened-fd pattern —
mutations are irreversible, so a TOCTOU swap there is data loss, not a leaked
file.

- **Gate:** fluers `write_file`/`exec` fd-anchored + released + Fae pinned to it.
- **Policy table + owner decisions:** `docs/plans/bswift-f7f8-routed-damagecontrol-policy-2026-06-30.md`.
- **Resolution record (read-routing, all closed):** `docs/plans/bswift-3b-followups-2026-06-30.md`.

### fluers 0.4.0 — tool-policy trait landed

fluers 0.4.0 (`feat(core): inherit tool policy into delegated subagents`) added a
generic `ToolPolicy` trait — a content-aware governance hook consulted before a
tool runs. Default allow-all. This is the foundation for Layer-4 governance;
Fae pins `=0.4.0`.

### Collaborate skill — merged

The `collaborate` skill (connect to other Fae/humans/agents over x0x) is merged
to `main`. Design: `docs/plans/fae-collaborate-skill-design-2026-06-29.md`.

## Out of scope (flagged, not active)

- **Swift legacy mutation paths** (`EditTool`/`WriteTool`) still path-based —
  separate from read-routing; folds into Layer-4 when mutations route.
- **Pre-existing clippy tech debt** in `fae-acp`/`fae-engine` (`expect()`/`panic`
  in non-test code) — predates this work; fix per-crate when touched.
