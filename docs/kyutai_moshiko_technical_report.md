# Kyutai Moshiko Technical Research Report

## Executive Summary

This report provides a comprehensive technical analysis of Kyutai's Moshiko model for implementation in a Rust-based conversational AI assistant. Moshiko is a speech-text foundation model that enables full-duplex, real-time spoken dialogue with approximately 200ms latency. The model represents a significant advancement in conversational AI by unifying speech recognition, language modeling, and speech synthesis into a single end-to-end architecture.

The key findings indicate that Moshiko is well-suited for Rust integration through the official Candle backend, supports limited personality steering via voice instructions and 92+ trained speaking styles, but has significant limitations in voice customization as it currently outputs only a single fixed voice (male for Moshiko, female for Moshika) without support for voice cloning or speaker embeddings. For applications requiring voice customization, Kyutai's separate Pocket TTS model offers voice cloning capabilities but would need to be integrated separately from Moshi.

---

## 1. Introduction

The Kyutai Moshiko model (`kyutai/moshiko-candle-bf16`) represents the first open-source, real-time full-duplex spoken dialogue system. Developed by Kyutai, a Paris-based non-profit AI research lab funded by Iliad Group, CMA CGM Group, and Schmidt Sciences, Moshi was released in September 2024 with full weights, code, and technical documentation under permissive licenses (MIT/Apache for code, CC-BY-4.0 for weights).

This report investigates the model's suitability for a personality-steerable, voice-customizable conversational AI assistant implemented in Rust, addressing architecture, capabilities, limitations, and integration requirements.

---

## 2. Full Audio-to-Audio Pipeline Architecture

### 2.1 Unified End-to-End Design

Unlike traditional conversational AI systems that rely on cascaded pipelines of separate ASR, LLM, and TTS components, Moshi employs a unified speech-to-speech architecture. This design eliminates the latency overhead and information loss inherent in cascaded approaches where paralinguistic information (emotion, prosody, speaker identity) is typically discarded during speech-to-text conversion.

The architecture consists of three principal components working in concert. The Helium backbone serves as the 7B-parameter text language model foundation, pretrained on 2.1 trillion English tokens with 54.3% MMLU performance. The Mimi codec functions as a state-of-the-art streaming neural audio codec that tokenizes audio at 12.5 Hz with only 1.1 kbps bitrate while preserving both semantic and acoustic information. The Depth Transformer handles hierarchical token generation across multiple codebook levels at each timestep.

### 2.2 The Inner Monologue Mechanism

A critical innovation in Moshi's architecture is the "Inner Monologue" approach, which jointly models text and audio tokens in a streaming fashion. Rather than treating speech generation as separate from language understanding, Moshi predicts time-aligned text tokens as a prefix to audio tokens at each timestep.

The text tokens are aligned to the 12.5Hz audio framerate using word-level timestamps derived from Whisper. Approximately 65% of tokens in English conversational speech are padding tokens (PAD and EPAD), with actual text content interspersed at the appropriate temporal positions. This mechanism significantly improves linguistic quality by grounding the audio generation in explicit textual reasoning while maintaining the streaming capability essential for real-time interaction.

### 2.3 Dual-Stream Full-Duplex Processing

Moshi processes two parallel audio streams simultaneously: its own speech output and the user's speech input. At each timestep, the model handles a sequence of 17 token streams consisting of one text token, Moshi's semantic token, seven Moshi acoustic tokens, the user's semantic token, and seven user acoustic tokens. This structure enables true full-duplex conversation where the model continuously listens while speaking, eliminating the need for explicit turn-taking detection that introduces latency in traditional systems.

### 2.4 Latency Characteristics

The theoretical minimum latency is 160ms, derived from two 80ms frames at the 12.5Hz framerate. The first frame accounts for the Mimi codec's initial processing window, while the second accommodates the acoustic delay between semantic and acoustic token generation. In practice, the system achieves approximately 200ms end-to-end latency on an L4 GPU, which compares favorably to the average human conversational response time of 230ms.

