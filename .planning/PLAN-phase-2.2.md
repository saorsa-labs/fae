# Phase 2.2: ImprovementCycleCoordinator

## Status: In Progress

## Context
Phase 2.1 delivered ImprovementStore (improvement.db) with full CRUD. This phase builds
the coordinator that drives the autonomous self-improvement loop as a deterministic
state machine integrated with the scheduler.

## Tasks

### Task 1: ImprovementCycleCoordinator actor skeleton + state machine
- Create `Sources/Fae/Scheduler/ImprovementCycleCoordinator.swift`
- Define CycleState enum: idle, collecting, training, evaluating, proposing, deploying
- Actor with ImprovementStore dependency
- `transition(to:)` method with valid transition enforcement
- `currentState` property reading from ImprovementStore
- Doc comments on all public members
- Files: `Sources/Fae/Scheduler/ImprovementCycleCoordinator.swift`

### Task 2: runCycle() — main orchestration loop
- Implement `runCycle()` async method that:
  1. Reads current state from ImprovementStore
  2. Checks minimum data threshold (>=20 feedback events AND >=5 corrections)
  3. If threshold not met, logs skip and returns
  4. Transitions IDLE -> COLLECTING: gathers pending feedback events
  5. Transitions COLLECTING -> TRAINING: delegates to training skill
  6. Transitions TRAINING -> EVALUATING: runs eval benchmark
  7. Transitions EVALUATING -> PROPOSING: generates proposal
  8. Error handling: any failure -> logs error, resets to IDLE
- Each transition persists state to ImprovementStore
- Stuck-detection: if trainingStartedAt > 2h ago, force reset to IDLE
- Files: `Sources/Fae/Scheduler/ImprovementCycleCoordinator.swift`

### Task 3: Scheduler integration
- Add "improvement_cycle" to schedulerTaskAllowlists in TrustedActionBroker
  with: ["activate_skill", "run_skill", "delegate_agent", "self_config"]
- Add improvement_cycle daily task in FaeScheduler.scheduler_tick at 03:00
- Add case to triggerByName for manual triggering
- Wire ImprovementStore into FaeScheduler (lazy open)
- Wire ImprovementCycleCoordinator creation in FaeScheduler
- Files: `TrustedActionBroker.swift`, `FaeScheduler.swift`

### Task 4: ImprovementCycleCoordinatorTests
- Test: initial state is idle
- Test: runCycle skips if <20 feedback events
- Test: runCycle skips if <5 correction-type events
- Test: valid state transitions succeed
- Test: invalid state transitions throw/reject
- Test: stuck-detection resets to idle after 2h
- Test: error during training resets to idle
- Test: idempotency (calling runCycle twice in IDLE is safe)
- Files: `Tests/HandoffTests/ImprovementCycleCoordinatorTests.swift`

### Task 5: Build verification
- swift build passes
- swift test --filter ImprovementCycleCoordinator passes
- No regressions in ImprovementStoreTests
