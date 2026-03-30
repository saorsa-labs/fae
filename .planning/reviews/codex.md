# External Review: Codex

## Reviewer: Codex (External)
## Scope: Phase 1.1 — LoRA Adapter Loading

### Summary

The LoRA adapter management implementation follows established patterns in the mlx-swift-lm ecosystem. The API design mirrors the `ModelAdapterFactory` pattern and correctly uses `LoRAContainer` as the concrete adapter type.

### Positive Observations

- Clean separation of concerns: `MLXLLMEngine` owns adapter lifecycle, `ModelManager` owns auto-load policy, `FaeCore.patchConfig` owns runtime hot-swap
- Correct use of `container.perform { }` for thread-safe model mutation
- `sessionState = nil` after adapter operations is crucial — without this, stale KV cache from pre-adapter generation would corrupt outputs
- The two-phase error model in `loadAdapter` (file read, then model apply) gives precise failure attribution

### Concerns

1. **Dead error case** (`adapterNotCompatible`): Defined but never thrown. The underlying `ModelAdapterError.incompatibleModelType` is swallowed into `adapterLoadFailed`. Either map it explicitly or remove until needed. Grade impact: -0.5.

2. **Missing path validation**: `config.training.personalAdapterPath` flows directly to `URL(fileURLWithPath:)` without sanitization. Should at minimum use `.standardizedFileURL` to normalize `..` components.

3. **`approvedAdapterCycles` unused**: Config field with no consumer. Acceptable as forward declaration, but should be commented.

### Grade: B+

Strong implementation with two minor polish items. No structural concerns.
