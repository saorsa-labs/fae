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
- CTC decode path is frame-independent — true chunk-based streaming without re-transcription
