# Phase 3.2: End-to-End Integration Tests

## Goal

Wire the onboarding phase advance to the real `FaeDeviceTransferHandler`, update
`query_onboarding_state` to include the current phase, and add comprehensive
integration tests for the full onboarding and JIT permission flow.

## Task List

### Task 1: Implement advance_onboarding_phase in FaeDeviceTransferHandler

The `FaeDeviceTransferHandler` currently uses the default trait impl for
`advance_onboarding_phase`, which always returns `OnboardingPhase::Welcome`.
Implement it to actually advance the phase stored in config and persist to disk.

Also update `query_onboarding_state` to include `"phase": current_phase.as_str()`
in the returned JSON.

File: `src/host/handler.rs`

Changes:
- Add `advance_onboarding_phase` impl that reads `onboarding_phase`, calls `advance()`,
  stores the new phase, saves to disk, and returns the new phase
- Update `query_onboarding_state` to include `"phase"` in the payload

### Task 2: Add onboarding handler unit tests

In `src/host/handler.rs` internal `#[cfg(test)]` module, add:
- `advance_onboarding_phase_cycles_through_phases` — Welcome → Permissions → Ready → Complete
- `advance_onboarding_phase_persists_to_disk`
- `query_onboarding_state_includes_phase`

File: `src/host/handler.rs`

### Task 3: Create tests/onboarding_lifecycle.rs

Full integration tests via the host command channel + real `FaeDeviceTransferHandler`:
- `onboarding_advance_cycles_through_all_phases` — Welcome → Permissions → Ready → Complete
- `onboarding_advance_persists_phase_to_disk`
- `onboarding_complete_after_full_advance_cycle`
- `onboarding_state_includes_phase_field`
- `onboarding_phase_resets_not_needed_stays_at_complete` — advance from Complete returns None/Complete

File: `tests/onboarding_lifecycle.rs` (NEW)

### Task 4: Add JIT capability integration tests

Extend `tests/capability_bridge_e2e.rs` with:
- `capability_request_jit_true_validates_and_succeeds`
- `capability_request_jit_false_also_validates_successfully`

These verify that the `jit` field passes through the full command channel with
the real handler correctly.

File: `tests/capability_bridge_e2e.rs`
