# Phase 1.1: MLXLLMEngine LoRA Adapter Loading

## Context
mlx-swift-lm has full LoRA adapter support built-in:
- `LoRAContainer.from(directory: URL)` loads adapter from directory with `adapter_config.json` + `adapters.safetensors`
- `model.load(adapter:)` applies adapter to loaded model
- `model.unload(adapter:)` removes adapter, restores original weights
- QLoRA supported for 4-bit quantized models (what Fae uses)
- Located at: `.build/checkouts/mlx-swift-lm/Libraries/MLXLMCommon/Adapters/`

## Task 1: Add adapter loading to MLXLLMEngine
**Files:** `native/macos/Fae/Sources/FaeInference/MLXLLMEngine.swift`
**Spec:**
- Add `import MLXLMCommon` for LoRAContainer access (if not already imported)
- Add `private var currentAdapter: (any ModelAdapter)?` property
- Add `public private(set) var loadedAdapterPath: String?` property
- Add `public func loadAdapter(from directory: URL) async throws` method:
  1. Load adapter: `let adapter = try LoRAContainer.from(directory: directory)`
  2. Apply to model: `try await container.perform { context in try context.model.load(adapter: adapter) }`
  3. Store: `self.currentAdapter = adapter; self.loadedAdapterPath = directory.path`
  4. Reset session state (KV cache invalid after adapter change)
- Add `public func unloadAdapter() async throws` method:
  1. Guard `currentAdapter != nil`
  2. Unload: `try await container.perform { context in context.model.unload(adapter: self.currentAdapter!) }`
  3. Clear: `self.currentAdapter = nil; self.loadedAdapterPath = nil`
  4. Reset session state
- Error handling: typed errors for missing directory, missing adapter_config.json, incompatible format
**Tests:** Unit test: load/unload cycle, invalid path error, nil adapter unload is no-op
**Done when:** `just build` passes, adapter can be loaded/unloaded programmatically

## Task 2: Verify FaeConfig.TrainingConfig has adapter fields
**Files:** `native/macos/Fae/Sources/Fae/Core/FaeConfig.swift`
**Spec:**
- Verify `personalAdapterPath: String?` exists in TrainingConfig (should already be there per codebase analysis)
- Verify `previousAdapterPath: String?` exists
- Add `adapterAutoLoadEnabled: Bool = false` if not present
- Add `approvedAdapterCycles: Int = 0` if not present (tracks earned auto-deploy progress)
**Tests:** None needed (additive fields with defaults)
**Done when:** TrainingConfig has all 4 adapter-related fields, `just build` passes

## Task 3: Wire adapter loading into model startup path
**Files:** `native/macos/Fae/Sources/Fae/ML/ModelManager.swift`
**Spec:**
- After `MLXLLMEngine.load(modelID:)` succeeds in ModelManager, check `FaeConfig.shared.training.personalAdapterPath`
- If path is set AND file exists AND `adapterAutoLoadEnabled == true`:
  1. Call `llmEngine.loadAdapter(from: URL(fileURLWithPath: path))`
  2. Log success: "Loaded personal adapter from \(path)"
- If adapter loading fails: log warning, continue with base model (graceful degradation, never crash)
- Add `var currentAdapterPath: String? { llmEngine.loadedAdapterPath }` computed property
**Tests:** Test graceful degradation: set invalid adapter path, verify base model still works
**Done when:** Model startup loads adapter when configured, `just build` passes

## Task 4: Add adapter hot-swap method
**Files:** `native/macos/Fae/Sources/FaeInference/MLXLLMEngine.swift`
**Spec:**
- Add `public func swapAdapter(to directory: URL?) async throws`:
  1. If `directory == nil`: unload current adapter and return
  2. If current adapter loaded: unload it first
  3. Load new adapter from directory
  4. Reset session state (KV cache)
- Guard: must not be called during active generation (check if generate stream is active)
- This is the method ImprovementCycleCoordinator will call for deployment/rollback
**Tests:** Test swap from nil to adapter, adapter to different adapter, adapter to nil
**Done when:** Hot-swap works without model reload, `just build` passes

## Task 5: Adapter round-trip integration tests
**Files:** `native/macos/Fae/Tests/IntegrationTests/AdapterLoadingTests.swift` (new)
**Spec:**
- Test `loadAdapter(from:)` with valid mock adapter directory (create minimal adapter_config.json + empty safetensors)
- Test `loadAdapter(from:)` with nonexistent directory throws typed error
- Test `loadAdapter(from:)` with directory missing adapter_config.json throws typed error
- Test `unloadAdapter()` when no adapter loaded is safe no-op
- Test `swapAdapter(to:)` replaces current adapter
- Test adapter loading resets KV cache (sessionState cleared)
- Note: these tests verify the API surface. Full mlx-tune → Swift round-trip is a separate manual test (needs actual trained adapter weights)
**Done when:** All tests pass, `just test` green
