# Full cross-platform ML pipeline — 2026-06-11

**Status:** Research decision note. No runtime code changed.

**Question:** Can Fae's whole ML pipeline be cross-platform — not just LLM inference?

**Answer:** **Mostly yes, but not as one magic backend.** The right architecture is a set of narrow provider seams: `ProviderAdapter` for LLM serving, plus explicit `VoiceAdapter`, `TrainingAdapter`, and `PerceptionAdapter` seams. The cross-platform path is strongest for text/LLM, audio I/O, VAD, wake, STT batch/near-streaming, embeddings, and likely TTS. The weakest lane is **personal training across all GPUs**: NVIDIA is mature, AMD/Intel are improving, Apple is MLX, and **Vulkan is inference-only, not a training backend**.

## 1. Product posture

- **Target:** Fae should be cross-platform by design, even if macOS remains the first complete voice-first product.
- **Do not collapse the stack:** mistral.rs is the primary **LLM serving lane**, not the full ML runtime.
- **Keep MLX where it wins:** personal LoRA training on Apple, Apple-first VLM/STT gaps, and short-term perception experiments.
- **Keep llama.cpp:** mandatory Vulkan fallback for consumer AMD/Intel Windows/Linux GPUs.
- **Add seams, not forks:** avoid owning candle/llama.cpp/ORT forks unless a product blocker proves unavoidable.

## 2. Pipeline matrix

| Lane | Apple today | Linux/Windows viable path | Maturity | GPU/accel story | Personalization/training | Needed spike |
|---|---|---|---|---|---|---|
| Audio I/O | AVAudioEngine / CoreAudio / cpal | cpal: WASAPI, ALSA, PipeWire, JACK, PulseAudio | **ready** | OS audio stack | n/a | S17 duplex/AEC integration |
| Wake word | Current Apple path / custom | openWakeWord ONNX/TFLite or sherpa-onnx keyword spotting | **viable-with-spike** | CPU is likely enough | custom wake models possible | S17 wake false-positive eval |
| VAD | Apple stack | Silero VAD ONNX, sherpa-onnx VAD | **ready** | Silero claims <1 ms/chunk CPU; ONNX can be faster | threshold tuning per user/device | S17 noisy-room eval |
| Noise suppression | Apple audio stack | RNNoise; WebRTC APM/SpeexDSP candidates | **viable-with-spike** | CPU/DSP | per-device calibration | S17 AEC/noise chain |
| STT | MLX/Gemma/Qwen path | whisper.cpp, sherpa-onnx, Gemma/Qwen audio via llama.cpp, Gemma-4 audio via mistral.rs where proven | **viable** | whisper.cpp supports CPU, Vulkan, CUDA, ROCm, OpenVINO, Core ML | vocabulary/context biasing before model training | S17 streaming endpointing |
| LLM serving | mistral.rs Metal; MLX optional | mistral.rs CPU/CUDA; llama.cpp Vulkan fallback | **ready for text-first** | mistral.rs: Metal/CUDA/CPU; llama.cpp: Vulkan/CUDA/Metal/etc. | LoRA/X-LoRA if adapter format works | S14 adapter portability |
| Tool calling / grammar | mistral.rs confirmed in S13 | mistral.rs grammar/tool fixes; llama.cpp Jinja/tool fallback | **ready-with-contract** | follows LLM backend | adapter can encode preferences | ProviderAdapter parity tests |
| VLM | MLX short-term; Gemma family | mistral.rs vision or llama.cpp multimodal | **viable-with-spike** | backend-dependent | VLM LoRA possible but not v1 | VLM quality/perf eval |
| TTS | Kokoro identity path; MLX experiments | Kokoro ONNX/ORT primary candidate; Piper fallback; sherpa-onnx TTS candidate | **likely viable, unproven for Fae voice** | ORT CPU/GPU; Piper CPU-friendly | voice packs / voice training pipeline separate from LLM LoRA | S15 TTS benchmark |
| Speaker ID / verification | shipped voiceprints | WeSpeaker/sherpa-onnx speaker verification or ONNX encoder | **viable-with-spike** | ORT CPU/GPU | enrollment required | S17 parity vs current voiceprints |
| Embeddings / rerank | current Swift/Rust path | fastembed/ORT/candle/llama.cpp embeddings | **ready** | CPU/ORT/GPU optional | user memory index not weight training | embedding eval |
| Personal LoRA training | MLX (`mlx-lm`/`mlx-tune`) | Unsloth/PEFT/Axolotl on CUDA; Unsloth ROCm/XPU candidates; CPU only for tiny/debug | **uneven** | CUDA strongest; ROCm/XPU improving; no Vulkan training | core Fae moat | S16 training lanes + S14 conversion |
| Adapter serving | MLX serving or fused model | mistral.rs LoRA/X-LoRA; llama.cpp GGUF LoRA | **plausible** | backend-dependent | requires format compatibility | S14 |

