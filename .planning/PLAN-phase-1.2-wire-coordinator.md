# Phase 1.2: Wire Coordinator → TrainingBridge

## Context

Phase 1.1 created TrainingBridge actor with methods for export, launch, poll, evaluate.
Now wire it into ImprovementCycleCoordinator.runCycle() to replace the training stub.

## Files to Modify

- `Sources/Fae/Scheduler/ImprovementCycleCoordinator.swift` — replace stub, add TrainingBridge dependency
- `Sources/Fae/Scheduler/FaeScheduler.swift` — wire TrainingBridge into coordinator creation
- `Tests/HandoffTests/ImprovementCycleCoordinatorTests.swift` — add training bridge tests

## Tasks

### Task 1: Add TrainingBridge dependency to ImprovementCycleCoordinator

- Add `var trainingBridge: TrainingBridge?` property
- Add `setTrainingBridge(_:)` method (called by FaeScheduler after wiring)
- Add `TrainingConfig` parameter passthrough for preset selection

### Task 2: Replace training stub in runCycle()

Replace the stub at Step 5 (TRAINING) with:
1. Guard trainingBridge is available
2. Export training data via bridge.exportTrainingData()
3. Check minimum thresholds (>=10 SFT examples)
4. Launch training via bridge.launchTraining()
5. Poll until complete via bridge.pollUntilComplete()
6. Store adapter path in ImprovementState.currentAdapterPath
7. Log results

### Task 3: Wire real evaluation

Replace zeroed EvalDelta at Step 6 (EVALUATING) with:
1. Call bridge.evaluateAdapter() to get loss-based score
2. Map score to EvalDelta (score > 0.5 → positive delta, else negative)
3. Keep ExternalReviewGate as-is (it uses EvalDelta for pass/fail)

### Task 4: Wire TrainingBridge in FaeScheduler

- In runImprovementCycle(), create TrainingBridge if needed
- Set it on the coordinator before running the cycle
- Handle TrainingBridgeError.uvNotAvailable gracefully (log and skip)

### Task 5: Tests

- Test coordinator skips gracefully when trainingBridge is nil
- Test coordinator calls export → launch → poll → evaluate flow
- Test adapter path is stored in state after training
