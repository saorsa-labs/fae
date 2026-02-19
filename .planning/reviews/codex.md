# Codex External Review

## Grade: B

## Summary

The phase 5.2 task 1 implementation adds substantial production-grade resilience infrastructure.
The new modules (`device_watcher`, `memory_pressure`, `model_integrity`, `fallback`) are well
structured with good documentation and test coverage.

## Critical Issue

The `ControlEvent` enum gained two new variants but the match arm in `src/bin/gui.rs` was not
updated. This is a clear oversight that prevents the codebase from compiling. This MUST be fixed
before any other work.

## Positive

- Constants for restart policy are clearly named and documented
- The `FallbackChain` design is clean and well-tested
- `ModelIntegrityChecker` correctly handles the four cases (Ok, Missing, Corrupt, NoChecksum)
- `MemoryPressureMonitor` only emits on state transitions, not repeatedly — correct design
- All new code avoids `.unwrap()` in production paths

## Concerns

1. The "crash recovery watcher" doesn't actually restart the pipeline — it notifies the caller.
   The spec says "wait backoff, restart" but the implementation says "emit event, let Swift handle it".
   This may be by design but should be clarified.

2. `sysctl` subprocess in `memory_pressure.rs` is a reliability risk under App Sandbox.

3. Required tests for restart event emission are missing.
