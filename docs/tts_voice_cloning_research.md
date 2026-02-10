# TTS and Voice Cloning Models for Fae Voice Assistant

**Research Date:** February 2026  
**Focus:** Rust/Candle compatible models with voice cloning and cross-platform support

---

## Executive Summary

This research evaluates seven TTS and voice cloning solutions for integration with Fae's existing Kokoro-82M ONNX pipeline. The analysis prioritizes Rust/Candle compatibility, cross-platform support, and practical integration paths.

**Top Recommendations:**

1. **Fish Speech 1.5 via fish-speech.rs** - Best voice cloning with native Rust/Candle, cross-platform
2. **Pocket TTS (Candle port)** - Excellent CPU performance with voice cloning, pure Rust
3. **Qwen3-TTS-rs** - Most feature-complete Candle implementation, text-described voices
4. **Kokoro voice interpolation** - Lowest friction for current pipeline enhancement

---

## 1. Fish Speech via fish-speech.rs

### Overview
Fish Speech is a high-quality voice cloning TTS model with an excellent pure Rust implementation using Candle.rs.

### HuggingFace Availability
- **Models:** fishaudio/fish-speech-1.5, 1.4, 1.2 SFT
- **Weights License:** CC-BY-NC-SA-4.0 (non-commercial only)
- **Code License:** Apache-2.0

