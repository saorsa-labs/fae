# Swift Rebuild Status

## Current default

- Primary build/test path is SwiftPM in `native/macos/Fae`.

## Phase 1 status

- Current Phase 1 parity status is tracked in [phase-1-parity.md](./phase-1-parity.md).
- Latest pass completed:
  - #28 config persistence (working load/save + defaults fallback behavior)
  - #34 degraded mode transition reporting (additive, no routing changes)
  - #35 baseline Phase 1 metrics hooks in pipeline (additive observability)
- Current workspace Swift tests are passing after these updates.
- Model tier update is now reflected in Swift config selection, including `mlx-community/Qwen3.5-35B-A3B-4bit` as the high-tier game-changing option on high-memory systems.

## Guardrails and cleanup tracking

- Residue tracking: [residue-tracker.md](./residue-tracker.md)
- Cleanup policy: [cleanup-policy.md](./cleanup-policy.md)

## PR A status

- ✅ PR A guardrails complete
  - Added root artifact hygiene verification (`/target` ignored; no tracked root target artifacts)
  - Added CI/dev-command Rust reintroduction guard script
  - Wired guard script into CI as an early step

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

- Quarantined root Rust residue into `legacy/rust-core/` to keep SwiftPM as the active default path.
- Added archival/rollback docs:
  - [legacy/rust-core/README.md](../../legacy/rust-core/README.md)
  - [legacy/rust-core/ROLLBACK.md](../../legacy/rust-core/ROLLBACK.md)
- Root `target/` artifact directory removed; ignore policy remains in place (`/target` in `.gitignore`).
