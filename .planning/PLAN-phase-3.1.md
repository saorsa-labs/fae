# Phase 3.1: Add New Test Suites for Simplified Permission Model

## Status: In Progress

## Tasks

### Task 1: SimplifiedToolExecutionTests
- Verify owner hits zero gates for all tools in the new 3-step flow
- Test: owner + normal tool -> proceeds without approval
- Test: DamageControlPolicy block verdict -> hard deny
- Test: DamageControlPolicy disaster verdict -> countdown narration
- Test: tool not in registry -> rejected
- File: Tests/HandoffTests/SimplifiedToolExecutionTests.swift

### Task 2: GuestToolAccessTests
- Verify guest tool grant filtering via VoiceConversationPolicy
- Test: guest with granted tool -> proceeds
- Test: guest without grant -> rejected
- Test: unknown speaker -> all tools rejected
- File: Tests/HandoffTests/GuestToolAccessTests.swift

### Task 3: SchedulerFullAccessTests
- Verify scheduler tasks get full access without per-task allowlists
- Test: scheduled task auto-approves (isOwner=true from PipelineCoordinator)
- Test: scheduled task + DamageControlPolicy block -> still blocked
- File: Tests/HandoffTests/SchedulerFullAccessTests.swift

### Task 4: OwnerDamageControlTests
- Verify DamageControlPolicy catches catastrophic ops even for owner
- Test: bash "rm -rf /" -> block
- Test: bash "mkfs" -> block
- Test: bash "rm -rf ~" -> disaster
- Test: bash "sudo rm -rf" -> confirmManual
- Test: bash "ls -la" -> allow
- File: Tests/HandoffTests/OwnerDamageControlTests.swift

### Task 5: CoWorkPreservedGatingTests
- Verify CoworkToolExecutor still gates external LLM calls
- Test: nonLocal model + credential path -> blocked
- Test: nonLocal model + normal path -> allowed
- Test: injection patterns in response -> flagged
- File: Tests/HandoffTests/CoWorkPreservedGatingTests.swift
