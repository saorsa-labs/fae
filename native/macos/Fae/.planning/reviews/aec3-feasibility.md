# WebRTC AEC3 Feasibility Assessment

**Date**: 2026-03-21
**Milestone**: 4.2 — Echo Handling Hardening
**Verdict**: **Infeasible** for Fae's current architecture. Enhanced heuristics implemented instead.

## 1. Reference Signal Access

### The Core Problem

AEC requires a **reference signal** — the exact audio being played out to the speakers — time-aligned with the microphone input. The AEC algorithm subtracts the estimated echo (derived from the reference) from the mic signal.

### macOS AVAudioEngine Limitations

Fae uses **separate AVAudioEngine instances** for capture and playback:
- `AudioCaptureManager` owns one `AVAudioEngine` for microphone input
- `AudioPlaybackManager` owns a separate `AVAudioEngine` for speaker output

**Why this matters:**
- macOS `AVAudioEngine` does not provide a "loopback tap" or "render callback" that gives you the final mixed audio being sent to the DAC
- Voice Processing (`setVoiceProcessingEnabled`) creates an aggregate audio unit that *could* provide AEC, but it requires capture and playback to share the same engine — Fae's architecture uses separate engines
- Enabling Voice Processing on the capture engine without a playback reference causes it to operate with a silent reference, which gates real mic input (documented in `AudioCaptureManager.configureVoiceProcessingIfAvailable`)

### Could We Get a Reference Signal?

**Option A: Merge into single AVAudioEngine** — Would require major architectural rework. The separate-engine design was chosen to avoid aggregate audio unit issues (HALC_ProxyIOContext errors, ~30dB attenuation without reference).

**Option B: Tap the playback engine's output** — We can install a tap on `engine.mainMixerNode` in `AudioPlaybackManager`, but this gives us audio at the mixer's sample rate and timing, not at the DAC output timing. The time alignment between this tap and the mic input is unpredictable (varies by audio device, buffer size, USB latency).

**Option C: Use the TTS samples directly** — We have the exact PCM samples being sent to TTS. But these are at 24kHz and go through resampling, speed adjustment, and the OS audio graph before reaching the speaker. The actual acoustic echo is the speaker-room-mic convolution of the *post-processing* signal, not the raw TTS output.

### Verdict: Reference signal access is **impractical** without architectural rework.

## 2. WebRTC AEC3 API Compatibility

### Build Complexity

- WebRTC's AEC3 lives in `modules/audio_processing/aec3/` — approximately 50+ C++ files
- Dependencies: `rtc_base`, `api/audio`, `modules/audio_processing/utility`, etc.
- No standalone AEC3 library — it's deeply embedded in WebRTC's build system (GN/Ninja)
- Extracting and building just AEC3 for Swift interop requires:
  - C wrapper around the C++ API
  - Static library compilation for arm64 macOS
  - Bridging header for Swift

### Licensing

WebRTC is BSD-3-Clause — compatible with Fae's license.

### Binary Size

Estimated 200-400KB for AEC3 alone, but pulling in dependencies could be 1-2MB.

### Runtime Requirements

AEC3 expects:
- 10ms audio frames at 16kHz or 48kHz
- Time-aligned reference and microphone signals (< 1ms jitter)
- Continuous reference signal (no gaps)

Our architecture cannot reliably provide these guarantees.

## 3. Alternative: Apple's Built-in AEC

macOS Voice Isolation (Neural Engine) provides system-level echo cancellation when enabled in Control Center. However:
- Not programmatically controllable — user must enable it manually
- macOS frequently reverts to "standard" mic mode
- Not available on all hardware

## 4. Chosen Approach: Enhanced Heuristics

Since AEC3 is infeasible without architectural rework, we enhanced the heuristic stack with:

### Phase 4.1 Delivered
1. **Per-band energy tracking** — Spectral shape discrimination (speaker-colored echo vs near-field speech)
2. **Output route detection** — Headphones vs speakers adjusts suppression aggressiveness
3. **Room decay estimation** — Adaptive echo tail based on measured post-playback decay
4. **Enhanced fae_self threshold** — Lower speaker embedding similarity threshold during playback window

### Phase 4.2 Delivered
5. **Cross-correlation with playback audio** — Correlate mic input with recent TTS output to detect echo patterns
6. **Spectral subtraction awareness** — Use known TTS spectral envelope to identify echo residue

## 5. Honest Assessment

### What Works Well
- Headphone scenario: excellent echo rejection (no speaker bleedthrough)
- MacBook speakers at low-moderate volume: good rejection via timing + text overlap + voice identity
- Per-band energy adds discriminative signal for near-field vs echo

### Known Limitations
- MacBook speakers at high volume: timing windows alone are insufficient; some echo segments may slip through to STT (caught by text-overlap layer)
- External speakers with significant reverb: room decay estimation helps but cannot fully compensate
- No true AEC means we cannot cancel echo from the waveform — we can only detect and reject it post-hoc

### Future Path
If echo rejection on speakers becomes a critical user issue:
1. **Merge to single AVAudioEngine** — Enable Voice Processing with proper reference
2. **SpeexDSP** — Lighter-weight C library with AEC, easier to extract than WebRTC
3. **Apple AudioUnit AEC** — If Apple exposes a first-party AEC AudioUnit in future macOS
