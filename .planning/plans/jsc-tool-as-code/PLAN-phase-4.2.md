# Phase 4.2: End-to-End Testing

## Goal
Validate the full JSC execution path across governance, pipeline, and recovery behavior.

## Tasks
- Add integration coverage for JS tool-program execution.
- Cover approval flows, budget failures, cancellation, and recovery.
- Add regression cases for existing non-script tool flows.
- Verify debug/canvas/tool events still surface correctly.

## Acceptance
- JSC path is covered by integration tests.
- Existing tool-call path does not regress.

## Validation
```bash
cd native/macos/Fae
swift build
swift test
```
