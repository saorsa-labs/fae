# ADR-003: Local-First LLM Inference

**Status:** Accepted (evolved — **local-FIRST, not local-only**; see ADR-012)
**Date:** 2026-02-13
**Scope:** On-device LLM inference (the default brain)

> **Reframed 2026-06-24 (ADR-012): local-FIRST, not local-only.** The original
> decision below — "Fae runs exclusively on local models, no API keys, no data leaves
> the device" — is **superseded in stance**. Fae's *default* brain is the on-device
> model (privacy-first by default), but per **ADR-012** Fae is a **coordinator** that
> also dispatches to external AIs (cloud APIs, ACP agents, mesh peers) when the user
> has provisioned them. External use is made safe by the **PII membrane**
> (`fae-pii-membrane`), not by prohibition. What remains unchanged: the on-device model
> is the default and requires no API keys, and nothing egresses without passing the
> membrane. This ADR is kept for its model-selection + hardware-ceiling rationale,
> which is still accurate for the local lane.
>
> Implementation changed from Rust/mistralrs/ONNX to Swift/MLX. Models evolved from Qwen3 to Qwen3.5, with Gemma 4 migration pending.
>
> **Update 2026-06-11 (Great Cleanup / orb-first):** the primary inference lane is now the
> Rust daemon (`crates/fae-daemon` + `fae-engine`, mistral.rs, Gemma 4 E4B) behind
> `llm.useDaemonEngine`, with a llama.cpp adapter planned for Vulkan-class hardware.
> The Swift/MLX engine described here remains the macOS fallback and LoRA training
> substrate. Local-only remains unchanged. See ADR-009 and
> `docs/architecture/great-cleanup-2026-06-11.md`.

## Context

Fae's core promise is privacy. The **on-device model is the default brain** and runs with no remote servers or API keys; external models are coordinated only when provisioned and only through the PII membrane (ADR-012). The local LLM backend must support:

- Correct, thorough responses that leverage tools (memory, web search, file ops) before answering
- Tool calling for all tasks (calendar, search, reminders, file management)
- Personality steering via system prompts
- Reasonable capability within local model size constraints

### Hardware reality

Apple Silicon Macs have unified memory shared between CPU and GPU. Available RAM directly constrains model size:

| System RAM | Available for models | Practical model ceiling |
|-----------|---------------------|------------------------|
| 8-16 GB | ~4-8 GB | 0.6B-1.7B Q4 |
| 16-32 GB | ~8-16 GB | 1.7B-4B Q4 |
| 32-64 GB | ~16-32 GB | 4B-8B Q4 |
| 64+ GB | ~32+ GB | 8B+ Q4 |

## Decision

### Local-first inference

The **default** brain runs on local models via `mistralrs` (Metal on Apple Silicon) / the llama.cpp sidecar — no API keys or remote servers required for the default path. External models (cloud APIs, ACP agents, mesh peers) are dispatched by the coordinator only when the user has provisioned them, and only through the PII membrane (ADR-012). *(Historical: the original `LlmBackend` accepted only `"local"`; that local-only constraint is superseded by ADR-012.)*

### Dual-channel architecture

Two independent LLM channels serve different purposes:

| Channel | Model | Context Budget | Speed | Purpose |
|---------|-------|---------------|-------|---------|
| **Voice** | Qwen3-1.7B (Q4_K_M) | ~1.5K tokens | ~85 T/s | Fast conversational responses |
| **Background** | Qwen3-4B+ (Q4_K_M) | Full window | Async | Tool-heavy tasks (calendar, search, etc.) |

The voice channel uses `VOICE_CORE_PROMPT` (~2KB condensed prompt with identity, style, and companion presence only — no tool schemas). When Fae detects a request needing tools, she gives an immediate spoken acknowledgment and dispatches work to the background channel asynchronously.

### Three prompt variants

