# Spike S17 — Cross-platform voice front-end

> **Status:** Proposed (2026-06-11)
> **Goal:** Prove the portable real-time voice front-end: audio I/O, VAD, wake, noise/AEC, speaker verification, endpointing, and barge-in.

## Candidate stack

- **Audio I/O:** cpal (CoreAudio, WASAPI, ALSA, PipeWire, JACK, PulseAudio).
- **VAD:** Silero VAD ONNX or sherpa-onnx VAD.
- **Wake:** openWakeWord ONNX/TFLite or sherpa-onnx keyword spotting.
- **Noise suppression:** RNNoise first; evaluate WebRTC APM/SpeexDSP for AEC and AGC.
- **STT:** whisper.cpp and/or sherpa-onnx streaming; Gemma/Qwen audio paths as model-level alternatives.
- **Speaker verification:** WeSpeaker/sherpa-onnx or current voiceprint-compatible ONNX encoder.
- **Barge-in:** mic/playback correlation plus VAD/ASR stop-word endpointing.

## Test matrix

- macOS built-in mic/speakers and headset.
- Linux PulseAudio/PipeWire and ALSA fallback.
- Windows WASAPI.
- Noisy-room, music-playing, and speaker-playback scenarios.

## Metrics

- Wake false accepts / false rejects.
- VAD segment accuracy and endpoint latency.
- STT partial/final latency.
- AEC/barge-in reliability while Fae is speaking.
- Speaker verification parity with existing enrollments.
- CPU use and memory footprint.
- Device hotplug and sleep/wake behavior.

## Acceptance criteria

- Stable duplex capture/playback on all three desktop OS families.
- VAD + endpointing good enough for hands-free conversation.
- Wake false-positive rate acceptable for daily use.
- Speaker verification can enforce the voice identity security model or clearly falls back to Apple-only for v1.
- All pieces fit behind `VoiceAdapter` without leaking backend-specific types into conversation logic.

## Output

- Recommended voice front-end stack.
- Per-platform blockers.
- UX degradations allowed for text-first non-Apple beta.
- Follow-up implementation plan.