## 3. TTS conclusion

**Cross-platform TTS is plausible now.** Kokoro ONNX is the best first candidate because it preserves the current Kokoro direction while moving inference through ONNX Runtime. Primary-source signals: kokoro-onnx declares ONNX Runtime, CPU support, and GPU support; Piper is a fast local neural TTS engine with CLI/Python/C/C++ APIs and training-new-voices documentation; sherpa-onnx includes speech synthesis among its supported functions.

Recommended TTS ladder:

1. **Kokoro ONNX/ORT** — primary cross-platform voice-continuity path.
2. **Piper** — fallback for robust local TTS, many voices, C/C++ integration, trainable voices.
3. **sherpa-onnx TTS** — evaluate if it simplifies one-ORT speech stack.
4. **MLX/Qwen3-TTS** — Apple premium/experimental only unless a portable runtime appears.

Do not claim parity until S15 measures real-time factor, streaming latency, phoneme quality, voice identity continuity, memory footprint, and Windows/Linux packaging.

## 4. Training conclusion

**Cross-platform training is possible, but fragmented.** There is no single backend equivalent to "Vulkan for inference" that makes local LoRA training uniform across all consumer GPUs.

Recommended training lanes:

1. **Apple:** MLX remains the default personal-training lane. It is product-aligned and efficient on Apple silicon.
2. **NVIDIA Linux/Windows/WSL:** Unsloth/PEFT/Axolotl are the strongest non-Apple LoRA/QLoRA paths.
3. **AMD Linux:** Unsloth ROCm is promising; PyTorch ROCm packaging and GPU support remain the operational risk.
4. **Intel Windows/Linux:** Unsloth XPU path is promising for Arc/Data Center/Ultra AIPC, but must be tested on target machines.
5. **CPU:** only for tiny adapters, CI smoke tests, and deterministic converter tests.

Key rule: **adapter portability matters more than trainer brand.** A trainer is useful to Fae only if it emits or can convert to artifacts that the serving backend can load: PEFT/safetensors for mistral.rs, GGUF LoRA or merged GGUF for llama.cpp, and MLX adapters/fused models for Apple.

## 5. Proposed seams

### `ProviderAdapter` — LLM serving

Already the right insurance seam for mistral.rs API churn, EricLBuehler maintainer concentration, llama.cpp fallback, remote providers, and model-family churn.

### `VoiceAdapter` — TTS/STT/speaker front-end

Expose stable operations:

- `transcribe(audio, context) -> Transcript`
- `synthesize(text, voice, style) -> AudioStream`
- `verifySpeaker(audio, enrollment) -> SpeakerDecision`
- `detectWake(audio) -> WakeDecision`
- `vad(audio) -> SpeechSegments`

Implementations can be MLX, ONNX/ORT, whisper.cpp, sherpa-onnx, Kokoro ONNX, Piper, or Apple native.

### `TrainingAdapter` — personal LoRA/dialect training

Expose stable operations:

- `prepareDataset(memory, examples, privacyPolicy) -> TrainingSet`
- `trainAdapter(baseModel, trainingSet, budget) -> AdapterArtifact`
- `convertAdapter(adapter, targetRuntime) -> AdapterArtifact`
- `evaluateAdapter(adapter, evalSuite) -> EvalReport`

Implementations can be MLX, Unsloth, PEFT, Axolotl, or a remote user-owned training node.

### `PerceptionAdapter` — VLM/screen/camera embeddings

Keep VLM and multimodal screen understanding swappable between MLX, mistral.rs vision, llama.cpp multimodal, and future ONNX/specialized models.

## 6. Spike plan

- **S14:** MLX personal LoRA → mistral.rs adapter portability. Already created.
- **S15:** Cross-platform TTS benchmark: Kokoro ONNX vs Piper vs sherpa-onnx.
- **S16:** Cross-platform training lanes: MLX vs Unsloth CUDA/ROCm/XPU vs PEFT/Axolotl.
- **S17:** Cross-platform voice front-end: cpal + VAD + wake + AEC/noise + speaker verification.

## 7. Decision

Proceed as if the **full pipeline should be cross-platform**, but gate claims by lane:

- **Ready now:** text-first daemon, LLM serving, audio I/O, VAD candidates, embeddings.
- **Likely with spikes:** TTS via Kokoro ONNX/Piper, speaker verification via ONNX, VLM via mistral.rs/llama.cpp, wake word.
- **Engineering program:** production streaming STT endpointing, AEC/barge-in, Windows/Linux voice packaging.
- **Research/ops program:** cross-platform personal training and adapter portability.

The moat is not "MLX forever" or "mistral everywhere." The moat is **portable personal intelligence**: local memory + private training + adapter portability + user-owned x0x mesh, served through narrow seams that let each platform use its best ML backend.
