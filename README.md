# Fae

> ## :warning: UNDER HEAVY DEVELOPMENT — DO NOT USE AS THIS COULD BE DANGEROUS SOFTWARE :warning:
>
> This project is in active early development. APIs, functionality, and behavior may change without notice. **Do not use in production or any environment where safety is a concern.** Use at your own risk.

![Fae](assets/fae.jpg)

Fae is a personal AI companion who listens, remembers, and helps — like having a knowledgeable friend who is always in the room. She runs entirely on your Mac, keeping your data private and secure.

**The vision is simple:** imagine a computer that your grandmother could use. Fae handles the complexity — setting up software, managing files, scheduling reminders, researching topics, and keeping track of the people and events that matter to you. You just talk to her.

**Website:** [the-fae.com](https://the-fae.com)

## Platform

Fae is a **pure Apple-native app**. The macOS app is built with SwiftUI and ships as a signed, notarized `.app` bundle.

| Platform | Status | Role |
|---|---|---|
| **macOS** (Apple Silicon) | Primary | Full app — on-device LLM inference, voice pipeline, memory, tools |
| **iOS / iPadOS** | Planned | Lightweight companion via Handoff — organisational tasks, reminders, briefings |

The heavy lifting (LLM inference, voice pipeline, memory) stays on your Mac. iOS/iPadOS devices receive Handoff for lighter organisational work — think of your iPhone as a remote for your Mac's brain.

**No web version. No Windows. No Linux builds.**

> **Cross-platform note:** An archived [Dioxus-based cross-platform GUI](https://github.com/saorsa-labs/fae/tree/dioxus-archive) branch exists for anyone wanting to experiment with a Rust GUI on macOS, Linux, and Windows. The headless `fae-host` bridge binary (see Architecture below) also makes it possible to connect any frontend on any platform. Contributions welcome.

## What Fae Does

### Always Listening, Never Intrusive

Fae is an always-present companion, not a summoned assistant. She listens continuously and decides when to speak:

- **Direct conversation** — talk to Fae naturally and she responds with warmth and clarity.
- **Overheard conversations** — if people nearby are discussing something Fae can help with, she may politely offer useful information.
- **Background noise** — Fae stays quiet when the TV is on, music is playing, or conversations don't involve her.
- **Listening control** — Fae stays in always-listening mode unless you press `Stop Listening`; press `Start Listening` to resume.

Fae uses echo cancellation and voice activity detection to separate your speech from ambient noise and her own voice. She never interrupts without good reason.

### Natural Conversation Flow

Fae is a voice assistant, not a real-time duplex system. When you speak, Fae listens, thinks, and then responds — just like a real conversation. A brief thinking pause (typically 1-3 seconds) is normal and by design. The orb breathes and glows while Fae is thinking, so you always know she heard you.

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

Fae can manage applications on your Mac through desktop automation tools:

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

Fae follows a **Ghostty-style architecture**: a large, cross-platform Rust core (`libfae`) with thin, platform-native GUI shells. The Rust core contains all the intelligence — voice pipeline, LLM inference, memory, scheduler, tools, and skills. The native shell is a lightweight SwiftUI wrapper that provides the UI and platform integration.

```
┌──────────────────────────────────────────────────────────────┐
│                     Platform Shells                          │
│                                                              │
│  macOS (Apple Silicon)     Headless (any platform)           │
│  ┌────────────────┐        ┌────────────────────┐            │
│  │ SwiftUI native │        │ fae-host binary     │            │
│  │ app (Fae.app)  │        │ (headless bridge)   │            │
│  │                │        │                     │            │
│  │ Orb animation, │        │ JSON stdin/stdout   │            │
│  │ conversation   │        │ IPC over Unix sock  │            │
│  │ WebView,       │        │                     │            │
│  │ settings UI,   │        │ Connect any UI:     │            │
│  │ Handoff        │        │ terminal, web, etc. │            │
│  └───────┬────────┘        └──────────┬──────────┘            │
│          │ C ABI                      │ JSON protocol         │
│          │ (in-process)               │                       │
│          ▼                            ▼                       │
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
- Apple Handoff support for iOS/iPadOS companion devices
- Code signing + notarization for Gatekeeper
- Self-update with staged downloads

### Headless Host Bridge

`fae-host` is a headless binary that exposes the full Rust core via a JSON protocol over stdin/stdout (or Unix socket). This is the same core — same voice pipeline, memory, intelligence, and tools — without a GUI.

You can connect any frontend to `fae-host`: a terminal UI, a web interface, an Electron app, or anything that speaks JSON. The protocol is documented in `src/host/contract.rs`.

### Cross-Platform GUI (Archived)

The [`dioxus-archive`](https://github.com/saorsa-labs/fae/tree/dioxus-archive) branch contains a Dioxus-based cross-platform GUI that runs on macOS, Linux, and Windows from a single Rust codebase. Development focus has moved to the native Swift shell, but the Dioxus branch is functional and available for experimentation. Contributions welcome.

### Voice Pipeline

**Microphone** (16kHz) -> **AEC** (echo cancellation) -> **VAD** (voice activity detection) -> **STT** (Parakeet ONNX) -> **LLM** (agent loop with tool calling) -> **TTS** (Kokoro-82M ONNX) -> **Speaker**

### Intelligence Pipeline

After each conversation turn, a background extraction pass analyses the conversation for dates, people, interests, and commitments. Results are stored as enriched memory records and can trigger scheduler tasks, relationship updates, and briefing items.

## LLM Backends

Fae always runs through the internal agent loop (tool calling + sandboxing). The backend setting chooses the LLM brain:

| Backend | Config | Inference | Notes |
|---|---|---|---|
| Local | `backend = "local"` | On-device via mistralrs (Metal on Apple Silicon) | Private, no network needed |

### Local Model Selection

Fae uses a dual-channel architecture with separate models for voice and background tasks:

| Channel | Model | Context Budget | Speed | Purpose |
|---|---|---|---|---|
| Voice | Qwen3-1.7B (Q4_K_M) | ~1.5K tokens | ~85 T/s | Fast conversational responses |
| Background | Qwen3-4B+ (Q4_K_M) | Full window | Async | Tool-heavy tasks (calendar, search, etc.) |

Auto mode selects based on system RAM, with a high-tier upgrade path available on capable machines. In the Swift rebuild path, `mlx-community/Qwen3.5-35B-A3B-4bit` is the top-tier game-changing option for high-memory systems, with smaller tiers retained for responsiveness and lower-memory hardware.

The voice channel stays fast by using a condensed ~2KB prompt with no tool schemas. When Fae detects a request that needs tools (calendar, reminders, web search), she gives an immediate spoken acknowledgment and dispatches the work to the background channel asynchronously. The dual-channel architecture lets Fae remain conversationally responsive while executing tool-heavy tasks in parallel.

See [LLM Benchmarks](docs/benchmarks/llm-benchmarks.md) for detailed speed and memory measurements.

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

Config file: `~/Library/Application Support/fae/config.toml` (macOS)

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

### Architecture Decision Records

- [ADR-001: Cascaded Voice Pipeline](docs/adr/001-cascaded-voice-pipeline.md)
- [ADR-002: Embedded Rust Core](docs/adr/002-embedded-rust-core.md)
- [ADR-003: Local-Only LLM Inference](docs/adr/003-local-llm-inference.md)
- [ADR-004: Fae Identity and Personality](docs/adr/004-fae-identity-and-personality.md)
- [ADR-005: Self-Modification Safety](docs/adr/005-self-modification-safety.md)

### Guides

- [Memory Guide](docs/guides/Memory.md)
- [Channel Setup Guide](docs/guides/channels-setup.md)
- [Model Switching](docs/guides/model-switching.md)
- [Linker Anchor](docs/guides/linker-anchor.md)

### Benchmarks

- [LLM Benchmarks — Local Inference on Apple Silicon](docs/benchmarks/llm-benchmarks.md)
- [Research — Tool Judgment & Voice Model Evaluation](docs/benchmarks/research.md)

### Other

- [Native macOS Swift App Shell](native/macos/Fae/README.md)
- [Apple Companion Receiver Templates](native/apple/FaeCompanion/README.md)

## Developer Commands

### Current default (Swift app)

```bash
cd native/macos/Fae
swift build
swift test
```

### Workspace recipes

```bash
just run-native-swift # Run native macOS SwiftUI app
just check            # Full validation across active components
```

### Legacy / archival (Rust core path)

```bash
just run              # Legacy headless host bridge (IPC mode)
just build            # Legacy Rust core library + binaries
just build-staticlib  # Legacy libfae.a staticlib build
just test             # Legacy Rust tests
just lint             # Legacy clippy
just fmt              # Legacy rustfmt
```

### Known blockers

- Swift build/test can fail when dependency fetch/submodule checkout cannot reach GitHub.
- First app run may block on initial model downloads.

## Release Artifacts

Each [release](https://github.com/saorsa-labs/fae/releases) includes:

| Artifact | Platform | Contents |
|---|---|---|
| `fae-*-macos-arm64.tar.gz` | macOS (Apple Silicon) | Fae.app bundle (Swift shell + libfae, signed + notarized) |
| `fae-*-macos-arm64.dmg` | macOS (Apple Silicon) | Drag-to-install disk image |
| `fae-darwin-aarch64` | macOS (Apple Silicon) | Standalone binary for self-update |
| `SHA256SUMS.txt` | All | GPG-signed checksums |

## License

AGPL-3.0
