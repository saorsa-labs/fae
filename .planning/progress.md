# Voice Pipeline Hardening — Progress Log

## Milestone 1: Sentence-Level TTS Pipelining — COMPLETE

### Phase 1.1: Enable Per-Sentence Streaming TTS
- [x] Task 1: Make preferFinalOnlySpeech configurable (default=false, streaming enabled)
- [x] Task 2: TextProcessing sentence/clause boundary tests (21 tests, all pass)
- [x] Task 3: Short/single-sentence response handling (verified existing turn-end path works)
- [x] Task 4: Double-synthesis prevention (deferredSentenceQueue empty in streaming mode, debug logging added)
- [x] Task 5: Orb state wired to streaming TTS (markAssistantSpeechStarted in enqueueTTS, no changes needed)
- [x] Task 6: Barge-in during queued playback (pendingTTSTask cancellation already handles chained sentences)
- [x] Task 7: Full build + test validation (1516 tests, 0 failures)

### Phase 1.2: Prosody & Latency Tuning
- [x] Task 1: TTFA instrumentation (time-to-first-audio logging + streaming summary at turn end)
- [x] Task 2: Clause-level timeout fallback (3s timeout triggers clause flush regardless of buffer size)
- [x] Task 3: Tuned minSentenceChunkChars 28→40; first-sentence exception for instant acknowledgment
- [x] Task 4: GPU contention mitigation (Task.yield() after TTS synthesis in pendingTTSTask chain)
- [x] Task 5: Build + test validation (1516 tests, 0 failures)

### Phase 1.3: Testing & Hardening
- [x] Task 1: FaeConfig regression tests — 3 tests (preferFinalOnly default, enable, explicit false)
- [x] Task 2: batchedTTSSegments edge cases — 8 tests (empty, short, long, emoji, code, order)
- [x] Task 3: Sentence boundary edge cases — 7 tests (>420 chars, emoji, multi-flush simulation, parens, whitespace)
- [x] Task 4: looksLikeNonProse TTS filter — 7 tests (XML, JSON, prose, short, numbers, symbols, markdown)
- [x] Task 5: Build + test validation (1541 tests, 0 failures)
- [x] Bug fix: FaeConfig TOML parser missing preferFinalOnly/prefer_final_only case + save() serializer

### Milestone 1 Evidence

**Files changed** (source):
- `Sources/Fae/Pipeline/PipelineCoordinator.swift` — streaming TTS path, thresholds, instrumentation
- `Sources/Fae/Core/FaeConfig.swift` — `tts.preferFinalOnly` config + TOML parser/serializer

**Files created** (tests):
- `Tests/HandoffTests/TextProcessingTests.swift` — 28 tests (sentence/clause boundary + looksLikeNonProse)
- `Tests/HandoffTests/VoicePipelineRegressionTests.swift` — 8 tests (batchedTTSSegments edge cases)
- `Tests/HandoffTests/FaeConfigTests.swift` — 3 tests (preferFinalOnly config regression)

**Test count**: 1516 → 1541 (+25 new tests), 0 failures
**Build**: zero warnings on `swift build`

**Baseline commits** (work this milestone builds on):
- `6419d955` feat(voice-pipeline): streaming ASR, silent generation buffering, generation takeover
- `ed798005` feat(voice-pipeline): neural turn detector wiring + speculative LLM prefill

---

## Milestone 2: Parakeet TDT Dual-Path Streaming ASR

### Phase 2.1: Parakeet TDT Integration — COMPLETE

- [x] Task 1: ParakeetStreamingEngine actor — skeleton + load
- [x] Task 2: Audio buffering and mel spectrogram in feedAudio
- [x] Task 3: getPartialTranscript and getFinalTranscript
- [x] Task 4: Unit tests for ParakeetStreamingEngine (12 tests, all passing)
- [x] Task 5: Wire ParakeetStreamingEngine into ModelManager
- [x] Task 6: FaeConfig StreamingASRConfig
- [x] Task 7: Benchmark scaffolding and diagnostics

### Phase 2.1 Evidence

**Files created**:
- `Sources/Fae/ML/ParakeetStreamingEngine.swift` — actor wrapping Parakeet TDT via mlx-audio-swift
- `Tests/IntegrationTests/ParakeetStreamingEngineTests.swift` — 12 tests (protocol conformance, state, mock)

**Files modified**:
- `Sources/Fae/Core/FaeConfig.swift` — added `StreamingASRConfig` struct + `streamingASR` field
- `Sources/Fae/ML/ModelManager.swift` — `parakeetEngine` property, `loadParakeetIfAvailable()`, wiring in `loadAll()`

**Test count**: 1541 -> 1553 (+12 new tests), 0 failures
**Build**: zero warnings on `swift build`

**Key design decisions**:
- Used MLX Parakeet from vendored mlx-audio-swift (not CoreML conversion) — model already available
- Parakeet `decode(mel:)` is internal; used public `generate()` API instead
- Non-fatal loading: Parakeet failure falls back to existing growing-buffer Qwen3-ASR

**Honest limitation**: Current `runDecode()` still decodes the entire accumulated audio buffer
on each pass (growing-buffer periodic decode with a lighter model). `decodedSampleCount` only
gates cadence, not incremental slice advancement. True incremental CTC decode (skip
already-processed frames) requires exposing the encoder's internal state or using
`decode(mel:)` directly — deferred as future optimization. The primary benefit today is a
second, lighter model providing independent partials on a different decode cadence.

### Phase 2.2: Fast-Path Wiring — COMPLETE

