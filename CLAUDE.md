# CLAUDE.md — Fae Implementation Guide

> **Current workflow:** Pure Swift macOS app from `native/macos/Fae` using `swift build` and `swift test`.
> No Rust core, no libfae.a, no C ABI — everything runs natively in Swift with MLX.

Project-specific implementation notes for AI coding agents.

## Core objective

Fae should be:

- **correct over fast** — Fae is not a real-time conversational chatbot. She is a thoughtful voice-first assistant that takes time to think, search, and verify before responding. Speed will improve as models improve, but correctness and thoroughness always come first.
- reliable in conversation
- memory-strong over long horizons
- proactive where useful
- quiet by default (no noise/clutter)

## Interaction model

Fae is **not** a real-time voice chat app. The current interaction pattern is:

1. User speaks (or types)
2. Fae acknowledges via **visual feedback** (orb breathing/glowing) and **audio feedback** (thinking tone)
3. Fae thinks — this may take seconds to tens of seconds depending on complexity (memory recall, web search, tool use)
4. Fae responds with a considered, correct answer via TTS

The orb and thinking tone are the primary UX bridge — they tell the user "Fae heard you and is working on it" during the thinking phase. This is essential because local LLM inference + multi-tool pipelines have inherent latency that cloud-based assistants hide with server farms.

As on-device models get faster and more capable, the latency gap will close naturally. The architecture is designed so that faster models = faster responses with zero code changes. But the design philosophy is always: **think carefully, then speak** — never rush to give a poor answer.

## Architecture overview

