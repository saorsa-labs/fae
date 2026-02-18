# Code Quality Review — Phase 1.1 FFI Surface

## Reviewer: Code Quality

### Findings

**FINDING CQ-1: [MEDIUM] `#[allow(dead_code)]` violates zero-tolerance policy**
File: `src/ffi.rs:48`
```rust
#[allow(dead_code)]
log_level: Option<String>,
```
Either implement log_level wiring to tracing or remove the field. The current state parses user input and discards it silently.
Vote: MUST FIX

**FINDING CQ-2: [LOW] `drain_events` uses `yield_now()` before drain — race window**
File: `src/ffi.rs:290-291`
```rust
rt.tokio_rt.block_on(tokio::task::yield_now());
rt.drain_events();
```
`yield_now()` gives the server task one scheduling opportunity to emit events, but there's no guarantee all events from a command dispatch will be ready. Under load, a command might produce events that arrive after `drain_events` returns. This is a best-effort synchronization — acceptable for Phase 1.1 but should be documented as a known limitation.
Vote: PASS (documented limitation, acceptable for phase)

**FINDING CQ-3: [LOW] `FaeInitConfig` uses `#[serde(default)]` with `Option` fields — redundant**
File: `src/ffi.rs:44-52`
```rust
#[derive(Debug, Default, serde::Deserialize)]
#[serde(default)]
struct FaeInitConfig {
    log_level: Option<String>,
    event_buffer_size: Option<usize>,
}
```
`Option<T>` fields default to `None` without `#[serde(default)]`. The attribute is redundant when all fields are `Option<T>`. Minor nit.
Vote: PASS (harmless)

**FINDING CQ-4: [LOW] `string_to_c` swallows NUL-byte errors with null return**
File: `src/ffi.rs:137-142`
If a JSON response contains a NUL byte (extremely unlikely but possible in adversarial input), the function silently returns null, which callers interpret as "no result". Should be documented.
Vote: PASS (edge case, acceptable)

**FINDING CQ-5: [MEDIUM] `callback` and `FaeEventCallback` type alias diverge slightly**
File: `src/ffi.rs:41, 354-355`
```rust
pub type FaeEventCallback = unsafe extern "C" fn(event_json: *const c_char, user_data: *mut c_void);
// ...
callback: Option<unsafe extern "C" fn(*const c_char, *mut c_void)>,
```
The `fae_core_set_event_callback` parameter type is spelled out rather than using the `FaeEventCallback` alias. Should use the alias for consistency.
Vote: SHOULD FIX

**FINDING CQ-6: [PASS] Command routing additions are clean and consistent**
File: `src/host/channel.rs`
`handle_conversation_inject_text` and `handle_conversation_gate_set` follow existing handler patterns exactly. Parse helpers (`parse_conversation_text`, `parse_gate_active`) are well-factored.
Vote: PASS

**FINDING CQ-7: [PASS] stdio bridge design is clean**
File: `src/host/stdio.rs`
Three-task pattern (reader, event forwarder, server) is idiomatic tokio. Writer sharing via `Arc<Mutex<BufWriter>>` is correct.
Vote: PASS

### Summary
- CRITICAL: 0
- HIGH: 0
- MEDIUM: 2 (CQ-1 = same as EH-1, CQ-5)
- LOW: 0 (passing)
- PASS: 5
