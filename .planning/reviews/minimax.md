# External Review — MiniMax

## Grade: A-

### Assessment

Phase 1.1 delivers a solid C ABI surface. The implementation is careful, well-documented, and passes all quality gates. The channel additions for conversation commands are clean extensions of the existing command surface.

### Issues Found

**[MUST FIX] #[allow(dead_code)] — policy violation**
The log_level field is parsed but ignored. Remove it in Phase 1.1; add it properly in Phase 1.3 when the runtime initialization is more complete.

**[SHOULD FIX] FaeEventCallback type alias not used in parameter**
Should be: `callback: Option<FaeEventCallback>`

**[SHOULD FIX] Re-entrancy warning missing from Rust ffi.rs doc**
The C header correctly warns about not calling fae_core_* from within the event callback. This contract should also appear in the Rust source docs for set_event_callback.

**[INFO] fae_core_poll_event and drain_events both drain from the same Receiver**
File: src/ffi.rs — event_rx is shared between drain_events (via Mutex lock) and fae_core_poll_event (also via Mutex lock). Both compete for events. This is correct behavior (events are consumed once) but could confuse callers who use both polling AND callback simultaneously. Consider documenting that mixing both modes is unsupported or defining the precedence.

### Verdict
APPROVED with minor fixes. Core design is production-quality for Phase 1.1.
