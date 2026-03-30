# Plan: Phase 3.2 — External Agent Review Gate (Integration)

## Context
ExternalReviewGate.swift exists with fallback chain (Codex → Claude Code → internal self-review),
verdict parsing, and deferral counting. 16 tests passing (commit 9879748f). What remains:

1. Wire SecurityEventLogger into ExternalReviewGate (currently a stub NSLog)
2. Add deferral tracking to ImprovementState
3. Integrate ExternalReviewGate into ImprovementCycleCoordinator (evaluating → proposing transition)
4. Tests for the new integration + build verification

## Tasks

### Task 1: Wire SecurityEventLogger into ExternalReviewGate
- Add `securityLogger` closure property to ExternalReviewGate (same injection pattern as delegateAgentRunner)
- Replace NSLog stub in `logResult()` with real SecurityEventLogger call via the closure
- Log: event="external_review_gate", toolName=provider.rawValue, decision=verdict.rawValue
- Test: verify logger closure is called with correct arguments

Files: `Sources/Fae/Memory/ExternalReviewGate.swift`, `Tests/HandoffTests/ExternalReviewGateTests.swift`

### Task 2: Add deferralCount to ImprovementState + ImprovementStore
- Add `deferralCount: Int` field to ImprovementState struct
- Update `ensureStateRow()` / table creation in ImprovementStore to include the column
- Add `incrementDeferral()` and `resetDeferrals()` helper methods on ImprovementStore
- Tests: deferral increment, reset

Files: `Sources/Fae/Memory/ImprovementStore.swift`, `Tests/HandoffTests/ImprovementStoreTests.swift`

### Task 3: Integrate ExternalReviewGate into ImprovementCycleCoordinator
- Add `reviewGate: ExternalReviewGate` property to coordinator (lazy, injectable for tests)
- In runCycle() evaluating step: call `reviewGate.review(evalDelta:currentDeferralCount:)`
- On PASS → continue to proposing
- On CONCERN → increment deferral via store, return to idle (skip this cycle)
- On FAIL → return to idle with error "review_failed"
- On maxDeferralsReached → return to idle with error
- Wire SecurityEventLogger closure from coordinator init

Files: `Sources/Fae/Scheduler/ImprovementCycleCoordinator.swift`, `Tests/HandoffTests/ImprovementCycleCoordinatorTests.swift`

### Task 4: Build verification + full test run
- `swift build` zero errors/warnings
- `swift test --filter HandoffTests` all pass
- Verify total test count stable or increased
- Update progress.md
