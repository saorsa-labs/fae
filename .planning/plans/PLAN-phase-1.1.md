# Phase 1.1: Model Loading & Lifecycle

## Overview

Ensure the Parakeet streaming ASR engine actually loads at startup, the lifecycle
transitions are correct, and all failure modes degrade gracefully. The code path
exists but has gaps: no `modelLoaded` event on success, no local cache pre-check,
and no tests for the env-var gate, load failure fallback, or FaeCore wiring.

TDD order: tests first, then the code change that makes them pass.

## Key Files

- `native/macos/Fae/Sources/Fae/ML/ModelManager.swift`
- `native/macos/Fae/Sources/Fae/ML/ParakeetStreamingEngine.swift`
- `native/macos/Fae/Sources/Fae/Core/FaeConfig.swift`
- `native/macos/Fae/Sources/Fae/Core/FaeCore.swift`
- `native/macos/Fae/Tests/IntegrationTests/ParakeetStreamingEngineTests.swift`
- `native/macos/Fae/Tests/HandoffTests/ModelManagerParakeetTests.swift` (new)

## Task 1: Add `modelLoaded` FaeEvent on Parakeet load success

**Files**: `Sources/Fae/ML/ModelManager.swift`

Add `eventBus.send(.modelLoaded(engine: "streaming_asr", modelId: ...))` on success.
Change failure branch to emit `runtimeProgress(stage: "streaming_asr_failed", ...)`.

**Tests** (new `ModelManagerParakeetTests.swift`):
- `testModelLoadedEventEmittedOnSuccess`
- `testStreamingASRFailedEventEmittedOnLoadError`

## Task 2: Add local HF cache check before download

**Files**: `Sources/Fae/ML/ParakeetStreamingEngine.swift`

Add `static func isCached(modelID: String) -> Bool` checking HF hub cache dir.
Log "loading from cache" vs "downloading model" accordingly.

**Tests**:
- `testIsCachedFalseWhenNoCacheDirectory`
- `testIsCachedTrueWhenSnapshotDirectoryExists`

## Task 3: Add diagnostics event emission

**Files**: `Sources/Fae/ML/ParakeetStreamingEngine.swift`, `Sources/Fae/ML/ModelManager.swift`

Add `emitDiagnosticsEvent(to:)` method. Call once after successful load.

**Tests**:
- `testDiagnosticsEventEmittedAfterLoad`
- `testDiagnosticsSummaryContainsLoadedTrue`

## Task 4: Test FAE_DISABLE_STREAMING_ASR env var gate

**Files**: `Sources/Fae/ML/ModelManager.swift`, `Tests/HandoffTests/ModelManagerParakeetTests.swift`

Extract env var check into testable `isStreamingASRDisabledByEnvironment(_:)`.

**Tests**:
- `testEnvVarGate_DisabledWhenSet`
- `testEnvVarGate_EnabledWhenAbsent`
- `testEnvVarGate_EnabledWhenZero`
- `testEnvVarGate_EnabledWhenOtherValue`

## Task 5: Config parsing and forwarding tests

**Files**: `Tests/IntegrationTests/ParakeetStreamingEngineTests.swift`

Verify config values flow through to engine constructor and load call.

**Tests**:
- `testConfigChunkSamplesForwardedToEngine`
- `testConfigModelIdForwardedToEngine`
- `testStreamingASRConfigTomlRoundTrip`

## Task 6: Graceful fallback test — load failure leaves pipeline functional

**Files**: `Tests/HandoffTests/ModelManagerParakeetTests.swift`

Mock engine factory that throws on load → verify `parakeetAvailable == false`, no error propagates.

**Tests**:
- `testLoadFailureLeavesPipelineFunctional`
- `testLoadSuccessSetsPipelineAvailable`
- `testLoadFailureDoesNotThrow`

## Task 7: Verify FaeCore → PipelineCoordinator wiring

**Files**: `Tests/HandoffTests/ModelManagerParakeetTests.swift`

Verify non-nil/nil parakeetEngine flows correctly to PipelineCoordinator.

**Tests**:
- `testParakeetEngineWiredToPipelineCoordinatorWhenLoaded`
- `testNilParakeetEngineDoesNotBlockPipelineStart`
