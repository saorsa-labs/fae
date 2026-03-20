# Phase 2.1: Parakeet TDT Streaming Engine Integration

## Context

The vendored `mlx-audio-swift` already contains a complete Parakeet TDT implementation
(`Sources/MLXAudioSTT/Models/Parakeet/`) with CTC, TDT, TDT-CTC, and RNNT variants.
The model supports `generate()` (batch) and `generateStream()` (chunked streaming).

The existing `StreamingSTTEngine` protocol is stubbed in `Sources/Fae/ML/StreamingSTTEngine.swift`
and defines: `feedAudio`, `getPartialTranscript`, `getFinalTranscript`, `reset`, `isLoaded`, `load`.

**Approach**: Build `ParakeetStreamingEngine` as an actor wrapping `ParakeetModel` from
mlx-audio-swift. Use the CTC decode path for frame-independent chunk processing. The MLX
implementation runs on GPU but Parakeet-TDT-0.6B is lightweight enough (~600M params, 4-bit)
that it can share the GPU with Qwen3-ASR without contention since they never run simultaneously
(Parakeet runs during speech, Qwen3-ASR runs after speech ends). CoreML ANE conversion is
deferred to Phase 2.4 as an optimization if GPU contention is measured.

**Model**: `mlx-community/parakeet-tdt-0.6b-v3` (TDT variant, 0.6B params).

## Tasks

### Task 1: ParakeetStreamingEngine actor — skeleton + load

**Files**: `Sources/Fae/ML/ParakeetStreamingEngine.swift` (new)

Create the `ParakeetStreamingEngine` actor conforming to `StreamingSTTEngine` protocol:
- Import `MLXAudioSTT` and `MLX`
- Implement `load()` using `ParakeetModel.fromPretrained("mlx-community/parakeet-tdt-0.6b-v3")`
- Store loaded model, track `isLoaded` state with `MLEngineLoadState`
- Implement stub versions of `feedAudio`, `getPartialTranscript`, `getFinalTranscript`, `reset`
- Add doc comments on all public members
- Hardcode model ID as a static constant with doc explaining the choice

### Task 2: Audio buffering and mel spectrogram in feedAudio

**Files**: `Sources/Fae/ML/ParakeetStreamingEngine.swift`

Implement the audio accumulation and mel spectrogram pipeline:
- `feedAudio(_ samples: [Float])` appends to internal `audioBuffer: [Float]`
- When buffer exceeds a configurable chunk threshold (default: 8000 samples = 500ms at 16kHz),
  compute log-mel spectrogram via `ParakeetAudio.logMelSpectrogram()` using the model's
  `preprocessConfig`
- Run CTC/TDT decode on the accumulated mel frames via `model.decode(mel:)`
- Extract text from `ParakeetAlignedResult` and store as current partial transcript
- Track decode timing for latency benchmarking
- `reset()` clears audioBuffer, partial transcript, and decode state

### Task 3: getPartialTranscript and getFinalTranscript

**Files**: `Sources/Fae/ML/ParakeetStreamingEngine.swift`

Complete the transcript retrieval methods:
- `getPartialTranscript()` returns the latest decoded text from the most recent `feedAudio` decode
- `getFinalTranscript()` runs one final decode on all accumulated audio, returns the result,
  then calls `reset()` to prepare for the next segment
- Apply basic text cleanup (trim whitespace, collapse multiple spaces)
- Add confidence estimation based on CTC posterior probabilities if available,
  otherwise return nil confidence
- Emit `StreamingSTTResult` objects with proper `isFinal` and `timestamp` fields

### Task 4: Unit tests for ParakeetStreamingEngine

**Files**: `Tests/IntegrationTests/ParakeetStreamingEngineTests.swift` (new)

Write tests that validate the engine without requiring the actual model download:
- Test that `isLoaded` is false before `load()` is called
- Test that `feedAudio` with empty samples does not crash
- Test that `reset()` clears partial transcript to empty string
- Test that `getPartialTranscript()` returns empty string before any audio is fed
- Test that `getFinalTranscript()` returns empty string and resets state when no audio buffered
- Test audio buffer accumulation: feed known samples, verify buffer grows
- Mock-based test: create a `MockParakeetStreamingEngine` conforming to `StreamingSTTEngine`
  to verify protocol conformance without real model

### Task 5: Wire ParakeetStreamingEngine into ModelManager

**Files**: `Sources/Fae/ML/ModelManager.swift`

Add Parakeet loading to ModelManager:
- Add `private(set) var parakeetEngine: ParakeetStreamingEngine?` property
- Add `loadParakeetIfAvailable()` async method that:
  - Creates `ParakeetStreamingEngine` instance
  - Calls `load()` with error handling (non-fatal — Parakeet is optional fast-path)
  - Logs success/failure via NSLog
  - Reports progress via eventBus
- Call `loadParakeetIfAvailable()` during model loading sequence (after STT, before TTS)
  so it loads in parallel concept but sequentially to avoid GPU memory spike
- Add `parakeetAvailable: Bool` computed property for pipeline queries
- Emit `.runtimeProgress` event with Parakeet load status

### Task 6: FaeConfig streaming ASR settings

**Files**: `Sources/Fae/Core/FaeConfig.swift`

Add configuration for the streaming ASR fast-path:
- Add `StreamingASRConfig` struct with:
  - `enabled: Bool` (default: `true` — on by default)
  - `modelId: String` (default: `"mlx-community/parakeet-tdt-0.6b-v3"`)
  - `chunkSamples: Int` (default: `8000` — 500ms at 16kHz)
  - `minChunkSamples: Int` (default: `4000` — 250ms minimum before first decode)
- Add `streamingASR: StreamingASRConfig` to `FaeConfig`
- Wire config values into `ParakeetStreamingEngine` via `ModelManager`
- Add doc comments explaining the dual-path ASR architecture

### Task 7: Benchmark scaffolding and smoke test

**Files**: `Sources/Fae/ML/ParakeetStreamingEngine.swift`, `Tests/IntegrationTests/ParakeetStreamingEngineTests.swift`

Add benchmarking instrumentation:
- Add `lastDecodeLatencyMs: Double?` property to `ParakeetStreamingEngine`
- Add `totalDecodeCount: Int` and `averageDecodeLatencyMs: Double` for aggregate stats
- Add `peakMemoryBytes: Int` tracking (via `MLX.GPU.snapshot().peakMemory`)
- Add test that verifies benchmark properties are correctly tracked (mock path)
- Add `diagnosticsSummary() -> String` method for debug console output
- Log latency per decode pass at debug level via NSLog
