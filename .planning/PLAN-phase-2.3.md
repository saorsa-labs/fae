# Phase 2.3: Semi-Automatic Deployment

## Status: In Progress

## Context
Phase 2.2 delivered ImprovementCycleCoordinator with the full state machine. This phase
adds the deployment side: morning proposals with personal messaging, earned auto-deploy
after 5 user-approved cycles, and adapter rollback tracking.

The ImprovementState record already tracks `currentAdapterPath`, `previousAdapterPath`,
`userApprovedCycles`, and `completedCycles`.

## Tasks

### Task 1: AdapterDeploymentManager — proposal + approval + rollback
- Create `Sources/Fae/Scheduler/AdapterDeploymentManager.swift`
- `generateProposal(baseline:postEval:gapsSummary:) -> DeploymentProposal` struct
  - DeploymentProposal: adapterPath, improvementSummary, metricsComparison, personalMessage
- `shouldAutoDeploy(state:) -> Bool` — true when userApprovedCycles >= 5
- `deploy(adapterPath:store:) async throws` — updates ImprovementState with current/previous
- `rollback(store:) async throws` — swaps current ↔ previous adapter paths
- Doc comments on all public members
- Files: `Sources/Fae/Scheduler/AdapterDeploymentManager.swift`

### Task 2: Wire deploying phase in ImprovementCycleCoordinator
- In the PROPOSING step: call AdapterDeploymentManager.generateProposal()
- In the DEPLOYING step: check shouldAutoDeploy()
  - If auto: call deploy() directly
  - If not: store proposal for morning delivery, stay in proposing until user approves
- Add `approveDeployment() async throws` method for user approval callback
- Files: `Sources/Fae/Scheduler/ImprovementCycleCoordinator.swift`

### Task 3: Morning proposal integration
- Add `pendingProposal: DeploymentProposal?` to ImprovementCycleCoordinator
- When enhanced_morning_briefing runs, check for pending proposals
- Format proposal as human-friendly message with metrics
- Files: `Sources/Fae/Scheduler/ImprovementCycleCoordinator.swift`, `FaeScheduler+Proactive.swift`

### Task 4: AdapterDeploymentManagerTests
- Test: generateProposal creates valid proposal with personal message
- Test: shouldAutoDeploy returns false when < 5 approved cycles
- Test: shouldAutoDeploy returns true when >= 5 approved cycles
- Test: deploy updates current/previous adapter paths
- Test: rollback swaps adapter paths correctly
- Test: approveDeployment increments userApprovedCycles
- Files: `Tests/HandoffTests/AdapterDeploymentManagerTests.swift`

### Task 5: Build verification
- swift build passes
- All improvement tests pass (store + coordinator + deployment)
