# Phase 1.1: FFI Surface — C ABI Boundary for Embedded Rust Core

## Objective

Create `src/ffi.rs` with a thin C ABI (`extern "C"`) surface that wraps
`HostCommandServer` and a tokio runtime behind an opaque `FaeRuntime` handle.
Add `crate-type = ["staticlib", "lib"]` so the crate compiles to both a static
library (for Swift to link) and a normal Rust lib (for integration tests).
Generate a C header with `cbindgen`.

This phase uses `NoopDeviceTransferHandler` (real handler is Phase 1.3).

## Quality gates

```bash
cargo fmt --all -- --check
cargo clippy --no-default-features --all-targets -- -D warnings
cargo test --no-default-features
```

---

## Task 1 — Write failing FFI lifecycle test (RED)
Files: tests/ffi_lifecycle.rs (NEW)
Tests: init/start/send_command/poll_event/stop lifecycle + event callback

## Task 2 — Add [lib] section and src/ffi.rs skeleton
Files: Cargo.toml, src/lib.rs, src/ffi.rs (NEW)
Add crate-type = ["staticlib", "lib"], create ffi module with stub signatures

## Task 3 — Implement FaeRuntime struct and fae_core_init
Files: src/ffi.rs
FaeRuntime owns tokio Runtime + HostCommandClient + Server + broadcast Rx + callback slot

## Task 4 — Implement fae_core_start and fae_core_stop
Files: src/ffi.rs
Start spawns server + event dispatcher, stop drops handle via Box::from_raw

## Task 5 — Implement fae_core_send_command
Files: src/ffi.rs
Parse CommandEnvelope, block_on client.send(), serialize response, CString::into_raw

## Task 6 — Implement fae_string_free
Files: src/ffi.rs
Null-check then CString::from_raw to reclaim

## Task 7 — Implement fae_core_poll_event
Files: src/ffi.rs
event_rx.try_recv() — non-blocking, return null on empty

## Task 8 — Implement fae_core_set_event_callback
Files: src/ffi.rs
Store callback + context in Arc<Mutex>, dispatcher task invokes on events

## Task 9 — Add FfiError type and FaeInitConfig
Files: src/ffi.rs
#[repr(i32)] error enum with thiserror, configurable init params

## Task 10 — Create cbindgen.toml and generate include/libfae.h
Files: cbindgen.toml (NEW), include/libfae.h (GENERATED), justfile

## Task 11 — Add ABI-level tests via extern "C" declarations
Files: tests/ffi_abi.rs (NEW)
Call through C ABI to catch calling-convention issues

## Task 12 — Verify staticlib compiles for macOS arm64
Files: justfile
Add build-staticlib recipes, verify symbols with nm
