# Milestone 2 Closeout: Parakeet TDT Dual-Path Streaming ASR

**Date**: 2026-03-20
**Status**: COMPLETE with caveats
**Verdict**: PASS as integration milestone, NOT proven as performance milestone

---

## What shipped

- `ParakeetStreamingEngine` actor (230 lines) conforming to `StreamingSTTEngine` protocol
- Wired into ModelManager, FaeCore, PipelineCoordinator as optional fast-path
- Audio fed to Parakeet in capture loop alongside Qwen3-ASR
- Vocabulary correction applied to all streaming partials
- StreamingPartialSource enum for fast/slow path tracking
- Disagreement detection between Parakeet and Qwen3-ASR
- Graceful degradation: Parakeet is nil-safe throughout; loading failure falls back silently
- FaeConfig.StreamingASRConfig for model ID, chunk sizes, enable flag
- 19 new tests (protocol conformance, state, config, dual-path mock, regression)

## What did NOT ship from the original roadmap

| Planned | Actual | Status |
|---------|--------|--------|
| CoreML Neural Engine target | MLX via vendored mlx-audio-swift | Changed — defensible |
| True incremental CTC decode | Periodic whole-buffer decode | Not achieved |
| Partial latency <100ms target | Not measured | Deferred |
| Eval corpus validation | Structural tests only | Deferred |
| Neural Engine contention check | Not applicable (MLX path) | N/A |
| Real audio fixture tests | Mock-based only | Deferred |

## Central technical limitation

**`ParakeetStreamingEngine.runDecode()` decodes the entire accumulated audio buffer on each
pass.** `decodedSampleCount` only gates cadence (when to run the next decode), not incremental
advancement (which frames to skip).

This means:
- Decode latency grows with utterance length (not constant per chunk)
- Compute cost scales with total accumulated audio
- The architectural advantage over Qwen3-ASR growing-buffer streaming is limited to:
  model is lighter (0.6B vs 1.7B), and decode cadence is independent

**Path to true incremental decode**: Expose the Parakeet conformer encoder's internal state
(hidden states, attention cache) so that `runDecode()` can process only new frames and
concatenate with cached encoder output. This requires changes to mlx-audio-swift's
`ParakeetModel` API (currently `generate()` is the only public entry point; `decode(mel:)`
is internal).

## Roadmap drift reconciliation

The roadmap originally promised CoreML Neural Engine integration. The implementation used
MLX instead because:
1. The Parakeet model was already available via vendored mlx-audio-swift
2. CoreML conversion was an unknown-length yak shave with uncertain quality
3. MLX provides immediate functionality while CoreML ANE remains a future optimization

This was a defensible engineering trade-off. The roadmap has been updated to reflect reality.

## Known residual risks

| Risk | Severity | Notes |
|------|----------|-------|
| Growing-buffer decode latency on long utterances | Medium | Will degrade on >10s speech segments |
| GPU contention: Parakeet + Qwen3-ASR + TTS on same MLX device | Medium | Not measured; Parakeet only runs during active speech |
| No real acoustic validation | High | All tests are structural/mock; real audio quality unknown |
| mlx-audio-swift API limitations | Low | `decode(mel:)` is internal; incremental decode blocked |

## Commits

1. `3a9019ab` — Phase 2.1: ParakeetStreamingEngine, config, ModelManager, 12 tests
2. `6c791ced` — Phase 2.2: Fast-path wiring into PipelineCoordinator
3. `e1352c03` — Phase 2.3: Dual-path orchestration, vocab correction, disagreement tracking
4. `b2ad9d42` — Phase 2.4: 7 regression tests

## Test coverage

| File | Tests | Coverage area |
|------|-------|--------------|
| `ParakeetStreamingEngineTests.swift` | 19 | Protocol, state, config, dual-path mock |
| **Total** | **19** | Structural + regression |

Final test suite: **1560 tests, 0 failures, 0 warnings**

## Handoff to Milestone 3

Milestone 3 (PipelineCoordinator Decomposition) is independent of the Parakeet incremental
decode limitation. The dual-path wiring in PipelineCoordinator will be part of what gets
decomposed into a `SpeechInputStage` actor.

## What would make this a fully proven performance milestone

1. One recorded audio fixture (5-10s speech) with Parakeet partial output snapshots at each
   decode pass, showing latency and text progression
2. Side-by-side comparison: Parakeet partials vs Qwen3-ASR partials on same audio
3. Decode latency measurement: per-pass ms at buffer sizes of 1s, 3s, 5s, 10s
4. GPU contention measurement: LLM tokens/sec with and without concurrent Parakeet decode
