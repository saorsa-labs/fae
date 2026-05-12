# Local Model Strategy

Last updated: April 4, 2026

This is the current canonical guide for Fae's local model stack.

## Product direction

Fae is transitioning from Qwen3.5 to **Gemma 4** as the primary local model family:

- Gemma 4 E2B/E4B models handle **audio input natively** (USM conformer), eliminating the need for a separate STT model on most tiers
- On ≥32GB Macs, a **dual-model path** pairs E2B (dedicated ASR) with 26B-A4B (LLM) for maximum quality
- Gemma 4 also includes native **vision** (text+image), potentially replacing the separate VLM stack

**Status:** Codebase prepped, waiting on [mlx-swift-lm PR #180](https://github.com/ml-explore/mlx-swift-lm/pull/180) for Swift support. Qwen3.5 remains the active fallback until Gemma 4 is validated in production.

## Text + audio model strategy (Gemma 4 target)

### Auto model selection (target)

| System RAM | Model | Mode | Context | Memory |
|---|---|---|---:|---:|
| `<8 GB` | Gemma 4 E2B 4-bit | Unified (audio-direct ASR+LLM) | 128K | ~6.9GB |
| `8–15 GB` | Gemma 4 E2B 4-bit | Unified (audio-direct ASR+LLM) | 128K | ~6.9GB |
| `16–31 GB` | Gemma 4 E4B 4-bit | Unified (audio-direct ASR+LLM) | 128K | ~8.5GB |
| `≥32 GB` | E2B (ASR) + 26B-A4B (LLM) | Dual (dedicated ASR + quality LLM) | 256K | ~20.9GB |

**Unified mode** (<32GB): Audio goes directly to the LLM. The model produces a `<transcript>` block (for UI display, memory, and conversation history) followed by its response, in a single inference pass.

**Dual mode** (≥32GB): E2B runs as a dedicated ASR engine (3.6GB). 26B-A4B runs as the LLM (14GB). Best quality — 98% MMLU, 100% on all Fae-specific metrics.

### Benchmark results (2026-04-02)

| Model | Tool Call | MMLU | Fae Cap | Asst Fit | Serial |
|---|---|---|---|---|---|
| Gemma 4 E2B 4-bit (2.3B eff) | 100% | 80% | 90% | 85% | 100% |
| Gemma 4 E4B 4-bit (4.5B eff) | 100% | 90% | 100% | 100% | 100% |
| Gemma 4 26B-A4B 4-bit (4B active) | 90% | 98% | 100% | 100% | 100% |

4-bit quantization is optimal for Gemma tool calling — higher precision (8-bit, bf16) makes the model "too polite" and reduces tool call rate. Avoid MXFP4 (worse than uniform 4-bit).

### Manual text presets

| Preset | Model | RAM | Role |
|---|---|---|---|
| `gemma_4_e2b` | `mlx-community/gemma-4-e2b-it-4bit` | 8+ GB | Compact unified (ASR+LLM) |
| `gemma_4_e4b` | `mlx-community/gemma-4-e4b-it-4bit` | 16+ GB | Full unified (ASR+LLM) — sweet spot |
| `gemma_4_26b_a4b` | `mlx-community/gemma-4-26b-a4b-it-4bit` | 32+ GB | Quality LLM (paired with E2B ASR) |

### Qwen fallback presets (active until Gemma 4 ships)

| Preset | Model | RAM | Role |
|---|---|---|---|
| `qwen3_5_2b` | `mlx-community/Qwen3.5-2B-OptiQ-4bit` | <8 GB | Compact fallback |
| `qwen3_5_4b` | `mlx-community/Qwen3.5-4B-4bit` | 8+ GB | Small general model |
| `qwen3_5_9b` | `Brooooooklyn/Qwen3.5-9B-unsloth-mlx` | 16+ GB | Quality fallback |
| `qwen3_5_35b_a3b` | `mlx-community/Qwen3.5-35B-A3B-4bit` | 32+ GB | MoE fallback |

Legacy aliases: `saorsa-1.1-tiny` → `qwen3_5_2b`, `saorsa_1_1_tiny` → `qwen3_5_2b`.

## Vision model strategy

With Gemma 4, vision is **built into the LLM** (all Gemma 4 models are natively multimodal). The separate VLM stack (SmolVLM2) may become redundant once Gemma 4 ships.

Current (active):

| System RAM | Auto vision model | Context |
|---|---|---:|
| `<16 GB` | disabled | — |
| `16+ GB` | SmolVLM2-500M (on-demand) | — |

## Speech models

### Target (Gemma 4)

| RAM | STT | TTS |
|---|---|---|
| <32 GB | None needed — LLM handles ASR via audio-direct | Kokoro-82M |
| ≥32 GB | Gemma 4 E2B (dedicated ASR, 3.6GB) | Kokoro-82M |

Gemma 4 E2B/E4B have native audio input via USM conformer (~300M params). ASR accuracy: 5/5 perfect on test utterances at 0.1-0.2s latency. No TTS output — Kokoro still needed.

### Current fallback (Qwen)

| Component | Auto selection |
|---|---|
| STT | `Qwen3-ASR-1.7B-4bit` at 16+ GB, otherwise `Qwen3-ASR-0.6B-4bit` |
| TTS | Kokoro-82M via FaeTTSAdapter |

## Switching behavior

- Changing the text model preset triggers an in-app pipeline reload.
- A full app restart is not required for normal model switching.
- If a selected model is not cached locally, Fae downloads it during that reload.
- All models cached at `~/.cache/huggingface/hub/` — shared between Python benchmarks and production Fae.

## Source of truth

The current runtime selection logic lives in:

- [FaeConfig.swift](../../native/macos/Fae/Sources/Fae/Core/FaeConfig.swift) — `recommendedModel()`, `recommendedSTTModel()`, `canonicalVoiceModelPreset()`
- Benchmark results: `scripts/benchmark-results/`
- Benchmark tool (Gemma): `scripts/benchmark_gemma4.py` (`--tiers` for production models)
- Benchmark tool (Qwen): `Sources/FaeBenchmark/` (native Swift)
