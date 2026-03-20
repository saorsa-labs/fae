# Phase 3.1: Extract SpeechInputStage + SpeakerGate

## Overview

Extract two actor boundaries from PipelineCoordinator:
1. **SpeechInputStage** — VAD loop, speech segment queue, audio feeding to streaming STT
2. **SpeakerGateActor** — speaker verification, enrollment state, role policy

## Approach

**Key constraint**: PipelineCoordinator is a Swift `actor`. Extracted types must integrate without changing observable behavior. We use a **protocol-first, move-behind-protocol** strategy:

1. Define protocols/types for the extracted concerns
2. Move state + logic behind new types (still called from coordinator)
3. Coordinator delegates to new types instead of managing state directly

**NOT creating separate Swift actors yet** — that would require async boundaries that change timing semantics. Phase 3.1 extracts into plain types/structs owned by the coordinator, reducing its line count and state variable count while preserving identical runtime behavior. True actor extraction (with async channels) comes in Phase 3.4 after all extractions are proven safe.

## Tasks

### Task 1: Define SpeechInputStage type with speech segment queue

**Goal**: Move speech segment queue management into `SpeechInputStage`.

**Files to create**:
- `Sources/Fae/Pipeline/SpeechInputStage.swift`

**State to move from PipelineCoordinator**:
- `speechSegmentTask`, `speechSegmentContinuation`, `speechSegmentQueueDepth`, `speechSegmentsDroppedForBackpressure`

**Methods to move**:
- `startSpeechSegmentProcessingLoop()`
- `stopSpeechSegmentProcessingLoop()`
- `enqueueSpeechSegment()`

**Coordinator changes**: Replace direct state access with calls to `SpeechInputStage`.

**Tests**: Build + all 1560 tests pass.

---

### Task 2: Move streaming STT feeding logic into SpeechInputStage

**Goal**: Move the streaming audio feeding logic (fast-path Parakeet + slow-path Qwen3-ASR) into SpeechInputStage.

**State to move**:
- `streamingEpoch`
- `lastStreamingPartialTranscript`
- `streamingSTTEngine` reference

**Logic to move**: The streaming audio feeding block from `runPipelineLoop()` (lines ~3578-3630) — the part that feeds audio to both STT engines and handles partial transcripts.

**SpeechInputStage gains**: `feedStreamingAudio(chunk:vadOutput:)` method.

**Tests**: Build + all 1560 tests pass.

---

### Task 3: Move streaming speaker gate into SpeakerGateActor

**Goal**: Extract speaker gate state and evaluation into `SpeakerGateActor`.

**Files to create**:
- `Sources/Fae/Pipeline/SpeakerGateActor.swift`

**State to move from PipelineCoordinator** (MARK: Speaker Identity State):
- `currentSpeakerLabel`, `currentSpeakerDisplayName`, `currentSpeakerRole`, `currentSpeakerIsOwner`
- `currentSpeakerIsKnownNonOwner`, `speakerEncoderMelFallbackCached`
- `previousSpeakerLabel`, `utterancesSinceOwnerVerified`, `currentUtteranceTimestamp`
- `streamingSpeakerSamples`, `streamingSpeakerLastEvaluatedSamples`, `streamingSpeakerVerdict`, `streamingSpeakerVerificationAvailable`

**State to move** (MARK: Enrollment State):
- `firstOwnerEnrollmentActive`, `firstOwnerEnrollmentContext`

**Methods to move**:
- `updateStreamingSpeakerGate(chunk:vadOutput:)`
- `resetStreamingSpeakerGate()`
- `shouldDropSegmentFromStreamingSpeakerGate()`
- Speaker verification methods used during segment processing

**Tests**: Build + all 1560 tests pass.

---

### Task 4: Wire SpeakerGateActor into segment processing path

**Goal**: Replace direct speaker state access in `handleSpeechSegment()` and `processTranscription()` with calls through SpeakerGateActor.

**Key integration points**:
- `handleSpeechSegment()` uses speaker state for identity checks
- `processTranscription()` uses speaker role for tool access decisions
- `processRecognizedVoiceText()` uses enrollment state

**Coordinator changes**: Access speaker state via `speakerGate.currentSpeakerLabel` etc. instead of direct vars.

**Tests**: Build + all 1560 tests pass.

---

### Task 5: Move wake word detection state into SpeechInputStage

**Goal**: Move the streaming wake word detection state into SpeechInputStage.

**State to move**:
- `streamingWakeSamples`, `streamingWakeLastEvaluatedSamples`, `streamingWakeDetection`
- `acousticWakeEvalStrideSamples`

**Methods to move**:
- `updateStreamingWakeDetector(chunk:vadOutput:)`
- `resetStreamingWakeDetector()`

**Tests**: Build + all 1560 tests pass.

---

### Task 6: Integration verification and line count audit

**Goal**: Verify the extraction reduced coordinator complexity and all tests pass.

**Checks**:
- `swift build` — zero warnings
- `swift test` — 1560 tests, 0 failures
- Line count: PipelineCoordinator should be ~200-400 lines shorter
- State variable count: ~20 fewer vars in coordinator
- New files have doc comments on all public types/methods
- No force unwraps in new code

**Update**: CLAUDE.md file inventory for Pipeline/ section (now 12 files).
