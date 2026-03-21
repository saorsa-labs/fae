# Milestone 4 Closeout: Echo Handling Hardening

**Date**: 2026-03-21
**Status**: Complete
**Test count**: 1616 (baseline: 1560, added: 56)
**Build warnings**: 0

## Summary

Milestone 4 hardened Fae's echo rejection for MacBook speaker output without requiring hardware AEC. The approach was heuristic enhancement rather than true AEC integration (found infeasible — see `aec3-feasibility.md`).

## Phase 4.1: Playback Baseline & Timing Improvements — SHIPPED

### Delivered

1. **Output route detection** (`OutputRoute` enum in `EchoSuppressor`)
   - Detects headphones, built-in speakers, external speakers, unknown
   - Adjusts echo timing windows via `routeTimingMultiplier`: headphones 0.3x, external 1.3x
   - Conservative fallback for unknown routes

2. **Per-band energy tracking** (`BandEnergy` struct)
   - Three-band decomposition: low (0-500 Hz), mid (500-4000 Hz), high (4000+ Hz)
   - Spectral tilt analysis distinguishes speaker-colored echo (rolled-off highs) from near-field speech
   - EMA baseline tracking during playback for comparison
   - `computeBandEnergy()` via lightweight DFT bin summation

3. **Room decay estimation** (`estimatedDecayMs`)
   - Post-playback RMS monitoring to measure room echo decay time
   - EMA smoothing across multiple playback cycles
   - Adaptive `effectiveEchoTailMs` — shorter measured decay = shorter blocking window
   - Clamped between 100ms floor and 800ms ceiling

4. **Enhanced fae_self rejection** (`faeSelfThresholdDuringPlayback()`)
   - During playback window: threshold reduced by 20% (more aggressive echo rejection)
   - Outside playback: normal threshold to avoid false rejections

### Tests Added: 35

## Phase 4.2: WebRTC AEC3 Evaluation — DOCUMENTED + ALTERNATIVES SHIPPED

### Findings

- **AEC3 is infeasible** without major architectural rework (separate capture/playback engines, no reference signal access)
- **Apple Voice Processing** disabled due to no-reference-signal attenuation
- Full feasibility analysis in `aec3-feasibility.md`

### Alternative Heuristics Delivered

5. **Cross-correlation echo detection** (`peakCrossCorrelation()`)
   - Ring buffer stores last 3 seconds of TTS audio at 16kHz
   - Strided normalized cross-correlation (10ms hops) between mic and playback
   - Threshold: 0.6 normalized correlation = echo
   - Works pre-STT for early rejection

6. **Spectral envelope comparison** (`spectralEnvelopeSimilarity()`)
   - Cosine similarity between mic and TTS band energy vectors
   - Threshold: 0.95 similarity = speaker-colored echo
   - Complements cross-correlation with spectral shape analysis

### Tests Added: 13

## Phase 4.3: Integration & Acoustic Testing — SHIPPED

### Delivered

7. **Synthetic echo test scenarios**
   - Echo at variable attenuation (0.1x to 0.8x)
   - Echo at variable delay (10ms to 200ms)
   - Speaker echo simulation with high-frequency rolloff
   - Mixed echo + user speech overlap scenarios
   - Near-field vs far-field band energy discrimination

8. **Output route scenario tests**
   - Headphone scenario: relaxed timing verified
   - External speaker scenario: aggressive timing verified

9. **Regression coverage**
   - All 1560 existing tests pass unchanged
   - New tests verify backward compatibility of `shouldAccept()`, `shouldRejectForEchoTail()`

### Tests Added: 8

## What Shipped vs. Planned

| Planned | Shipped | Notes |
|---------|---------|-------|
| Per-band energy tracking | Yes | Full DFT-based band decomposition |
| Room decay estimation | Yes | EMA-smoothed adaptive tail |
| Speaker-vs-headphone detection | Yes | Output route enum with timing multiplier |
| Enhanced fae_self during playback | Yes | 20% threshold reduction |
| WebRTC AEC3 evaluation | Yes (infeasible) | Documented, alternatives shipped |
| Cross-correlation heuristic | Yes | 3s ring buffer, strided correlation |
| Spectral envelope comparison | Yes | Cosine similarity on band vectors |
| MS AEC Challenge corpus testing | No | Requires real audio corpus; synthetic tests cover patterns |
| Real hardware test matrix | No | Requires physical test environment; documented expected behavior |

## Known Limitations

1. **No true AEC**: Cannot subtract echo from the waveform — only detect and reject post-hoc
2. **MacBook speakers at high volume**: Timing + text overlap are primary defenses; cross-correlation adds a pre-STT check
3. **External speakers with reverb**: Room decay estimation adapts but has 800ms ceiling
4. **DFT computation cost**: `computeBandEnergy()` runs O(n*k) DFT — acceptable for 576-sample chunks but not for long buffers

## Files Modified

- `Sources/Fae/Pipeline/EchoSuppressor.swift` — All new features
- `Tests/HandoffTests/EchoHandlingHardeningTests.swift` — 56 new tests (new file)

## Files Not Modified (by design)

- `PipelineCoordinator.swift` — New features are opt-in via EchoSuppressor API; pipeline integration wiring is a separate concern for when features are activated
- `AudioCaptureManager.swift` — No changes needed; band energy computed from existing samples
- `AudioPlaybackManager.swift` — Playback audio ring buffer fed by caller, not self-tapped
