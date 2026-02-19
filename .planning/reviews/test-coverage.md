# Test Coverage Review

## Grade: B+

## Findings

### MUST FIX: No test verifying restart event emission (acceptance criterion)

**Plan Task 1 Acceptance Criteria**: "Tests: verify restart emits event, verify clean stop does not restart"

The plan explicitly requires these tests. While the crash recovery watcher is implemented, no
tests in the changed files verify:
1. That an unexpected pipeline exit causes an `auto_restart` event to be emitted
2. That a clean stop (cancel token) does NOT trigger restart

The `src/host/handler.rs` watcher logic is not unit-tested. The watcher body is complex async
logic and should have integration tests.

### OK: `AudioDeviceWatcher` has adequate tests

- `watcher_stops_on_cancel` — correct
- `watcher_stops_when_gate_tx_closed` — correct (though limited: can't force real device change)
- `restart_audio_gate_command_has_device_name` — tests the command struct
- `restart_audio_gate_command_none_device` — tests None variant

### OK: `MemoryPressureMonitor` has threshold tests

- `pressure_level_normal_above_warning`
- `pressure_level_warning_at_threshold`
- `pressure_level_warning_between_thresholds`
- `pressure_level_critical_at_threshold`
- `pressure_level_critical_below_threshold`
- `available_memory_mb_returns_nonnegative`
- `monitor_stops_on_cancel`
- `pressure_event_carries_level_and_mb`

### OK: `ModelIntegrityChecker` has comprehensive tests

- `missing_file_returns_missing`
- `no_checksum_returns_no_checksum`
- `correct_checksum_returns_ok`
- `wrong_checksum_returns_corrupt`
- `case_insensitive_checksum_comparison`
- `integrity_result_display`

### OK: `FallbackChain` has full coverage

8 tests covering all major paths including transient/permanent failures, ordering, exhaustion.

### SHOULD ADD: Test that `run_sysctl_u64` handles sandbox restrictions gracefully

The macOS memory check uses a subprocess. No test verifies graceful degradation when
`sysctl` is unavailable (e.g., returns None on error).
