# Error Handling Review — Phase 1.1 FFI Surface

## Reviewer: Error Handling Hunter

### Findings

**FINDING EH-1: [MEDIUM] `#[allow(dead_code)]` on `log_level` in FaeInitConfig**
File: `src/ffi.rs:48`
```rust
#[allow(dead_code)]
log_level: Option<String>,
```
The `log_level` field is parsed from JSON but never used. This suppresses a warning rather than implementing the feature. The field should either be removed or wired to `tracing_subscriber`. Using `#[allow(dead_code)]` violates zero-tolerance policy.
Vote: SHOULD FIX

**FINDING EH-2: [MEDIUM] Silent error swallowing in `drain_events`**
File: `src/ffi.rs:78-113`
Poisoned mutex guards in `drain_events()` are silently returned early via `return`. While this is an FFI boundary and panicking is unacceptable, there is no logging or signaling to indicate events were dropped. This could silently lose events.
Vote: SHOULD FIX

**FINDING EH-3: [LOW] `expect()` in `tests/host_command_channel_v0.rs`**
File: `tests/host_command_channel_v0.rs`
```rust
.expect("lock conversation text records")
.expect("lock gate set records")
```
These are in test code. Per project guidelines, `.expect()` is acceptable in tests. No action needed.
Vote: PASS

**FINDING EH-4: [HIGH] `fae_core_send_command` returns null on parse error — silent failure**
File: `src/ffi.rs:282-283`
```rust
let envelope: CommandEnvelope = match serde_json::from_str(json_str) {
    Ok(e) => e,
    Err(_) => return std::ptr::null_mut(),
};
```
Parse errors return null with no error detail. Callers (Swift) cannot distinguish null-on-error from null-on-OOM. The error return path for failed command serialization could provide an error JSON string instead of null.
Vote: SHOULD FIX

**FINDING EH-5: [LOW] `unwrap_or_else` in `src/bin/host_bridge.rs:22`**
File: `src/bin/host_bridge.rs:22`
```rust
.unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info"))
```
This is in a `main()` binary, not library code. Acceptable pattern for CLI error recovery. No action needed.
Vote: PASS

### Summary
- CRITICAL: 0
- HIGH: 1 (EH-4)
- MEDIUM: 2 (EH-1, EH-2)
- LOW: 0 (passing)
- PASS: 2
