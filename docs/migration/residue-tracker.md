# Migration Residue Tracker

Tracks non-blocking residue from Rust-era architecture during Swift-first migration.

## Scope

- Root-level migration residue that could confuse current build/test/release flow
- CI/dev-command references that may accidentally reintroduce Rust toolchain dependencies

## Current tracked residue

- Legacy/archival Rust references remain in historical docs by design
- Guard script added: `scripts/ci/guard-no-rust-reintro.sh`

## PR A updates

- Added CI/dev-command guardrails for Rust reintroduction checks
- Confirmed root `target` artifacts are ignored and not tracked

## PR B status

- Bridge files (exact filenames):
  - `HostCommandBridge.swift`
  - `ConversationBridgeController.swift`
  - `OrbStateBridgeController.swift`
  - `PipelineAuxBridgeController.swift`
- PR B performed a neutral Swift-first terminology/comment refactor.
- Behavior and event/notification names were unchanged.
- Next actions (future PRs):
  - Consolidate overlapping bridge responsibilities into a single stable path.
  - Remove obsolete bridge surfaces once migration milestones confirm no remaining callers.

## PR C status

- Root Rust artifacts quarantined to `legacy/rust-core/`:
  - `Cargo.toml` — **QUARANTINED**
  - `Cargo.lock` — **QUARANTINED**
  - `build.rs` — **QUARANTINED**
  - `.cargo/` — **QUARANTINED**
  - `src/` — **QUARANTINED**
  - `include/` — **QUARANTINED**
  - `tests/` — **QUARANTINED**
- Root build artifact directory:
  - `target/` — **REMOVED** (and remains ignored via root `.gitignore` entry `/target`)
- Archival docs added:
  - `legacy/rust-core/README.md`
  - `legacy/rust-core/ROLLBACK.md`
