# Fixes Applied — Phase 1.1 Review Iteration 1
## Date: 2026-03-30

### Fix 1: Map `ModelAdapterError.incompatibleModelType` → `MLEngineError.adapterNotCompatible`
**File:** `Sources/FaeInference/MLXLLMEngine.swift`
**Change:** Added explicit `catch ModelAdapterError.incompatibleModelType` clause in `loadAdapter(from:)` apply phase, throwing `adapterNotCompatible` instead of generic `adapterLoadFailed`.
**Impact:** `adapterNotCompatible` error case is now thrown when the base model does not conform to `LoRAModel`. Callers can distinguish incompatibility from IO/parse failures.

### Fix 2: Add post-failure state invariant test
**File:** `Tests/IntegrationTests/AdapterLoadingTests.swift`
**Change:** Added `testLoadAdapterFailureDoesNotLeavePartialState` — verifies that after a failed `loadAdapter` call, `isAdapterLoaded` is false and `loadedAdapterPath` is nil.
**Impact:** The key state-consistency invariant is now tested explicitly.

### Fix 3 (minor): Add clarifying comment to `approvedAdapterCycles`
**File:** `Sources/Fae/Core/FaeConfig.swift`
**Change:** Added doc comment explaining the field is read by ImprovementCycleCoordinator in Phase 2.

### Fix 4 (minor): Use `standardizedFileURL` for adapter path
**File:** `Sources/Fae/ML/ModelManager.swift`
**Change:** Applied `.standardizedFileURL` to the adapter URL to normalize any `..` path components before passing to `loadAdapter`.

### Fix 5 (minor): Update `swapAdapter` doc to state base-model guarantee
**File:** `Sources/FaeInference/MLXLLMEngine.swift`
**Change:** Extended doc comment to explicitly state that on `loadAdapter` failure, the engine remains on the base model (previous adapter already unloaded).

### Build After Fixes
- `swift build`: Build complete (7.83s) — PASS
- `swift test --filter AdapterLoadingTests`: 7/7 PASS — PASS
