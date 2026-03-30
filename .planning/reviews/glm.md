# External Review: GLM-4.7

## Reviewer: GLM-4.7 (External)
## Scope: Phase 1.1 — LoRA Adapter Loading

### Review

The implementation adds LoRA adapter hot-swap capability to `MLXLLMEngine` with appropriate error handling and state management. The code is idiomatic Swift and follows the existing codebase conventions.

### Positive Points

- The three-method API (`loadAdapter`, `unloadAdapter`, `swapAdapter`) is clean and minimal
- Error types are well-named and conform to `LocalizedError`
- `public private(set)` visibility pattern is correct for observable state
- KV cache invalidation after adapter change is critical and correctly implemented
- Auto-load at model startup is correctly gated behind a feature flag

### Concerns

1. **`adapterNotCompatible` dead code**: Defined in `MLEngineError` but never thrown. The underlying incompatibility error (`ModelAdapterError.incompatibleModelType`) is not distinguished from other `adapterLoadFailed` errors. This reduces error granularity. Should be explicitly mapped. SHOULD FIX.

2. **Path security**: The adapter path from config is used without validation. While the threat model is limited (local config file), using `URL.standardizedFileURL` is a minimal mitigation. MINOR.

3. **`approvedAdapterCycles: Int = 0`**: No consumer. OK as placeholder, but confusing without a comment.

### Grade: B+

Well-implemented feature. Two polish issues noted.
