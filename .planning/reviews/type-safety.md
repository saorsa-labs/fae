# Type Safety Review

## Grade: B+

## Findings

### MUST FIX: `ControlEvent` match is non-exhaustive in `src/bin/gui.rs`

**File**: `src/bin/gui.rs:4943`

Two new enum variants are not covered. This is a type-safety violation — the compiler
correctly rejects non-exhaustive matches. The fix is to add wildcard or explicit arms
for `AudioDeviceChanged` and `DegradedMode`.

### OK: `Arc<Mutex<T>>` sharing is consistent

All fields that need sharing between tasks use `Arc<Mutex<T>>`. Fields that don't need
sharing remain plain `Mutex<T>`. The distinction is clear and correct.

### OK: `AtomicBool` memory ordering

`clean_exit_flag.store(true, Ordering::SeqCst)` and `.load(Ordering::SeqCst)` use
the strongest ordering, which is correct for a synchronization flag between an async
task and the watcher.

### OK: Broadcast channel type parameters

`broadcast::channel::<MemoryPressureEvent>(4)` — buffer size 4 is appropriate for
low-frequency events (every 30s). The `Lagged` error is handled in the bridge loop.

### OK: `mpsc::UnboundedSender<GateCommand>` in `AudioDeviceWatcher`

Using `UnboundedSender` is appropriate here since the pipeline can always consume
device change commands faster than they're produced (at most every 2s).

### SHOULD FIX: `pipeline_mode: Mutex<PipelineMode>` uses fully-qualified path

**File**: `src/host/handler.rs`

```rust
pipeline_mode: Mutex<crate::pipeline::coordinator::PipelineMode>,
```

Should use a use-statement at the top of the file or within the impl block for clarity.
Not a type-safety issue but a style concern.
