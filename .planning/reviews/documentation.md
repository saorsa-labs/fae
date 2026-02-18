# Documentation Review — Phase 1.1 FFI Surface

## Reviewer: Documentation Auditor

### Findings

**FINDING DOC-1: [PASS] Module-level doc comment in `src/ffi.rs` is excellent**
The lifecycle diagram, thread-safety statement, and function list are clear and accurate.
Vote: PASS

**FINDING DOC-2: [PASS] `include/fae.h` header is production-quality**
Memory ownership table, re-entrancy warning, lifecycle example — all accurate and useful for Swift consumers.
Vote: PASS

**FINDING DOC-3: [MEDIUM] Re-entrancy warning in `fae.h` should also be in Rust `ffi.rs` doc**
File: `include/fae.h:31-35`
The re-entrancy warning (do not call fae_core_* from within the callback) exists in the C header but not in the Rust source doc comment for `fae_core_set_event_callback`. The authoritative contract should be in both places.
Vote: SHOULD FIX

**FINDING DOC-4: [LOW] `fae_core_start` return code -1 covers multiple failure cases**
File: `src/ffi.rs:206-249`, `include/fae.h:70`
The function returns -1 for: null handle, already started, server already consumed, poisoned mutex. A caller cannot distinguish these cases. Acceptable for Phase 1.1 but noted for Phase 1.3.
Vote: PASS (by-design simplification)

**FINDING DOC-5: [PASS] New channel handlers have doc comments**
File: `src/host/channel.rs`
`request_conversation_inject_text` and `request_conversation_gate_set` trait methods are clearly named; the default no-op implementation is appropriate.
Vote: PASS

**FINDING DOC-6: [LOW] `src/host/stdio.rs` module doc references "event forwarder" task but the term isn't consistent with the code variable name `event_handle`**
Minor naming inconsistency. No functional impact.
Vote: PASS

**FINDING DOC-7: [PASS] `cbindgen.toml` referenced in PLAN but not present**
File: `.planning/PLAN-phase-1.1.md:Task 10`
The plan mentions `cbindgen.toml` but the header was hand-written. This is acceptable — cbindgen output would need manual curation anyway. The manually-written header is arguably cleaner.
Vote: PASS (deliberate deviation, acceptable)

### Summary
- CRITICAL: 0
- HIGH: 0
- MEDIUM: 1 (DOC-3)
- LOW: 0 (passing)
- PASS: 6
