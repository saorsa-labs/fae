# Fae

> ## :warning: UNDER HEAVY DEVELOPMENT — DO NOT USE AS THIS COULD BE DANGEROUS SOFTWARE :warning:
>
> This project is in active early development. APIs, functionality, and behavior may change without notice. **Do not use in production or any environment where safety is a concern.** Use at your own risk.

![Fae](assets/fae.jpg)

Fae is a personal AI companion who listens, remembers, and helps — like having a knowledgeable friend who is always in the room. She runs entirely on your Mac, keeping your data private and secure.

**The vision is simple:** imagine a computer that your grandmother could use. Fae handles the complexity — setting up software, managing files, scheduling reminders, researching topics, and keeping track of the people and events that matter to you. You just talk to her.

> **Note:** Fae is not a real-time chatbot. She is a thoughtful voice-first assistant that prioritises correctness and thorough tool use over speed. When you ask Fae something, she thinks carefully — searching her memory, consulting the web, reading files, running tools — and then responds with a considered answer. The orb breathes and glows while she works, and a gentle thinking tone plays so you always know she heard you and is on it. As local models improve, conversational latency will naturally decrease, but Fae will always favour getting things right over getting things fast.

**Website:** [the-fae.com](https://the-fae.com)

## Platform

Fae is a **pure Apple-native app** built with Swift and MLX. Every model runs on-device using Apple Silicon's Neural Engine and GPU — no cloud, no API keys, no data leaves your Mac.

| Platform | Status | Role |
|---|---|---|
| **macOS** (Apple Silicon) | Primary | Full app — on-device LLM, STT, TTS, voice identity, memory, tools |
| **iOS / iPadOS** | Planned | Lightweight companion via Handoff |

**No web version. No Windows. No Linux builds.**

## What Fae Does

### Always Listening, Never Intrusive

Fae is an always-present companion, not a summoned assistant. She listens continuously and decides when to speak:

- **Direct conversation** — talk to Fae naturally and she responds with warmth and clarity.
- **Overheard conversations** — if people nearby are discussing something Fae can help with, she may politely offer useful information.
- **Background noise** — Fae stays quiet when the TV is on, music is playing, or conversations don't involve her.
- **Listening control** — press Stop/Start Listening to toggle, or say "go to sleep Fae" / "hey Fae".

Fae uses echo cancellation, voice activity detection, and speaker identity to separate your speech from ambient noise and her own voice.

### Thoughtful, Not Instant

Fae is not designed for rapid-fire chat. When you speak, she listens, thinks, and then responds with care. Depending on the complexity of your request, this can take anywhere from a few seconds (simple questions) to tens of seconds (multi-tool tasks like searching the web, reading files, and cross-referencing memory).

**What you see and hear while Fae is working:**

- The **orb breathes and glows** — visual confirmation that Fae heard you and is thinking
- A gentle **thinking tone** plays — audio feedback so you know she's on it, even if you're not looking at the screen
- When tools are in use, the orb shifts to a **focused state** — so you can tell the difference between thinking and working

This is by design. Fae prioritises giving you a correct, well-researched answer over giving you a fast one. As on-device models improve, response times will decrease naturally — but Fae will always think before she speaks.

### Remembers Everything That Matters

Fae has a durable memory system that learns about you over time — your name, preferences, work context, relationships, interests, commitments, and routines. All stored locally.

- **Automatic recall** — before every response, Fae recalls relevant memories to personalise her help.
- **Automatic capture** — after every turn, Fae records useful facts, events, interests, commitments, and people.
- **Conflict resolution** — when information changes, Fae supersedes old facts with lineage tracking.
- **Explicit control** — ask Fae to remember or forget anything. All operations are auditable.
- **Background maintenance** — periodic consolidation, reindexing, backups, and cleanup.

Storage: `~/Library/Application Support/fae/fae.db` (SQLite, WAL mode, semantic reranking)

### Voice Identity

Fae recognises your voice and can distinguish you from others in the room using speaker embedding:

- **ECAPA-TDNN speaker encoder** — Core ML model running on the Neural Engine, produces 1024-dim x-vector embeddings.
- **First-launch enrollment** — the first voice Fae hears becomes the "owner" automatically.
- **Progressive enrollment** — each recognised interaction strengthens the voice profile.
- **Owner gating** — when enabled, non-owner voices don't see tool schemas, preventing strangers from running commands.
- **Self-echo rejection** — Fae's own voice is enrolled as `fae_self` and filtered from the pipeline.
- **Text injection** — always trusted (physical device access implies owner).

Configure via `[speaker]` in config.toml. See [Voice Identity Guide](docs/guides/voice-identity.md).

### Self-Modification

Fae can change her own personality and learn new skills:

- **Personality tuning** — say "be more cheerful", "less chatty", "speak formally" and Fae persists the preference via `self_config` tool.
- **Custom instructions** — stored at `~/Library/Application Support/fae/custom_instructions.txt`, loaded on every prompt.
- **Python skills** — Fae can write, install, and manage Python scripts using `uv run --script` with PEP 723 inline metadata.
- **Skill management** — read, edit, or delete her own skills at `~/Library/Application Support/fae/skills/`.

See [Self-Modification Guide](docs/guides/self-modification.md).

### Proactive Intelligence

Fae doesn't just respond — she learns forward from your conversations and acts on what she discovers:

- **Conversation mining** — extracts dates, birthdays, upcoming events, people mentioned, interests, and commitments.
- **Morning briefings** — say "good morning" and Fae delivers a warm summary of upcoming commitments, people to reconnect with, and research she's done.
- **Relationship tracking** — remembers who you mention, how you know them, and when you last talked about them.
- **Background research** — uses web search to find information on topics you care about.
- **Skill proposals** — when Fae notices patterns, she proposes new skills. Always asks before installing.
- **Noise control** — daily delivery budgets and quiet hours prevent Fae from ever becoming annoying.

### Desktop Automation

Fae can manage applications on your Mac through desktop automation tools:

- Open, close, and interact with desktop applications.
- Read and write files, configure software, and manage system settings.
- Execute shell commands with a safety-first approval model.

Tool modes control how much access Fae has:

| Mode | What Fae Can Do |
|---|---|
| `off` | Conversation only — no computer access |
| `read_only` | Read files and check system state |
| `read_write` | Read and write files |
| `full` | Full access including shell commands (with approval) |
| `full_no_approval` | Full access without approval prompts |

### Scheduler

Fae has a built-in task scheduler that runs in the background:

- **User tasks** — set reminders, recurring check-ins, and follow-ups through natural conversation.
- **System tasks** — automatic memory maintenance, update checks, intelligence extraction, and briefing preparation.
- **Speak handler** — scheduled tasks can make Fae speak (e.g. morning briefing delivery).

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
| `morning_briefing` | Daily at 08:00 | Compile and deliver morning briefing |
| `skill_proposals` | Daily at 11:00 | Detect skill opportunities from interests |
| `skill_health_check` | Every 5 minutes | Validate Python skill runtime health |

## Architecture

Fae is a **pure Swift app** powered by [MLX](https://github.com/ml-explore/mlx-swift) for on-device ML inference. No Rust core, no subprocess — all intelligence runs natively on Apple Silicon.

```
┌──────────────────────────────────────────────────────────────┐
│                       Fae.app (Swift)                         │
│                                                               │
│  Mic (16kHz) → VAD → Speaker ID → STT → LLM → TTS → Speaker │
│                         │              │                      │
│                         │              ├── Memory (SQLite)     │
│                         │              ├── Tools (18 built-in) │
│                         │              ├── Scheduler           │
│                         │              └── Self-Config         │
│                         │                                     │
│                         └── Voice Identity (Core ML)          │
│                                                               │
│  ML Engines (all MLX, on-device):                             │
│  ┌───────────┐ ┌────────────┐ ┌───────────┐ ┌─────────────┐  │
│  │ STT       │ │ LLM        │ │ TTS       │ │ Speaker     │  │
│  │ Qwen3-ASR │ │ Qwen3-8B   │ │ Qwen3-TTS │ │ ECAPA-TDNN  │  │
│  │ 1.7B 4bit │ │ MLX 4bit   │ │ 1.7B bf16 │ │ Core ML     │  │
│  └───────────┘ └────────────┘ └───────────┘ └─────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

### Model Stack

| Engine | Model | Framework | Precision | Purpose |
|---|---|---|---|---|
| STT | Qwen3-ASR-1.7B | MLX | 4-bit | Speech-to-text |
| LLM | Qwen3-8B | MLX | 4-bit | Conversation, reasoning, tool use |
| TTS | Qwen3-TTS-1.7B | MLX | bf16 | Text-to-speech with voice cloning |
| Embedding | Hash-384 | MLX | - | Semantic memory search |
| Speaker | ECAPA-TDNN | Core ML | fp16 | Voice identity (1024-dim x-vectors) |

Auto mode selects the LLM based on system RAM:
- 48+ GiB → Qwen3-8B
- 32-48 GiB → Qwen3-4B
- <32 GiB → Qwen3-1.7B

### Pipeline

The unified pipeline handles everything in a single pass — the LLM decides when to use tools via `<tool_call>` markup inline:

1. **Audio capture** (16kHz mono)
2. **VAD** — voice activity detection, barge-in support
3. **Speaker ID** — ECAPA-TDNN embedding, owner verification
4. **Echo suppression** — time-based + text-overlap + voice identity filtering
5. **STT** — Qwen3-ASR transcription
6. **LLM** — Qwen3 with inline tool calling (max 5 tool turns per query)
7. **TTS** — Qwen3-TTS with voice cloning, sentence-level streaming
8. **Playback** — with barge-in interruption support

**Latency profile:** End-to-end response time depends on request complexity. Simple greetings take a few seconds; tool-heavy tasks (web search + memory recall + file operations) can take 10-30 seconds. The orb and thinking tone provide continuous feedback throughout. Fae favours correctness over speed — she will search, verify, and cross-reference rather than guess.

### Tools (18 Built-in)

| Category | Tools |
|---|---|
| Core + Web | `read`, `write`, `edit`, `bash`, `self_config`, `web_search`, `fetch_url` |
| Apple | `calendar`, `reminders`, `contacts`, `mail`, `notes` |
| Scheduler | `scheduler_list`, `scheduler_create`, `scheduler_update`, `scheduler_delete`, `scheduler_trigger` |
| Roleplay | `roleplay` |

The LLM decides when to use tools — no separate routing or intent classification needed.

### Adaptive Window

| Mode | Size | Style |
|---|---|---|
| Collapsed | 120x120 | Borderless floating orb, always-on-top |
| Compact | 340x500 | Borderless window with conversation |

Conversation and canvas are independent `NSPanel` windows positioned adjacent to the orb.

## Privacy

**Everything runs on your Mac.** Zero data leaves the device:

- Audio is processed locally — no cloud transcription.
- LLM runs locally — no API calls, no tokens sent anywhere.
- Memories stored locally in SQLite — no sync, no backup to cloud.
- Voice biometrics stored locally — speaker profiles never leave the device.
- Web search uses DuckDuckGo HTML endpoint — the most privacy-friendly option.
- No telemetry, no analytics, no tracking.

## Security

- Tool execution sandboxed with approval gates on dangerous operations.
- Path traversal blocking prevents access outside approved directories.
- Voice identity gating prevents unauthorized tool use.
- Security-scoped bookmarks for persistent file access under App Sandbox.
- Skills reviewed and approved by user before installation.

## Configuration

Config file: `~/Library/Application Support/fae/config.toml` (macOS)

```toml
[llm]
maxTokens = 512
contextSizeTokens = 16384
temperature = 0.7
voiceModelPreset = "auto"

[memory]
enabled = true
maxRecallResults = 6

[speaker]
enabled = true
threshold = 0.70
ownerThreshold = 0.75
requireOwnerForTools = false
progressiveEnrollment = true
maxEnrollments = 50

[conversation]
requireDirectAddress = false
directAddressFollowupS = 20
```

## Documentation

### Architecture Decision Records

- [ADR-001: Cascaded Voice Pipeline](docs/adr/001-cascaded-voice-pipeline.md)
- [ADR-002: Embedded Rust Core](docs/adr/002-embedded-rust-core.md) (historical)
- [ADR-003: Local-Only LLM Inference](docs/adr/003-local-llm-inference.md)
- [ADR-004: Fae Identity and Personality](docs/adr/004-fae-identity-and-personality.md)
- [ADR-005: Self-Modification Safety](docs/adr/005-self-modification-safety.md)

### Guides

- [Memory Guide](docs/guides/Memory.md)
- [Voice Identity Guide](docs/guides/voice-identity.md)
- [Self-Modification Guide](docs/guides/self-modification.md)
- [Channel Setup Guide](docs/guides/channels-setup.md)

### Benchmarks

- [LLM Benchmarks — Local Inference on Apple Silicon](docs/benchmarks/llm-benchmarks.md)

## Developer Commands

### Building Fae

```bash
cd native/macos/Fae
swift build
swift test
```

### Workspace recipes

```bash
just run-native       # Build, sign, launch with log capture
just build-native     # Build the Swift app
just check            # Full validation
```

### Known blockers

- Swift build/test can fail when dependency fetch cannot reach GitHub.
- First app run blocks on initial model downloads (~8 GB for full stack).

## Release Artifacts

Each [release](https://github.com/saorsa-labs/fae/releases) includes:

| Artifact | Platform | Contents |
|---|---|---|
| `fae-*-macos-arm64.tar.gz` | macOS (Apple Silicon) | Fae.app bundle (signed + notarized) |
| `fae-*-macos-arm64.dmg` | macOS (Apple Silicon) | Drag-to-install disk image |
| `SHA256SUMS.txt` | All | GPG-signed checksums |

## License

AGPL-3.0
