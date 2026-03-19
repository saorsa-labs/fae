# Phase 1.4: Developer Harness & Runtime Validation

## Goal
Validate the JSC runtime before wiring it into the main conversation pipeline.

## Tasks
- Add a developer/test harness to run JS tool programs against mocked or safe tools.
- Capture per-step execution logs and surfaced errors.
- Validate lifecycle, cancellation, and teardown outside the live LLM path.
- Document the harness entry point for future debugging.

## Acceptance
- Developers can run tool programs without going through full prompt generation.
- Logs are sufficient to debug bridge failures and governance decisions.

## Validation
```bash
cd native/macos/Fae
swift build
swift test
```
