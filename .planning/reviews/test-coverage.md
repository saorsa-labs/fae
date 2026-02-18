# Test Coverage Review — Phase 1.1 FFI Surface

## Reviewer: Test Coverage Analyst

### Findings

**FINDING TC-1: [PASS] FFI ABI tests cover all 8 extern "C" functions**
File: `tests/ffi_abi.rs`
- fae_core_init: null case + valid case ✓
- fae_core_start: success path ✓
- fae_core_send_command: round-trip ✓
- fae_core_poll_event: null-when-empty ✓
- fae_core_set_event_callback: callback-fires test ✓
- fae_core_stop: tested in lifecycle test ✓
- fae_core_destroy: tested in lifecycle test ✓
- fae_string_free: null no-op test ✓
Vote: PASS

**FINDING TC-2: [MEDIUM] Missing test: double-start returns -1**
File: `tests/ffi_abi.rs`
No test verifies that calling `fae_core_start` twice returns -1 on the second call. The implementation handles this but it's unverified at the ABI level.
Vote: SHOULD FIX

**FINDING TC-3: [MEDIUM] Missing test: send_command on unstarted runtime**
File: `tests/ffi_abi.rs`
No test calls `fae_core_send_command` before `fae_core_start`. The behavior is undefined (would block forever or return null). Should either document or test.
Vote: SHOULD FIX

**FINDING TC-4: [LOW] Missing test: fae_core_poll_event after a command that produces an event**
File: `tests/ffi_abi.rs`
The poll_event path with an actual event is not tested at the ABI level (the callback path is tested, but not poll). Minor gap.
Vote: SHOULD FIX (low priority)

**FINDING TC-5: [PASS] Channel handler tests are thorough**
File: `src/host/channel.rs` (unit tests) + `tests/host_command_channel_v0.rs`
6 unit tests + 7 integration tests for conversation commands. Tests cover success, empty input, missing fields, and false-value cases.
Vote: PASS

**FINDING TC-6: [PASS] stdio bridge unit tests cover parse roundtrip**
File: `src/host/stdio.rs`
3 unit tests verifying parse-error response structure and JSON roundtrip. Adequate for the module's scope.
Vote: PASS

**FINDING TC-7: [LOW] No test for `fae_core_destroy(null)` no-op at ABI level**
File: `tests/ffi_abi.rs`
The null-destroy no-op is documented but not explicitly tested through the ABI.
Vote: SHOULD FIX (low priority)

### Summary
- CRITICAL: 0
- HIGH: 0
- MEDIUM: 2 (TC-2, TC-3)
- LOW: 2 (TC-4, TC-7)
- PASS: 4
