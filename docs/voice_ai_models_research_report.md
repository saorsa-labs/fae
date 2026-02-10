# Voice-to-Voice AI Models Research Report

**For Conversational AI Assistant with Personality Steering in Rust**

---

## Executive Summary

This research evaluates end-to-end voice-to-voice AI models and cascaded pipeline approaches for building a conversational AI assistant requiring personality steering via system prompts, Rust/cross-platform support, and natural conversational quality. The key finding is that **no unified speech-to-speech model currently offers robust system prompt support**—personality steering remains primarily achievable through cascaded architectures where the LLM component handles behavior control.

**Top Recommendations:**
1. **For Maximum Personality Control**: Cascaded pipeline using sherpa-rs (Rust) with Whisper ASR + any steerable LLM + Parler-TTS/Fish Speech
2. **For Near-Native Voice Experience**: Ultravox (MIT license, excellent system prompt support) + TTS backend
3. **For Full End-to-End (Limited Steering)**: Moshi with Rust backend (requires fine-tuning for personality)

---

## 1. End-to-End Speech-to-Speech Models

### 1.1 Moshi (Kyutai Labs)

Moshi represents the current state-of-the-art in unified speech-to-speech models, offering full-duplex dialogue with approximately 200ms latency. The architecture combines a 7B parameter Temporal Transformer with a Depth Transformer for modeling inter-codebook dependencies, built atop the Mimi streaming neural audio codec that achieves 1.1kbps compression at 80ms latency[1].

| Attribute | Details |
|-----------|---------|
| **Architecture** | Unified speech-to-speech with dual audio stream modeling |
| **System Prompt Support** | **NO** - requires fine-tuning for personality changes |
| **Rust Support** | **Full native implementation** in `rust/` directory |
| **Platform Support** | CUDA, Metal (macOS), CPU |
| **Latency** | ~160-200ms theoretical, ~200ms practical on L4 GPU |
| **Voice Options** | Moshiko (male), Moshika (female) - pre-trained only |
| **License** | Apache 2.0 (Rust), MIT (Python), CC-BY 4.0 (weights) - commercial OK |

**Critical Limitation**: The Moshi team explicitly states that changing voice or personality "would require fine tuning, which is not currently supported"[2]. This fundamentally disqualifies Moshi for applications requiring runtime personality steering via system prompts.

**Rust Implementation Details**: The Rust backend is production-ready, built with Candle, and supports both CUDA (`--features cuda`) and Metal (`--features metal`). The `rustymimi` crate provides the Mimi codec implementation with Python bindings for hybrid deployments[1].

### 1.2 MiniCPM-o (OpenBMB)

MiniCPM-o 4.5 delivers GPT-4o-level multimodal capabilities including bilingual real-time speech conversation with configurable voices in English and Chinese. The model demonstrates full-duplex omni-modal capability, processing continuous video and audio streams with support for voice activity detection and interruption handling[3].

| Attribute | Details |
|-----------|---------|
| **Architecture** | Omni-modal LLM with streaming speech encoder/decoder |
| **System Prompt Support** | **YES** - standard LLM prompting applies |
| **Rust Support** | **NO** - PyTorch only |
| **Platform Support** | CUDA primarily, Ollama available |
| **Latency** | Real-time streaming |
| **Voice Options** | Configurable voices (English, Chinese) |
| **License** | MiniCPM Model License |

**Assessment**: While MiniCPM-o supports system prompts through its underlying LLM architecture, the lack of Rust support and CUDA dependency make it unsuitable for cross-platform Rust deployment.

### 1.3 Qwen2.5-Omni (Alibaba)

Qwen2.5-Omni represents a comprehensive any-to-any multimodal model capable of processing text, images, audio, and video inputs while generating both text and natural speech outputs. The model features end-to-end voice chat capabilities with real-time streaming support[4].

| Attribute | Details |
|-----------|---------|
| **Architecture** | End-to-end omni-modal with Thinker (reasoning) and Talker (generation) |
| **System Prompt Support** | **PARTIAL** - specific system prompt required for audio output |
| **Rust Support** | **NO** - PyTorch/Transformers only |
| **Platform Support** | CUDA, vLLM-Omni support |
| **Voice Options** | Single voice ("Qwen" persona required for audio output) |
| **License** | Qwen License (research-friendly) |

**System Prompt Constraint**: Audio output requires a specific system prompt: "You are Qwen, a virtual human developed by the Qwen Team, Alibaba Group..."[5]. This fixed persona requirement significantly limits personality customization potential.

---

