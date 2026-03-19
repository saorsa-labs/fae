# Phase 3.4: Dry-Run Mode

## Goal
Let users preview what a tool program intends to do before real execution.

## Tasks

### Task 1: DryRunToolExecutor — record-only executor
- Create `DryRunToolExecutor` that wraps `ToolExecutor` and records calls without executing
- Each recorded call captures: tool name, arguments, risk level, requires approval
- Returns synthetic success results so scripts run to completion
- File: `Sources/Fae/Runtime/DryRunToolExecutor.swift`

### Task 2: Add dry-run mode to JSCRuntime
- Add `dryRun` parameter to `JSCRuntime.run()`
- When dry-run, use `DryRunToolExecutor` instead of real executor
- Return a `DryRunPlan` with all recorded intended calls + script result
- File: `Sources/Fae/Runtime/JSCRuntime.swift`

### Task 3: DryRunPlan summary formatter
- Format recorded calls into a readable plan summary for the user
- Include tool names, argument summaries, risk levels
- Suitable for both voice output and conversation display
- File: `Sources/Fae/Runtime/DryRunPlan.swift`

### Task 4: Tests
- Test dry-run records calls without executing
- Test dry-run script runs to completion with synthetic results
- Test plan summary formatting
- Test dry-run does not mutate state
- File: `Tests/HandoffTests/DryRunModeTests.swift`

## Acceptance
- Users can inspect and approve a plan before execution.
- Dry-run does not mutate user state.

## Validation
```bash
cd native/macos/Fae
swift build
swift test
```
