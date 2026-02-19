# GLM-4.7 External Review

## Grade: B

## Summary

Well-structured addition of resilience infrastructure. The main blocker is the build failure
from the non-exhaustive pattern match.

## Findings

### CRITICAL (Block)
1. `src/bin/gui.rs:4943` — Missing match arms for `ControlEvent::AudioDeviceChanged` and
   `ControlEvent::DegradedMode`. Compile error E0004.

### IMPORTANT
1. The crash watcher semantics: the spec says "auto-restart with backoff" but the code
   emits an event asking the caller to restart. For an embedded library (libfae), the
   caller is Swift which must observe this event and call `request_runtime_start()` again.
   This is indirect but may be the right architecture. Needs documentation clarification.

2. Memory pressure detection spawns `sysctl` process. For App Sandbox compliance this
   should use `sysctlbyname()` via FFI or the `sysctl` crate.

### MINOR
1. `pipeline_mode` field has no doc comment in handler struct
2. The `let` chain `if let Ok(...) && let Some(jh) = ...` is Rust 2024 syntax — confirm
   MSRV is compatible (Rust 1.64+ for `let` chains, actually 1.88 for full stability)

## Verdict

Fix the build error. Consider replacing the `sysctl` subprocess with an in-process call.
