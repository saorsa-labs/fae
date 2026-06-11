# Spike S15 — Cross-platform TTS benchmark

> **Status:** Proposed (2026-06-11)
> **Goal:** Prove whether Fae can keep a high-quality, local, cross-platform TTS lane without depending on Apple/MLX.

## Candidates

1. **Kokoro ONNX/ONNX Runtime** — primary candidate for voice continuity.
2. **Piper** — robust local fallback with CLI/Python/C/C++ APIs and trainable voices.
3. **sherpa-onnx TTS** — evaluate if one ONNX speech stack can cover STT/TTS/speaker/VAD.
4. **MLX/Qwen3-TTS** — Apple premium/experimental baseline, not the cross-platform target.

## Test matrix

| Platform | CPU | GPU/accelerator |
|---|---|---|
| macOS Apple Silicon | yes | Core ML/Metal/MLX where available |
| Linux NVIDIA | yes | CUDA/ORT CUDA |
| Linux AMD | yes | ROCm/ORT if practical |
| Linux Intel | yes | OpenVINO/ORT if practical |
| Windows AMD/Intel/NVIDIA | yes | DirectML/ORT/CUDA where practical |

## Metrics

- Real-time factor (RTF) for short, medium, and long utterances.
- Time-to-first-audio for streaming.
- Memory footprint.
- Voice continuity vs current Fae voice.
- Pronunciation/phoneme quality on names, Scottish place names, code, dates, and reminders.
- Packaging complexity and binary/model size.
- License compatibility.

## Acceptance criteria

- At least one non-Apple path produces RTF < 1.0 on CPU for normal utterances.
- Streaming or chunked playback can begin fast enough for Fae's conversational UX.
- Voice quality is acceptable for daily use or has a clear voice-training path.
- The implementation can be hidden behind `VoiceAdapter.synthesize`.

## Output

- Benchmark table.
- Audio samples.
- Recommended default and fallback.
- Packaging notes for macOS/Linux/Windows.
