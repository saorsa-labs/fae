# Phase 1.5: Integration Testing + Latency Validation

## Objective

Full FFI lifecycle tests, latency microbenchmarks, and sandbox verification
for the embedded Rust core architecture.

## Tasks

### Task 1 — FFI ABI lifecycle tests (COMPLETE — pre-existing)

File: `tests/ffi_abi.rs`

6 tests covering:
- Null init returns null
- Full lifecycle: init → start → stop → destroy
- host.ping command roundtrip
- poll_event returns null when empty
- string_free(null) is safe no-op
- Event callback fires on device.go_home

### Task 2 — Latency microbenchmark harness (COMPLETE — pre-existing)

Files: `src/host/latency.rs`, `tests/native_latency_harness_v0.rs`

3 benchmark scenarios:
- noop_dispatch: in-process dispatch overhead
- channel_ipc_roundtrip: mpsc channel overhead
- uds_ipc_roundtrip: Unix domain socket overhead

All report ordered percentiles (p50 ≤ p95 ≤ p99).

### Task 3 — Sandbox/entitlements verification (COMPLETE)

File: `Entitlements.plist`

- App sandbox entitlement verified
- Network server comment updated for UDS socket (not Dioxus)
- In-process Rust verified by all host command tests passing

### Task 4 — Build verification (COMPLETE)

- cargo fmt: PASS
- cargo clippy -D warnings: PASS (zero warnings)
- cargo test --all-features: PASS (all tests green)
- FFI tests: 6/6 passed
- Latency tests: 3/3 passed