## 2. Audio-Understanding LLMs (Speech Input → Text/Speech Output)

### 2.1 Ultravox (Fixie.ai) - **RECOMMENDED FOR PERSONALITY STEERING**

Ultravox emerges as the most promising option for personality-steerable voice AI. Unlike cascaded systems requiring separate ASR stages, Ultravox directly projects audio into the LLM's high-dimensional space via a multimodal adapter, eliminating transcription latency and preserving paralinguistic information[6].

| Attribute | Details |
|-----------|---------|
| **Architecture** | Audio encoder + LLM (Llama 3.3 70B base, 8B variants available) |
| **System Prompt Support** | **YES - FULL SUPPORT** with comprehensive documentation |
| **Rust Support** | **NO** - Python/PyTorch training, API deployment |
| **Platform Support** | Cloud API, self-hosting requires significant GPU |
| **Output** | Currently text (speech token output planned) |
| **License** | **MIT** - fully open source, commercial OK |

**Personality Steering Capabilities**: Ultravox provides exceptional prompt engineering documentation for voice AI applications[7]:

```
You are [Name], a friendly AI [customer service agent / helper / etc].
You're interacting with the user over voice, so speak casually.
Keep your responses short and to the point, much like someone would in dialogue.
```

Additional steering patterns include tool usage control, number/date formatting for speech, jailbreak prevention, and step-by-step instruction delivery. The documentation explicitly notes: "prompting is the most effective tool we have for controlling LLMs."

**Integration Path**: While Ultravox lacks native Rust support, it can be integrated via API calls from Rust applications. For a fully local deployment, pair Ultravox's open-source model with a Rust-based TTS system like Parler-TTS via Candle.

### 2.2 Qwen2-Audio (Alibaba)

Qwen2-Audio provides a capable audio-understanding model that accepts various audio signals and performs analysis or generates text responses based on speech instructions. The instruct-tuned variant supports chat-style interactions[8].

| Attribute | Details |
|-----------|---------|
| **Architecture** | Audio encoder + LLM (7B parameters) |
| **System Prompt Support** | **PARTIAL** - intelligently switches modes without explicit prompts |
| **Rust Support** | **NO** |
| **Platform Support** | CUDA, OpenVINO conversion available |
| **Output** | Text only |
| **License** | Qwen License |

**Note**: The model "does not use any system prompts to switch between voice chat and audio analysis modes"[8]—it intelligently infers context. This implicit behavior offers less granular personality control compared to Ultravox.

---

## 3. Cascaded Pipeline Components

For applications requiring maximum flexibility in personality steering and cross-platform Rust support, a cascaded pipeline (ASR + LLM + TTS) remains the most viable approach.

### 3.1 HuggingFace Speech-to-Speech Pipeline

The HuggingFace Speech-to-Speech project provides a modular, open-source implementation combining four components: VAD (Silero), STT (Whisper/Parakeet), LLM (any instruction-following model), and TTS (Parler-TTS/MeloTTS/Kokoro)[9].

| Component | Options | Rust Available |
|-----------|---------|----------------|
| **VAD** | Silero VAD v5 | Yes (silero-vad-rs) |
| **ASR** | Whisper, Parakeet TDT (<100ms), Paraformer | Yes (Candle, sherpa-rs) |
| **LLM** | Any Transformers model, OpenAI API | Yes (Candle, llama.cpp bindings) |
| **TTS** | Parler-TTS, MeloTTS, ChatTTS, Kokoro-82M | Yes (Candle for Parler-TTS) |

**Platform Support**: CUDA (with Torch Compile), Mac MPS (Lightning Whisper MLX, MLX LM, MeloTTS), Docker with NVIDIA Container Toolkit, and server/client deployment for distributed execution[9].

### 3.2 ASR Options with Rust Support

**OpenAI Whisper via Candle**: The canonical choice for Rust-based ASR, with Candle providing direct Whisper implementation supporting CPU, CUDA, and Metal backends. Distil-Whisper variants offer 6x faster inference at minimal quality loss[10].

**NVIDIA Parakeet TDT**: Achieves sub-100ms latency with state-of-the-art accuracy on English transcription. The 600M parameter model delivers industry-leading word error rates with proper punctuation and timestamps[11]. Available through NeMo but lacks direct Rust implementation—requires ONNX conversion for sherpa-onnx integration.

**Sherpa-ONNX**: The most comprehensive cross-platform solution, supporting 12 programming languages including Rust via sherpa-rs bindings. Models include streaming Zipformer, Paraformer, Whisper, Moonshine, and SenseVoice across numerous languages[12].

