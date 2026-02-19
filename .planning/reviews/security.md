# Security Scanner Review

## Grade: B+

## Findings

### SHOULD FIX: `sysctl` subprocess in memory pressure monitor

**File**: `src/memory_pressure.rs:185`

Spawning `sysctl` as a subprocess has security implications under App Sandbox.
The sandbox may block `Process::new("sysctl")`. If it returns garbage data, the
pressure computation could be wrong. Use `sysctl` via libc bindings or the `sysctl` crate
for safe in-process calls.

### INFO: Restart loop DoS potential

The crash recovery is bounded to `MAX_RESTART_ATTEMPTS = 5`. This prevents runaway restart
storms. The `RESTART_UPTIME_RESET_SECS = 30` reset is reasonable. No security concern.

### INFO: Checksum comparison is case-insensitive

`src/model_integrity.rs:81`:
```rust
if actual.eq_ignore_ascii_case(expected)
```

Case-insensitive comparison for hex digests is fine and correct.

### INFO: No secrets in event payloads

Reviewed all `serde_json::json!` payloads emitted by the new code. None contain sensitive data
(keys, passwords, file paths with user-specific content). Device names are limited to display
names. Memory levels are numeric. All safe.

### INFO: AtomicBool ordering

`clean_exit_flag` uses `Ordering::SeqCst` for both store and load, which is the strongest
ordering. Correct for a synchronization flag between tasks.

### OK: No unsafe code introduced in this task

All new files (`device_watcher.rs`, `memory_pressure.rs`, `model_integrity.rs`, `fallback.rs`)
contain no `unsafe` blocks.
