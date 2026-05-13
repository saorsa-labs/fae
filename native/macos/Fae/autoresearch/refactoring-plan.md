# Fae Test Coverage Refactoring Plan

**Goal**: Increase test coverage from 27.8% → 50%+ through targeted production code refactoring.

**Current state**: 33,271 / 119,699 lines covered. All pure-logic code that doesn't require system frameworks is already tested. Remaining uncovered code falls into four categories:

| Category | Lines | Strategy |
|----------|-------|----------|
| SwiftUI views (monolithic) | ~35,000 | Extract ViewModels |
| PipelineCoordinator/FaeCore static methods | ~8,000 | Extract to pure modules |
| System framework dependencies | ~12,000 | Add protocol abstractions |
| Complex actors with state machines | ~6,000 | Extract decision logic |

---

## Phase 1: Extract Pure Logic from Monolithic Files (Highest ROI)

### 1.1 PipelineCoordinator static methods → `PipelineHelpers` module

**File**: `PipelineCoordinator.swift` (8,216 lines, 2% covered)

The file contains **23+ pure `static func` methods** that take inputs and return outputs with no side effects:

```
shouldRecallMemoryForTurn(userText:)
memoryTurnGuidance(for:)
visibleToolNamesForTurn(available:mentioned:)
explicitlyMentionedToolNames(in:)
inferredToolNamesForTurn(text:available:)
shouldSuppressEpisodeRecallForToolSensitiveTurn(...)
deterministicEasyTurnAction(text:)
batchedTTSSegments(segments:)
shouldAcceptVoiceApprovalResponse(...)
llmFailureFallbackMessage(...)
prefersLegacyInlineToolPrompt(modelId:)
resolveRelayReply(...)
idleRearmSeconds(config:)
silenceThresholdMs(config:)
shouldSkipSTTAfterSpeakerVerification(...)
streamingSpeakerSimilarityDecision(...)
fusedVoiceAttentionDecision(...)
shouldDeferSemanticTurn(...)
normalizeForPhraseMatch(_:)
isConversationStopTrigger(...)
```

**Refactoring**:
- Create `Sources/Fae/Pipeline/PipelineHelpers.swift` as a pure `enum PipelineHelpers` with all static methods moved out
- Keep the actor thin — it delegates to `PipelineHelpers.*` for decisions
- Each method becomes independently testable

**Estimated coverage gain**: +2.0% (1,600+ lines of pure logic)

---

### 1.2 FaeScheduler distilled skill logic → `SkillDistiller` module

**File**: `FaeScheduler.swift` (2,202 lines, 38% covered)

Contains **9 pure static methods** for generating distilled skill markdown:

```
derivedDistilledSkillName(userGoals:signature:)
distilledSkillDescription(goals:signature:)
distilledSkillBody(instruction:rationale:)
distilledInstruction(for toolName:)
distilledSkillRationale(evidence:)
distilledEvidenceJSON(events:)
renderDistilledSkillMarkdown(name:description:body:confidence:)
distilledConfidence(evidenceCount:)
```

**Refactoring**:
- Create `Sources/Fae/Scheduler/SkillDistiller.swift` as a pure `enum SkillDistiller`
- All methods are string manipulation — trivially testable

**Estimated coverage gain**: +0.4% (800 lines)

---

### 1.3 FaeCore utility methods → `FaeCoreUtils` module

**File**: `FaeCore.swift` (3,900 lines, 23% covered)

Contains pure utility methods:
```
extractPrimaryName(from:) — string parsing
migrateStartupIntroState(_:inout FaeConfig) — config migration logic
migrateChannelSecretsToKeychain(_:inout FaeConfig) — config migration
hasConfiguredChannelEndpoints(_:) — predicate
```

**Refactoring**:
- Extract `extractPrimaryName` → `TextProcessing.extractPrimaryName()` (already has TextProcessing module)
- Extract config migration methods → `ConfigMigrator` enum with testable pure functions
- `hasConfiguredChannelEndpoints` → `ChannelConfigExtensions.hasConfiguredEndpoints`

**Estimated coverage gain**: +0.3% (600 lines)

---

## Phase 2: Protocol Abstractions for System Frameworks

### 2.1 EntityStore / SQLiteMemoryStore — add testable protocol