### 3.3 TTS Options with Rust/Cross-Platform Support

**Parler-TTS via Candle**: A 2.2B parameter model generating natural speech with text-based voice descriptions. Candle support enables pure Rust/WASM deployment. Voice customization occurs through natural language descriptions (e.g., "A female speaker with a calm, British accent")[13].

**Fish Speech / OpenAudio**: Offers expressive TTS with zero-shot voice cloning from 10-30 second samples. A community Rust implementation using Candle exists at `fish-speech.rs`, enabling voice cloning capabilities in Rust applications[14].

**Sherpa-ONNX TTS**: Supports Piper, Matcha, and VITS models across multiple languages with full cross-platform deployment including mobile, embedded, and WebAssembly[12].

**Kokoro-82M**: A lightweight 82M parameter TTS model suitable for edge deployment, supported in the HuggingFace Speech-to-Speech pipeline.

---

## 4. Rust ML Ecosystem for Speech

### 4.1 Candle (HuggingFace)

Candle serves as the primary Rust ML framework for speech applications, offering a minimalist design with GPU support via CUDA and Metal backends[15].

**Supported Speech Models**:
- **Whisper**: Multi-lingual speech-to-text
- **EnCodec**: Audio compression
- **MetaVoice-1B**: Text-to-speech
- **Parler-TTS**: Large-scale TTS with voice descriptions

**Platform Matrix**:
| Backend | CPU | CUDA | Metal | WASM |
|---------|-----|------|-------|------|
| Support | ✓ (MKL/Accelerate) | ✓ (NCCL multi-GPU) | ✓ | ✓ |

### 4.2 ONNX Runtime for Rust (ort)

The `ort` crate provides ergonomic Rust bindings to ONNX Runtime 1.22+, enabling hardware-accelerated inference across platforms[16]. This approach works particularly well for models originally in PyTorch that have been converted to ONNX format.

**Relevant Crates**:
- `ort` - Core ONNX Runtime bindings
- `silero-vad-rs` - Silero VAD implementation
- `rusty-whisper` - Whisper via tract

### 4.3 Sherpa-RS

The `sherpa-rs` crate wraps sherpa-onnx for Rust, providing a unified interface for speech processing tasks[17]:

| Feature | Status |
|---------|--------|
| Spoken language detection | ✓ |
| Speaker embedding/labeling | ✓ |
| Speaker diarization | ✓ |
| Speech-to-text | ✓ |
| Text-to-speech | ✓ |
| Voice activity detection | ✓ |

**Cross-Platform Coverage**: Android, iOS, Windows, macOS, Linux, HarmonyOS, Raspberry Pi, RISC-V, WebAssembly, and various NPUs (NVIDIA Jetson, Qualcomm QNN, Ascend)[12].

---

## 5. Comprehensive Model Comparison

| Model | Type | System Prompt | Rust | Cross-Platform | Latency | Voice Custom | License |
|-------|------|---------------|------|----------------|---------|--------------|---------|
| **Moshi** | Unified S2S | ❌ (needs fine-tune) | ✅ Native | CUDA/Metal/CPU | ~200ms | 2 voices (fixed) | Apache/MIT/CC-BY |
| **Ultravox** | Audio LLM | ✅ **Full** | ❌ | API/Cloud | ~100ms | TTS-dependent | MIT |
| **MiniCPM-o** | Omni-modal | ✅ | ❌ | CUDA mainly | Real-time | Configurable | MiniCPM License |
| **Qwen2.5-Omni** | Omni-modal | ⚠️ Constrained | ❌ | CUDA | Real-time | Fixed persona | Qwen License |
| **HF S2S Pipeline** | Cascaded | ✅ (LLM layer) | ⚠️ Components | CUDA/MPS | Variable | Full TTS control | Apache |
| **Sherpa-ONNX** | Pipeline components | N/A | ✅ (sherpa-rs) | **All platforms** | Model-dep | TTS-dependent | Apache |

---

## 6. Recommended Architectures

