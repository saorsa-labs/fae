# External Review — Codex

## Grade: A-

### Summary
The FFI surface is well-structured for a Phase 1.1 implementation. The extern "C" ABI is clean, the memory ownership model is clear, and the C header documentation is production-ready. The channel additions for ConversationInjectText and ConversationGateSet are consistent with the existing command surface.

### Positive Observations
- Excellent SAFETY documentation on all unsafe blocks
- Opaque handle pattern with Box::into_raw/from_raw is textbook correct
- Event drain synchronization with yield_now() is pragmatic and documented
- Test coverage exercises the complete ABI lifecycle

### Issues Found

**[SHOULD FIX] `#[allow(dead_code)]` on log_level field**
Policy violation. Remove the field or implement it.

**[SHOULD FIX] FaeEventCallback alias not used in set_event_callback parameter**
Minor inconsistency that could cause future divergence.

**[SHOULD FIX] Missing test for double-start returning -1**
Contract is documented but not tested.

**[INFO] Concurrent double-start TOCTOU**
The started/server pattern provides practical protection but a formal review might flag the non-atomic check. Document in code comments.

### Verdict
APPROVED with minor fixes required. Core architecture is solid.
