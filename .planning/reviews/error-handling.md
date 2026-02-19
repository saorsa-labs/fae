# Error Handling Hunter Review — Iteration 2

## Grade: B+

## Status of Previous Findings

### RESOLVED: Build failure — FIXED
The `ControlEvent` match is now exhaustive.

### STILL PRESENT (SHOULD FIX): Mutex lock with `.map(|g| *g)` pattern
Same as before — silent swallow of poison errors in restart counter reads.
Still present but low-severity. Votes: 4/15.

### STILL PRESENT (SHOULD FIX): `mp_bridge_jh` detached
Still dropped without tracking. Low-severity. Votes: 4/15.

### STILL PRESENT (INFO): `run_sysctl_u64` spawns subprocess
Still present in `src/memory_pressure.rs:185`. Medium-severity but pre-existing.

## New Findings

### OK: New tests use explicit error handling
The two new tests (`clean_stop_does_not_emit_auto_restart_event` and
`unexpected_exit_emits_auto_restart_event`) use proper tokio timeout assertions
and do not rely on unwrap in production paths.

### OK: All error paths in new tests are verified
`tokio::time::timeout(...).await.expect(...)` is appropriate in `#[cfg(test)]`
context where `#[allow(clippy::expect_used)]` is set.

## Verdict: No new MUST FIX items. Previous SHOULD FIX items are low-severity carry-overs.
