# Phase 2.2: ImprovementCycleCoordinator

## Context

Phase 2.1 created `ImprovementStore` with 5 tables and 23 passing tests. Phase 2.2
creates the `ImprovementCycleCoordinator` actor — a deterministic state machine that
drives the autonomous improvement loop using data from ImprovementStore.

## State Machine

```
IDLE → COLLECTING → TRAINING → EVALUATING → PROPOSING → DEPLOYING → IDLE
                                                ↘ IDLE (if rejected / low confidence)
```

- **IDLE**: waiting for enough feedback events (threshold: 20 events, 5 corrections)
- **COLLECTING**: sampling data, exporting training pairs via training-data-bridge skill
- **TRAINING**: invoking training-orchestrator skill (mlx-tune SFT)
- **EVALUATING**: running FaeBenchmark with --adapter flag, comparing to baseline
- **PROPOSING**: emitting morning proposal to user for approval
- **DEPLOYING**: hot-swapping adapter via patchConfig, storing previous for rollback

## Tasks

### Task 1: Define ImprovementCycleCoordinator actor skeleton

File: `Sources/Fae/Memory/ImprovementCycleCoordinator.swift`

- Define `ImprovementCycleState` enum: idle, collecting, training, evaluating, proposing, deploying
- Define `ImprovementCycleError` enum: storeNotOpen, belowThreshold, trainingFailed, evalFailed, noBaseline
- Define `ImprovementCycleCoordinator` actor with:
  - `store: ImprovementStore` (injected)
  - `eventBus: FaeEventBus` (injected, weak-ish — actually actors can hold strong refs)
  - `cycleState: ImprovementCycleState` (actor-isolated computed from store)
  - `start()` / `stop()` lifecycle
  - `canRunCycle() throws -> Bool` — minimum threshold check
  - Stub methods for each phase transition (returning immediately for now)

### Task 2: Implement threshold checking and COLLECTING phase

- `canRunCycle()`: query ImprovementStore.pendingFeedbackCount() >= 20
  AND count of correction signal types >= 5
- `startCollecting()`: transition state to "collecting", export training data
  (call SkillManager/run_skill "training-data-bridge" with action "export_sft")
  For this phase, stub the skill call with a comment — full wiring is Phase 3
- Store state transition in ImprovementStore.writeState()

### Task 3: Implement TRAINING → EVALUATING → PROPOSING transitions

- `startTraining()`: transition to "training", record trainingStartedAt
  Stub: log intent, set state to "evaluating" immediately (full mlx-tune in Phase 3)
- `runEvaluation()`: transition to "evaluating"
  Stub: set adapterWins placeholder, transition to "proposing"
- `proposeToUser()`: transition to "proposing"
  Emit a `FaeEvent.runtimeProgress` with stage "improvement_proposal_ready"
  Store proposal in ImprovementState for the UI to read

### Task 4: Implement DEPLOYING and rollback

- `deploy(approved: Bool)`:
  - If approved: call FaeCore.patchConfig("training.personal_adapter_path", ...)
    via a closure/callback (injected so coordinator doesn't need FaeCore import)
  - Store currentAdapterPath → previousAdapterPath before updating
  - Increment userApprovedCycles, completedCycles
  - Transition back to "idle"
  - If not approved: just transition back to "idle", zero out trainingStartedAt

- `rollback()`:
  - Swap currentAdapterPath ↔ previousAdapterPath
  - Call deploy callback with previousAdapterPath
  - Emit runtimeProgress stage "adapter_rolled_back"

### Task 5: Tests — ImprovementCycleCoordinatorTests.swift

File: `Tests/HandoffTests/ImprovementCycleCoordinatorTests.swift`

Tests to cover:
- `testCanRunCycleFalseWhenBelowThreshold` — fresh store, canRunCycle() returns false
- `testCanRunCycleTrueWhenAboveThreshold` — insert 20+ events (5+ corrections), returns true
- `testStartCollectingTransitionsState` — verify ImprovementStore state becomes "collecting"
- `testDeployApprovedIncrementsCounters` — userApprovedCycles increments
- `testDeployRejectedKeepsIdle` — state returns to idle without incrementing
- `testRollbackSwapsAdapterPaths` — currentAdapterPath and previousAdapterPath swap
- `testFullCycleStubRoundTrip` — idle → collecting → training → evaluating → proposing → deploying → idle
