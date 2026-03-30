# Plan: Phase 4.1 — Shadow Evaluation Integration

## Context
ShadowEvaluator.swift already exists with 19 tests: episode replay, heuristic scoring,
promotion gate (60% win rate), overnight window enforcement. What remains is integrating
it into ImprovementCycleCoordinator and implementing the alternating-night schedule.

## Tasks

### Task 1: Add ShadowEvaluator to ImprovementCycleCoordinator
- Add `shadowEvaluator: ShadowEvaluator` property (injectable, defaults to new instance)
- Add `isShadowEvalNight()` check: odd completedCycles = shadow eval, even = training
  (alternates with training nights; directive tuning every 7th takes priority)
- Tests: shadow eval night detection for various cycle counts

Files: `Sources/Fae/Scheduler/ImprovementCycleCoordinator.swift`

### Task 2: Integrate shadow eval into the evaluating step
- In the evaluating step, after running the review gate:
  - Run `shadowEvaluator.runEvaluation(ignoreWindow: true)` (window already checked at cycle level)
  - If shadow eval returns `promotionGatePassed == false`, abort: return to idle with error
  - If passed, continue to proposing
- If no episodes available (fresh install), skip shadow eval gracefully
- Tests: shadow eval blocks deployment when gate fails, allows when passes

Files: `Sources/Fae/Scheduler/ImprovementCycleCoordinator.swift`, `Tests/HandoffTests/ImprovementCycleCoordinatorTests.swift`

### Task 3: Episode capture from conversations
- Add `captureEpisode()` method to coordinator: captures current conversation as ShadowEvalEpisode
- Called from runCycle() collecting step: store episodes from the last N conversations
- For now, capture is a stub that stores placeholder episodes
- Tests: episode capture stores to ImprovementStore

Files: `Sources/Fae/Scheduler/ImprovementCycleCoordinator.swift`

### Task 4: Build verification + full test run
- `swift build` zero errors/warnings
- All HandoffTests pass
- Update progress.md
