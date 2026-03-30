# Error Handling Review

## Reviewer: Error Handling Hunter
## Scope: Phase 1.1 — LoRA Adapter Loading

### Findings

**PASS** - No force-try (`try!`) anywhere in the diff.
**PASS** - No force-unwrap (`!`) on optionals in new code.
**PASS** - All throwing calls are wrapped in do/catch with typed error mapping.
**PASS** - `loadAdapter(from:)` uses two-phase error wrapping: file read failure → `adapterLoadFailed`, model apply failure → `adapterLoadFailed`. Both phases caught independently.
**PASS** - `unloadAdapter()` is non-throwing (unload cannot meaningfully fail at the MLX level).
**PASS** - `ModelManager` catches adapter load failure and continues with base model — correct degraded mode behavior (adapter is optional, base model must not be blocked).

### Issues

**SHOULD FIX (1 vote):** `adapterNotCompatible` error case is defined but never thrown. `LoRAContainer.from(directory:)` internally throws `ModelAdapterError.incompatibleModelType` when the model doesn't conform to `LoRAModel`, but `loadAdapter` catches this as a generic error and re-wraps it as `adapterLoadFailed`. The semantic distinction is lost. Either:
  - Map `ModelAdapterError.incompatibleModelType` specifically to `adapterNotCompatible` via pattern matching, or
  - Remove `adapterNotCompatible` until the incompatibility path is explicitly wired.

**MINOR (1 vote):** `unloadAdapter()` silently clears `currentAdapter = nil` in the guard branch even when `container` is nil but `currentAdapter` is non-nil (impossible in practice due to actor sequencing, but logically inconsistent — if adapter is loaded, container must exist). Not a real bug but slightly misleading.

### Verdict: PASS with minor notes