Fae is a **pure Swift app** powered by [MLX](https://github.com/ml-explore/mlx-swift) for on-device ML inference. All intelligence runs natively on Apple Silicon — no cloud, no API keys, no data leaves the Mac.

```
┌──────────────────────────────────────────────────────────────┐
│                       Fae.app (Swift)                        │
│                                                              │
│  Mic (16kHz) → VAD → Speaker ID → STT → LLM → TTS → Speaker│
│                         │              │                     │
│                         │              ├── Memory (SQLite)    │
│                         │              ├── Tools (18 built-in)│
│                         │              ├── Scheduler          │
│                         │              └── Self-Config        │
│                         │                                    │
│                         └── Voice Identity (Core ML)         │
│                                                              │
│  ML Engines (all MLX/CoreML, on-device):                     │
│  ┌───────────┐ ┌────────────┐ ┌───────────┐ ┌────────────┐  │
│  │ STT       │ │ LLM        │ │ TTS       │ │ Speaker    │  │
│  │ Qwen3-ASR │ │ Qwen3-8B   │ │ Qwen3-TTS │ │ ECAPA-TDNN │  │
│  │ 1.7B 4bit │ │ MLX 4bit   │ │ 1.7B bf16 │ │ Core ML    │  │
│  └───────────┘ └────────────┘ └───────────┘ └────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

### Model stack

| Engine | Model | Framework | Precision | Purpose |
|--------|-------|-----------|-----------|---------|
| STT | Qwen3-ASR-1.7B | MLX | 4-bit | Speech-to-text |
| LLM | Qwen3-8B | MLX | 4-bit | Conversation, reasoning, tool use |
| TTS | Qwen3-TTS-1.7B | MLX | bf16 | Text-to-speech with voice cloning |
| Embedding | Hash-384 | MLX | - | Semantic memory search |
| Speaker | ECAPA-TDNN | Core ML | fp16 | Voice identity (1024-dim x-vectors) |

Auto mode selects the LLM based on system RAM:
- 96+ GiB → Qwen3.5-35B-A3B (65K context)
- 80-95 GiB → Qwen3.5-35B-A3B (49K context)
- 64-79 GiB → Qwen3.5-35B-A3B (32K context)
- 48-63 GiB → Qwen3-8B (32K context)
- 32-47 GiB → Qwen3-4B (16K context)
- 16-31 GiB → Qwen3-1.7B (8K context)
- <16 GiB → Qwen3-1.7B (4K context)

Context window is now properly wired from model selection through to the pipeline.
`FaeConfig.recommendedMaxHistory()` scales conversation history with context size
(formula: `(contextSize - 5000 - maxTokens) / 400`, clamped to [6, 50]).
`ConversationStateTracker` also performs token-aware truncation (chars / 3.5 estimate)
to prevent overflow when individual messages are very long.

### Unified pipeline

Single pipeline where the LLM decides tool use via `<tool_call>` markup inline — no separate intent classifier or agent loop:

1. **Audio capture** (16kHz mono)
2. **VAD** — voice activity detection, barge-in support
3. **Speaker ID** — ECAPA-TDNN embedding, owner verification
4. **Echo suppression** — time-based + text-overlap + voice identity filtering
5. **STT** — Qwen3-ASR transcription
6. **LLM** — Qwen3 with inline tool calling (max 5 tool turns per query)
7. **TTS** — Qwen3-TTS with voice cloning, sentence-level streaming
8. **Playback** — with barge-in interruption support

**Latency note:** This is not a low-latency conversational pipeline. Steps 5-7 each involve ML inference on local hardware. The LLM may chain multiple tool calls (web search, memory, file ops) before responding. Total end-to-end time ranges from ~3s (simple greetings) to ~30s (complex multi-tool queries). The orb visual state and thinking tone provide continuous user feedback throughout.

## Memory-first architecture

Storage: SQLite with GRDB (`~/Library/Application Support/fae/fae.db`)

Key behavior:

- automatic recall before LLM generation (hybrid: 60% ANN neural + 40% FTS5 lexical)
- automatic capture after each completed turn
- explicit edit operations with audit history
- daily automated backups with rotation

Behavioral truth sources:

- `SOUL.md`
- `~/Library/Application Support/fae/fae.db` (SQLite)
- `docs/guides/Memory.md`

### Memory capture (MemoryOrchestrator)

After each turn, the orchestrator extracts and persists:

| Step | Pattern | MemoryKind | Example |
|------|---------|------------|---------|
| 1 | Always | `.episode` | Full turn text |
| 2 | "forget ..." | (soft delete) | Forget matching records |
| 3 | "remember ..." | `.fact` | Explicit remember commands |
| 4 | "my name is ..." | `.profile` | Name with upsert (supersede old) |
| 5 | "I prefer/like/love ..." | `.profile` | Preference statements |
| 6 | "I'm interested in ..." | `.interest` | Interest statements |
| 7 | "I need to ... by ..." | `.commitment` | Deadlines and promises |
| 8 | "my birthday is ..." | `.event` | Dates and events |
| 9 | "my sister ..." | `.person` | Relationship mentions |

Implementation files:

| File | Role |
|------|------|
| `Memory/MemoryOrchestrator.swift` | Recall (ANN+FTS5 hybrid), capture, GC, graph context |
| `Memory/SQLiteMemoryStore.swift` | GRDB-backed SQLite store, search, CRUD, retention |
| `Memory/MemoryTypes.swift` | MemoryRecord, MemoryKind, MemoryStatus, constants |
| `Memory/MemoryBackup.swift` | Backup and rotation |
| `Memory/VectorStore.swift` | sqlite-vec ANN tables (`memory_vec`, `fact_vec`) |
| `Memory/EntityStore.swift` | Entity graph: persons, orgs, locations, typed relationships |
| `Memory/EntityLinker.swift` | Extract entities and edges from person records |
| `Memory/EntityBackfillRunner.swift` | One-time backfill of legacy person records → entity graph |
| `Memory/EmbeddingBackfillRunner.swift` | Background backfill of all records/facts into ANN index |
| `Memory/PersonQueryDetector.swift` | Detect person/org/location queries ("who works at X?") |
| `Memory/EntityContextFormatter.swift` | Format entity profiles with relationship edges |
| `ML/NeuralEmbeddingEngine.swift` | Tiered Qwen3-Embedding (8B/4B/0.6B by RAM; hash fallback) |

## Scheduler

Tick interval: 60s. All 12 built-in tasks:

| Task | Schedule | Purpose |
|------|----------|---------|
| `check_fae_update` | every 6h | Check for Fae updates (via Sparkle) |
| `memory_migrate` | every 1h | Schema migration checks |
| `memory_reflect` | every 6h | Consolidate duplicate memories |
| `memory_reindex` | every 3h | Health check + integrity verification |
| `memory_gc` | daily 03:30 | Retention cleanup (episode expiry) |
| `memory_backup` | daily 02:00 | Atomic backup with rotation |
| `noise_budget_reset` | daily 00:00 | Reset proactive interjection counter |
| `stale_relationships` | every 7d | Detect relationships needing check-in |
| `morning_briefing` | daily 08:00 | Compile and speak morning briefing |
| `skill_proposals` | daily 11:00 | Detect skill opportunities from interests |
| `skill_health_check` | every 5min | Python skill health checks |
| `embedding_reindex` | weekly Sun 03:00 | Re-embed records missing ANN vectors after model change |

### Scheduler speak handler

The scheduler can make Fae speak via `speakHandler` closure, wired by `FaeCore` to `PipelineCoordinator.speakDirect()`. Used by morning briefing and stale relationship reminders.

Implementation: `Scheduler/FaeScheduler.swift`

## Tool system

Tools are registered dynamically in `ToolRegistry.buildDefault()`. Full inventory (19 tools):

| Category | Tools |
|----------|-------|
| Core | `read`, `write`, `edit`, `bash`, `self_config` |
| Web | `web_search` (DuckDuckGo HTML), `fetch_url` (with content extraction) |
| Skills | `run_skill` (run installed Python skills by name) |
| Apple | `calendar`, `reminders`, `contacts`, `mail`, `notes` |
| Scheduler | `scheduler_list`, `scheduler_create`, `scheduler_update`, `scheduler_delete`, `scheduler_trigger` |
| Roleplay | `roleplay` (multi-voice reading sessions) |

The LLM is told which skills are installed via `PersonalityManager.assemblePrompt(installedSkills:)`.
Skills are discovered at prompt assembly time from `SkillManager.installedSkillNames()`.
Skill proposals from the scheduler now store `.commitment` memory records so the LLM
can follow up naturally in the next conversation.

Tool modes (configurable via Settings > Tools) — **enforced by ToolRegistry + PipelineCoordinator**:

| Mode | Access |
|------|--------|
| `off` | Read-only tools (read, web_search, fetch_url, Apple reads, scheduler_list, roleplay) |
| `read_only` | Same as off (explicit read-only intent) |
| `read_write` | Read tools + write, edit, self_config, scheduler mutation |
| `full` | All tools including bash **(recommended default)** |
| `full_no_approval` | All tools, skip approval only if speaker is verified owner |

Even "off" mode keeps read tools available — Fae is local, she should always be able to read.
Tool mode is enforced at two levels: schema filtering (LLM never sees blocked tools) and
execution guard (rejected even if LLM hallucinates a tool call).

The LLM decides when to use tools via `<tool_call>` markup inline — no separate routing or intent classification.

### Apple tool permission request flow

When an Apple tool is invoked but the required macOS permission is missing, it triggers the
JIT permission flow automatically rather than returning a dead-end error:

1. Tool calls `requestPermission(capability:)` — a private async helper in `AppleTools.swift`
2. Posts `.faeCapabilityRequested` (same channel `JitPermissionController` already handles)
3. Native macOS permission dialog appears (or System Settings opens for mail/notes)
4. If granted → tool retries and returns result; if denied → friendly error

MailTool and NotesTool use a try→detect→request→retry pattern since their permissions are
only detectable from AppleScript error responses, not via a pre-flight API.

Settings > Tools shows an **"Apple Tool Permissions"** section with per-tool Granted/Not Granted
status badges and Grant buttons. See `docs/guides/scheduler-tooling-and-permissions.md`.

### Tool security (v0.8.1)

4-layer safety model for the tool system:

| Layer | Implementation | Purpose |
|-------|---------------|---------|
| **Tool mode filtering** | `ToolRegistry.toolSchemas(for:)` | LLM never sees tools outside current mode |
| **Execution guard** | `PipelineCoordinator.executeTool()` | Rejects tool calls even if LLM hallucinates them |
| **Path validation** | `PathPolicy.validateWritePath()` | Blocks writes to dotfiles, system paths, Fae config |
| **Rate limiting** | `ToolRateLimiter` | Per-tool sliding-window limits (bash: 5/min, write: 10/min) |

Additional hardening:

- **SelfConfigTool**: requires approval, jailbreak pattern detection, 2000-char limit
- **BashTool**: process group kill on timeout, stderr filtered from LLM, command classification (known-safe vs unknown warning)
- **EditTool**: first-occurrence-only replacement, occurrence count reporting
- **FetchURLTool**: blocks cloud metadata endpoints (169.254.169.254, metadata.google.internal)
- **WriteTool**: content null-byte sanitization via `InputSanitizer`
- **ApprovalManager**: 20s timeout (was 58s)

Implementation files:

| File | Role |
|------|------|
| `Tools/BuiltinTools.swift` | All core + web tool implementations |
| `Tools/AppleTools.swift` | Apple integration tools (calendar, contacts, etc.) |
| `Tools/SchedulerTools.swift` | Scheduler management tools |
| `Tools/Tool.swift` | Tool protocol definition |
| `Tools/RoleplayTool.swift` | Multi-voice roleplay session management |
| `Tools/ToolRegistry.swift` | Dynamic tool registration, schema generation, mode filtering |
| `Tools/PathPolicy.swift` | Write-path validation (blocklist for dotfiles, system paths) |
| `Tools/InputSanitizer.swift` | Shell metacharacter detection, bash command classification |
| `Tools/ToolRateLimiter.swift` | Per-tool sliding-window rate limiter |
| `Tools/ToolRiskPolicy.swift` | Risk-level → approval routing |

### Web search (DuckDuckGo)

`WebSearchTool` POSTs to `https://html.duckduckgo.com/html/` and parses result blocks from the HTML response. Extracts titles from `result__a` links, snippets from `result__snippet` divs, and unwraps DDG redirect URLs (`uddg` parameter). Returns up to 5 results by default.

`FetchURLTool` fetches any URL and extracts main content by stripping boilerplate HTML tags (script, style, nav, footer, header, aside), extracting from `<article>`, `<main>`, or `<body>` in priority order, and normalizing whitespace. Maximum 100K chars output.

## Roleplay reading (multi-voice TTS)

Fae can read plays, scripts, books, and news using distinct character voices.

### How it works

1. The `roleplay` tool manages session lifecycle (start, assign voices, stop)
2. During a roleplay session, the LLM outputs `<voice character="Name">dialog</voice>` tags inline
3. `VoiceTagStripper` (streaming parser) extracts character-annotated segments from the token stream
4. Each segment routes to TTS with the character's voice description (instruct mode) or Fae's cloned voice (narrator/ICL mode)

### Voice modes

| Mode | Trigger | TTS behavior |
|------|---------|-------------|
| ICL (default) | `voiceInstruct: nil` | Uses `refAudio` + `refText` — Fae's cloned voice |
| Instruct | `voiceInstruct: "description"` | Uses text description of voice characteristics |

### Implementation files

| File | Role |
|------|------|
| `Pipeline/VoiceTagParser.swift` | `VoiceSegment` + `VoiceTagStripper` — streaming `<voice>` tag parser |
| `Tools/RoleplayTool.swift` | `RoleplayTool` (Tool protocol) + `RoleplaySessionStore` (actor) |
| `ML/MLXTTSEngine.swift` | `synthesize(text:voiceInstruct:)` — dual-mode TTS |
| `Pipeline/PipelineCoordinator.swift` | Routes voice segments to TTS with per-character voices |
| `Core/PersonalityManager.swift` | `roleplayPrompt` — LLM instructions for voice tag usage |

## Voice identity (speaker verification)

ECAPA-TDNN speaker encoder (from Qwen3-TTS) runs via Core ML on the Neural Engine.
Produces 1024-dim x-vector embeddings from audio for speaker verification.

| File | Role |
|------|------|
| `Core/MLProtocols.swift` | `SpeakerEmbeddingEngine` protocol |
| `ML/CoreMLSpeakerEncoder.swift` | Core ML inference + mel spectrogram (Accelerate vDSP) |
| `ML/SpeakerProfileStore.swift` | Profile enrollment, matching, JSON persistence |
| `Core/FaeConfig.swift` | `SpeakerConfig` — thresholds, gating, progressive enrollment |
| `Resources/Models/SpeakerEncoder.mlmodelc/` | Compiled Core ML model (~18MB) |

Behavior:

- **First launch**: first speaker auto-enrolled as "owner" (no explicit enrollment step)
- **Progressive enrollment**: each recognized interaction adds to the profile centroid (up to 50 embeddings)
- **Owner gating**: when `requireOwnerForTools = true`, non-owner voices don't see tool schemas
- **Text injection**: always trusted (physical device access)
- **Degraded mode**: if model not found or load fails, pipeline continues without voice identity

Config: `[speaker]` section in `config.toml` — see `docs/guides/voice-identity.md`.

Model conversion: `python3 scripts/convert_speaker_model.py` (ONNX → Core ML, one-time).

## Self-modification

Fae can modify her own behavior and learn new skills. See `docs/guides/self-modification.md`.

### SelfConfigTool

The `self_config` tool persists personality preferences to `~/Library/Application Support/fae/custom_instructions.txt`.

| Action | Description |
|--------|-------------|
| `get_instructions` | Read current custom instructions |
| `set_instructions` | Replace all instructions with new text |
| `append_instructions` | Add without removing existing |
| `clear_instructions` | Remove all, revert to defaults |

Implementation: `SelfConfigTool` in `Tools/BuiltinTools.swift`.

### Python skills

Fae can write, install, and run Python scripts using `uv run --script` with PEP 723 inline metadata. Skills are stored at `~/Library/Application Support/fae/skills/` and managed by `SkillManager`.

Implementation files:

| File | Role |
|------|------|
| `Skills/SkillManager.swift` | Skill lifecycle (create, run, list, delete) |
| `Core/PersonalityManager.swift` | Python/uv capability prompt + self-modification prompt |

## Proactive behavior

Fae doesn't just respond — she actively learns from conversations and acts on discoveries.

### Proactive intelligence prompt

`PersonalityManager.proactiveBehaviorPrompt` instructs the LLM to:

- Search for relevant news and updates about user interests
- Follow up on mentioned projects, deadlines, and interests
- Research topics overnight and share findings in morning conversations
- Track commitments and remind when deadlines approach
- Suggest new Python skills when patterns emerge
- Limit to 1-2 proactive items per conversation start (noise control)

### Morning briefing

`FaeScheduler.runMorningBriefing()` runs daily at 08:00:

1. Queries memory for recent commitments, events, and people
2. Compiles a brief summary (1-3 sentences)
3. Speaks via `speakHandler` → `PipelineCoordinator.speakDirect()`

### Noise budget

`proactiveInterjectionCount` tracks daily proactive messages. Reset at midnight by `noise_budget_reset` scheduler task.

## Prompt/identity stack

`PersonalityManager.assemblePrompt()` builds the system prompt:

1. Core system prompt (identity, style, warmth, companion presence)
2. SOUL contract (`SOUL.md`)
3. User name context (when known from memory)
4. Custom instructions (from `custom_instructions.txt`)
5. Memory context (injected by MemoryOrchestrator.recall)
6. Tool schemas (when tools available — LLM sees full tool definitions inline)
7. Python/uv capability prompt (when tools available)
8. Self-modification prompt (when tools available)
9. Proactive behavior prompt (when tools available)

Implementation: `Core/PersonalityManager.swift`

Human contract document: `SOUL.md`

## Quiet operation policy

Fae should work continuously without becoming noisy.

- Keep maintenance chatter off the main conversational surface.
- Escalate only failures or high-value actionable items.
- Prefer digests over repeated single-event interruptions.
- Morning briefing: max 1-3 sentences, only when meaningful content exists.
- Proactive interjections: max 1-2 per conversation start.

## User feedback during thinking

Since Fae is not a low-latency chatbot, continuous feedback during the thinking phase is critical:

- **Orb visual state**: transitions to `thinking` mode immediately on speech detection — the orb breathes and glows to show Fae is working.
- **Thinking tone**: a warm ascending two-note tone (A3→C4, 300ms) plays when Fae begins thinking — audio confirmation that she heard you.
- **Tool use indicator**: the orb shifts to `focus` state when tools are executing, so the user can distinguish thinking from active tool work.
- **Sentence-level TTS streaming**: Fae begins speaking as soon as the first sentence is ready, rather than waiting for the full response.

These feedback mechanisms are not cosmetic — they are the primary UX that makes Fae usable despite the inherent latency of on-device ML inference.

## Configuration

Config file: `~/Library/Application Support/fae/config.toml`

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

Data paths:
- Config: `~/Library/Application Support/fae/config.toml`
- Memory: `~/Library/Application Support/fae/fae.db`
- Custom instructions: `~/Library/Application Support/fae/custom_instructions.txt`
- Skills: `~/Library/Application Support/fae/skills/`
- Speaker profiles: `~/Library/Application Support/fae/speakers.json`
- Cache: `~/Library/Caches/fae/`

## Swift file inventory

All paths under `native/macos/Fae/Sources/Fae/`.

### Core

| File | Role |
|------|------|
| `FaeApp.swift` | App entry, FaeAppDelegate owns all state, creates window via AppKit |
| `ContentView.swift` | Main view, orb, progress overlay, subtitle overlay |
| `BackendEventRouter.swift` | Routes FaeEventBus events to NotificationCenter |
| `Core/FaeCore.swift` | Lightweight facade: config, ModelManager, PipelineCoordinator, Scheduler |
| `Core/FaeConfig.swift` | Model selection, TTS config, tool mode, speaker config |
| `Core/FaeEventBus.swift` | Combine-based event bus |
| `Core/FaeEvent.swift` | Event types |
| `Core/FaeTypes.swift` | Shared type definitions |
| `Core/PersonalityManager.swift` | System prompt assembly with tool schemas, self-mod, proactive |
| `Core/MLProtocols.swift` | ML engine protocols (STT, LLM, TTS, Embedding, Speaker) |
| `Core/VoiceCommandParser.swift` | Voice command detection (show/hide conversation, etc.) |
| `Core/SentimentClassifier.swift` | Sentiment analysis for orb mood |
| `Core/CredentialManager.swift` | Keychain credential management |
| `Core/DiagnosticsManager.swift` | Diagnostics and debug info |
| `Core/PermissionStatusProvider.swift` | macOS permission status checks |
| `Core/IntroCrawl.swift` | Intro text crawl animation |

### ML Engines

| File | Role |
|------|------|
| `ML/ModelManager.swift` | Loads STT, LLM, TTS, Speaker engines; tracks degraded mode |
| `ML/MLXSTTEngine.swift` | Qwen3-ASR speech-to-text via mlx-swift |
| `ML/MLXLLMEngine.swift` | Qwen3 LLM inference via mlx-swift |
| `ML/MLXTTSEngine.swift` | Qwen3-TTS text-to-speech via mlx-audio-swift |
| `ML/MLXEmbeddingEngine.swift` | Hash-384 embedding engine for semantic search |
| `ML/CoreMLSpeakerEncoder.swift` | ECAPA-TDNN Core ML speaker embedding |
| `ML/SpeakerProfileStore.swift` | Speaker profile enrollment, matching, persistence |

### Pipeline

| File | Role |
|------|------|
| `Pipeline/PipelineCoordinator.swift` | Unified pipeline: STT → LLM (with tools) → TTS |
| `Pipeline/EchoSuppressor.swift` | Time-based + text-overlap + voice identity echo filtering |
| `Pipeline/VoiceActivityDetector.swift` | Voice activity detection |
| `Pipeline/VoiceTagParser.swift` | `VoiceSegment` + `VoiceTagStripper` for multi-voice roleplay |
| `Pipeline/ConversationState.swift` | Conversation history management |
| `Pipeline/TextProcessing.swift` | Text cleanup and processing utilities |

### Memory

| File | Role |
|------|------|
| `Memory/MemoryOrchestrator.swift` | Recall (ANN+FTS5 hybrid), capture, GC, graph context |
| `Memory/SQLiteMemoryStore.swift` | GRDB-backed SQLite: insert, search, supersede, retain |
| `Memory/MemoryTypes.swift` | MemoryRecord, MemoryKind, MemoryStatus, constants |
| `Memory/MemoryBackup.swift` | Database backup and rotation |
| `Memory/VectorStore.swift` | sqlite-vec ANN tables (`memory_vec`, `fact_vec`) |
| `Memory/EntityStore.swift` | Entity graph: persons, orgs, locations, typed relationships |
| `Memory/EntityLinker.swift` | Extract and persist entities/edges from person records |
| `Memory/EntityBackfillRunner.swift` | One-time backfill: legacy person records → entity graph |
| `Memory/EmbeddingBackfillRunner.swift` | Background paged backfill of all records/facts into ANN |
| `Memory/PersonQueryDetector.swift` | Detect person/org/location queries ("who works at X?") |
| `Memory/EntityContextFormatter.swift` | Format entity profiles including relationship edges |

### Tools

| File | Role |
|------|------|
| `Tools/BuiltinTools.swift` | Core tools (read, write, edit, bash, self_config, web_search, fetch_url) |
| `Tools/AppleTools.swift` | Apple integration tools (calendar, contacts, mail, reminders, notes) |
| `Tools/SchedulerTools.swift` | Scheduler management tools |
| `Tools/Tool.swift` | Tool protocol definition |
| `Tools/ToolRegistry.swift` | Dynamic registration, schema generation, mode filtering |
| `Tools/PathPolicy.swift` | Write-path validation (dotfile/system path blocklist) |
| `Tools/InputSanitizer.swift` | Shell metacharacter detection, bash command classification |
| `Tools/ToolRateLimiter.swift` | Per-tool sliding-window rate limiter |
| `Tools/ToolRiskPolicy.swift` | Risk-level → approval routing |

### Audio

| File | Role |
|------|------|
| `Audio/AudioCaptureManager.swift` | Microphone capture (16kHz mono) |
| `Audio/AudioPlaybackManager.swift` | Audio playback with barge-in support |
| `Audio/AudioToneGenerator.swift` | Thinking tone (A3→C4, 300ms) |

### Scheduler & Skills

| File | Role |
|------|------|
| `Scheduler/FaeScheduler.swift` | Background task scheduler with speak handler |
| `Skills/SkillManager.swift` | Python skill lifecycle (create, run, list, delete) |

### Orb & Window

| File | Role |
|------|------|
| `NativeOrbView.swift` | Metal-rendered orb |
| `OrbAnimationState.swift` | Orb animation state machine |
| `OrbTypes.swift` | OrbMode, OrbFeeling, OrbPalette enums |
| `OrbStateBridgeController.swift` | Maps events to orb visual state |
| `WindowStateController.swift` | Adaptive window (collapsed 120x120 / compact 340x500) |
| `NSWindowAccessor.swift` | NSWindow property access from SwiftUI |
| `VisualEffectBlur.swift` | NSVisualEffectView wrapper |

### Conversation & Canvas

| File | Role |
|------|------|
| `ConversationController.swift` | Conversation state (messages, listening) |
| `ConversationBridgeController.swift` | Routes events to conversation UI |
| `ConversationWindowView.swift` | Conversation NSPanel content view |
| `InputBarView.swift` | Text input bar |
| `SubtitleOverlayView.swift` | Floating subtitle overlay |
| `SubtitleStateController.swift` | Subtitle display state |
| `CanvasController.swift` | Canvas rendering controller |
| `CanvasWindowView.swift` | Canvas NSPanel content view |
| `LoadingCanvasContent.swift` | Canvas loading placeholder |

### Auxiliary Windows

| File | Role |
|------|------|
| `AuxiliaryWindowManager.swift` | Independent NSPanel windows (conversation, canvas) |
| `PipelineAuxBridgeController.swift` | Routes voice commands to auxiliary windows |
| `ProgressOverlayView.swift` | Model download/load progress overlay |
| `ApprovalOverlayController.swift` | Tool approval lifecycle |
| `ApprovalOverlayView.swift` | Floating approval card (Yes/No) |

### Settings

| File | Role |
|------|------|
| `SettingsView.swift` | TabView settings |
| `SettingsGeneralTab.swift` | General settings (listening, theme, updates) |
| `SettingsModelsTab.swift` | Model selection and download |
| `SettingsToolsTab.swift` | Tool mode picker |
| `SettingsSkillsTab.swift` | Skill management |
| `SettingsChannelsTab.swift` | Channel configuration |
| `SettingsSchedulesTab.swift` | Scheduler task configuration |
| `SettingsAboutTab.swift` | About, version info |
| `SettingsDeveloperTab.swift` | Developer diagnostics |

### System & Misc

| File | Role |
|------|------|
| `AudioDevices.swift` | Audio device enumeration |
| `DockIconAnimator.swift` | Dock icon animation |
| `SparkleUpdaterController.swift` | Sparkle auto-update |
| `JitPermissionController.swift` | Just-in-time permission requests |
| `HelpWindowController.swift` | Help HTML pages |
| `ProcessCommandSender.swift` | Process-level command dispatch |
| `ResourceBundle.swift` | Bundle resource helpers |
| `HostCommandBridge.swift` | NotificationCenter → command sender |
| `DeviceHandoff.swift` | Apple Handoff support |
| `HandoffKVStore.swift` | Handoff state store |
| `HandoffToolbarButton.swift` | Handoff toolbar button |
| `SkillImportView.swift` | Skill file import UI |
| `LicenseAcceptanceView.swift` | License acceptance screen |
| `FaeRelayServer.swift` | Local relay server |

### Adaptive window system

| Mode | Size | Style |
|------|------|-------|
| Collapsed | 120x120 | Borderless floating orb, always-on-top |
| Compact | 340x500 | Borderless window with conversation |

Conversation and canvas are independent `NSPanel` windows managed by `AuxiliaryWindowManager`, positioned adjacent to the orb.

## NotificationCenter names

| Name | Purpose |
|------|---------|
| `.faeBackendEvent` | Raw backend events |
| `.faeOrbStateChanged` | Orb visual state changes (mode, feeling, palette) |
| `.faePipelineState` | Pipeline lifecycle (stopped/starting/running/stopping/error) |
| `.faeRuntimeState` | Runtime lifecycle (starting/started/stopped/error) |
| `.faeRuntimeProgress` | Model download/load progress |
| `.faeAssistantGenerating` | LLM generation active/inactive |
| `.faeAudioLevel` | Audio level updates for orb visualization |

## Delivery quality requirements

Always run from `native/macos/Fae`:

```bash
swift build
swift test
```

Known blockers:
- Dependency fetch requires network access to GitHub.
- First app run blocks on initial model downloads (~8 GB for full stack).

## Testing Fae with Chatterbox TTS

Chatterbox is a local TTS server for voice-testing Fae's pipeline.

```bash
# Start Chatterbox:
cd /Users/davidirvine/Desktop/Devel/projects/chatterbox
./start_service.sh

# Speak to Fae (plays through speakers → mic → Fae pipeline):
curl -s -X POST http://127.0.0.1:8000/speak \
  -H "Content-Type: application/json" \
  -d '{"text": "Fae, what time is it?", "voice": "jarvis", "play": true}'
```

## LLM model evaluation

Benchmarks: `docs/benchmarks/llm-benchmarks.md`.

Auto mode selects based on system RAM:

| System RAM | Model | Notes |
|------------|-------|-------|
| 8-16 GB | Qwen3-0.6B | Only option that fits |
| 16-32 GB | Qwen3-1.7B | Best voice quality at ~85 T/s |
| 32-48 GB | Qwen3-4B | Good balance |
| 48+ GB | Qwen3-8B | Best quality |

Key metrics: T/s at voice context (needs >60), `/no_think` compliance, idle RAM, answer quality.

## Completed milestones

- **v0.6.2** — Production hardening: pipeline startup, runtime event routing, settings redesign
- **v0.7.0** — Dogfood readiness: backend cleanup, voice command routing, UX feedback, settings expansion
- **Milestone 7** — Memory Architecture v2: SQLite + semantic retrieval, hybrid scoring, backups
- **v0.8.0** — Pure Swift migration: MLX engines, unified pipeline, no Rust core
  - WebSearchTool: DuckDuckGo HTML search (ported from fae-search crate)
  - FetchURLTool: Content extraction with boilerplate stripping
  - Self-modification: SelfConfigTool + Python skills via uv
  - Voice identity: ECAPA-TDNN Core ML speaker encoder
  - Proactive behavior: morning briefing, scheduler speak handler, noise budget
  - Enhanced memory capture: interests, commitments, events, persons
- **v0.8.1** — Tool security hardening: 4-layer safety model
  - Tool mode enforcement: schema filtering + execution guard (off/read_only/read_write/full)
  - Write-path security: PathPolicy blocklist (dotfiles, system paths, Fae config)
  - Self-config safety: approval required, jailbreak pattern detection, length limits
  - Bash hardening: process group kill, stderr filtering, command classification
  - Rate limiting: per-tool sliding-window limits
  - Cloud metadata protection: blocks AWS/GCP/Azure metadata endpoints
  - Edit safety: first-occurrence-only replacement
  - Approval UX: 20s timeout (was 58s)
- **v0.9.0** — Memory v2: neural embeddings, ANN search, knowledge graph
  - NeuralEmbeddingEngine: tiered Qwen3-Embedding (64 GB→8B, 32 GB→4B, 16 GB→0.6B, <16 GB→hash)
  - VectorStore: sqlite-vec `vec0` ANN tables (`memory_vec`, `fact_vec`) inside `fae.db`
  - Hybrid recall: 60% ANN cosine + 40% FTS5 lexical (was 70/30 hash-only)
  - Schema v6: `entity_relationships`, temporal facts (`started_at`/`ended_at`), `entity_type` column
  - EntityStore: typed entity graph — persons, organisations, locations with bidirectional edges
  - EntityLinker: auto-extract `works_at`, `lives_in`, `knows`, `reports_to` edges
  - PersonQueryDetector: graph queries — "who works at X?", "who lives in X?"
  - EmbeddingBackfillRunner: background paged backfill of all records/facts into ANN index
  - EntityBackfillRunner: one-time migration of legacy person records → entity graph
  - Scheduler: `embedding_reindex` weekly task (Sunday 03:00)
