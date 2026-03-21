# Phase 4.1: Playback Baseline & Timing Improvements

## Goal
Improve echo rejection accuracy by adding spectral awareness, output route detection, and stronger fae_self rejection during playback.

## Tasks

### Task 1: Audio Output Route Detection
Add speaker-vs-headphone detection using AVAudioSession/AVAudioEngine output route inspection. When headphones are detected, echo suppression can be more relaxed (no speaker bleedthrough). When speakers are active, use more aggressive windows.

**Files**: `EchoSuppressor.swift`, `AudioPlaybackManager.swift`

### Task 2: Per-Band Energy Tracking
Replace single broadband RMS playback baseline with per-frequency-band energy tracking (low/mid/high). Echo from speakers has characteristic spectral shape (attenuated highs, boosted mids). This allows distinguishing user speech (full spectrum) from echo (speaker-colored).

**Files**: `EchoSuppressor.swift`, `AudioCaptureManager.swift`

### Task 3: Room Decay Estimation
Estimate room reverb decay time from the tail of playback segments. Use this to dynamically adjust echoTailMs instead of fixed constants. Shorter decay = shorter tail = faster response.

**Files**: `EchoSuppressor.swift`

### Task 4: Enhanced fae_self Rejection During Playback
During active playback window, lower the fae_self speaker embedding similarity threshold. Currently uses unified threshold — during playback, echo is more likely, so accept lower similarity as evidence of echo.

**Files**: `EchoSuppressor.swift`, `PipelineCoordinator.swift`

### Task 5: Tests for Phase 4.1
Unit tests for all new functionality: output route detection, per-band energy, room decay, enhanced fae_self threshold.

**Files**: `Tests/HandoffTests/EchoHandlingHardeningTests.swift`

## Success Criteria
- `swift build` zero warnings
- `swift test` all pass (existing + new)
- Output route detection correctly identifies headphones vs speakers
- Per-band energy provides better echo/speech discrimination signal
