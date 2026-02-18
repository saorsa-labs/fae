# Code Simplifier Review — Phase 1.1 FFI Surface

## Reviewer: Code Simplifier

### Findings

**FINDING SIMP-1: [SHOULD FIX] Replace inlined fn type with FaeEventCallback alias**
File: `src/ffi.rs:354-355`
Current:
```rust
callback: Option<unsafe extern "C" fn(*const c_char, *mut c_void)>,
```
Simplified:
```rust
callback: Option<FaeEventCallback>,
```
Two characters versus a complex inline type. Use the alias.
Vote: SHOULD FIX

**FINDING SIMP-2: [SHOULD FIX] Remove `log_level` field or prefix with `_`**
File: `src/ffi.rs:48-49`
Current:
```rust
#[allow(dead_code)]
log_level: Option<String>,
```
Simplified option A (remove):
```rust
// (field deleted)
```
Simplified option B (prefix underscore, keeps JSON field parsing):
```rust
_log_level: Option<String>,
```
Option A is cleaner for Phase 1.1. Option B preserves forward compatibility.
Vote: MUST FIX

**FINDING SIMP-3: [PASS] `drain_events` locking pattern cannot be simplified without UB**
The sequential separate-lock approach is necessary. No simplification available without introducing lock ordering issues.
Vote: PASS

**FINDING SIMP-4: [PASS] `string_to_c` helper is minimal and clear**
Vote: PASS

**FINDING SIMP-5: [PASS] `cstr_to_str` helper is minimal and clear**
Vote: PASS

**FINDING SIMP-6: [PASS] `borrow_runtime` helper is minimal and clear**
Vote: PASS

**FINDING SIMP-7: [PASS] New channel handlers follow DRY principle**
The emit_event + ok response pattern is consistent with all other handlers.
Vote: PASS

### Summary
- MUST FIX: 1 (SIMP-2 = same as EH-1/CQ-1/QP-3)
- SHOULD FIX: 1 (SIMP-1 = same as CQ-5/TS-1/QP-6)
- PASS: 5
