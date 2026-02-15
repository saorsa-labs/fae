# fae

> ## :warning: UNDER HEAVY DEVELOPMENT — DO NOT USE AS THIS COULD BE DANGEROUS SOFTWARE :warning:
>
> This project is in active early development. APIs, functionality, and behavior may change without notice. **Do not use in production or any environment where safety is a concern.** Use at your own risk.

![Fae](assets/fae.jpg)

Fae is your personal AI assistant. It is currently made up of a few different models in a pipeline. As AI and small models improve, we will simply improve the "brain" of the system. Fae allows you to set remote AI models like OpenAI or Anthropic, or use open-source models. However, Fae retains the security: anything involving your keys, passwords, or wallets is handled by Fae and the local AI. She can hand off tasks to larger models for deeper thinking, but you don't necessarily need that; you can work directly with Fae.

What we want people to realize is that while she is relatively capable now and will improve quickly, she is already significantly more capable than a human at:
1. Configuring the computer
2. Getting software to work
3. Operating a wallet
4. Handling payments

Because she is completely local, your passwords and keys are safe. To put it in perspective, you will need a relatively powerful computer—a decent laptop like a MacBook works fine—and hardware requirements will improve over time. This is not intended to be an OpenClaw or OpenAI replacement right now.

Fae is a personal, capable, local assistant who gets significantly smarter every few months. She gets to know you over time, and the memories you share with her are yours. They are stored locally and maintained securely. We work as hard as we can to ensure that security is in place.

This is the first significant step on a ladder. It allows for:
1. Very easy setup
2. Reasonable intelligence
3. A highly capable configuration manager for your computer

Imagine a tool that allows your grandmother to use a computer, set things up, download software, and configure it. At the moment, we recommend that users use the menu system to introduce new skills to Fae. You can read the skill yourself before it ever reaches her context window, which is an important security element.

Fae is your personal second brain. She is there to help you, and for you to help her. As your memories grow and you get to know each other, the AI models will improve. Updates over the next few months will improve her brain, helping her know you better through the memories living on your computer. We will also add the ability to securely store those memories in different locations so you don't lose them, while ensuring no one else has access to them.

If you have ever wanted to run a node on a network, run a server, or use peer-to-peer software—which has historically been complex and required professional tweaking—Fae takes all that difficulty away. Fae allows a novice to outperform a modern-day computer wizard. Beyond being a friend and a memory, she is likely a better computer professional than anyone you know today. We hope you enjoy using Fae and understand the vision behind what she is.

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
