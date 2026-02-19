# Code Simplifier Review

## Grade: B-

## Findings

### SHOULD FIX: Restart counter read duplicated

**File**: `src/host/handler.rs`

The restart watcher reads `restart_count_watcher.lock().map(|g| *g).unwrap_or(MAX_RESTART_ATTEMPTS)`
twice (once to check the limit, once to compute `new_attempt`). This could be a single read.

### SHOULD FIX: Memory pressure bridge loop could use a function

The `mp_bridge_jh` async block (40+ lines) is spawned inline. This should be extracted
to a module-level function or method for readability:

```rust
async fn run_memory_pressure_bridge(
    mut rx: broadcast::Receiver<MemoryPressureEvent>,
    event_tx: broadcast::Sender<EventEnvelope>,
    cancel: CancellationToken,
)
```

### SHOULD FIX: `serde_json::json!` for level string could use `PressureLevel`'s Display

Instead of a match to get `"normal"/"warning"/"critical"` strings, add a `Display` impl
on `PressureLevel` and use `format!("{}", ev.level)`.

### OK: `FallbackChain` internal helper extracted correctly

The per-provider state lookup in `next_provider` is clean.

### OK: `current_default_device_name` is a free function

Good separation — the polling loop delegates device name retrieval to a testable free function.

### INFO: `restart_count_watcher.lock().map(|g| *g).unwrap_or(...)` pattern

This appears 3 times. A helper closure or function would reduce repetition.
