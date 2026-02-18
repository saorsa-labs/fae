# Security Review — Phase 1.1 FFI Surface

## Reviewer: Security Scanner

### Findings

**FINDING SEC-1: [HIGH] Double-free risk on `fae_core_destroy` called twice**
File: `src/ffi.rs:408-415`
```rust
pub unsafe extern "C" fn fae_core_destroy(handle: *mut c_void) {
    if handle.is_null() { return; }
    let _ = unsafe { Box::from_raw(handle as *mut FaeRuntime) };
}
```
The function accepts null as a no-op but has no protection against double-free. If a caller passes the same non-null handle twice, UB occurs. The header comment says "Must not be called more than once" but this is only enforced by documentation, not code. For a public C ABI, this is a safety gap. Consider poisoning the handle after first destroy (set to a sentinel value) — but since the caller owns the pointer variable, this cannot be done from Rust. At minimum, the safety contract should be more prominent in the header.
Vote: SHOULD FIX (documentation + stronger header warning)

**FINDING SEC-2: [MEDIUM] `callback_user_data` is `*mut c_void` behind Mutex — cross-thread use**
File: `src/ffi.rs:62`
The raw pointer `*mut c_void` is stored in a `Mutex` and accessed from any thread calling `drain_events`. While this is documented in the SAFETY comments, the callback itself could be invoked from a tokio worker thread that is different from the Swift UI thread. Swift's Main Actor pattern may not be safe here if the user_data points to Swift objects. The header re-entrancy warning covers the deadlock case, but the thread-safety of the user_data object is not addressed.
Vote: SHOULD FIX (header documentation)

**FINDING SEC-3: [LOW] `cstr_to_str` lifetime annotation `'a` is technically unsound**
File: `src/ffi.rs:125`
```rust
unsafe fn cstr_to_str<'a>(ptr: *const c_char) -> Option<&'a str>
```
The `'a` lifetime is unbounded — the returned reference is tied to nothing concrete. This is idiomatic for FFI helpers but a reviewer should note: if the C string is freed or mutated by the caller during the reference's use, UB occurs. All call sites appear to use the result immediately (not stored), which is safe in practice.
Vote: PASS (by-design FFI pattern, well-documented)

**FINDING SEC-4: [MEDIUM] No version field in FFI ABI — future ABI evolution risk**
File: `include/fae.h`
The C header exposes 8 functions with no versioning mechanism. If the ABI changes in Phase 1.3 (real handler), callers compiled against an old header will link silently to incompatible symbols. Recommend a `FAE_ABI_VERSION` constant or symbol versioning.
Vote: SHOULD FIX (minor, forward-looking)

**FINDING SEC-5: [LOW] `send_command` blocks the calling thread with `block_on`**
File: `src/ffi.rs:286`
```rust
let response = rt.tokio_rt.block_on(rt.client.send(envelope));
```
If called from a tokio runtime's thread, this would panic. However, since this is a C FFI boundary, the caller is Swift — not a tokio thread. Safe as designed.
Vote: PASS

### Summary
- CRITICAL: 0
- HIGH: 1 (SEC-1)
- MEDIUM: 2 (SEC-2, SEC-4)
- LOW: 0 (passing)
- PASS: 2
