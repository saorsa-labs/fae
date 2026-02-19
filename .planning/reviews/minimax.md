# MiniMax External Review

## Grade: B

## Summary

Good architectural additions for production resilience. The code follows existing patterns
in the codebase. The build failure and missing tests are the main gaps.

## Findings

### MUST FIX
1. **`src/bin/gui.rs`**: Non-exhaustive ControlEvent match. Two new variants uncovered.
   This is a compile-time regression introduced by this task.

2. **Missing required tests**: The plan explicitly requires tests for:
   - restart emits `auto_restart` event
   - clean stop does NOT trigger restart
   These are missing.

### SHOULD FIX
1. `run_sysctl_u64` uses subprocess. Should use `libc::sysctlbyname` for App Sandbox safety.

2. The memory pressure bridge task (`mp_bridge_jh`) is detached with `drop()` without
   being tracked. If the parent lock fails, it leaks.

### STYLE
1. The inline async blocks in `request_runtime_start` (watcher, bridge) should be
   extracted to helper functions for readability.

2. Consider using `let else` syntax where possible for cleaner guard patterns.

## Positive
- `FallbackChain` is cleanly designed with clear separation of transient vs permanent errors
- `ModelIntegrityChecker` handles all cases including case-insensitive comparison
- All new public APIs are documented with examples
