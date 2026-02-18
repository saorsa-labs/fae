# Quality Patterns Review — Phase 1.1 FFI Surface

## Reviewer: Quality Patterns Analyst

### Findings

**FINDING QP-1: [PASS] FFI lifecycle follows Rust FFI idioms correctly**
- `Box::into_raw` / `Box::from_raw` for opaque handle management ✓
- `CString::into_raw` / `CString::from_raw` for string ownership ✓
- Null-checks at all FFI entry points ✓
- `SAFETY` comments on all `unsafe` blocks ✓
Vote: PASS

**FINDING QP-2: [PASS] `#[unsafe(no_mangle)]` used correctly (Rust 2024 edition)**
The `#[unsafe(no_mangle)]` attribute is the correct form for Rust 2024. Older codebases use `#[no_mangle]` which is now deprecated. This is correct.
Vote: PASS

**FINDING QP-3: [HIGH] `#[allow(dead_code)]` on `log_level` — policy violation**
File: `src/ffi.rs:48`
This violates the zero-tolerance warning policy. Three options:
1. Remove the field (simplest)
2. Wire it to `tracing_subscriber::EnvFilter`
3. Use `_log_level` naming convention (field name prefixed with underscore)
Option 3 would remove the allow annotation while keeping the JSON field for future use. Option 1 is cleanest for Phase 1.1.
Vote: MUST FIX

**FINDING QP-4: [PASS] `NoopDeviceTransferHandler` used in FFI layer — correct choice for Phase 1.1**
Using the noop handler is explicitly called out in the phase plan. The real handler comes in Phase 1.3.
Vote: PASS

**FINDING QP-5: [PASS] `command_channel(32, event_capacity, handler)` — appropriate capacity**
32-command buffer is generous for the synchronous FFI use case.
Vote: PASS

**FINDING QP-6: [MEDIUM] `FaeEventCallback` type alias not used in `fae_core_set_event_callback` signature**
File: `src/ffi.rs:355`
Duplicates the fn type instead of using the alias. Minor but inconsistent.
Vote: SHOULD FIX

**FINDING QP-7: [PASS] Channel handler additions follow existing code patterns exactly**
The new `handle_conversation_inject_text` and `handle_conversation_gate_set` match the pattern of `handle_orb_flash`, `handle_capability_request`, etc. Consistent style.
Vote: PASS

### Summary
- CRITICAL: 0
- HIGH: 1 (QP-3 = same as CQ-1)
- MEDIUM: 1 (QP-6 = same as TS-1)
- LOW: 0
- PASS: 5
