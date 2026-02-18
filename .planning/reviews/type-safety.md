# Type Safety Review — Phase 1.1 FFI Surface

## Reviewer: Type Safety Analyst

### Findings

**FINDING TS-1: [HIGH] `FaeEventCallback` type alias not used for `set_event_callback` parameter**
File: `src/ffi.rs:354-355`
```rust
callback: Option<unsafe extern "C" fn(*const c_char, *mut c_void)>,
```
vs the defined alias:
```rust
pub type FaeEventCallback = unsafe extern "C" fn(event_json: *const c_char, user_data: *mut c_void);
```
The parameter should use `Option<FaeEventCallback>` for consistency and to ensure the C header's typedef and Rust's type match. Currently they match structurally but not nominally — a future refactor could diverge them.
Vote: MUST FIX

**FINDING TS-2: [MEDIUM] `FaeRuntime.callback` stores `Option<FaeEventCallback>` but field type is copy of the fn type**
File: `src/ffi.rs:61`
```rust
callback: Mutex<Option<FaeEventCallback>>,
```
This is actually correct (uses the alias). See TS-1 for the parameter mismatch.
Vote: PASS

**FINDING TS-3: [LOW] `i32` return from `fae_core_start` — C header uses `int32_t`**
File: `src/ffi.rs:215`, `include/fae.h:71`
Rust `i32` and C `int32_t` are both guaranteed 32-bit signed. The mapping is correct. However, `int` (not `int32_t`) is the conventional return type for C functions returning 0/-1 error codes. Minor style point.
Vote: PASS

**FINDING TS-4: [PASS] `FaeCoreHandle = void*` typedef is clean**
The opaque handle pattern is idiomatic and correct for C ABI.
Vote: PASS

**FINDING TS-5: [PASS] `unsafe impl Send + Sync for FaeRuntime` with SAFETY comment**
File: `src/ffi.rs:68-72`
The SAFETY comment correctly identifies that all mutable state is Mutex-protected and that the raw pointer lifetime is caller-managed. The unsafety is justified.
Vote: PASS

**FINDING TS-6: [PASS] `borrow_runtime` lifetime annotation is intentionally unconstrained**
The `'a` lifetime in `borrow_runtime<'a>` is a standard FFI idiom where the caller's safety contract guarantees validity. Acceptable.
Vote: PASS

### Summary
- CRITICAL: 0
- HIGH: 1 (TS-1)
- MEDIUM: 0
- LOW: 0
- PASS: 5
