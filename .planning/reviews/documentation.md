# Documentation Review

## Reviewer: Documentation Auditor
## Scope: Phase 1.1 — LoRA Adapter Loading

### Findings

**PASS** - All three new public methods (`loadAdapter`, `unloadAdapter`, `swapAdapter`) have doc comments.
**PASS** - `loadedAdapterPath` has an inline doc comment.
**PASS** - `isAdapterLoaded` computed var has a doc comment.
**PASS** - Doc comments use DocC-style parameter/throws documentation (`- Parameter:`, `- Throws:`).
**PASS** - `MLEngineError` new cases have inline descriptions in `errorDescription`.
**PASS** - New `FaeConfig.Training` fields have self-describing names (no doc comments needed for simple Bool/Int config fields).

### Issues

**MINOR (1 vote):** `loadAdapter` doc comment says "The KV cache is reset after loading" but doesn't mention that any **in-flight** generation will not be interrupted — the actor ensures mutual exclusion so this is safe, but documenting it explicitly would help future maintainers. E.g., "Safe to call while idle; actor isolation guarantees no concurrent generation."

**MINOR (1 vote):** `unloadAdapter` doc comment says "If no adapter is loaded, this method returns silently" but the guard also checks `container` — if `container` is nil (engine shut down), it also returns silently and resets state. The comment is slightly incomplete.

**MINOR (1 vote):** `swapAdapter(to:)` doc says "Propagates errors from `loadAdapter(from:)` if loading fails" but doesn't note what happens to the model state if loading fails mid-swap (base model is restored because `unloadAdapter` already completed before the failed `loadAdapter`). This is an important contract for callers.

### Verdict: PASS (documentation quality is good, minor completeness notes only)
