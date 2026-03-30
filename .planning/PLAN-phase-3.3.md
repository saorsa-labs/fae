# Plan: Phase 3.3 — Directive-Based Fast Tuning

## Context
The improvement cycle runs nightly. Every 7th cycle, instead of LoRA training, Fae analyzes
accumulated feedback patterns and generates directive amendments. This is "fast tuning" because
it changes behavior immediately (via directive.md) without waiting for adapter training.

ImprovementStore has FeedbackEvents with signal types. directive.md is managed by SelfConfigTool.
The DirectiveTuner detects patterns in feedback and proposes targeted directive amendments.

## Tasks

### Task 1: DirectiveTuner — pattern detection + directive generation
- Create `Sources/Fae/Scheduler/DirectiveTuner.swift`
- Struct `FeedbackPattern` with: patternType, frequency, sampleEvidence, suggestedAmendment
- `detectPatterns(events: [FeedbackEvent]) -> [FeedbackPattern]`
  - Pattern types: repeated_correction (same correction >3x), persistent_reask (re_ask >5x),
    abandonment_cluster (3+ abandonments same topic), style_preference (praise patterns)
- `generateAmendment(patterns: [FeedbackPattern]) -> String?`
  - Returns a directive amendment string or nil if no strong patterns
- `applyAmendment(amendment: String, currentDirective: String?) -> String`
  - Appends amendment with date header, max 2000 chars total
- Tests: pattern detection for each type, amendment generation, amendment application

Files: `Sources/Fae/Scheduler/DirectiveTuner.swift`, `Tests/HandoffTests/DirectiveTunerTests.swift`

### Task 2: Integrate DirectiveTuner into ImprovementCycleCoordinator
- Add `isDirectiveTuningCycle()`: true every 7th completed cycle
- In runCycle(), after collecting: if directive tuning cycle, run DirectiveTuner instead
  - Read unconsumed events, detect patterns, generate amendment
  - If amendment: read current directive, apply, write back
  - Mark events consumed, transition to idle (skip training/eval/deploy)
- Tests: directive cycle detection, directive tuning bypasses training

Files: `Sources/Fae/Scheduler/ImprovementCycleCoordinator.swift`, `Tests/HandoffTests/ImprovementCycleCoordinatorTests.swift`

### Task 3: Directive rollback support
- Add `previousDirective: String?` field to ImprovementState + schema migration
- Before applying amendment: store current directive as previousDirective
- Add `rollbackDirective()` method to coordinator
- Tests: rollback restores previous directive

Files: `Sources/Fae/Memory/ImprovementStore.swift`, `Sources/Fae/Scheduler/ImprovementCycleCoordinator.swift`

### Task 4: Build verification + full test run
- `swift build` zero errors/warnings
- All HandoffTests pass
- Update progress.md
