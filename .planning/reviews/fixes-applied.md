# Fixes Applied — Phase 1.1 Review Iteration 1
**Date:** 2026-02-18

## MUST FIX Items — Applied

### Fix F-1: Removed `#[allow(dead_code)]` from `log_level`
File: `src/ffi.rs:48`
- Renamed field to `_log_level` (Rust convention for intentionally unused fields)
- Updated doc comment to explain it's reserved for Phase 1.3
- Eliminates the `#[allow(dead_code)]` attribute

### Fix F-2: Used `FaeEventCallback` alias in `fae_core_set_event_callback`
File: `src/ffi.rs:354`
- Changed `Option<unsafe extern "C" fn(*const c_char, *mut c_void)>` to `Option<FaeEventCallback>`
- Ensures nominal type consistency between alias definition and parameter usage

### Fix F-4: Added re-entrancy warning to Rust doc comment
File: `src/ffi.rs`
- Added "Re-entrancy warning" section to `fae_core_set_event_callback` doc comment
- Matches the warning already present in `include/fae.h`

## Build Verification
```
cargo clippy --no-default-features --all-targets -- -D warnings → CLEAN ✓
cargo fmt --all -- --check                                       → CLEAN ✓
cargo nextest run --no-default-features                          → 2127/2127 PASS ✓
```

## SHOULD FIX Items — Deferred

### F-3: Double-start test
Deferred to Phase 1.2 test hardening. The implementation correctly returns -1 via the `server.take()` guard.

### F-5: send_command before start behavior
Deferred. Behavior is caller-UB (blocking indefinitely). Will be addressed when adding timeout support in Phase 1.3.
