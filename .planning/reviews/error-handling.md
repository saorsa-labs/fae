# Error Handling Hunter Review

## Grade: B

## Findings

### MUST FIX: Mutex lock with `.map(|g| *g)` can silently swallow poison errors

**File**: `src/host/handler.rs`

In the restart watcher:
```rust
let attempt = restart_count_watcher
    .lock()
    .map(|g| *g)
    .unwrap_or(MAX_RESTART_ATTEMPTS);
```

`Mutex::lock()` returns `Result<MutexGuard, PoisonError>`. Using `.map()` here treats the error
case silently — if the mutex is poisoned, `attempt` gets `MAX_RESTART_ATTEMPTS` (giving up)
rather than reporting the error. Same pattern used for `restart_count_watcher.lock()` in multiple
places. Prefer explicit `ok()` with a comment explaining the fallback behavior.

### MUST FIX: `mp_bridge_jh` is dropped without being stored or awaited

**File**: `src/host/handler.rs`

```rust
if let Ok(mut guard) = self.memory_pressure_handle.lock() {
    // Detach bridge (cancelled by token); store monitor for explicit abort.
    drop(mp_bridge_jh);
    *guard = Some(mp_monitor_jh);
}
```

The bridge task is detached with `drop(mp_bridge_jh)`. If cancellation of the token doesn't
work correctly (e.g., the select branch never fires), this task becomes a ghost. The comment
says "cancelled by token" but the token used is `memory_pressure_token.clone()`, which is only
cancelled when the handler is stopped. If stop is not called, the bridge runs forever.

### SHOULD FIX: Restart watcher fires on handler token cancellation, not pipeline exit

The watcher waits for `restart_watcher_token.cancelled()` which fires when the parent token is
cancelled (i.e., `request_runtime_stop`). This means a clean stop also reaches the watcher body
before checking `clean_exit_flag`. The `clean_exit_flag` check at the start of the watcher
is correct but may have a race: the pipeline task may not have had time to set the flag before
the watcher proceeds. An `Ordering::SeqCst` fence is used, which is correct.

### SHOULD FIX: `run_sysctl_u64` spawns a subprocess

**File**: `src/memory_pressure.rs:185`

```rust
let output = std::process::Command::new("sysctl").arg("-n").arg(name).output().ok()?;
```

This spawns a subprocess on every poll (every 30s). Under macOS App Sandbox, `Process` may be
restricted. This is fragile and could fail silently (returning 0, triggering false pressure events).
The comment says "subprocess-free" but the implementation IS a subprocess.

### OK: All new files use proper `?` propagation

`src/model_integrity.rs` and `src/llm/fallback.rs` use proper `Result` types and `?` operator.
No `unwrap()` in production code paths (only in `#[cfg(test)]` modules with `#[allow]`).

### OK: `AudioDeviceWatcher` handles send failure gracefully

```rust
if self.gate_tx.send(cmd).is_err() {
    warn!("audio device watcher: gate_tx closed, stopping");
    break;
}
```
