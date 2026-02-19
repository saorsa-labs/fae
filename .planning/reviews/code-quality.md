# Code Quality Review

## Grade: B

## Findings

### MUST FIX: New `ControlEvent` variants not handled in `src/bin/gui.rs`

**File**: `src/bin/gui.rs:4953`

The match arm handling `ControlEvent` in the GUI event loop does not cover
`AudioDeviceChanged` and `DegradedMode`. This is a direct compile error.

### SHOULD FIX: Redundant Arc clones in `request_runtime_start`

**File**: `src/host/handler.rs`

The method clones multiple `Arc<Mutex<...>>` fields to pass to the restart watcher and
then clones them again for other tasks. The pattern is consistent but verbose. This is
acceptable as-is but worth noting.

### SHOULD FIX: `dev.description().ok().map(|d| d.name().to_owned())`

**File**: `src/audio/device_watcher.rs:98-100`

```rust
dev.description()
    .ok()
    .map(|d| d.name().to_owned())
```

`DeviceTrait::description()` returns `Result<DeviceDescription, DevicesError>`. This chains
are readable but `d.name()` returns `&str`, so `to_owned()` is correct. Minor: could use
`and_then` style for clarity.

### OK: Constants are well-named

`RESTART_BACKOFF_SECS`, `MAX_RESTART_ATTEMPTS`, `RESTART_UPTIME_RESET_SECS` are clearly named
and documented. `WARNING_THRESHOLD_MB`, `CRITICAL_THRESHOLD_MB` are well-defined public constants.

### OK: New modules are properly structured

All new files have module-level doc comments and proper `pub`/`pub(crate)` visibility.