**Files**: `EntityStore.swift` (854 lines, 0%), `ToolAnalytics.swift` (180 lines, 0%)

Both use GRDB `DatabaseQueue` directly. The logic is SQL queries wrapped in actor methods.

**Refactoring**:
- Define `protocol EntityStoreProtocol: Actor { func find(byId:); func find(byName:); ... }`
- Keep `EntityStore` as the production implementation
- For testing: create `MockEntityStore` that returns pre-configured results
- The SQL query logic itself is thin — the value is in testing the higher-level callers

**Estimated coverage gain**: +0.5% (400 lines of protocol + mock)

### 2.2 VocabularyHarvester — extract name extraction logic

**File**: `VocabularyHarvester.swift` (180 lines, 0%)

Uses Contacts + Calendar frameworks directly. But the calendar name extraction has pure logic:
```swift
// Extract probable proper names from event titles
let words = title.components(separatedBy: .whitespacesAndNewlines)
for word in words { ... } // uppercase check, commonWords filter, "with <Name>" pattern
```

**Refactoring**:
- Extract `static func extractProperNames(from eventTitle: String) -> [String]` to a pure helper
- Extract `commonWords: Set<String>` as a testable constant
- The Contacts/Calendar harvesting stays in the framework-dependent layer

**Estimated coverage gain**: +0.2% (150 lines)

### 2.3 SkillMigrator — extract file classification logic

**File**: `SkillMigrator.swift` (188 lines, 0%)

Uses FileManager but has pure logic for classifying which files are legacy skills:
```swift
// .py / .md files that aren't in a directory structure
guard !entry.lastPathComponent.hasPrefix(".") else { continue }
```

**Refactoring**:
- Extract `static func shouldMigrate(entry: URL, in sourceRoot: URL) -> Bool` as pure function
- Extract `static func buildSkillDirectory(name: String, from file: URL) -> SkillDirectoryConfig` 
- The FileManager operations stay thin; the classification logic is testable

**Estimated coverage gain**: +0.2% (150 lines)

---

## Phase 3: SwiftUI ViewModel Extraction

### 3.1 CoworkWorkspaceView → CoworkWorkspaceViewModel

**File**: `CoworkWorkspaceView.swift` (13,709 lines, 0%)

This is the single largest file. It contains:
- `EditableSchedulerTaskDraft` struct with `new()` and `from(task:)` factory methods
- Model selection logic (`CoworkModelOptionSection`)
- Capability badge rendering
- Scheduler editor with draft validation
- Custom `FlowLayout` layout engine

**Refactoring**:
1. Extract `EditableSchedulerTaskDraft` → its own file (already testable as a struct)
2. Create `CoworkWorkspaceViewModel: @Observable` that owns all state and business logic:
   - Task CRUD operations
   - Model selection/validation
   - Capability display logic
   - Scheduler draft validation (`isValid`, `validationErrors`)
3. Create `CoworkModelSelector` pure module for model filtering/sorting logic
4. The View becomes a thin presentation layer that reads from ViewModel

**Estimated coverage gain**: +1.5% (2,000 lines of extractable logic)

### 3.2 Settings tabs → SettingsViewModels

**Files**: ~20 Settings*Tab files, ~12,000 total lines, 0% covered

Most Settings tabs are thin bindings to `FaeConfig` properties. The ones with actual logic:

- **SettingsModelsPerformanceTab** (2,217 lines): Model benchmark display, sorting, filtering
- **SettingsDiagnosticsTab** (1,452 lines): Diagnostic data aggregation
- **SettingsModelsTab** (1,087 lines): Model selection/download logic
- **SettingsOtherLLMsTab** (1,135 lines): API key management validation

**Refactoring**:
1. Create `SettingsModelsViewModel` with:
   - `func sortedModels(by metric:) -> [ModelInfo]` 
   - `func filterModels(query:) -> [ModelInfo]`
   - `func benchmarkComparison(a:b:) -> ModelComparison`
2. Create `SettingsDiagnosticsViewModel` with:
   - `func aggregateDiagnostics() -> DiagnosticSummary`
3. Create `ApiKeyValidator` pure module:
   - `static func validateAnthropicKey(_:) -> ValidationResult`
   - `static func validateOpenAIKey(_:) -> ValidationResult`