### Option A: Maximum Personality Control (Recommended)

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│  Silero VAD │ →  │ Whisper ASR │ →  │ LLM w/Prompt│ →  │ Parler-TTS  │
│  (sherpa-rs)│    │  (Candle)   │    │  (Candle)   │    │  (Candle)   │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
```

**Rust Stack**: sherpa-rs (VAD) + Candle (Whisper + LLM + Parler-TTS)
**Platforms**: CPU, CUDA, Metal
**Personality**: Full system prompt control at LLM layer
**Voice Control**: Text description to Parler-TTS or cloned voice via Fish Speech

### Option B: Near-Native Experience with Steering

```
┌─────────────┐    ┌─────────────────────┐    ┌─────────────┐
│   Audio In  │ →  │ Ultravox (API/Local)│ →  │ TTS Output  │
│             │    │ + System Prompt     │    │ (sherpa-rs) │
└─────────────┘    └─────────────────────┘    └─────────────┘
```

**Rust Stack**: Rust client for Ultravox API + sherpa-rs TTS
**Personality**: Excellent system prompt support
**Voice Control**: Separate TTS selection
**Trade-off**: Requires API or significant GPU for local Ultravox

### Option C: Lowest Latency (Limited Personality)

```
┌─────────────────────────────────────────────┐
│              Moshi (Rust Backend)           │
│         CUDA/Metal native inference         │
└─────────────────────────────────────────────┘
```

**Rust Stack**: Native Moshi Rust implementation
**Personality**: Moshiko/Moshika fixed voices only
**Use Case**: When latency is paramount and fixed personalities are acceptable

---

## 7. Critical Findings and Recommendations

The research reveals a fundamental tension in current voice AI: **unified speech-to-speech models sacrifice system prompt controllability for lower latency**, while **cascaded approaches maintain full steering capability at the cost of additional latency**.

For the specified requirements (personality steering + Rust + cross-platform), the optimal path forward is:

1. **Immediate Implementation**: Build a cascaded pipeline using sherpa-rs with Whisper ASR + a Candle-based LLM (Llama/Mistral/Qwen) + Parler-TTS. This provides full system prompt control, native Rust, and cross-platform support.

2. **Voice Customization**: Use Parler-TTS with text descriptions for voice characteristics, or integrate Fish Speech via the fish-speech.rs Candle implementation for voice cloning capabilities.

3. **Latency Optimization**: Consider Parakeet TDT for sub-100ms ASR (requires ONNX conversion), streaming LLM generation, and chunked TTS output.

4. **Future Path**: Monitor Ultravox's development of speech token output, which would enable a more unified experience while maintaining system prompt capabilities.

---

## Sources

[1] [Moshi GitHub Repository](https://github.com/kyutai-labs/moshi) - Kyutai Labs official repository with Rust implementation details

[2] [Moshi Custom Prompt Issue #76](https://github.com/kyutai-labs/moshi/issues/76) - Official confirmation that personality changes require fine-tuning

[3] [MiniCPM-o HuggingFace](https://huggingface.co/openbmb/MiniCPM-o-4_5) - Model card with bilingual speech conversation details

[4] [Qwen2.5-Omni Technical Report](https://huggingface.co/Qwen/Qwen2.5-Omni-7B) - Official model documentation

[5] [Qwen2.5-Omni GitHub](https://github.com/QwenLM/Qwen2.5-Omni) - System prompt requirements for audio output

[6] [Ultravox GitHub](https://github.com/fixie-ai/ultravox) - Architecture and training details

[7] [Ultravox Prompting Guide](https://docs.ultravox.ai/gettingstarted/prompting) - Comprehensive personality steering documentation

[8] [Qwen2-Audio Technical Report](https://arxiv.org/abs/2407.10759) - Architecture and system prompt behavior

[9] [HuggingFace Speech-to-Speech](https://github.com/huggingface/speech-to-speech) - Modular pipeline implementation

[10] [Candle GitHub](https://github.com/huggingface/candle) - Supported models including Whisper and Parler-TTS

[11] [NVIDIA Parakeet TDT](https://developer.nvidia.com/blog/nvidia-speech-ai-models-deliver-industry-leading-accuracy-and-performance/) - ASR performance benchmarks

[12] [Sherpa-ONNX](https://github.com/k2-fsa/sherpa-onnx) - Cross-platform speech processing with Rust bindings

[13] [Parler-TTS](https://github.com/huggingface/parler-tts) - Text-description based voice synthesis

[14] [Fish Speech Rust Implementation](https://github.com/EndlessReform/fish-speech.rs) - Candle-based voice cloning

[15] [Candle ML Framework](https://github.com/huggingface/candle) - Rust ML framework with speech model support

[16] [ort - ONNX Runtime for Rust](https://github.com/pykeio/ort) - ONNX Runtime Rust bindings

[17] [sherpa-rs Crate](https://crates.io/crates/sherpa-rs) - Rust bindings for sherpa-onnx

---

*Report generated: February 2026*
*Research scope: HuggingFace models, open-source voice AI projects, Rust ML ecosystem*
