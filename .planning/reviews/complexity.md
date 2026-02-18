# Complexity Review — Phase 1.1 FFI Surface

## Reviewer: Complexity Analyst

### Findings

**FINDING COMP-1: [PASS] `FaeRuntime` has 7 Mutex-wrapped fields — necessary complexity**
File: `src/ffi.rs:57-66`
The number of Mutex wrappers reflects the FFI constraint: each field must be independently lockable from any C-calling thread. This is not accidental complexity but required for thread safety. No refactor opportunity without sacrificing safety.
Vote: PASS

**FINDING COMP-2: [PASS] `drain_events` locking pattern is verbose but safe**
File: `src/ffi.rs:78-113`
Three sequential lock acquisitions (callback, user_data, event_rx) followed by the drain loop. Could be combined but the separate locks allow other threads to proceed. The verbosity is justified.
Vote: PASS

**FINDING COMP-3: [LOW] `fae_core_start` has 4 separate mutex lock calls for what is essentially one operation**
File: `src/ffi.rs:222-248`
```rust
let mut started = match rt.started.lock() {...};
if *started { return -1; }
let server = { let mut guard = match rt.server.lock() {...}; ... };
let join_handle = rt.tokio_rt.spawn(server.run());
if let Ok(mut guard) = rt.server_handle.lock() {...}
*started = true;
```
There's a TOCTOU gap: `started` is checked and set non-atomically (four separate locks). If two threads call `fae_core_start` concurrently, both could pass the `*started` check. While the header says "safe to call from any thread," concurrent double-start is technically a data race here. The server take() acts as a secondary guard, making the actual impact benign, but it's subtle.
Vote: SHOULD FIX (consolidate into single lock or document the secondary protection)

**FINDING COMP-4: [PASS] stdio bridge complexity is appropriate**
File: `src/host/stdio.rs`
Three-task pattern with Arc<Mutex<BufWriter>> is the standard tokio approach. No simpler correct design exists.
Vote: PASS

**FINDING COMP-5: [PASS] `parse_conversation_text` and `parse_gate_active` are clean single-responsibility parsers**
File: `src/host/channel.rs:623-642`
Well-factored, no unnecessary complexity.
Vote: PASS

### Summary
- CRITICAL: 0
- HIGH: 0
- MEDIUM: 0
- LOW: 1 (COMP-3)
- PASS: 4
