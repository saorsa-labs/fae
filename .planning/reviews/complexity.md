# Complexity Review

## Grade: C+

## Findings

### SHOULD FIX: `request_runtime_start` is too long

**File**: `src/host/handler.rs`

The method `request_runtime_start` has grown to approximately 300+ lines with the new
crash recovery watcher, device watcher, and memory pressure monitor all spawned inline.
This makes it very hard to read and reason about.

Each watcher spawn should be extracted to a private helper method:
- `fn spawn_restart_watcher(...)`
- `fn spawn_device_watcher(...)`
- `fn spawn_memory_pressure_monitor(...)`

### SHOULD FIX: Restart watcher inner logic is 80+ lines of inline async

The restart watcher async block in `request_runtime_start` spans ~80 lines including
counter management, backoff computation, and event emission. This should be a separate
`async fn` or method.

### OK: `FallbackChain::next_provider` is clear

The while-loop with early continue for exhausted providers is readable and correct.

### OK: `MemoryPressureMonitor::run` is clean

The select loop with threshold comparison is simple and well-structured.

### OK: `AudioDeviceWatcher::run` is simple

32 lines of clean polling loop. No complexity concerns.

### OK: `ModelIntegrityChecker::verify` is straightforward

Early returns for missing/no-checksum cases, then hash comparison. Clear flow.
