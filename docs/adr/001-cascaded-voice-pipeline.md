# ADR-001: Cascaded Voice Pipeline

**Status:** Superseded (historical)
**Date:** 2026-02-10
**Scope:** Rust-era voice pipeline architecture (`src/pipeline/`, `src/stt/`, `src/tts/`, `src/vad/`, `src/audio/`)

> Historical note: this ADR documents the pre-Swift-rebuild architecture.
> Active production implementation lives in `native/macos/Fae/Sources/Fae/`.

## Context

Fae requires a voice-to-voice system with on-device audio processing that:

- Supports personality steering via system prompts (critical for Fae's identity)
- Runs entirely on-device with no API keys or remote servers
- Has native Rust support for embedding in `libfae`
- Provides audio and visual feedback during processing so users know Fae is working

We evaluated unified speech-to-speech models, omni-modal models, and cascaded pipeline approaches.

### Models evaluated

| Model | Type | System Prompt | Rust | Latency | License |
|-------|------|---------------|------|---------|---------|
| **Moshi** | Unified S2S | No (needs fine-tune) | Native Candle | ~200ms | Apache/MIT/CC-BY |
| **Ultravox** | Audio LLM | Full support | No (Python) | ~100ms | MIT |
| **MiniCPM-o** | Omni-modal | Yes | No (Python) | Real-time | MiniCPM License |
| **Qwen2.5-Omni** | Omni-modal | Constrained | No (Python) | Real-time | Qwen License |
| **HF S2S Pipeline** | Cascaded | Yes (LLM layer) | Components | Variable | Apache |
| **Sherpa-ONNX** | Components | N/A | sherpa-rs | Model-dep | Apache |

### Key finding

No unified speech-to-speech model currently offers robust system prompt support. Moshi (the only Rust-native option) provides only 2 fixed voices (Moshiko/Moshika) with no runtime personality steering — any customization requires fine-tuning. Ultravox has excellent prompt support but requires Python/API and significant GPU for local deployment.

### Moshi deep analysis

Moshi uses a dual-codebook architecture (Mimi codec) with 12.5 Hz semantic tokens and acoustic residual streams. It achieves ~200ms theoretical latency but has fundamental limitations for Fae:

- **No system prompt**: Personality is baked into training data, not steerable at runtime
- **2 voices only**: Moshiko (male) and Moshika (female), no voice cloning
- **Context**: 3000 token window, no long conversation support
- **Quality**: Intelligible but below state-of-art TTS quality

## Decision

Fae uses a **cascaded pipeline** with independent, swappable components:

```
Mic (16kHz) -> AEC -> Silero VAD -> Parakeet STT (ONNX) -> LLM Agent -> Kokoro TTS (ONNX) -> Speaker
```

### Component stack

| Component | Implementation | Runtime | Size |
|-----------|---------------|---------|------|
| VAD | Silero VAD v5 | ONNX Runtime (`ort`) | ~2 MB |
| STT | Parakeet TDT 0.6B | ONNX Runtime (`ort`) | ~600 MB |
| LLM | Qwen3 (1.7B/4B) GGUF | mistral.rs (Metal) | ~1-3 GB |
| TTS | Kokoro-82M | ONNX Runtime (`ort`) | ~350 MB |
| Embedding | all-MiniLM-L6-v2 | ONNX Runtime (`ort`) | ~23 MB |
| AEC | Custom ring buffer | Pure Rust | - |

### Pipeline characteristics

- **Echo cancellation**: Reference buffer + RMS ceiling + configurable echo tail (1000ms with AEC, 2000ms without)
- **VAD**: Silero with hysteresis (speech threshold 0.5, silence threshold 0.35), 15s duration cap
- **STT**: Parakeet TDT 0.6B, streaming partial transcriptions
- **TTS**: Clause-level streaming via `find_clause_boundary()`, single ONNX model with `misaki-rs` G2P
- **Playback**: CoreAudio on macOS, assistant-speaking flag for echo suppression

## Consequences

### Positive

- **Full personality control** at the LLM layer via system prompts (SOUL.md, VOICE_CORE_PROMPT)
- **Complete Rust coverage** via `ort`, `mistralrs`, and native audio crates
- **Component independence** — swap STT/LLM/TTS independently as better models emerge
- **Local-only privacy** — all inference on-device, no API keys or remote servers
- **Proven quality** — each component is best-in-class for its role

### Negative

- **Higher total latency** than unified models (~3-30s end-to-end depending on tool use, vs ~200ms theoretical for unified S2S). Fae favours correctness over speed — the orb and thinking tone provide continuous user feedback during processing. Latency will decrease as on-device models improve.
- **More moving parts** — 5 components to maintain vs 1 unified model
- **No voice cloning yet** — Kokoro has fixed voices (future: Fish Speech, Qwen3-TTS)

## Alternatives considered

**Option B — Ultravox (near-native)**: Excellent system prompt support and MIT license, but requires Python/API and significant GPU for local deployment. Could be a future cloud-hybrid option.

**Option C — Moshi (lowest latency)**: Native Rust with ~200ms latency, but only 2 fixed voices with no runtime personality steering. Requires fine-tuning for any customization. Fundamental architecture mismatch with Fae's identity-first design.

## TTS evolution path

Evaluation of next-generation TTS models for voice cloning capability:

| Model | Quality | Cloning | Rust | Size | Status |
|-------|---------|---------|------|------|--------|
| Fish Speech 1.5 | High | Zero-shot | fish-speech.rs bindings | ~600 MB | Recommended next |
| Pocket TTS | Good | Fast | Pure Rust possible | ~200 MB | Watch |
| Qwen3-TTS-rs | High | Zero-shot | Planned | ~1 GB | Future |
| Kokoro-82M | Good | No | Current | ~350 MB | In production |

The architecture supports hot-swapping TTS engines without changing the pipeline.

## References

- Kyutai Moshiko technical report (internal evaluation)
- TTS voice cloning research (7 models evaluated)
- HuggingFace voice AI model ecosystem
- Rust ML ecosystem: `ort`, `mistralrs`, `candle`