- [x] Task 1: Add `streamingSTTEngine` property to PipelineCoordinator + init parameter
- [x] Task 2: Feed audio to Parakeet in capture loop alongside Qwen3-ASR
- [x] Task 3: Reset Parakeet at all 4 streaming epoch reset points
- [x] Task 4: Build (zero warnings) + test validation (1553 tests, 0 failures)

**Files modified**:
- `Sources/Fae/Pipeline/PipelineCoordinator.swift` — streaming fast-path feed + resets
- `Sources/Fae/Core/FaeCore.swift` — wire `parakeetEngine` from ModelManager into PipelineCoordinator

**Test count**: 1553 tests, 0 failures (no change)
**Build**: zero warnings on `swift build`

### Phase 2.3: Dual-Path Orchestration — COMPLETE

- [x] Task 1: Apply vocabulary correction to streaming partials (correctNameRecognition + DynamicVocabularyCorrector)
- [x] Task 2: Track fast-path vs. slow-path partials with StreamingPartialSource enum
- [x] Task 3: Disagreement detection: log when Parakeet and Qwen3-ASR diverge significantly
- [x] Task 4: Clear lastFastPathPartial at all 3 streaming reset points
- [x] Task 5: Adaptive fallback already handled (nil-safe streamingSTTEngine throughout)
- [x] Task 6: Build (zero warnings) + test validation (1553 tests, 0 failures)

**Files modified**:
- `Sources/Fae/Pipeline/PipelineCoordinator.swift` — vocabulary correction on partials, source tracking, disagreement logging

**Test count**: 1553 tests, 0 failures (no change)
**Build**: zero warnings on `swift build`

### Phase 2.4: Evaluation & Regression Testing — COMPLETE

- [x] Task 1: Dual-path mock simulation test (parallel feeding, independent reset)
- [x] Task 2: StreamingSTTResult equality and defaults tests
- [x] Task 3: KeywordBiasConfig defaults test
- [x] Task 4: FaeConfig.StreamingASRConfig defaults, custom values, and Codable round-trip tests
- [x] Task 5: Full build + test validation (1560 tests, 0 failures)

**Files modified**:
- `Tests/IntegrationTests/ParakeetStreamingEngineTests.swift` — 7 new dual-path regression tests

**Test count**: 1553 -> 1560 (+7 new tests), 0 failures
**Build**: zero warnings on `swift build`

### Milestone 2 Summary

**Total files created** (4):
- `Sources/Fae/ML/ParakeetStreamingEngine.swift` — 230 lines
- `Tests/IntegrationTests/ParakeetStreamingEngineTests.swift` — 19 tests
- `.planning/PLAN-phase-2.1.md`
- `.planning/PLAN-phase-2.2.md`

**Total files modified** (4):
- `Sources/Fae/Core/FaeConfig.swift` — StreamingASRConfig struct
- `Sources/Fae/ML/ModelManager.swift` — parakeetEngine loading
- `Sources/Fae/Pipeline/PipelineCoordinator.swift` — dual-path wiring, vocab correction, disagreement tracking
- `Sources/Fae/Core/FaeCore.swift` — wire parakeetEngine into PipelineCoordinator

**Test count**: 1541 -> 1560 (+19 new tests across 4 phases), 0 failures
**Build**: zero warnings throughout all phases

---

## Milestone 3: PipelineCoordinator Decomposition

### Phase 3.1: Extract SpeechInputStage + SpeakerGate

**Baseline**: PipelineCoordinator 10,080 lines, 1560 tests passing

- [x] Extract SpeechInputStage (speech segment queue, streaming epoch, wake detection state) (commit: a83c554a)
  - Created `SpeechInputStage.swift` (150 lines)
  - Moved ~15 state vars
  - 1560 tests pass, 0 warnings

- [x] Extract SpeakerGateState (speaker identity + enrollment + streaming speaker gate) (commit: c56aaf14)
  - Created `SpeakerGateState.swift` (99 lines)
  - Moved ~20 state vars into consolidated struct
  - 1560 tests pass, 0 warnings

- [x] Extract BargeInTypes (PendingBargeIn, PlaybackBargeInCandidate, GenerationTakeoverCandidate) (commit: 9dea0e66)
  - Created `BargeInTypes.swift` (75 lines)
  - 3 nested structs promoted to top-level types
  - 1560 tests pass, 0 warnings

- [x] Extract ToolCallParsing (ToolCall, ScriptBlock, parsing methods) (commit: d35b2112)
  - Created `ToolCallParsing.swift` (221 lines)
  - ~190 lines of parsing logic extracted (forwarding methods preserved API)
  - Updated 7 files referencing PipelineCoordinator.ToolCall/ScriptBlock
  - 1560 tests pass, 0 warnings

- [x] Extract PipelineTypes (PipelineMode, PipelineDegradedMode, GateState, etc.) (commit: 566e0a05)
  - Created `PipelineTypes.swift` (84 lines)
  - 6 nested enums promoted to top-level types
  - 1560 tests pass, 0 warnings

### Phase 3.1 Evidence

**PipelineCoordinator line count**: 10,080 -> 9,724 (-356 lines)
**New files created** (5): SpeechInputStage.swift, SpeakerGateState.swift, BargeInTypes.swift, ToolCallParsing.swift, PipelineTypes.swift (629 lines total)
**State variables moved out of coordinator**: ~35 (speech input, speaker gate, streaming wake)
**Nested types extracted to top level**: 9 (3 structs + 6 enums)
**Test count**: 1560 tests, 0 failures throughout
**Build**: zero warnings throughout
