# External Review — GLM-4

## Grade: B+

### Assessment

The FFI surface successfully achieves its Phase 1.1 objective. The design is conservative and correct. The primary concerns are policy compliance (#[allow(dead_code)]) and type consistency (FaeEventCallback alias).

### Issues Found

**[MUST FIX] #[allow(dead_code)] on log_level**
This is a direct violation of the zero-tolerance warning policy. Even in FFI boundary code, suppression attributes require justification. Removing the field is the cleanest fix.

**[SHOULD FIX] Type alias not used in fae_core_set_event_callback**
Small inconsistency that could be confusing to Swift developers reading both the header and the Rust source.

**[SHOULD FIX] No test for send_command before start**
The function would block indefinitely if called before start. This behavior should be tested and possibly made fail-fast instead.

**[INFO] Security concern: double-free on fae_core_destroy**
The null-check protection is insufficient for double-free. While this is inherent to C ABI design, a comment in the source describing why a sentinel approach wasn't used would be helpful.

**[INFO] ABI version constant absent**
Consider adding #define FAE_ABI_VERSION 1 to the header for future compatibility checking.

### Verdict
CONDITIONAL APPROVAL. Fix the #[allow(dead_code)] and type alias issues. The remaining concerns are documentation/polish.
