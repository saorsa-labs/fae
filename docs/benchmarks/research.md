# Fae Research & Evaluation

Consolidated research findings and evaluation suites that inform Fae's architecture.

---

## Tool Judgment Eval Suite

Validates the "should call a tool" vs "should not call a tool" boundary for Fae's agent.

**Test file:** `tests/tool_judgment_eval.rs`

**Run:**

```bash
just tool-judgment-eval
```

### Coverage design

- Broad category mix: arithmetic, text transforms, meta prompts, static reasoning, planning, local read/write, real-time/date, web freshness, multi-step execution
- Balanced positive/negative labels to catch both over-calling and under-calling
- Per-category scoring in addition to aggregate metrics

### Enforced expectations

- Dataset size and breadth minimums (category count, per-category count, class balance)
- Perfect policy scores 100%
- Always-call policy fails
- Never-call policy fails
- Local-only policy exposes web/time judgment gaps

### Why this exists

Small models can regress on tool judgment even when tool execution is stable. This suite keeps judgment quality explicit and measurable during refactors.

---

## Voice-to-Voice AI Models Research

Evaluation of end-to-end voice-to-voice AI models and cascaded pipeline approaches for Fae's conversational system, requiring personality steering via system prompts, Rust/cross-platform support, and natural conversational quality.

### Key finding

**No unified speech-to-speech model currently offers robust system prompt support.** Personality steering remains primarily achievable through cascaded architectures where the LLM component handles behavior control.

### Decision outcome

Fae uses **Option A: Cascaded pipeline** — the architecture that provides maximum personality control:

```
Mic → AEC → Silero VAD → Parakeet STT (ONNX) → LLM Agent → Kokoro TTS (ONNX) → Speaker
```

All components run locally via ONNX Runtime or native Rust inference (mistral.rs for LLM). No API calls required.

### Model comparison summary

| Model | Type | System Prompt | Rust | Latency | License |
|-------|------|---------------|------|---------|---------|
| **Moshi** | Unified S2S | No (needs fine-tune) | Native | ~200ms | Apache/MIT/CC-BY |
| **Ultravox** | Audio LLM | Full support | No | ~100ms | MIT |
| **MiniCPM-o** | Omni-modal | Yes | No | Real-time | MiniCPM License |
| **Qwen2.5-Omni** | Omni-modal | Constrained | No | Real-time | Qwen License |
| **HF S2S Pipeline** | Cascaded | Yes (LLM layer) | Components | Variable | Apache |
| **Sherpa-ONNX** | Components | N/A | sherpa-rs | Model-dep | Apache |

### Why cascaded won

1. **Personality control** — full system prompt control at LLM layer; unified models (Moshi, Qwen2.5-Omni) require fine-tuning or fixed personas
2. **Rust-native** — Candle, ort, and sherpa-rs provide complete Rust coverage; unified models are Python-only (except Moshi)
3. **Component flexibility** — swap STT/LLM/TTS independently as better models emerge
4. **Local-only privacy** — all inference on-device, no API keys or remote servers

### Rust ML ecosystem used

| Component | Fae uses | Crate |
|-----------|----------|-------|
| VAD | Silero VAD | via `ort` |
| STT | Parakeet TDT 0.6B | via `ort` |
| LLM | Qwen3 (1.7B/4B) GGUF | `mistralrs` (Metal) |
| TTS | Kokoro-82M | via `ort` |
| Embedding | all-MiniLM-L6-v2 | via `ort` |

### Alternative architectures evaluated

**Option B — Near-native with Ultravox**: Ultravox has excellent system prompt support and MIT license, but requires Python/API and significant GPU for local deployment. Could be a future cloud-hybrid option.

**Option C — Lowest latency with Moshi**: Native Rust implementation with ~200ms latency, but only 2 fixed voices (Moshiko/Moshika) with no runtime personality steering. Requires fine-tuning for any customization.

### Future watch

- Ultravox speech token output (would enable unified experience with prompt control)
- Model-assisted extraction/validation for memory capture
- Smaller, faster voice models as they emerge

---

*Research conducted February 2026. Sources: HuggingFace models, open-source voice AI projects, Rust ML ecosystem.*
