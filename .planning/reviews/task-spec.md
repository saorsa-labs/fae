# Task Assessor Review — Phase 5.2 Task 1

## Task: Pipeline Crash Recovery — Auto-Restart with Backoff

## Acceptance Criteria Assessment

| # | Criterion | Status | Notes |
|---|-----------|--------|-------|
| 1 | Add `restart_policy` to handler: max 5 attempts, delays [1,2,4,8,16]s | PASS | `MAX_RESTART_ATTEMPTS=5`, `RESTART_BACKOFF_SECS=[1,2,4,8,16]` |
| 2 | Monitor pipeline JoinHandle in watcher task; detect unexpected exit | PARTIAL | Watcher waits for cancellation token, not JoinHandle. Relies on `clean_exit_flag`. Different mechanism than spec. |
| 3 | On unexpected exit: update `PipelineState::Error`, wait backoff, restart | PARTIAL | Updates state to Error but does NOT wait backoff or restart — only emits event and signals Swift side to call `request_runtime_start` again. No actual auto-restart. |
| 4 | On clean stop (cancel token): do NOT restart | PASS | `clean_exit_flag` check prevents restart on clean stop |
| 5 | Emit `pipeline.control` event with `"action": "auto_restart"` + attempt count | PASS | Emitted correctly |
| 6 | Reset backoff counter on successful run > 30s | PASS | `RESTART_UPTIME_RESET_SECS = 30` |
| 7 | Add `restart_count: u32` and `last_restart_at: Option<Instant>` to handler state | PASS | Both fields present as `Arc<Mutex<...>>` |
| 8 | Tests: verify restart emits event, verify clean stop does not restart | FAIL | These tests are NOT present |

## Additional Tasks Partially Implemented in This Commit

The commit includes work beyond task 1:
- **Task 2 (Model Integrity)**: `src/model_integrity.rs` — COMPLETE
- **Task 3 (Audio Device Hot-Swap)**: `src/audio/device_watcher.rs` — COMPLETE
- **Task 4 (Network Resilience)**: `src/llm/fallback.rs`, `network_timeout_ms` in config — COMPLETE

## Critical Gap

Criterion 3 says "wait backoff, restart". The implementation only EMITS an event requesting
Swift to restart. The actual restart logic is delegated to the Swift caller. This may be
by design (since the handler is also the restart entry point), but it means the spec
criterion "restart" is not fully self-contained in the Rust layer.

## Verdict: PARTIAL PASS

Core mechanism is in place. Missing required unit tests for restart behavior. The "auto-restart"
is actually "notify caller to restart" rather than self-healing.