The streaming architecture ensures this latency remains constant regardless of input length, unlike batch processing approaches where latency scales with sequence duration. Every component operates causally, meaning decisions are made using only past and present information, enabling immediate response generation.

---

## 3. Personality Steering Capabilities

### 3.1 Current Limitations

Investigation of the official GitHub repository revealed that Moshi does not currently support system prompts or explicit personality conditioning in the traditional LLM sense. A GitHub issue (#76) asking about custom prompts to focus the LLM on particular topics was closed without a visible public response, suggesting this capability is not natively supported in the released models.

### 3.2 Voice Instruction Following

Despite the absence of system prompts, Moshi demonstrates the ability to follow voice instructions for style adaptation during conversation. The model can respond to requests like "speak like a pirate" or "whisper" by adjusting its vocal characteristics accordingly. This represents an implicit form of personality steering through conversational context rather than explicit conditioning.

### 3.3 Training-Time Style Embedding

The instruction fine-tuning phase incorporated 20,000+ hours of synthetic dialogue data with 92 distinct speaking styles including angry, happy, sarcastic, whispering, and various character voices. These styles were embedded into the model through fine-tuning rather than being selectable at inference time, meaning the model has learned to produce these styles when contextually appropriate but cannot be explicitly directed to adopt a specific persona through configuration.

### 3.4 Expressiveness Range

Reports indicate Moshi can express over 70 emotions and adapt to various scenarios including accent impersonation (French accent poetry), character embodiment (pirate character with appropriate vocal tone and energy), and suspenseful whispered delivery. However, accessing these capabilities relies on conversational context rather than API-level controls.

### 3.5 Potential Approaches for Personality Control

For applications requiring persistent personality steering, several approaches merit consideration. Fine-tuning on custom dialogue data with the desired personality characteristics would embed the persona into the model weights. Alternatively, prepending a textual context window with personality-defining information might influence behavior, though this would require experimentation as it is not a documented feature. The most robust approach would involve modifying the training pipeline to support explicit persona conditioning, which is possible given the open-source nature of the code.

---

## 4. Voice Customization Options

### 4.1 Available Voice Choices

The released Moshi models offer exactly two voice options. Moshiko produces a male voice while Moshika produces a female voice. These represent different model checkpoints trained with distinct voice characteristics, not runtime-selectable options. Users select the voice by choosing the appropriate model variant at load time.

| Voice | Backend | Quantization | HuggingFace Repository |
|-------|---------|--------------|------------------------|
| Moshiko (male) | Rust/Candle | bf16, int8 | kyutai/moshiko-candle-bf16, kyutai/moshiko-candle-q8 |
| Moshika (female) | Rust/Candle | bf16, int8 | kyutai/moshika-candle-bf16, kyutai/moshika-candle-q8 |
| Moshiko | PyTorch | bf16, int8 | kyutai/moshiko-pytorch-bf16, kyutai/moshiko-pytorch-q8 |
| Moshika | PyTorch | bf16, int8 | kyutai/moshika-pytorch-bf16, kyutai/moshika-pytorch-q8 |
| Moshiko | MLX | bf16, int4, int8 | kyutai/moshiko-mlx-bf16, q4, q8 |
| Moshika | MLX | bf16, int4, int8 | kyutai/moshika-mlx-bf16, q4, q8 |

### 4.2 Voice Cloning and Custom Voices

Moshi explicitly does not support voice cloning or custom voice injection. The technical report states this limitation is intentional "to prevent impersonation" and notes the model achieves 98.7% speaker consistency by training on a single actor voice during instruction tuning. The architecture encodes voice characteristics in the acoustic tokens (levels 2-8 of the RVQ), but these are generated by the model rather than conditioned on external speaker embeddings.

### 4.3 Speaker Embedding Support

The Mimi codec encodes speaker identity, prosody, and acoustic conditions in its 8-level RVQ structure, with the first level capturing semantic/linguistic content and levels 2-8 capturing acoustic details. However, there is no documented API for injecting external speaker embeddings at inference time. The speaker characteristics are determined by the training data and model weights rather than input conditioning.

### 4.4 Voice Characteristic Control

Runtime control of pitch, speed, and emotion is not available through explicit parameters. These characteristics emerge from the model's learned representations and contextual understanding. While the model can naturally vary these aspects during conversation, users cannot programmatically specify target values.

### 4.5 Alternative: Kyutai Pocket TTS for Voice Cloning

For applications requiring voice cloning, Kyutai offers a separate model called Pocket TTS. This 100M-parameter model supports voice cloning from approximately 5 seconds of reference audio, capturing voice color, emotion, accent, cadence, and even acoustic conditions like reverb and microphone characteristics. The voice sample is encoded using an 18M-parameter codec encoder, with the resulting embedding prefixed to the generation sequence.

However, Pocket TTS is a standalone text-to-speech model, not an integrated conversational system. Using it for voice customization would require a hybrid architecture where Moshi handles conversation and generates text, which is then synthesized by Pocket TTS with the desired voice. This approach would increase complexity and latency while potentially losing some of Moshi's paralinguistic preservation benefits.

---

## 5. Rust/Candle Integration

### 5.1 Official Rust Backend

The `moshiko-candle-bf16` variant is specifically designed for Rust deployment using Hugging Face's Candle framework. One of the Moshi authors (Laurent Mazare) is also the primary author of Candle, ensuring deep integration quality. The Rust implementation provides both the inference backend and a CLI client.

### 5.2 Crate Structure

The Moshi Rust implementation is published on crates.io as the `moshi` crate. The repository structure separates concerns into the main `rust/` directory containing the Candle/Rust production backend, with the Mimi codec available through Python bindings via the `rustymimi` package for interoperability scenarios.

### 5.3 Running the Server

```bash
cd rust
cargo run --features cuda --bin moshi-backend -r -- --config moshi-backend/config.json standalone

# For macOS with Metal acceleration:
cargo run --features metal --bin moshi-backend -r -- --config moshi-backend/config.json standalone

# For quantized 8-bit model:
cargo run --features cuda --bin moshi-backend -r -- --config moshi-backend/config-q8.json standalone
```

### 5.4 CLI Client

```bash
cargo run --bin moshi-cli -r -- tui --host localhost
```

### 5.5 Dependencies and Requirements

The Rust implementation requires a recent Rust toolchain. For GPU acceleration, CUDA support requires the `cuda` feature flag, while macOS Metal acceleration uses the `metal` feature. It is important to note that Candle does not support Metal/MLX acceleration for the Moshi model specifically; attempting to run the Rust code with hardware acceleration on Apple Silicon may not work as expected based on GitHub issue reports.

### 5.6 Configuration Options

The configuration is specified via JSON files (`config.json` or `config-q8.json`) that define model paths, quantization settings, and server parameters. The HuggingFace repository can be specified to automatically download weights.

### 5.7 Limitations

GPU support on Apple Silicon is problematic for the Rust backend. Users on Mac are advised to use the MLX implementation (Python) rather than the Rust/Candle backend for hardware acceleration. The Rust backend works well on NVIDIA GPUs with CUDA support.

---

## 6. Moshi/Moshiko Ecosystem

### 6.1 Core Components

The Moshi ecosystem comprises three main components. Helium is the 7B-parameter text language model backbone with 32 layers, 4096 hidden dimension, 32 attention heads, and 11264 MLP dimension, supporting a context length of 3000 steps (approximately 4 minutes of audio). Mimi is the 96.2M-parameter streaming neural audio codec operating at 12.5Hz with 8 codebooks of 2048 centroids each. The Depth Transformer handles per-timestep codebook generation with 6 layers, 1024 hidden dimension, and depthwise parametrization.

### 6.2 Related Models and Variants

Kyutai has released a comprehensive ecosystem of audio AI models. Moshiko and Moshika represent the male and female voice variants available across PyTorch, MLX, and Candle backends in bf16, int8, and int4 quantization levels. Pocket TTS offers a 100M-parameter text-to-speech model with voice cloning capabilities, running at 6x real-time on CPU. The STT models (stt-1b-en_fr) provide speech-to-text functionality for English and French. Hibiki enables real-time speech translation. The CASA models implement cross-attention vision-language fusion for streaming inputs.

### 6.3 Documentation and Papers

The primary technical reference is the Moshi paper (arXiv:2410.00037) authored by Alexandre Defossez, Laurent Mazare, Manu Orsini, Amelie Royer, Patrick Perez, Herve Jegou, Edouard Grave, and Neil Zeghidour. The full PDF is available at kyutai.org/Moshi.pdf with detailed methodology, architecture specifications, and evaluation results.

### 6.4 Community Resources

The official GitHub repository (github.com/kyutai-labs/moshi) contains implementations in Python/PyTorch, MLX for Apple devices, and Rust/Candle. A live demo is available at moshi.chat for interactive testing. Scaleway provides managed inference endpoints for production deployment without self-hosting.

---

## 7. Naturalness and Quality Assessment

### 7.1 Audio Quality Metrics

The Mimi codec achieves strong performance on objective metrics with ABX phonetic discriminability of 8.1% (lower is better) and MUSHRA quality score of 81.0 out of 100. These results indicate high-fidelity audio reconstruction that preserves both linguistic content and speaker characteristics.

### 7.2 Prosody and Expressiveness

The speech-to-speech architecture preserves paralinguistic information that would be lost in cascaded systems. Emotion, intonation, emphasis, and speaking rhythm are encoded in the acoustic tokens and can vary naturally during conversation. The model learned 92+ speaking styles during instruction fine-tuning, enabling contextually appropriate expressiveness.

### 7.3 Conversational Naturalness

Full-duplex processing enables natural conversation flow with appropriate back-channeling (acknowledging sounds like "uh-huh"), interruption handling, and simultaneous listening/speaking. The 200ms latency is below the average human response time, contributing to natural-feeling interactions.

### 7.4 Limitations in Naturalness

The model is English-only, limiting international deployment. Complex reasoning tasks may show degradation compared to larger text-only models. The single-voice limitation means voice characteristics cannot be adapted to user preferences or branding requirements.

---

## 8. Comparison with Alternatives

### 8.1 Moshi vs OpenAI Realtime API

| Aspect | Moshi | OpenAI Realtime API |
|--------|-------|---------------------|
| Latency | ~200ms | Not disclosed (fast) |
| Model Size | 7B parameters | GPT-4o (much larger) |
| Reasoning | Good for conversational tasks | Superior overall reasoning |
| Voice Options | 2 (Moshiko, Moshika) | 6 preset voices |
| Voice Cloning | Not supported | Not supported |
| Fine-tuning | Fully supported (open source) | Not available |
| Pricing | Self-hosted or ~$0.02/min (PiAPI) | $0.06-0.24/min |
| Licensing | CC-BY-4.0 (weights), MIT/Apache (code) | Proprietary |
| Full-Duplex | Native | Native |

### 8.2 Key Differentiators

Moshi's primary advantages are its open-source nature enabling full customization through fine-tuning, significantly lower operational costs for self-hosted or third-party deployments, and the unified architecture preserving paralinguistic information. OpenAI's Realtime API offers superior reasoning capabilities from the larger underlying model and more voice choices but at higher cost and without customization options.

---

## 9. Recommendations for Rust Implementation

### 9.1 Feasibility Assessment

Implementing a conversational AI assistant in Rust using Moshiko is technically feasible with the official Candle backend. The model provides production-quality real-time conversation with appropriate latency characteristics. However, significant limitations exist for the stated requirements.

### 9.2 Personality Steering

The lack of system prompt support means personality steering must be achieved through alternative approaches. Consider fine-tuning on custom dialogue data embodying the desired persona, maintaining conversational context that establishes personality through interaction, or modifying the codebase to support explicit conditioning (possible given open-source availability).

### 9.3 Voice Customization

Voice customization requirements cannot be met with Moshi alone. Possible approaches include accepting the Moshiko/Moshika voice options as sufficient, implementing a hybrid architecture with Pocket TTS for voice cloning (adds complexity and latency), or fine-tuning Moshi on target voice data (requires significant resources and expertise).

### 9.4 Recommended Architecture

For a production system requiring both personality steering and voice customization, consider a hybrid approach. Use Moshi for conversation management, language understanding, and generating text responses. Fine-tune a custom Moshi checkpoint with desired personality traits. Route text output to Pocket TTS for synthesis with custom voice when voice cloning is required, or use Moshi's native audio output when acceptable.

### 9.5 Development Roadmap

For immediate development, deploy the Candle backend with Moshiko/Moshika and evaluate baseline quality. In the short term, develop conversational patterns that establish personality through interaction. For medium-term enhancement, investigate fine-tuning pipelines for personality embedding. For long-term optimization, consider contributing speaker embedding support to the open-source project.

---

## 10. Sources

1. [Kyutai Moshiko Candle Model](https://huggingface.co/kyutai/moshiko-candle-bf16) - Primary model repository, HuggingFace
2. [Moshi GitHub Repository](https://github.com/kyutai-labs/moshi) - Official implementation, MIT/Apache license
3. [Moshi Technical Paper](https://arxiv.org/abs/2410.00037) - Defossez et al., 2024, arXiv
4. [Moshi Paper PDF](https://kyutai.org/Moshi.pdf) - Full technical report, Kyutai
5. [HuggingFace Transformers Moshi Documentation](https://huggingface.co/docs/transformers/en/model_doc/moshi) - API reference
6. [Kyutai Organization](https://huggingface.co/kyutai) - Full model ecosystem
7. [Pocket TTS Technical Report](https://kyutai.org/pocket-tts-technical-report) - Voice cloning capabilities
8. [Mimi Codec Model](https://huggingface.co/kyutai/mimi) - Neural audio codec details
9. [GitHub Issue #76 - Custom Prompts](https://github.com/kyutai-labs/moshi/issues/76) - System prompt discussion
10. [OpenAI Realtime API vs Moshi Comparison](https://piapi.ai/blogs/openai-realtime-api-vs-moshi-api) - Feature and pricing comparison
11. [Moshi Voice AI Expressiveness](https://medium.com/@shrimangalevallabh789/moshi-voice-ai-the-advanced-voice-ai-that-feels-almost-human-d185d85da97d) - Emotion capabilities
12. [Moshi Rust Crate](https://crates.io/crates/moshi) - Official Rust package
13. [Emergent Mind Moshi Overview](https://www.emergentmind.com/topics/moshi-a-speech-text-foundation-model) - Architecture summary
14. [Kyutai Blog - Moshi Release](https://kyutai.org/blog/2024-09-18-moshi-release) - Official announcement

---

## Appendix A: Quick Reference

### Model Specifications
- **Parameters**: 7B (Helium) + 96.2M (Mimi) + Depth Transformer
- **Latency**: ~200ms practical, 160ms theoretical
- **Audio Rate**: 12.5 Hz, 24 kHz sampling
- **Bitrate**: 1.1 kbps
- **Language**: English only
- **License**: CC-BY-4.0 (weights), MIT/Apache (code)

### Rust Deployment
```bash
# Clone and build
git clone https://github.com/kyutai-labs/moshi
cd moshi/rust

# Run with CUDA
cargo run --features cuda --bin moshi-backend -r -- \
  --config moshi-backend/config.json standalone

# Run CLI client
cargo run --bin moshi-cli -r -- tui --host localhost
```

### HuggingFace Transformers Usage
```python
from transformers import MoshiForConditionalGeneration, AutoFeatureExtractor

model = MoshiForConditionalGeneration.from_pretrained("kyutai/moshiko-pytorch-bf16")
feature_extractor = AutoFeatureExtractor.from_pretrained("kyutai/moshiko-pytorch-bf16")

output = model.generate(
    input_ids=input_ids,
    user_input_values=audio_input,
    moshi_input_values=moshi_history,
    max_new_tokens=25
)
```

---

*Report generated: 2026-02-10*
*Research conducted for: Rust-based Conversational AI Assistant Project*