### Rust/Candle/ONNX Support
| Aspect | Status |
|--------|--------|
| Implementation | **Native Candle.rs** - 94.7% Rust |
| Repository | [EndlessReform/fish-speech.rs](https://github.com/EndlessReform/fish-speech.rs) |
| Binary Size | ~15MB static binary |
| Flash Attention | Optional for NVIDIA (candle-flash-attn) |

### Voice Cloning Capability
**Excellent zero-shot cloning:**
- POST WAV + transcription to `/v1/audio/encoding` → returns `.npy` voice file
- Persistent voices: save `.npy` files with `index.json` mapping
- Quality: 300k+ hours training data for English/Chinese

### Prosody/Emotion Control
- Natural prosody from reference audio
- No explicit emotion tags, but cloned voices retain emotional characteristics
- Multi-language support: EN, ZH, JA, DE, FR, ES, KO, AR, RU + more

### Cross-Platform Status
| Platform | Status |
|----------|--------|
| Linux CUDA | ✅ Fully supported |
| Linux CPU | ✅ Supported |
| macOS Metal | ✅ Fully supported |
| macOS CPU | ✅ Supported |
| Windows | ⚠️ Not officially supported (difficult install) |
| WSL | ⚠️ Not officially supported |

### Integration Complexity
**Medium** - Requires running as separate server or embedding Candle inference.

```rust
// Build with Metal support
cargo build --release --bin server --features metal

// Or CUDA support
cargo build --release --bin server --features cuda
```

**Integration Path:**
1. Run fish-speech.rs as OpenAI-compatible server
2. Create voice encodings from reference audio
3. Call `/v1/audio/speech` endpoint from Fae pipeline
4. Stream audio response back

---

## 2. Pocket TTS (Candle Port)

### Overview
Kyutai's Pocket TTS is a 100M parameter model optimized for CPU with voice cloning. Multiple Rust/Candle ports exist.

### HuggingFace Availability
- **Model:** kyutai/pocket-tts (100M parameters)
- **License:** MIT
- **Paper:** arXiv:2509.06926

### Rust/Candle/ONNX Support
| Aspect | Status |
|--------|--------|
| Primary Port | [babybirdprd/pocket-tts](https://github.com/babybirdprd/pocket-tts) |
| Alternative | pocket-tts crate on crates.io |
| Framework | Pure Candle - no ONNX runtime needed |

### Voice Cloning Capability
**Good zero-shot cloning:**
- Voice cloning via `mimi` feature flag
- Requires reference audio sample
- 8 preset voices: alba, marius, javert, jean, fantine, cosette, eponine, azelma

### Prosody/Emotion Control
- Limited explicit control
- Prosody derived from reference audio
- English only

### Cross-Platform Status
| Platform | Status |
|----------|--------|
| CPU | ✅ Primary target - 3x real-time |
| Metal (macOS) | ✅ Supported via feature flag |
| CUDA | ❌ Not primary focus |

### Integration Complexity
**Low** - Can embed directly as Rust crate.

```toml
[dependencies]
pocket-tts = { version = "x.x", features = ["metal", "mimi"] }
```

**Performance:**
- First chunk latency: ~200ms
- Real-time factor: 3-7x real-time on CPU
- Peak memory: ~2GB

---

## 3. Qwen3-TTS-rs

### Overview
Pure Rust Candle implementation of Alibaba's Qwen3-TTS with the most complete feature set.

### HuggingFace Availability
- **Models:** Qwen/Qwen3-TTS-0.6B-Base, 1.7B-Base, CustomVoice, VoiceDesign
- **Size:** 1.8-3.9GB depending on variant

### Rust/Candle/ONNX Support
| Aspect | Status |
|--------|--------|
| Repository | [TrevorS/qwen3-tts-rs](https://github.com/TrevorS/qwen3-tts-rs) |
| Framework | Pure Candle with HuggingFace Hub integration |
| Optimizations | Fused kernels, KV cache, GPU-side sampling |

### Voice Cloning Capability
**Excellent multi-mode cloning:**
- **ICL mode:** Full voice cloning with reference audio + transcript (best quality)
- **x-vector mode:** Faster speaker embedding only (no transcript needed)
- **Preset speakers:** 9 built-in voices (CustomVoice models)
- **Text-described voices:** Natural language prompts (VoiceDesign models)

### Prosody/Emotion Control
- **VoiceDesign variant:** Text descriptions like "warm female voice with slight British accent"
- Natural prosody from reference audio in cloning modes

### Cross-Platform Status
| Platform | Feature Flag | Status |
|----------|--------------|--------|
| CPU | `cpu` (default) | ✅ Works but slow (5-6x real-time) |
| CPU + MKL | `mkl` | ✅ Faster Intel CPUs |
| CPU + Accelerate | `accelerate` | ✅ Faster Apple CPUs |
| CUDA | `cuda` | ✅ Best (0.48-0.65 RTF) |
| CUDA + Flash Attn | `flash-attn` | ✅ Requires CUDA toolkit |
| Metal | `metal` | ✅ Apple Silicon |

### Integration Complexity
**Medium-High** - Larger models, more setup, but most features.

```rust
// Feature selection
cargo build --release --features "metal"
// or
cargo build --release --features "cuda,flash-attn"
```

---

## 4. OpenVoice v2

### Overview
MyShell AI's zero-shot voice cloning with granular style control.

### HuggingFace Availability
- **Model:** myshell-ai/OpenVoiceV2
- **License:** MIT
- **Base TTS:** MeloTTS

### Rust/Candle/ONNX Support
| Aspect | Status |
|--------|--------|
| Native Rust | ❌ None found |
| ONNX | ⚠️ No official export |
| OpenVINO | ✅ Available |

### Voice Cloning Capability
**Excellent zero-shot cloning:**
- Clone any voice from short audio sample
- Cross-lingual cloning (clone English voice → output any language)
- Granular tone/style transfer

### Prosody/Emotion Control
**Best-in-class style control:**
- Emotion: happy, sad, angry, fearful, etc.
- Accent control
- Rhythm, pauses, intonation parameters

### Cross-Platform Status
| Platform | Status |
|----------|--------|
| Python | ✅ Primary |
| Rust | ❌ Requires Python interop or ONNX export |
| CPU | ✅ Works |
| GPU | ✅ Works |

### Integration Complexity
**High** - No native Rust support. Options:
1. Run as Python subprocess/server
2. Export to ONNX (unofficial, complex)
3. Use OpenVINO (Intel-focused)

---

## 5. Coqui XTTS-v2

### Overview
Coqui's voice cloning TTS that creates voices from 6-second audio clips.

### HuggingFace Availability
- **Model:** coqui/XTTS-v2
- **Fork:** idiap/coqui-ai-TTS (maintained after Coqui shutdown)
- **License:** MPL-2.0

### Rust/Candle/ONNX Support
| Aspect | Status |
|--------|--------|
| ONNX Export | ⚠️ Community attempts, complex architecture |
| Native Rust | ❌ None |
| GitHub Discussion | [#4014](https://github.com/coqui-ai/TTS/discussions/4014) |

### Voice Cloning Capability
**Excellent:**
- 6-second audio → voice clone
- Cross-lingual cloning
- No fine-tuning required

### Prosody/Emotion Control
- Natural prosody from reference
- Limited explicit emotion control

### Cross-Platform Status
| Platform | Status |
|----------|--------|
| Python | ✅ Primary |
| Rust | ❌ No viable path |
| CPU | ✅ Slow |
| GPU | ✅ Recommended |

### Integration Complexity
**Very High** - No Rust path. Company shut down in 2024, community fork exists but Python-only.

---

## 6. StyleTTS2

### Overview
High-quality TTS with style transfer achieving human-level naturalness.

### HuggingFace Availability
- **Repository:** yl4579/StyleTTS2
- **Stars:** 6.2k
- **License:** MIT (inference package)

### Rust/Candle/ONNX Support
| Aspect | Status |
|--------|--------|
| ONNX Export | ⚠️ Open issue [#117](https://github.com/yl4579/StyleTTS2/issues/117) - no resolution |
| Native Rust | ❌ None |
| Stylish-TTS | Alternative variant, still Python |

### Voice Cloning Capability
**Good style transfer:**
- Reference audio style matching
- Requires fine-tuning for best results

### Prosody/Emotion Control
- Excellent prosody modeling
- Style transfer from reference

### Cross-Platform Status
- Python only, CUDA recommended

### Integration Complexity
**Very High** - No viable Rust/ONNX path despite community interest.

---

## 7. MARS5-TTS

### Overview
CAMB.AI's speech emulation model with AR-NAR pipeline.

### HuggingFace Availability
- **Model:** CAMB-AI/MARS5-TTS
- **License:** Apache-2.0
- **Paper:** English speech model

### Rust/Candle/ONNX Support
| Aspect | Status |
|--------|--------|
| Native Rust | ❌ None |
| ONNX | ❌ No export |

### Voice Cloning Capability
**Excellent emulation:**
- Zero-shot voice cloning
- Good prosody matching

### Cross-Platform Status
- Python + PyTorch only
- No ONNX export available

### Integration Complexity
**Very High** - Python-only, would require PyO3 bindings or server approach.

---

## 8. Kokoro Voice Customization

### Overview
Methods to extend your existing Kokoro-82M pipeline with custom voices.

### Voice Interpolation (kokovoicelab)

**Repository:** [RobViren/kokovoicelab](https://github.com/RobViren/kokovoicelab)

**How it works:**
- SQLite database of voice style vectors
- Interpolate between existing voices to create new ones
- Export to `.pt` (single voice) or `voices.bin` (all voices)

**Example - Create accent blend:**
```bash
uv run kokovoicelab.py \
  --source-query "SELECT * FROM voices WHERE language='American English'" \
  --target-query "SELECT * FROM voices WHERE language='British English'" \
  --ranges="-2,-1,0,1,2" \
  --output-dir "samples"
```

**Capabilities:**
- Accent interpolation (American ↔ British, etc.)
- Gender interpolation
- Quality-weighted blending
- Values beyond original range (-2 to +2) create exaggerated characteristics

### HuggingFace Voice Mixer

**Space:** [ysharma/Make_Custom_Voices_With_KokoroTTS](https://huggingface.co/spaces/ysharma/Make_Custom_Voices_With_KokoroTTS)

- Web UI for voice combination
- Adjustable weights per voice
- Download resulting voice files

### Voice File Format
| Format | Usage |
|--------|-------|
| `.pt` | PyTorch tensor, single voice style vector |
| `voices.bin` | NPZ archive of all voice vectors |
| `.npy` | NumPy array (some implementations) |

### Integration with Existing Pipeline
**Lowest friction option:**
1. Use kokovoicelab to create custom interpolated voices
2. Export as `.pt` or update `voices.bin`
3. Load in existing kokoro-onnx pipeline

**Limitations:**
- Cannot clone arbitrary voices
- Limited to interpolation of existing 54+ voices
- No true voice cloning from audio samples

---

## Supplementary Options

### sherpa-rs (sherpa-onnx Rust bindings)

**Repository:** [thewh1teagle/sherpa-rs](https://github.com/thewh1teagle/sherpa-rs)

| Aspect | Details |
|--------|---------|
| Type | Rust bindings to sherpa-onnx |
| TTS Support | ✅ via `tts` feature |
| Platforms | Windows, Linux, macOS, Android, iOS |
| Voice Cloning | ❌ Uses pre-built TTS models |
| Integration | `cargo add sherpa-rs --features tts` |

**Best for:** Production-ready multi-platform TTS without voice cloning.

---

## Comparison Matrix

| Model | Rust/Candle | ONNX | Voice Cloning | Emotion Control | Cross-Platform | Integration |
|-------|-------------|------|---------------|-----------------|----------------|-------------|
| **Fish Speech 1.5** | ✅ Native | ❌ | ✅ Zero-shot | ⚠️ Via reference | ✅ (no Windows) | Medium |
| **Pocket TTS** | ✅ Native | ❌ | ✅ Zero-shot | ⚠️ Limited | ✅ CPU focus | Low |
| **Qwen3-TTS-rs** | ✅ Native | ❌ | ✅ Multi-mode | ✅ Text-described | ✅ All | Medium-High |
| **OpenVoice v2** | ❌ | ⚠️ | ✅ Excellent | ✅ Best | Python only | High |
| **Coqui XTTS** | ❌ | ⚠️ | ✅ Excellent | ⚠️ Limited | Python only | Very High |
| **StyleTTS2** | ❌ | ⚠️ | ⚠️ Fine-tune | ✅ Good | Python only | Very High |
| **MARS5-TTS** | ❌ | ❌ | ✅ Good | ⚠️ Limited | Python only | Very High |
| **Kokoro Custom** | ✅ (via ONNX) | ✅ | ❌ Interpolate | ❌ | ✅ | Very Low |
| **sherpa-rs** | ✅ Bindings | ✅ | ❌ | ❌ | ✅ All | Low |

---

## Recommended Integration Strategy

### Phase 1: Quick Wins (Current Pipeline Enhancement)
1. **Use kokovoicelab** to create custom interpolated voices
2. Export new `voices.bin` for existing Kokoro pipeline
3. Effort: 1-2 hours

### Phase 2: Add Voice Cloning (fish-speech.rs)
1. Build fish-speech.rs with Metal/CUDA
2. Run as sidecar service with OpenAI-compatible API
3. Create voice encodings from reference audio
4. Route "clone voice" requests to fish-speech.rs, default to Kokoro
5. Effort: 1-2 days

### Phase 3: Full Featured (Qwen3-TTS-rs)
1. Integrate Qwen3-TTS-rs for text-describedvoices
2. Use VoiceDesign model for natural language voice control
3. Keep Kokoro for fast default synthesis
4. Route complex requests to Qwen3
5. Effort: 1 week

### Architecture Suggestion

```
┌─────────────────────────────────────────────────┐
│                 Fae Voice Assistant              │
├─────────────────────────────────────────────────┤
│                   TTS Router                     │
│  ┌───────────────────────────────────────────┐  │
│  │ "default" → Kokoro-82M (fast, low memory) │  │
│  │ "clone"   → fish-speech.rs (voice clone)  │  │
│  │ "design"  → Qwen3-TTS (text-described)    │  │
│  └───────────────────────────────────────────┘  │
└─────────────────────────────────────────────────┘
```

---

## Sources

1. [fish-speech.rs GitHub](https://github.com/EndlessReform/fish-speech.rs) - Native Rust/Candle Fish Speech implementation
2. [kokovoicelab GitHub](https://github.com/RobViren/kokovoicelab) - Kokoro voice interpolation tools
3. [pocket-tts crate](https://lib.rs/crates/pocket-tts) - Rust Pocket TTS implementation
4. [Qwen3-TTS-rs GitHub](https://github.com/TrevorS/qwen3-tts-rs) - Pure Rust Qwen3-TTS
5. [sherpa-rs GitHub](https://github.com/thewh1teagle/sherpa-rs) - Rust bindings to sherpa-onnx
6. [OpenVoice GitHub](https://github.com/myshell-ai/OpenVoice) - Zero-shot voice cloning
7. [Coqui XTTS HuggingFace](https://huggingface.co/coqui/XTTS-v2) - Voice cloning model
8. [StyleTTS2 GitHub](https://github.com/yl4579/StyleTTS2) - Style-based TTS
9. [MARS5-TTS GitHub](https://github.com/Camb-ai/MARS5-TTS) - CAMB.AI speech model
10. [Kokoro Custom Voices Space](https://huggingface.co/spaces/ysharma/Make_Custom_Voices_With_KokoroTTS) - Voice mixer
