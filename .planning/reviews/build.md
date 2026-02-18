# Build Validation Report
**Date**: 2026-02-18
**Mode**: gsd (phase 1.2)

## Results

| Check | Status | Details |
|-------|--------|---------|
| cargo check --all-features --all-targets | PASS | Finished dev profile in 21.06s, zero warnings |
| cargo clippy --all-features --all-targets -- -D warnings | PASS | Finished dev profile in 16.47s, zero warnings |
| cargo nextest run --all-features | PASS | 2192 passed, 4 skipped, 1 leaky (pre-existing) |
| cargo fmt --all -- --check | PASS | No formatting issues |
| swift build --package-path native/macos/FaeNativeApp -c release | PASS | Build complete in 0.10s, zero errors, zero warnings |
| swift build --package-path native/macos/FaeNativeApp (debug) | PASS | Build complete in 2.25s |

## Errors/Warnings
None. All checks passed cleanly.

## Notes
- libfae.a present at both target/debug/libfae.a and target/aarch64-apple-darwin/release/libfae.a
- All 8 FFI symbols confirmed exported via nm: _fae_core_init, _fae_core_start, _fae_core_send_command, _fae_core_poll_event, _fae_core_set_event_callback, _fae_core_stop, _fae_core_destroy, _fae_string_free

## Grade: A
