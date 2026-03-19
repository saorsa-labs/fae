# Phase 1.2: Build JSCRuntime + Promise Bridge

## Goal
Add a fresh-per-run JavaScriptCore runtime and a narrow Promise-based `fae.*`
bridge that routes through `ToolExecutor`.

## Tasks
- Create `JSCRuntime` actor responsible for context lifecycle and execution.
- Create `JSCToolBridge` that exposes a minimal script API.
- Use Promise-based host calls; do not block the main actor with semaphores.
- Define `JSCScriptResult` with final value, logs, and failure details.
- Add unit tests for successful host calls, rejected host calls, and runtime teardown.

## Key Files
- `native/macos/Fae/Sources/Fae/Runtime/`
- `native/macos/Fae/Sources/Fae/Pipeline/`

## Acceptance
- Scripts can call at least one host-exposed tool via the bridge.
- All host calls still flow through `ToolExecutor`.
- JS runtime is discarded after each execution.

## Validation
```bash
cd native/macos/Fae
swift build
swift test
```
