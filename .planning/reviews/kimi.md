# Kimi K2 External Review

## Grade: B-

## Summary

The implementation is mostly correct but the non-exhaustive match in `gui.rs` is a blocking
compiler error that must be resolved. The restart watcher mechanism is sound but has subtle
issues with how it interacts with the cancellation token hierarchy.

## Key Findings

### Critical
- `src/bin/gui.rs:4943`: Non-exhaustive `ControlEvent` match. `AudioDeviceChanged` and
  `DegradedMode` variants missing. BLOCKS BUILD.

### Important
- The restart watcher monitors a child cancellation token, not the pipeline JoinHandle.
  This means it fires whenever the parent token is cancelled (including clean stops) and
  relies on `clean_exit_flag` to distinguish. This is fragile — if the flag is set after
  a delay, the watcher could race.

- `run_sysctl_u64` spawns a subprocess. Under macOS App Sandbox the `com.apple.security.temporary-exception.sbpl`
  entitlement is needed for subprocess execution. Fae likely has this but it's worth verifying.

### Minor
- `mp_bridge_jh` drop without tracking is a minor leak risk
- Missing acceptance-criterion tests for restart event verification

## Verdict

Fix the build error first. Address test gaps before merging.
