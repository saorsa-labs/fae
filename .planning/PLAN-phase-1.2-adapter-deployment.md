# Phase 1.2: Adapter Deployment Mechanism

## Context

Phase 1.1 added `loadAdapter/unloadAdapter/swapAdapter` to MLXLLMEngine and
auto-load on model startup from config. Phase 1.2 makes the adapter path runtime-
adjustable: the LLM (or ImprovementCycleCoordinator) can call `self_config` with
`training.personal_adapter_path` to deploy or roll back an adapter without restarting.

## Files

- `native/macos/Fae/Sources/Fae/Tools/BuiltinTools.swift` — SelfConfigTool adjustableKeys
- `native/macos/Fae/Sources/Fae/Core/FaeCore.swift` — patchConfig switch
- `native/macos/Fae/Sources/Fae/Pipeline/PipelineCoordinator.swift` — adapter reload on config change
- `native/macos/Fae/Sources/FaeInference/MLXLLMEngine.swift` — adapter API (Phase 1.1, read-only)
- `native/macos/Fae/Tests/HandoffTests/AdapterDeploymentTests.swift` (new)

---

## Task 1: Add training.personal_adapter_path to adjustableKeys

**Files**: `Sources/Fae/Tools/BuiltinTools.swift`

Add to `adjustableKeys`:
```swift
"training.personal_adapter_path": SettingSpec(
    valueType: .string(allowed: []),  // empty = any string allowed
    description: "Path to personal LoRA adapter directory (nil to unload). " +
                 "Triggers hot-swap on the running LLM engine."
),
```

Note: `.string(allowed: [])` means allow any string (not restricted to an enum list).
Also add `"training.adapter_auto_load_enabled"` as a bool key:
```swift
"training.adapter_auto_load_enabled": SettingSpec(
    valueType: .bool,
    description: "Auto-load personal adapter when LLM engine starts up"
),
```

**Tests** (Task 4): adjustableKeys contains the two new keys

**Done when**: `just build` passes, SelfConfigTool lists both new keys.

---

## Task 2: Add patchConfig cases for adapter path in FaeCore

**Files**: `Sources/Fae/Core/FaeCore.swift`

Add two new `case` entries in `patchConfig(_:payload:)` before the `default:` case
(around line 2091-2096):

```swift
case "training.personal_adapter_path":
    // Value can be a String path or NSNull/nil to unload adapter.
    let newPath: String?
    if let s = value as? String, !s.isEmpty {
        newPath = s
    } else {
        newPath = nil
    }
    config.training.personalAdapterPath = newPath
    persistConfig(reason: "config.patch.training.personal_adapter_path")
    // Notify PipelineCoordinator to hot-swap adapter.
    Task { [weak self] in
        await self?.pipelineCoordinator?.applyAdapterChange(path: newPath)
    }

case "training.adapter_auto_load_enabled":
    guard let enabled = value as? Bool else { return }
    config.training.adapterAutoLoadEnabled = enabled
    persistConfig(reason: "config.patch.training.adapter_auto_load_enabled")
```

**Tests** (Task 4):
- Setting valid path updates config and triggers applyAdapterChange
- Setting nil/empty unloads adapter and clears config
- Setting adapter_auto_load_enabled persists

**Done when**: `just build` passes.

---

## Task 3: Add applyAdapterChange to PipelineCoordinator

**Files**: `Sources/Fae/Pipeline/PipelineCoordinator.swift`

Add a new public method to `PipelineCoordinator` actor:

```swift
/// Hot-swap the LLM's personal LoRA adapter.
/// Called by FaeCore when training.personal_adapter_path config changes.
/// Safe to call during idle or active generation (waits for idle if generating).
func applyAdapterChange(path: String?) async {
    guard let engine = llmEngine else {
        NSLog("PipelineCoordinator: applyAdapterChange — no LLM engine, skipping")
        return
    }
    do {
        let url = path.map { URL(fileURLWithPath: $0) }
        try await engine.swapAdapter(to: url)
        if let path {
            NSLog("PipelineCoordinator: adapter loaded from %@", path)
        } else {
            NSLog("PipelineCoordinator: adapter unloaded (base model active)")
        }
        // Emit event so UI and tests can observe the change.
        eventBus?.send(.runtimeProgress(stage: "adapter_changed",
                                        detail: path ?? "nil",
                                        progress: 1.0))
    } catch {
        NSLog("PipelineCoordinator: adapter swap failed — %@", error.localizedDescription)
        // Emit failure event; do NOT crash. Base model remains active.
        eventBus?.send(.runtimeProgress(stage: "adapter_change_failed",
                                        detail: error.localizedDescription,
                                        progress: 0.0))
    }
}
```

Find where `llmEngine` is declared/stored in PipelineCoordinator to get the right property
name. Check for any generation-active guard that should block adapter swap during active
inference (if MLXLLMEngine.swapAdapter already handles this, no guard needed here).

**Tests** (Task 4):
- applyAdapterChange(path:) calls engine.swapAdapter
- applyAdapterChange(path: nil) calls engine.swapAdapter(to: nil)
- Failure emits runtimeProgress(stage: "adapter_change_failed")

**Done when**: `just build` passes with zero warnings.

---

## Task 4: Add AdapterDeploymentTests

**Files**: `native/macos/Fae/Tests/HandoffTests/AdapterDeploymentTests.swift` (new)

Test all three tasks above. Minimal, no actual MLX calls — mock the engine.

```swift
// Test 1: adjustableKeys includes training.personal_adapter_path
// Test 2: adjustableKeys includes training.adapter_auto_load_enabled
// Test 3: patchConfig("training.personal_adapter_path", path) updates config
// Test 4: patchConfig("training.personal_adapter_path", "") sets nil
// Test 5: patchConfig("training.adapter_auto_load_enabled", true) persists
// Test 6: applyAdapterChange calls swapAdapter on engine
// Test 7: applyAdapterChange(nil) calls swapAdapter(to: nil) on engine
// Test 8: applyAdapterChange failure emits adapter_change_failed event
```

Use existing `MockLLMEngine` or create minimal protocol stub for `swapAdapter`.

**Done when**: `just test` green, 8+ new tests passing.

---

## Task 5: Build + test validation

**Files**: All modified files

- `just build` — zero errors, zero warnings
- `just test` — all tests pass (no new failures beyond pre-existing 5)
- Confirm SelfConfigTool `get_settings` output lists the two new keys with descriptions
