# fae

> ## :warning: UNDER HEAVY DEVELOPMENT — DO NOT USE AS THIS COULD BE DANGEROUS SOFTWARE :warning:
>
> This project is in active early development. APIs, functionality, and behavior may change without notice. **Do not use in production or any environment where safety is a concern.** Use at your own risk.

A real-time voice conversation system in Rust. Fae is a calm, helpful Scottish voice assistant designed for low-latency local operation with optional cloud providers.

## Architecture Overview

```
Mic (16kHz) -> AEC -> VAD -> STT -> LLM -> TTS -> Speaker
                |                         |
                +-> Wakeword              +-> Memory capture

Before each LLM turn: memory recall injects durable context.
After each LLM turn: memory capture persists episodes/facts/profile updates.
```

## LLM Backends

The agent loop, tool calling, and sandboxing are shared. The backend changes where inference runs.

| Backend | Config | Inference location | Tool loop |
|---|---|---|---|
| Local | `backend = "local"` | On-device (`mistralrs`) | Yes |
| API | `backend = "api"` | Remote OpenAI-compatible endpoint | Yes |
| Agent | `backend = "agent"` | Remote provider adapters (OpenAI/Anthropic/custom) | Yes |

Local fallback is supported when `enable_local_fallback = true`.

## Tool Modes

| Mode | Tools |
|---|---|
| `off` | none |
| `read_only` | `read` |
| `read_write` | `read`, `edit`, `write` |
| `full` | `read`, `edit`, `write`, `bash` |
| `full_no_approval` | same as `full`, without approval gate |

Canvas tools (`canvas_render`, `canvas_interact`, `canvas_export`) are registered when canvas is enabled.

## Security Model

All tool execution is scoped to the workspace boundary.

1. Input sanitization for command/path arguments.
2. Path validation and traversal blocking.
3. Output truncation/sanitization for safe model feedback.
4. Approval gate for high-risk tools unless running in `full_no_approval`.

## Memory System

Fae has an automated memory system with no manual button flow required for normal operation.

- Storage root: `~/.fae/memory/`
- Core files:
  - `manifest.toml` (schema metadata)
  - `records.jsonl` (memory records)
  - `audit.jsonl` (memory operation log)
- Legacy compatibility files:
  - `~/.fae/memory/primary_user.md`
  - `~/.fae/memory/people.md`
- Voice samples: `~/.fae/voices/`

Lifecycle per turn:

1. Recall: query current input, rank active durable memories, inject bounded `<memory_context>`.
2. Capture: persist episode + detect durable updates (name/preferences/explicit remember/forget).
3. Conflict handling: supersede older truths with lineage instead of destructive overwrite.
4. Retention: episodic records are soft-forgotten according to policy.

Background maintenance jobs:

- `memory_migrate`
- `memory_reflect`
- `memory_reindex`
- `memory_gc`

Main-screen UX policy:

- Memory telemetry is suppressed on the main conversational surface.
- Memory maintenance telemetry is shown in canvas/event surfaces.

See:

- [Memory Guide](docs/Memory.md)
- [Memory Architecture Plan](docs/memory-architecture-plan.md)
- [Personalization and Proactive Plan](docs/personalization-interviews-and-proactive-plan.md)

## Prompt Stack and SOUL

Runtime system prompt assembly is layered:

1. `CORE_PROMPT`
2. Personality profile (`fae` or custom)
3. Loaded skills (built-in + user)
4. User add-on prompt

[`SOUL.md`](SOUL.md) documents human-facing behavior and principles for identity, memory, and tool use.

## Context and History Defaults

- `llm.context_size_tokens` defaults based on system RAM:
  - `< 12 GiB`: `8192`
  - `< 20 GiB`: `16384`
  - `< 40 GiB`: `32768`
  - `>= 40 GiB`: `65536`
- `llm.max_history_messages`: `24`
- Memory recall defaults:
  - `memory.recall_max_items = 6`
  - `memory.recall_max_chars = 1200`

## Configuration

Config file: `~/.config/fae/config.toml`

```toml
[llm]
backend = "local"
model_id = "unsloth/Qwen3-4B-Instruct-2507-GGUF"
context_size_tokens = 32768
max_history_messages = 24
enable_local_fallback = true
tool_mode = "read_only"

[memory]
enabled = true
auto_capture = true
auto_recall = true
recall_max_items = 6
recall_max_chars = 1200
min_profile_confidence = 0.70
retention_days = 365
schema_auto_migrate = true
```

## Developer Commands

```bash
just run           # Run GUI app
just build         # Build (CLI-only)
just build-gui     # Build GUI binary
just test          # Run tests
just lint          # Run clippy
just fmt           # Format code
```

## License

AGPL-3.0
