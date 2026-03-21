# Project Closeout: Voice Pipeline Hardening

**Date**: 2026-03-21
**Status**: COMPLETE
**Final test count**: 1616 (all passing, zero warnings)

## Project Goal

Address the 4 weakest areas identified in the voice pipeline review:
1. TTS is final-only — time-to-first-audio is poor
2. Streaming STT uses growing-buffer re-transcription — no lightweight fast-path
3. PipelineCoordinator is ~10K lines — every fix risks regressions
4. Echo handling is layered heuristics — fragile on speaker-out

## Milestone Summary

### Milestone 1: Sentence-Level TTS Pipelining
Enabled per-sentence streaming TTS (previously dead code behind `preferFinalOnlySpeech = true`).
First audio plays while LLM still generates subsequent sentences.
- `tts.preferFinalOnly` config (default: false)
- First-sentence exception for instant acknowledgment
- 3s clause timeout, GPU contention mitigation
- 39 tests added

### Milestone 2: Parakeet TDT Dual-Path Streaming ASR
Integrated Parakeet TDT 0.6B as second, lighter ASR providing independent streaming partials.
- ParakeetStreamingEngine actor via mlx-audio-swift
- Dual-path wiring with vocabulary correction and disagreement tracking
- Honest limitation: periodic whole-buffer decode, not true incremental CTC
- 19 tests added

### Milestone 3: PipelineCoordinator Decomposition
Reduced coordinator from 10,080 to 7,893 lines (-21.7%) via state extraction and pure function promotion.
- 10 new files, ~90 pure static functions extracted
- Honest limitation: core methods (generateWithTools, main loop) can't move without async boundary changes
- 0 tests added (pure refactor, all 1560 existing tests pass)

### Milestone 4: Echo Handling Hardening
Expanded echo rejection from 5 layers to 12 layers, fully wired into the live pipeline.
- Output route detection (startup + periodic polling)
- Per-band energy tracking with spectral tilt discrimination
- Room decay estimation with adaptive echo tail
- Cross-correlation with TTS playback ring buffer
- Spectral envelope cosine similarity
- Enhanced fae_self threshold during playback
- AEC3 evaluated as infeasible (documented in aec3-feasibility.md)
- 56 tests added

All layers are wired into PipelineCoordinator's runtime audio processing loop.

## Quality Metrics

| Metric | Value |
|--------|-------|
| Tests at start | 1516 |
| Tests at end | 1616 |
| Tests added | 100 (39 + 19 + 0 + 42 + ongoing wiring) |
| Test failures | 0 |
| Build warnings | 0 |
| PipelineCoordinator lines | 10,080 → ~7,900 (-21.7%) |

## What Was Not Delivered (honest)

| Planned | Status | Notes |
|---------|--------|-------|
| Coordinator <2K lines | Not achieved | Actor coupling prevents deeper extraction |
| True incremental CTC decode | Not achieved | Parakeet uses periodic whole-buffer decode |
| CoreML Neural Engine offload | Not pursued | MLX used instead (model already available) |
| Live acoustic corpus evaluation | Not done | Structural/synthetic tests only |
| WebRTC AEC3 | Infeasible | Documented in aec3-feasibility.md |
| MS AEC Challenge corpus | Not done | Requires real audio + physical test environment |

## Future Recommendations

1. **True incremental Parakeet decode**: Expose encoder internal state in mlx-audio-swift
2. **Single-engine AEC**: Merge capture/playback into one AVAudioEngine for real AEC
3. **Actor decomposition**: If async boundary changes are pursued, SpeechInputStage and TTSStage are the best candidates for full actor extraction
4. **Live testing**: Run the app with TTFA instrumentation to measure real streaming TTS improvement
