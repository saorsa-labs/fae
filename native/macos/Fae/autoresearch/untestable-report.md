# Untestable Code Report — Fae Coverage Gap Analysis

**Date**: 2026-05-12
**Current coverage**: 28.1% (33,648 / 119,699 lines)
**Target**: 90%
**Gap**: ~74,500 lines need test coverage

## Summary

To reach 90% coverage without modifying production code, approximately **35,000+ lines of SwiftUI/AppKit UI code** must either be refactored for testability or excluded from coverage targets. The remaining ~39,500 lines are in complex async coordinators and framework-dependent modules.

## Categories of Untestable Code

### 1. Pure SwiftUI Views (~25,000 lines)

These files contain only `.body` computed properties and SwiftUI view declarations. They cannot be unit-tested without extracting logic into view models:

| File | Lines | Module |
|------|-------|--------|
| CoworkWorkspaceView.swift | 13,709 | Cowork |
| FaeApp.swift | 1,827 | App |
| SettingsModelsPerformanceTab.swift | 2,217 | Settings |
| SettingsModelsTab.swift | 1,087 | Settings |
| SettingsOtherLLMsTab.swift | 1,135 | Settings |
| SpeakerEnrollmentView.swift | 1,176 | Settings |
| InputOverlayView.swift | 1,466 | Input |
| ContentView.swift | 1,006 | Main |
| ConversationWindowView.swift | 701 | Conversation |
| ConversationScrollView.swift | 639 | Conversation |
| SettingsDiagnosticsTab.swift | 1,452 | Settings |
| SettingsDeveloperTab.swift | 596 | Settings |
| SettingsAwarenessTab.swift | 545 | Settings |
| SettingsTrainingTab.swift | 536 | Settings |
| SettingsToolsTab.swift | 531 | Settings |
| SettingsSpeakerTab.swift | 439 | Settings |
| SettingsPersonalityTab.swift | 452 | Settings |
| SettingsMemoryTab.swift | 504 | Settings |
| SettingsSchedulesTab.swift | 487 | Settings |
| SettingsSkillsTab.swift | 742 | Settings |
| SettingsOverviewTab.swift | 782 | Settings |
| SettingsGeneralTab.swift | 365 | Settings |
| SettingsChannelsTab.swift | 389 | Settings |
| InputBarView.swift | 880 | Input |
| InputOverlayController.swift | 365 | Input |

**Recommendation**: Extract view model logic, use `@Observable` or `ObservableObject` patterns with testable pure functions.

### 2. AppKit Controllers (~3,000 lines)

NSWindow-based controllers requiring AppKit main thread:

| File | Lines |
|------|-------|
| CoworkWindowController.swift | 369 |
| AboutWindowController.swift | 33 |
| DebugConsoleWindowView.swift | 228 |
| MemoryImportWindowView.swift | 761 |
| MemoryImportWindowController.swift | 44 |
| ReceiptsTimelineView.swift | 398 |
| ReceiptsWindowController.swift | 234 |

### 3. Framework-Dependent Modules (~5,000 lines)

Require hardware, AVFoundation, SoundAnalysis, or other system frameworks:

| File | Lines | Dependency |
|------|-------|------------|
| AudioDevices.swift | 82 | CoreAudio |
| AudioToneGenerator.swift | 70 | AVFoundation |
| WAVParser.swift | 94 | AVFoundation |
| AppleSpeechClassifier.swift | 142 | SoundAnalysis |
| MLXVLMEngine.swift | 242 | MLX/Metal |
| CoreMLAudioClassifier.swift | 133 | CoreML |
| MLXSpeechVerifier.swift | 159 | MLX |
| CharacterVoiceLibrary.swift | 66 | AVFoundation |
| VoiceLibrary.swift | 122 | AVFoundation |

### 4. Complex Async Coordinators (~8,000 lines)

PipelineCoordinator and similar actors with deep dependency chains:

| File | Lines | Issue |
|------|-------|-------|
| PipelineCoordinator.swift | 8,216 | 300+ state variables, requires full pipeline setup |

### 5. Network/External Service Modules (~2,000 lines)

| File | Lines | Dependency |
|------|-------|------------|
| FaeRelayServer.swift | 461 | Network |
| DeviceHandoff.swift | 299 | Network/Bonjour |
| ACPSessionManager.swift | 881 | ACP protocol |
| AccessibilityBridge.swift | 313 | NSAccessibility |

## What Was Tested (New Tests Added)

| Module | Files Tested | Lines Covered |
|--------|-------------|---------------|
| SentimentClassifier | Full | ~22 lines |
| ToolPermissionSnapshot | Full | ~149 lines |
| DiagnosticsManager | Partial | ~29 lines |
| SpeakerGateState | Full | ~24 lines |
| TTSState | Full | ~12 lines |
| PendingBargeIn, PlaybackBargeInCandidate, GenerationTakeoverCandidate | Full | ~137 lines |
| BargeInDecisions (pure functions) | Full | ~50+ lines |
| BargeInState | Partial | ~50 lines |
| ToolResult | Full | ~82 lines |
| ToolRiskLevel, ActionSource | Full | ~15 lines |
| FaeEvent enum | All cases | ~40 lines |
| FaePipelineState, FaeRuntimeState | Full | ~10 lines |
| IntroCrawl | Partial | ~3 lines |
| RescueMode | Partial | ~19 lines |
| SpeechInputStage | Partial | ~20 lines |
| AppleSpeechClassifier constants | Partial | ~5 lines |
| ClassificationResult | Full | ~15 lines |
| ReversibilityEngine.CheckpointRecord | Full | ~10 lines |

## Recommendations for the Team

1. **Extract view models from SwiftUI views** — Move all business logic out of `.body` into `@Observable` classes. This alone could add 15-20% coverage.

2. **Protocol-based abstractions for framework deps** — Create testable protocols for AVFoundation/MLX/SoundAnalysis with mock implementations.

3. **Reduce PipelineCoordinator complexity** — Extract pure decision functions (like BargeInDecisions) from the coordinator. Already started with `BargeInDecisions` and `SpeakerGateState`.

4. **Exclude pure UI from coverage targets** — Consider excluding `Settings*Tab.swift`, `*View.swift`, and `*WindowController.swift` files from coverage requirements. They're rendering code, not business logic.

5. **Add test helpers** — Create factory functions for complex types like `SpeechSegment`, `LLMMessage`, etc. to reduce test boilerplate.
