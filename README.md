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

Storage: `~/.fae/memory/fae.db` (SQLite, WAL mode, sqlite-vec for semantic search)

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
| `memory_backup` | Daily at 02:00 | Atomic database backup with rotation |
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

Fae is built as a Rust core library (`libfae`) with platform-specific native shells:

```
┌──────────────────────────────────────────────────────────────┐
│                     Platform Shells                          │
│                                                              │
│  macOS (arm64)          Linux / Windows                      │
│  ┌────────────────┐     ┌────────────────────┐               │
│  │ Swift native   │     │ fae-host binary     │               │
│  │ app (Fae.app)  │     │ (headless bridge)   │               │
│  │                │     │                     │               │
│  │ SwiftUI + orb  │     │ JSON stdin/stdout   │               │
│  │ animation,     │     │ IPC over Unix sock  │               │
│  │ conversation   │     │ or named pipe       │               │
│  │ WebView,       │     │                     │               │
│  │ settings UI    │     │ Connect any UI:     │               │
│  └───────┬────────┘     │ web, terminal, etc. │               │
│          │ C ABI        └──────────┬──────────┘               │
│          │ (in-process)            │ JSON protocol            │
│          ▼                         ▼                          │
│  ┌───────────────────────────────────────────────────────┐   │
│  │                   libfae (Rust core)                   │   │
│  │                                                       │   │
│  │  Mic -> AEC -> VAD -> STT -> LLM Agent -> TTS -> Spk │   │
│  │              │                    │                    │   │
│  │              │                    ├── Memory           │   │
│  │              │                    ├── Intelligence     │   │
│  │              │                    ├── Scheduler        │   │
│  │              │                    └── Tools/Skills     │   │
│  │              │                                        │   │
│  │              └── Vision (Qwen3-VL, camera input)      │   │
│  └───────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────┘
```

### macOS — Full Native App

On macOS, Fae ships as a native `.app` bundle. The Swift shell links `libfae.a` directly via C ABI — the Rust core runs in-process with zero IPC overhead. The app includes:

- Adaptive window (floating orb / compact conversation mode)
- WebView-based conversation + canvas panels
- Native settings, help, and menu system
- Code signing + notarization for Gatekeeper
- Self-update with staged downloads

### Linux and Windows — Headless Host Bridge

On Linux and Windows, Fae ships as `fae-host`, a headless binary that exposes the full Rust core via a JSON protocol over stdin/stdout (or Unix socket on Linux, named pipe on Windows). This is the same core — same voice pipeline, memory, intelligence, and tools — without a platform-specific GUI.

You can connect any frontend to `fae-host`: a terminal UI, a web interface, an Electron app, or anything that speaks JSON. The protocol is documented in `src/host/contract.rs`.

### Experimental: Dioxus Cross-Platform GUI

There is an archived Dioxus-based cross-platform GUI on the [`dioxus-archive`](https://github.com/saorsa-labs/fae/tree/dioxus-archive) branch. This provides a single Rust GUI that runs on macOS, Linux, and Windows. Development focus has moved to the native Swift shell for macOS, but the Dioxus branch is functional and available for anyone who wants to experiment with a cross-platform Rust GUI for Fae. Contributions welcome.

### Voice Pipeline

**Microphone** (16kHz) -> **AEC** (echo cancellation) -> **VAD** (voice activity detection) -> **STT** (Parakeet ONNX) -> **LLM** (agent loop with tool calling) -> **TTS** (Kokoro-82M ONNX) -> **Speaker**

### Intelligence Pipeline

After each conversation turn, a background extraction pass analyses the conversation for dates, people, interests, and commitments. Results are stored as enriched memory records and can trigger scheduler tasks, relationship updates, and briefing items.

## LLM Backends

Fae always runs through the internal agent loop (tool calling + sandboxing). The backend setting chooses the LLM brain:

| Backend | Config | Inference | Notes |
|---|---|---|---|
| Local | `backend = "local"` | On-device via mistralrs (Metal on Mac, CUDA on Linux) | Private, no network needed |

### Local Model Selection

Fae automatically selects the best local model based on your system RAM:

| System RAM | Model | Capabilities |
|---|---|---|
| 24 GiB+ | Qwen3-VL-8B-Instruct | Vision + text, stronger tool calling and coding |
| < 24 GiB | Qwen3-VL-4B-Instruct | Vision + text, lighter footprint |

Both models support vision (camera/image understanding) and are loaded via VisionModelBuilder with ISQ Q4K quantization. If a vision model fails to load, Fae falls back to Qwen3-4B text-only (GGUF).

Fae runs exclusively on local models — no API keys or remote servers required.

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
use_hybrid_search = true
semantic_weight = 0.60
integrity_check_on_startup = true
backup_keep_count = 7

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
5. Vision capabilities (when vision model is loaded)
6. Built-in + user skills
7. Onboarding context (until onboarding is complete)
8. User message

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
just run              # Run headless host bridge (IPC mode)
just run-native-swift # Run native macOS SwiftUI app
just build            # Build Rust core library + binaries
just build-staticlib  # Build libfae.a for Swift embedding
just test             # Run tests
just lint             # Run clippy (zero warnings)
just fmt              # Format code
just check            # Full CI validation
```

## Release Artifacts

Each [release](https://github.com/saorsa-labs/fae/releases) includes:

| Artifact | Platform | Contents |
|---|---|---|
| `fae-*-macos-arm64.tar.gz` | macOS (Apple Silicon) | Fae.app bundle (Swift shell + libfae, signed + notarized) |
| `fae-*-macos-arm64.dmg` | macOS (Apple Silicon) | Drag-to-install disk image |
| `fae-darwin-aarch64` | macOS (Apple Silicon) | Standalone binary for self-update |
| `fae-*-linux-x86_64.tar.gz` | Linux (x86_64) | `fae-host` headless binary |
| `fae-linux-x86_64` | Linux (x86_64) | Standalone binary for self-update |
| `fae-*-windows-x86_64.zip` | Windows (x86_64) | `fae-host.exe` headless binary |
| `fae-windows-x86_64.exe` | Windows (x86_64) | Standalone binary for self-update |
| `SHA256SUMS.txt` | All | GPG-signed checksums |

## License

AGPL-3.0