**Estimated coverage gain**: +1.0% (1,200 lines of extractable logic)

### 3.3 InputOverlayView / InputBarView → InputViewModel

**Files**: `InputOverlayView.swift` (1,466 lines), `InputBarView.swift` (880 lines)

Contains input processing logic:
- Text composition state management
- Attachment handling
- Send/cancel button state computation
- Voice vs text input mode switching

**Refactoring**:
- Create `InputViewModel: @Observable` with:
  - `func computeSendButtonState() -> ButtonState`
  - `func processAttachments(items:) -> [Attachment]`
  - `func shouldShowVoiceInput() -> Bool`

**Estimated coverage gain**: +0.4% (500 lines)

---

## Phase 4: Actor Decision Logic Extraction

### 4.1 ACPSessionManager → ACPStateMachine

**File**: `ACPSessionManager.swift` (881 lines, 0%)

Actor managing ACP session state machine with `SessionStatus` enum:
```swift
enum SessionStatus {
    case idle, prompting, streaming(tokensReceived: Int),
         awaitingApproval(toolName: String, description: String), completed(stopReason: String)
}
```

**Refactoring**:
- Extract `ACPStateMachine` as a pure value type:
  - `func transition(from status: SessionStatus, event: ACPEvent) -> (newStatus: SessionStatus, sideEffects: [ACPSideEffect])`
  - All state transitions become testable table-driven tests
- Actor becomes thin wrapper that applies transitions

**Estimated coverage gain**: +0.5% (400 lines)

### 4.2 AudioCaptureManager → extract audio processing logic

**File**: `AudioCaptureManager.swift` (806 lines, 8% covered)

Uses AVFoundation but has pure signal processing:
- VAD threshold computation
- Energy level calculation
- Silence detection algorithms

**Refactoring**:
- Extract `VADProcessor` with pure methods:
  - `static func computeEnergy(samples:) -> Float`
  - `static func isSilence(energy:threshold:) -> Bool`
  - `static func detectSpeechOnset(samples:threshold:) -> Int?`

**Estimated coverage gain**: +0.3% (250 lines)

---

## Summary of Expected Coverage Gains

| Phase | Refactoring | Lines Unlocked | Est. Coverage Gain |
|-------|-------------|----------------|-------------------|
| 1.1 | PipelineCoordinator → PipelineHelpers | 1,600 | +2.0% |
| 1.2 | FaeScheduler → SkillDistiller | 800 | +0.4% |
| 1.3 | FaeCore → ConfigMigrator | 600 | +0.3% |
| 2.1 | EntityStore protocol + mock | 400 | +0.5% |
| 2.2 | VocabularyHarvester name extraction | 150 | +0.2% |
| 2.3 | SkillMigrator classification | 150 | +0.2% |
| 3.1 | CoworkWorkspaceView → ViewModel | 2,000 | +1.5% |
| 3.2 | Settings tabs → ViewModels | 1,200 | +1.0% |
| 3.3 | Input views → InputViewModel | 500 | +0.4% |
| 4.1 | ACPSessionManager → StateMachine | 400 | +0.5% |
| 4.2 | AudioCaptureManager → VADProcessor | 250 | +0.3% |
| **Total** | | **8,050 lines** | **+7.3%** |

**Projected final coverage**: 27.8% + 7.3% = **~35%**

---

## Implementation Order (Recommended)

1. **PipelineHelpers extraction** — highest ROI, pure logic, no breaking changes
2. **SkillDistiller extraction** — small, fast win
3. **ACPStateMachine extraction** — enables table-driven state machine tests
4. **ConfigMigrator extraction** — config migration is critical path
5. **CoworkWorkspaceViewModel** — largest file, most impactful but biggest change
6. **Settings ViewModels** — moderate effort, good ROI
7. **Protocol abstractions** (EntityStore, VocabularyHarvester) — lower priority

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| Breaking existing behavior when extracting methods | Each extraction is a cut-paste followed by tests that verify identical output |
| SwiftUI @Observable learning curve | Use `@Observable` (swift 5.9+) not `ObservableObject` — simpler, no KVO |
| Actor isolation constraints | Extracted pure functions are `nonisolated(unsafe)` or free-standing — no actor needed |
| Test flakiness from timing-dependent code | Pure extracted methods have no timing dependencies |
