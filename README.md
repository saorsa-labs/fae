# fae

> ## :warning: UNDER HEAVY DEVELOPMENT — DO NOT USE AS THIS COULD BE DANGEROUS SOFTWARE :warning:
>
> This project is in active early development. APIs, functionality, and behavior may change without notice. **Do not use in production or any environment where safety is a concern.** Use at your own risk.

![Fae](assets/fae.jpg)

Fae is a local-first personal AI assistant built in Rust for low-latency voice interaction and practical computer operations. Today, she runs a multi-model pipeline, and that "brain" can be upgraded over time as smaller and better models become available.

The project exists to make advanced computer tasks accessible to everyday users without giving up control of private data. You can run Fae fully local, connect remote providers such as OpenAI or Anthropic, or combine both. Sensitive workflows can stay on-device while remote models are optional for deeper reasoning.

In practice, Fae is designed to help with:

1. Computer setup and configuration
2. Software installation and troubleshooting
3. Wallet-oriented workflows
4. Payment-related workflows

Fae is not positioned as a replacement for large hosted AI platforms today. It is a personal assistant that runs close to the user, improves quickly as model quality improves, and keeps long-term memory under user control on local storage. A modern laptop (for example, a recent MacBook) is recommended for the best local experience.

## Using Fae Out of the Box

1. Run `just run`.
2. Click `Start Listening` and speak naturally in short, concrete requests.
3. Keep default local settings to start, then change capabilities gradually as trust grows.
4. Open `Fae -> Fae Guide` for prompt examples and operating patterns.

## Menu Options (What They Are For)

| Menu option | Why it exists | How to use it |
|---|---|---|
| `Fae -> Settings...` (`Preferences...` on non-macOS) | Day-to-day runtime controls | Set tool mode, wake word, stop phrase, channels, and updates, then click `Save`. |
| `Fae -> Soul...` | Personality and behavior scaffolding | Edit `SOUL.md` and onboarding behavior, then save. |
| `Fae -> Skills...` | Safe capability expansion | Download a skill draft, review/edit it, run analysis, then install only if approved. |
| `Fae -> Memories...` | Memory transparency and control | Manage primary profile data and review/edit durable records (including forget/invalidate actions). |
| `Fae -> Ingestion...` | Bring local files into memory | Select a file/folder and run ingestion in the background using the local brain. |
| `Fae -> Fae Guide` | In-app usage help | Review recommended prompt style, tool safety, and update flow. |
| `Fae -> Check for Updates...` | Keep Fae current | Run a manual update check from the menu bar. |

As you customize Fae, the typical progression is: keep tools conservative at first, tune your model selection in `Models`, refine behavior in `Soul`, add reviewed skills, and gradually let Fae handle more of your personal workflow.

## Architecture Overview

```
Mic (16kHz) -> AEC -> VAD -> STT -> LLM -> TTS -> Speaker
                |                         |
                +-> Wakeword              +-> Memory capture

Before each LLM turn: memory recall injects durable context.
After each LLM turn: memory capture persists episodes/facts/profile updates.
```

## LLM Backends

Fae always runs through the internal agent loop (tool calling + sandboxing). The backend setting only chooses the LLM brain source (local vs API).

| Backend | Config | Inference location | Tool loop |
|---|---|---|---|
| Local | `backend = "local"` | On-device (`mistralrs`) | Yes |
| API | `backend = "api"` | Remote OpenAI-compatible endpoint | Yes |
| Agent | `backend = "agent"` | Compatibility auto-mode (local when no remote creds, otherwise API) | Yes |

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
2. `~/.fae/SOUL.md` (with repository fallback)
3. Built-in + user skills (`Skills/*.md` + `~/.fae/skills/*.md`)
4. User add-on prompt
5. `~/.fae/onboarding.md` is injected only while onboarding is incomplete

[`SOUL.md`](SOUL.md) documents human-facing behavior and principles for identity, memory, and tool use.

Prompt copy interview guide: `docs/prompt-content-interview.md`.

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
api_type = "auto"
# external_profile = "work-openai"

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
