# External Review: MiniMax

## Reviewer: MiniMax (External)
## Scope: Phase 1.1 — LoRA Adapter Loading

### Summary

Phase 1.1 delivers a clean, minimal adapter loading API on top of the existing `mlx-swift-lm` infrastructure. The implementation is correct and follows established patterns.

### Architecture Evaluation

The three-layer architecture is well-designed:
1. `MLXLLMEngine` — pure adapter lifecycle (load/unload/swap)
2. `ModelManager` — startup auto-load policy
3. `FaeCore.patchConfig` → `PipelineCoordinator.applyAdapterChange` — runtime hot-swap path

This separation means each layer has a single responsibility and can be tested independently.

### Issues Found

1. **Dead code** (`adapterNotCompatible`): Not thrown anywhere. The distinction between "failed to load files" and "model incompatible with adapter" is semantically important and should be preserved by mapping `ModelAdapterError.incompatibleModelType` to this case. SHOULD FIX (1 vote).

2. **Test coverage gap**: No test verifies that after a failed `loadAdapter`, the engine state remains clean (no partial adapter state). This is the most important invariant of the method. SHOULD FIX (1 vote).

3. **Missing `swapAdapter` state guarantee doc**: What happens when `unloadAdapter` succeeds but `loadAdapter` fails? The doc doesn't say "base model is active" — critical contract for callers. MINOR.

### Grade: A-

Solid implementation. Two actionable items, both minor-to-moderate.
