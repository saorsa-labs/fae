# Remove Dual-Model System

## Problem
Technical debt: the dual-model system (worker subprocesses, turn routing, inference priority, concierge model) adds significant complexity that is no longer maintained or needed. Fae is a single-LLM pipeline.

## Success Criteria
- Zero references to concierge, dual-model, worker subprocess, inference priority, or turn routing in code, tests, or docs
- DualModelCompat.swift shim deleted
- swift build — zero errors, zero warnings
- swift test — all tests pass
- CLAUDE.md updated to reflect single-model architecture

---

## Milestone 1: Remove Dual-Model System

### Phase 1.1: Delete shim + clean FaeConfig
- Delete Core/DualModelCompat.swift
- Remove 5 LLM config properties: dualModelEnabled, conciergeModelPreset, dualModelMinSystemRAMGB, keepConciergeHot, allowConciergeDuringVoiceTurns
- Remove 3 types: LocalPipelineMode, LocalLLMSelection, LocalModelStackPlan
- Remove 6+ static methods: isDualModelEligible, recommendedConciergeModel, canonicalConciergeModelPreset, shouldHoldStartupForConciergeHotLoad, recommendedLocalModelStack, isDualModelActive
- Remove TOML parsing/serialization for deleted keys
- Remove patchConfig key cases for deleted keys

### Phase 1.2: Clean PipelineCoordinator
- Remove conciergeEngine stored property and init param
- Remove 7 methods: currentDualModelPlan(), selectedLocalModel(for:), selectLLMRoute(...), publishRouteDiagnostics(...), engine(for:), selectedModelId(for:)
- Remove InferencePriorityController begin/end calls
- Simplify generation: always use llmEngine directly (no route selection)
- Remove TurnLLMRoute/TurnRoutingPolicy usage — replace with direct calls
- Remove shouldPreferToolFreeFastPath usage

### Phase 1.3: Clean FaeCore + ModelManager + FaeApp
- FaeCore: remove conciergeEngine: nil init param, remove startup concierge block, remove dual-model config from settings dict
- ModelManager: remove loadedConciergeModelId, dualModelActive, loadConciergeIfNeeded(), simplify publishLocalStackStatus()
- FaeApp: remove worker subprocess launch path (WorkerProcessRole/LLMWorkerService)

### Phase 1.4: Clean UI + secondary files
- SettingsModelsPerformanceTab, SettingsOverviewTab, SettingsDiagnosticsTab
- PipelineAuxBridgeController, LocalModelStatusFormatter, AboutWindowView
- ConversationBridgeController, TestServer, PersonalityManager

### Phase 1.5: Clean tests + update docs
- FaeConfigTests, LocalModelStatusFormatterTests, RuntimeContractTests, PipelineCoordinatorPolicyTests
- Update CLAUDE.md to reflect single-model architecture
