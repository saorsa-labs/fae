# Progress Log

## Phase 1.1: FFI Surface

- [x] Task 1-2: src/ffi.rs skeleton + Cargo.toml [lib] crate-type
- [x] Task 3: FaeRuntime struct + fae_core_init
- [x] Task 4: fae_core_start / fae_core_stop
- [x] Task 5: fae_core_send_command (CommandEnvelope → ResponseEnvelope round-trip)
- [x] Task 6: fae_string_free (null-safe CString reclaim)
- [x] Task 7: fae_core_poll_event (non-blocking broadcast try_recv)
- [x] Task 8: fae_core_set_event_callback (synchronous dispatch during send_command)
- [x] Task 9: FaeInitConfig serde struct
- [x] Task 10: include/fae.h C header with full documentation
- [x] Task 11: tests/ffi_abi.rs — 6 ABI-level tests, all passing
- [x] Task 12: justfile staticlib recipes + nm symbol verification (8/8 symbols)
- [ ] Phase review pending
