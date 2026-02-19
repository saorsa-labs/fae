# Quality Patterns Review

## Grade: B

## Findings

### MUST FIX: `mp_bridge_jh` is silently dropped

**File**: `src/host/handler.rs`

```rust
if let Ok(mut guard) = self.memory_pressure_handle.lock() {
    drop(mp_bridge_jh);  // ← task is detached without being tracked
    *guard = Some(mp_monitor_jh);
}
```

The bridge task is detached. If the lock fails (poisoned mutex), the bridge task is leaked
and never cleaned up. Both the monitor and bridge handles should be tracked.

### SHOULD FIX: Cancellation token child scoping

The restart watcher uses `token.child_token()` but the parent token (`token`) is the same
one used for pipeline cancellation. When `request_runtime_stop` cancels the parent token,
the restart watcher fires. This is intentional but fragile: if the token hierarchy changes,
the watcher may fire at wrong times. The watcher should observe the pipeline JoinHandle
directly rather than the cancellation token.

### OK: Proper cleanup in `request_runtime_stop`

The stop method now aborts the restart watcher, device watcher, and memory pressure handles
(based on the diff showing the new abort calls). Cleanup is consistent.

### OK: `AudioDeviceWatcher` uses owned `CancellationToken`

The watcher owns its token (moved in via `new()`). Cancellation is unambiguous.

### OK: `FallbackChain` is pure value type (no async)

No shared state, no synchronization needed. Clean design.

### OK: `broadcast::channel` buffer size is appropriate

Buffer of 4 for memory pressure events is fine given the 30s poll interval.

### SHOULD FIX: `if let Ok(...)` chains on mutex locks in stop handler can silently skip

Several places in stop code use:
```rust
if let Ok(mut guard) = self.restart_watcher_handle.lock()
    && let Some(jh) = guard.take()
{
    jh.abort();
}
```

If the mutex is poisoned, the abort is silently skipped and the task runs forever.
Use `unwrap_or_else` or log on poison.
