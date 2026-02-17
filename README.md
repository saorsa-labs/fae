# Fae

> ## :warning: UNDER HEAVY DEVELOPMENT — DO NOT USE AS THIS COULD BE DANGEROUS SOFTWARE :warning:
>
> This project is in active early development. APIs, functionality, and behavior may change without notice. **Do not use in production or any environment where safety is a concern.** Use at your own risk.

![Fae](assets/fae.jpg)

Fae is a personal AI companion who listens, remembers, and helps — like having a knowledgeable friend who is always in the room. She runs entirely on your computer, keeping your data private and secure.

**The vision is simple:** imagine a computer that your grandmother could use. Fae handles the complexity — setting up software, managing files, scheduling reminders, researching topics, and keeping track of the people and events that matter to you. You just talk to her.

## What Fae Does

### Always Listening, Never Intrusive

Fae is an always-present companion, not a summoned assistant. She listens continuously and decides when to speak:

- **Direct conversation** — talk to Fae naturally and she responds with warmth and clarity.
- **Overheard conversations** — if people nearby are discussing something Fae can help with, she may politely offer useful information.
- **Background noise** — Fae stays quiet when the TV is on, music is playing, or conversations don't involve her.
- **Listening control** — Fae stays in always-listening mode unless you press `Stop Listening`; press `Start Listening` to resume.

Fae uses echo cancellation and voice activity detection to separate your speech from ambient noise and her own voice. She never interrupts without good reason.

### Remembers Everything That Matters

Fae has a durable memory system that learns about you over time — your name, preferences, work context, relationships, and routines. All stored locally on your machine.

- **Automatic recall** — before every response, Fae recalls relevant memories to personalise her help.
- **Automatic capture** — after every conversation turn, Fae records useful facts, events, and updates.
- **Conflict resolution** — when information changes, Fae supersedes old facts with lineage tracking, never silently overwrites.
- **Explicit control** — ask Fae to remember or forget anything. All operations are auditable.
- **Background maintenance** — Fae periodically consolidates, reindexes, and cleans up memories to keep them useful and bounded.

Storage: `~/.fae/memory/` (JSONL records, TOML manifest, audit log)

### Proactive Intelligence

Fae doesn't just respond — she learns forward from your conversations and acts on what she discovers:

- **Conversation mining** — extracts dates, birthdays, upcoming events, people mentioned, interests, and commitments from every conversation.
- **Self-scheduling** — creates reminders, research tasks, and check-in prompts automatically via her built-in scheduler.
- **Morning briefings** — say "good morning" or "what's new" and Fae delivers a warm summary of upcoming events, people to reconnect with, and research she's done overnight.
- **Relationship tracking** — remembers who you mention, how you know them, and when you last talked about them. Gently surfaces stale relationships you might want to check in on.
- **Background research** — when Fae detects your interests, she researches topics in the background and prepares summaries for your next briefing.
- **Skill proposals** — when Fae notices patterns (frequent calendar mentions, repeated email discussions), she proposes new skills to help. Always asks before installing.
- **Noise control** — daily delivery budgets, cooldown periods, deduplication, and quiet hours prevent Fae from ever becoming annoying.

Proactivity levels: **Off** (disabled), **Digest Only** (extract but deliver only on request), **Gentle** (scheduled briefings, default), **Active** (briefings + timely reminders).

### Desktop Automation

Fae can manage applications on your computer through a cross-platform desktop automation tool:

- Open, close, and interact with desktop applications.
- Read and write files, configure software, and manage system settings.
- Execute shell commands with a safety-first approval model.
- Help with tasks like installing software, configuring networks, and managing wallets.

Tool modes control how much access Fae has:

| Mode | What Fae Can Do |
|---|---|
| `off` | Conversation only — no computer access |
| `read_only` | Read files and check system state |
| `read_write` | Read and write files |
| `full` | Full access including shell commands (with approval) |
| `full_no_approval` | Full access without approval prompts |

Canvas tools (`canvas_render`, `canvas_interact`, `canvas_export`) are available when canvas is enabled.

### Scheduler

Fae has a built-in task scheduler that runs in the background:

- **User tasks** — set reminders, recurring check-ins, and follow-ups through natural conversation ("remind me every morning to review my tasks").
- **System tasks** — automatic memory maintenance, update checks, intelligence extraction, and briefing preparation.
- **Conversation triggers** — scheduled tasks can inject prompts into the conversation at the right time.
- **Management** — view all tasks via `Fae -> Scheduled Tasks...` in the menu, or ask Fae to list, create, update, or delete tasks by voice.

Built-in scheduled tasks:

| Task | Schedule | Purpose |
|---|---|---|
| `check_fae_update` | Every 6 hours | Check for new Fae releases |
| `memory_migrate` | Every 1 hour | Schema migration checks |
| `memory_reflect` | Every 6 hours | Consolidate duplicate memories |
| `memory_reindex` | Every 3 hours | Memory health and reindexing |
| `memory_gc` | Daily at 03:30 | Retention cleanup |
| `noise_budget_reset` | Daily at midnight | Reset proactive delivery budget |
| `stale_relationships` | Weekly | Detect relationships needing check-in |
| `morning_briefing` | Daily at 08:00 | Prepare morning briefing data |
| `skill_proposals` | Daily at 11:00 | Detect skill opportunities |

### Skills System

Fae's capabilities grow over time through skills — markdown guides that teach her new workflows:

- Built-in skills cover common tasks out of the box.
- User skills live in `~/.fae/skills/` and can be added, reviewed, and edited from the `Fae -> Skills...` menu.
- Fae can propose new skills when she detects useful patterns in your conversations.
- All skills are reviewed by you before installation — Fae never installs a skill without your explicit approval.
- Packaged skills can be installed with `cargo run --bin fae-skill-package -- install <package-dir>` (examples: `Skills/packages/native-device-handoff`, `Skills/packages/native-orb-semantics`).

### External Channels

Fae can communicate through external channels beyond voice:

- **Discord** — connect a Discord bot for text-based Fae interaction.
- **WhatsApp** — receive and send messages through WhatsApp.
- **Webhooks** — integrate with other services through configurable webhooks.

Configure via `Fae -> Channels...` in the menu.

## Architecture

```
Mic (16kHz) -> AEC -> VAD -> STT -> LLM (Agent Loop) -> TTS -> Speaker
                |                         |                  |
                +-> Wakeword              +-> Memory         +-> Orb state events (native UI)
                                          +-> Intelligence
                                          +-> Scheduler
```

**Voice pipeline:** microphone capture at 16kHz, acoustic echo cancellation (AEC), voice activity detection (VAD) with configurable sensitivity, speech-to-text (STT via Parakeet ONNX), LLM processing through the agent loop, text-to-speech (TTS via Kokoro-82M ONNX), and speaker output with orb-state signaling for native shells.

**Intelligence pipeline:** after each conversation turn, a background extraction pass analyses the conversation for dates, people, interests, and commitments. Results are stored as enriched memory records and can trigger scheduler tasks, relationship updates, and briefing items.

## LLM Backends

Fae always runs through the internal agent loop (tool calling + sandboxing). The backend setting chooses the LLM brain:

| Backend | Config | Inference | Notes |
|---|---|---|---|
| Local | `backend = "local"` | On-device (mistralrs, Metal on Mac) | Private, no network needed |
| API | `backend = "api"` | Remote (OpenAI, Anthropic, Ollama, etc.) | More capable models |
| Agent | `backend = "agent"` | Auto (local when no creds, API otherwise) | Backward compatibility |

Local fallback: when `enable_local_fallback = true`, Fae falls back to the local model if the remote API is unreachable.

## Security

- All tool execution is sandboxed within workspace boundaries.
- Path traversal blocking prevents access outside approved directories.
- Approval gates on high-risk operations (shell commands, file writes) unless in `full_no_approval` mode.
- Secrets, passwords, and wallet material are never sent to remote models — always handled by the local brain.
- Skills are reviewed and approved by the user before installation.
- Security-scoped bookmarks (macOS) for persistent file access under App Sandbox.

## Menu Options

| Menu | Purpose | What to Do |
|---|---|---|
| `Fae -> Settings...` | Runtime controls | Set tool mode, channels, updates, and listening behavior |
| `Fae -> Soul...` | Personality and behaviour | Edit SOUL.md to tune Fae's personality |
| `Fae -> Skills...` | Capability expansion | Review, edit, and install skill guides |
| `Fae -> Memories...` | Memory transparency | View, edit, and manage durable records |
| `Fae -> Scheduled Tasks...` | Task management | View configured tasks, schedules, and run history |
| `Fae -> Channels...` | External communication | Configure Discord, WhatsApp, webhooks |
| `Fae -> Ingestion...` | File ingestion | Import local files into memory |
| `Fae -> Fae Guide` | Usage help | Prompt style, tool safety, update flow |
| `Fae -> Check for Updates...` | Stay current | Manual update check |

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

[memory]
enabled = true
auto_capture = true
auto_recall = true
recall_max_items = 6
recall_max_chars = 1200
retention_days = 365

[intelligence]
enabled = false          # Enable proactive intelligence
proactivity_level = "gentle"  # off, digest_only, gentle, active
quiet_hours_start = 23   # No proactive delivery 23:00-07:00
quiet_hours_end = 7
annoyance_budget_daily = 5
briefing_hour = 8
briefing_min = 0

[conversation]
companion_presence = true  # Always-listening mode
```

Context window defaults scale with system RAM: 8K tokens (< 12 GiB), 16K (< 20 GiB), 32K (< 40 GiB), 64K (>= 40 GiB).

## Prompt Stack and SOUL

Runtime system prompt assembly:

1. Core system prompt (`Prompts/system_prompt.md`)
2. SOUL behavioral contract (`SOUL.md`)
3. Memory context (from `~/.fae/memory/`)
4. Proactive intelligence context (when available)
5. Built-in + user skills
6. Onboarding context (until onboarding is complete)
7. User message

[`SOUL.md`](SOUL.md) defines Fae's identity, memory principles, tool use rules, presence behaviour, and proactive intelligence guidelines.

## Documentation

- [Memory Guide](docs/Memory.md)
- [Memory Architecture Plan](docs/memory-architecture-plan.md)
- [Personalization and Proactive Plan](docs/personalization-interviews-and-proactive-plan.md)
- [Channel Setup Guide](docs/channels-setup.md)
- [Native macOS Swift App Shell](native/macos/FaeNativeApp/README.md)
- [Apple Companion Receiver Templates](native/apple/FaeCompanion/README.md)
- [Native App Architecture v0](docs/architecture/native-app-v0.md)
- [Native App Latency Validation Plan](docs/architecture/native-app-latency-plan.md)

## Developer Commands

```bash
just run           # Run GUI app
just build         # Build (CLI-only)
just build-gui     # Build GUI binary
just test          # Run tests (2076 tests)
just lint          # Run clippy (zero warnings)
just fmt           # Format code
just check         # Full CI validation
```

## License

AGPL-3.0
