# Phase 3.3: Pipeline Integration

## Goal
Wire JS tool programs into the main conversation path after budgets, governance, and structured APIs exist.

## Tasks

### Task 1: Add `<tool_program>` tag parsing alongside `<tool_call>` in PipelineCoordinator
- Extend `PipelineCoordinator.parseToolCalls()` to also detect `<tool_program>` blocks
- Add a `ScriptBlock` struct to hold parsed JS source + optional allowedTools + optional budget
- Ensure existing `<tool_call>` parsing is unchanged
- Files: `Sources/Fae/Pipeline/PipelineCoordinator.swift`
- Test: `Tests/HandoffTests/PipelineCoordinatorPolicyTests.swift` (add parsing tests)

### Task 2: Wire JSCRuntime into PipelineCoordinator
- Add a `jscRuntime: JSCRuntime?` field to PipelineCoordinator
- Initialize it in the init (lazily or eagerly) using the shared toolExecutor
- Add contextFactory/callbacksFactory that build from coordinator state
- Files: `Sources/Fae/Pipeline/PipelineCoordinator.swift`

### Task 3: Route `<tool_program>` through JSCRuntime in generateWithTools
- After tool-call extraction, check for script blocks
- If script blocks found, execute them via `jscRuntime.run()` (no prefix(5) cap)
- Feed script results back into conversation history as tool results
- Preserve existing tool-call path (prefix(5) cap) untouched
- Add event bus emissions for script start/end
- Files: `Sources/Fae/Pipeline/PipelineCoordinator.swift`

### Task 4: Integration tests for script path
- Test that `<tool_program>` scripts execute through the pipeline
- Test that `<tool_call>` still works normally (regression)
- Test that script results appear in conversation history
- Test that script path has no prefix(5) cap
- Test that budget/governance is enforced on script path
- Files: `Tests/HandoffTests/PipelineIntegrationTests.swift`

## Acceptance
- Fae can execute a JS tool program in a normal conversation turn.
- Existing tool-call flows still work.
- Script path is governed and auditable.

## Validation
```bash
cd native/macos/Fae
swift build
swift test
```
