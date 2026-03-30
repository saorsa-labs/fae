# Phase 2.1: ImprovementStore (improvement.db)

## Status: In Progress

## Context
`ImprovementStore.swift` already implements all 5 tables (feedback_events, improvement_baselines, improvement_state, capability_gaps, shadow_eval) with full CRUD methods. `FaeDirectories.improvementDatabase` path is already defined. What's missing: comprehensive test coverage.

## Tasks

### Task 1: ImprovementStoreTests — FeedbackEvent CRUD
- Create `Tests/HandoffTests/ImprovementStoreTests.swift`
- Test: appendFeedbackEvent inserts and returns ID
- Test: pendingFeedbackEvents returns only unconsumed events
- Test: markConsumed flips consumed flag
- Test: pendingFeedbackCount returns correct count
- Test: open() is idempotent (second call is no-op)
- Files: `Tests/HandoffTests/ImprovementStoreTests.swift`

### Task 2: ImprovementStoreTests — Baseline + State CRUD
- Test: insertBaseline stores and returns with ID
- Test: latestBaseline returns most recent for given modelID
- Test: latestBaseline returns nil for unknown model
- Test: ensureStateRow creates singleton (idempotent)
- Test: readState returns initial idle state
- Test: writeState persists changes
- Test: writeState roundtrip (write then read)
- Files: `Tests/HandoffTests/ImprovementStoreTests.swift`

### Task 3: ImprovementStoreTests — CapabilityGap + ShadowEval CRUD
- Test: insertGap and unaddressedGaps (priority ordering)
- Test: markGapAddressed excludes from unaddressed
- Test: appendShadowEpisode stores episode
- Test: unevaluatedEpisodes respects limit
- Test: recordEvalOutcome marks evaluated + stores outcome
- Test: shadowEvalCounts returns correct counts
- Files: `Tests/HandoffTests/ImprovementStoreTests.swift`

### Task 4: ImprovementStoreTests — Error paths + persistence
- Test: operations before open() throw notOpen
- Test: readState before ensureStateRow throws stateNotInitialised
- Test: close then reopen preserves data
- Test: empty database returns empty arrays and zero counts
- Files: `Tests/HandoffTests/ImprovementStoreTests.swift`

### Task 5: Build verification
- Run `swift build && swift test` from native/macos/Fae
- Verify all new tests pass, zero regressions
- Files: N/A
