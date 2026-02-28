# ADR-003: Local-Only LLM Inference

**Status:** Superseded (historical)
**Date:** 2026-02-13
**Scope:** Rust-era LLM backend (`src/llm/`, `src/config.rs`, `src/personality.rs`, `src/fae_llm/`)

> Historical note: this ADR documents the earlier Rust stack.
> Current production model orchestration is Swift-native in `native/macos/Fae`.

## Context

Fae's core promise is privacy — all intelligence runs on the user's Mac with no remote servers. The LLM backend must support:

- Fast conversational responses for the voice channel (<100ms TTFT)
- Tool calling for background tasks (calendar, search, reminders)
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

### Local-only inference

Fae runs exclusively on local models via `mistralrs` with Metal acceleration on Apple Silicon. No API keys or remote servers required. The `LlmBackend` config only accepts `"local"`.

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

- **Complete privacy** — no data leaves the device
- **No API costs** — runs entirely on hardware the user already owns
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
