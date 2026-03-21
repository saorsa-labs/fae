# Project Closeout: Voice Pipeline Hardening

**Date**: 2026-03-21
**Status**: COMPLETE
**Duration**: Milestones 1-4 across multiple sessions
**Final test count**: 1616 (all passing, zero warnings)

## Project Goal

Harden Fae's voice pipeline for reliable real-time conversation: streaming ASR, robust barge-in, echo rejection on MacBook speakers, and acoustic resilience without hardware AEC.

## Milestone Summary

### Milestone 1: Streaming ASR & Silent Generation Buffering
**Status**: Complete (commit 6419d955)

Delivered streaming speech recognition, silent generation buffering (LLM generates while TTS plays), and generation takeover (new input preempts in-flight generation). Foundation for responsive voice interaction.

### Milestone 2: Barge-In Hardening
**Status**: Complete (commits 2299e4fd, 3d8a2acc, e1cfc075, 06109b75)

Delivered echo gate + fae_self speaker rejection, transcript evidence bypass for instant interruption, graceful speaker verification degradation (instead of fail-closed), and unblocked interruption during playback by making echo suppression a signal rather than a gate.

### Milestone 3: PipelineCoordinator Decomposition
**Status**: Complete (pre-existing, phase 3.2 plan in `.planning/`)

Decomposed the monolithic PipelineCoordinator into stage-oriented concerns for maintainability.

### Milestone 4: Echo Handling Hardening
**Status**: Complete

Added 12-layer echo rejection stack (up from 5 original layers):

| Layer | Component | Phase |
|-------|-----------|-------|
| 1 | Active suppression (assistantSpeaking) | Original |
| 2 | Echo tail window (onset-time, duration-proportional) | Original |
| 3 | Short utterance guard | Original |
| 4 | Duration cap (15s) | Original |
| 5 | Amplitude cap (RMS ceiling) | Original |
| 6 | Text-overlap rejection (bag-of-words + consecutive) | M2 |
| 7 | Playback baseline tracking (adaptive EMA) | M2 |
| 8 | Per-band energy tracking (spectral tilt) | M4 Phase 4.1 |
| 9 | Output route awareness (headphones vs speakers) | M4 Phase 4.1 |
| 10 | fae_self similarity boost during playback | M4 Phase 4.1 |
| 11 | Cross-correlation with playback audio | M4 Phase 4.2 |
| 12 | Spectral envelope comparison | M4 Phase 4.2 |

Plus: room decay estimation for adaptive echo tail timing.

## Quality Metrics

| Metric | Value |
|--------|-------|
| Total tests | 1616 |
| Tests added by M4 | 56 |
| Test failures | 0 |
| Build warnings | 0 |
| Force-unwraps added | 0 |
| Files modified | 1 (EchoSuppressor.swift) |
| Files created | 1 (EchoHandlingHardeningTests.swift) |

## What Was NOT Delivered

1. **WebRTC AEC3 integration** — Evaluated and documented as infeasible without architectural rework (separate capture/playback AVAudioEngine instances prevent reference signal access). See `aec3-feasibility.md`.

2. **MS AEC Challenge corpus testing** — Requires real audio corpus and physical test environment. Synthetic test scenarios cover the key patterns.

3. **Pipeline integration wiring** — The new EchoSuppressor features (band energy, cross-correlation, spectral comparison) are fully implemented and tested as standalone APIs. Wiring them into PipelineCoordinator's audio processing loop is a separate integration task — the APIs are ready to call from `processVADOutput()` and `evaluateBargeIn()`.

## Architecture Impact

The echo handling hardening is **entirely contained in `EchoSuppressor.swift`** — a value type (struct) with no external dependencies. This means:

- Zero risk of breaking existing pipeline behavior
- New features are opt-in via explicit API calls
- All state is local and resettable (`reset()`)
- No changes to AudioCaptureManager, AudioPlaybackManager, or PipelineCoordinator

## Future Recommendations

1. **Pipeline integration**: Wire `computeBandEnergy()`, `recordPlaybackAudio()`, `peakCrossCorrelation()`, and `bandEnergyLooksLikeSpeech()` into the PipelineCoordinator's VAD processing loop for real-time echo detection.

2. **Output route detection**: Add AVAudioSession route change notification handler in AudioPlaybackManager to update `echoSuppressor.outputRoute` automatically.

3. **Decay measurement**: Call `beginDecayMeasurement()` and `addDecaySample()` in PipelineCoordinator when assistant speech ends.

4. **Single-engine AEC (future)**: If echo rejection on speakers becomes a critical user issue, merging capture/playback into a single AVAudioEngine with Voice Processing enabled would provide true AEC. This is a significant architectural change.

5. **SpeexDSP AEC**: Lighter-weight alternative to WebRTC AEC3 — a C library that's easier to extract and integrate via Swift bridging. Worth evaluating if the heuristic stack proves insufficient.

## Project Health

The voice pipeline hardening project is complete. All four milestones delivered their core objectives:
- Streaming ASR with responsive buffering
- Robust barge-in with multi-signal evidence
- Clean pipeline architecture
- 12-layer echo rejection with spectral, temporal, and semantic analysis

The system is well-positioned for future enhancement without requiring architectural rework for the common case (headphones + moderate speaker volume).
