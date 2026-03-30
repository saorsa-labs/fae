# Plan: Phase 4.2 — CEO Expansions (Vault Backup + Self-Diagnostic)

## Context
From roadmap:
- Git Vault backup for improvement.db + adapters
- Self-diagnostic integration for improvement health

## Tasks

### Task 1: Add improvement.db to Git Vault backup list
- Add `FaeDirectories.improvementDatabase` to GitVaultManager's backup file list
- Add adapter directory to vault backup (if present)
- Tests: verify improvement.db path is in backup list

Files: `Sources/Fae/Backup/GitVaultManager.swift`

### Task 2: Self-diagnostic improvement health
- Create `ImprovementHealthReporter` — generates a health summary
- Reports: current cycle state, completedCycles, deferralCount, lastCycleAt, lastCycleError,
  pending feedback count, shadow eval stats
- Format as a structured dictionary for DiagnosticsManager integration
- Tests: health report generation

Files: `Sources/Fae/Scheduler/ImprovementHealthReporter.swift`, `Tests/HandoffTests/ImprovementHealthReporterTests.swift`

### Task 3: Build verification + full test run
- `swift build` zero errors/warnings
- All HandoffTests pass
- Update progress.md