1. **CORE_PROMPT** (~18KB): Full system prompt with tools, scheduler, skills, coding policy. Used by background channel.
2. **VOICE_CORE_PROMPT** (~2KB): Condensed for voice — identity, style, companion presence only. Used by voice channel.
3. **BACKGROUND_AGENT_PROMPT**: Task-focused, tool-heavy, spoken-friendly output. Used by background agents.

Prompt assembly order: system prompt -> SOUL contract -> memory context -> skills/tool instructions -> user message.

### Automatic model selection

`VoiceModelPreset::Auto` selects based on system RAM:

| RAM | Voice Model | Background Model |
|-----|-------------|-----------------|
| >= 32 GB | Qwen3-1.7B | Qwen3-4B |
| < 32 GB | Qwen3-1.7B | Qwen3-1.7B |

All auto-selected models are **text-only GGUF**. Vision models are only enabled via explicit `enable_vision = true` config.

### Available presets

| Preset | Model | GGUF File | Use Case |
|--------|-------|-----------|----------|
| Auto | RAM-dependent | See above | Default |
| Qwen3_4b | Qwen3-4B | Q4_K_M | Stronger reasoning |
| Qwen3_1_7b | Qwen3-1.7B | Q4_K_M | Fast voice |
| Qwen3_0_6b | Qwen3-0.6B | Q4_K_M | Minimal RAM |

### Vision support (opt-in)

Vision-capable models (Qwen3-VL variants) accept image inputs for screen analysis, document reading, and visual context. They use `VisionModelBuilder` with ISQ Q4K quantization (slower startup, higher RAM). If vision load fails, automatic fallback to text-only GGUF.

| Aspect | Text-only GGUF | Vision (VL + ISQ) |
|--------|----------------|-------------------|
| Loading | Fast (pre-quantized) | Slow (ISQ at startup) |
| Speed | Higher T/s | ~10-20% slower |
| RAM | Lower | Higher (vision encoder) |
| Capabilities | Text only | Text + image |

### Context window scaling

Defaults scale with system RAM:

| RAM | Default Context |
|-----|----------------|
| < 12 GB | 8K tokens |
| < 20 GB | 16K tokens |
| < 40 GB | 32K tokens |
| >= 40 GB | 64K tokens |

## Consequences

### Positive

- **Privacy by default** — on the default local path no data leaves the device; any external dispatch is provisioned + PII-gated (ADR-012)
- **No API costs by default** — the local brain runs on hardware the user already owns; cloud costs only when the user provisions a paid model, under the D2 budget caps
- **Dual-channel** keeps voice responsive while enabling tool-heavy background work
- **Automatic scaling** — model and context window adapt to hardware

### Negative

- **Capability ceiling** — local models (1.7B-8B) are less capable than cloud models (70B+)
- **Apple Silicon only** — Metal acceleration required for acceptable speed
- **RAM pressure** — LLM + STT + TTS + embedding all compete for unified memory

## Voice command switching

Users can switch models via voice:

| Command | Effect |
|---------|--------|
| "use the local model" | Switch to on-device Qwen3 |
| "list models" | Show available models |
| "what model are you using?" | Report current model |

## Tool system

Both channels access the same tool registry through the `fae_llm` agent loop:

- **Core**: read, write, edit, bash
- **Web**: web_search, fetch_url
- **Apple**: calendar, contacts, mail, reminders, notes
- **Desktop**: screenshots, window management, typing, clicks
- **Scheduler**: list/create/update/delete/trigger tasks
- **Skills**: python_skill (JSON-RPC subprocess)
- **Canvas**: render, interact, export

Tool modes (`AgentToolMode`): `off`, `read_only`, `read_write`, `full`, `full_no_approval`.

## References

- LLM benchmarks: `docs/benchmarks/llm-benchmarks.md`
- `src/config.rs` — `VoiceModelPreset`, `recommended_local_model()`, `AgentToolMode`
- `src/personality.rs` — `CORE_PROMPT`, `VOICE_CORE_PROMPT`, `BACKGROUND_AGENT_PROMPT`
- `src/llm/mod.rs` — Model loading (GGUF + Vision paths)
