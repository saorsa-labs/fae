# Phase 2.1: Streaming Consensus Engine

## Status: In Progress

## Context
Replace batch-mode `runConsensus()` in `CoworkWorkspaceController.swift` with a streaming multi-agent comparison. The `CoworkStreamingProvider` protocol already exists with `stream(request:onPartialText:)`.

## Tasks

### Task 1: Create TaggedChunk type and StreamingConsensusEngine skeleton
- Create `Cowork/StreamingConsensusEngine.swift`
- `TaggedChunk` struct: agentID, agentName, delta, isComplete, errorText
- `StreamingConsensusEngine` actor with method signature
- Files: `Sources/Fae/Cowork/StreamingConsensusEngine.swift`

### Task 2: Implement streaming logic with TaskGroup + AsyncStream
- Each agent runs independently via TaskGroup
- Streaming providers emit tagged chunks via onPartialText
- Non-streaming providers emit single chunk on completion
- Independent failure: one error doesn't cancel others
- Files: `Sources/Fae/Cowork/StreamingConsensusEngine.swift`

### Task 3: Wire into CoworkWorkspaceController.runConsensus()
- Replace batch TaskGroup with StreamingConsensusEngine
- Stream chunks to update latestConsensusResults progressively
- Still build consensus summary after all agents complete
- Files: `Sources/Fae/Cowork/CoworkWorkspaceController.swift`

### Task 4: Add cancel propagation and partial result preservation
- Store consensus Task for cancellation
- On cancel, preserve completed results in latestConsensusResults
- Files: `Sources/Fae/Cowork/CoworkWorkspaceController.swift`

### Task 5: Unit tests for streaming consensus
- Test: all agents complete successfully
- Test: one agent fails, others succeed
- Test: cancellation preserves completed results
- Test: non-streaming provider emits single chunk
- Files: `Tests/HandoffTests/StreamingConsensusEngineTests.swift`
