# CLAUDE.md — Fae Implementation Guide

> **Current workflow:** Pure Swift macOS app from `native/macos/Fae` using `swift build` and `swift test`.
> No Rust core, no libfae.a, no C ABI — everything runs natively in Swift with MLX.

Project-specific implementation notes for AI coding agents.

## Core objective

Fae should be:

- **correct over fast** — Fae is not a real-time conversational chatbot. She is a thoughtful voice-first assistant that takes time to think, search, and verify before responding. Speed will improve as models improve, but correctness and thoroughness always come first.
- reliable in conversation
- memory-strong over long horizons
- **proactive from day 1** — all awareness, memory, learning, and intelligence features are always-on from first launch. No setup required beyond voice enrollment.
- the best, most proactive friend anyone can have

## Proactive-by-default philosophy

**Fae is proactive from the moment she's installed.** There are no feature toggles for core capabilities — voice identity is the security model, not settings switches.

### Voice identity security model

1. **Pre-enrollment (first launch)**: Fae listens to everyone, continually nudges to enroll as primary user. No tool calls except voice enrollment. Barge-in always on.
2. **Primary user enrolled**: Fae ONLY responds to recognized voices. Primary user has full tool access.
3. **Conversation mode**: While primary user is in an active conversation, Fae can hear and respond to others present (social context).
4. **Guest access**: Primary user can introduce people and optionally grant them tool access.

### Always-on features (cannot be toggled off)

| Feature | Purpose |
|---------|---------|
| Proactive awareness | Watches for presence, monitors screen, researches overnight, delivers briefings |
| Camera presence detection | Knows when you're at the desk — greetings, departure detection |
| Screen monitoring | Understands what you're working on — builds silent context, never interrupts |
| Overnight research | Researches topics you care about during quiet hours (22:00-06:00) |
| Enhanced morning briefing | Calendar, mail, research findings, and reminders when you arrive |
| Long-term memory | Remembers important things from every conversation |
| Automatic note import | Ingests notes into memory without being asked |
| Daily summaries | Creates daily digests of what happened |
| Personal learning | Continuously improves based on your interactions |
| Barge-in | User can always interrupt Fae mid-speech |
| Voice identity enforcement | After primary enrollment, only recognized voices get responses |

### Settings UI treatment

These features are shown in Settings as an **informational showcase** — not toggle panels:
- Each feature shows a clear explanation of WHAT it does and WHY it matters
- No on/off toggles — these features define what Fae IS
- Intensity/interval controls (e.g., camera check interval) remain adjustable
- The section educates users about Fae's capabilities and builds trust

## Justfile recipes (canonical commands)

All commands run from `native/macos/Fae/`. Use `just <recipe>` — never raw `swift`/`cargo` commands.

```bash
just --list              # Show all available recipes
just build               # Build Fae (debug)
just build-release       # Build Fae (release)
just test                # Run all tests
just test-target <t>     # Run specific test target
just check               # Full validation (build + test)
just clean               # Clean build artifacts
just run-native          # Build, sign, and run (requires: source ~/.secrets)
just bundle              # Build signed .app bundle (requires: source ~/.secrets)
just prod-check          # Production-focused validation for worker-backed runtime
just build-acpx          # Build acpx standalone binary (requires bun)
just build-benchmark     # Build benchmark tool (requires xcodebuild)
just benchmark <model>   # Run benchmark for a model
just benchmark-all       # Benchmark all models
just benchmark-tools <m> # Benchmark only tool calling
```

**Launch from project root**: `source ~/.secrets && just run-native` — NEVER open `.build/` artifacts directly.

## Release-validation contract

Canonical validation source: `docs/checklists/app-release-validation.md`.
Live test scenarios: `docs/checklists/main-and-cowork-live-test-scenarios.md`.

Required for: model swaps, prompt/routing changes, voice capture/STT/TTS/playback changes, approval/permission/popup changes, memory/scheduler/skills/settings changes, Cowork behavior changes.

## Architecture overview

Pure Swift app powered by [MLX](https://github.com/ml-explore/mlx-swift). All intelligence runs on Apple Silicon — no cloud, no API keys, no data leaves the Mac.

```
Mic (16kHz) → VAD → Speaker ID → STT → LLM → TTS → Speaker
                       │              │
                       │              ├── Memory (SQLite + ANN + FTS5)
                       │              ├── Tools (37 built-in)
                       │              ├── Skills (21 built-in)
                       │              ├── Scheduler (~23 tasks)
                       │              ├── Backup (Git Vault)
                       │              └── Self-Config
                       │
                       └── Voice Identity (Core ML ECAPA-TDNN)
```

### Model stack

| Engine | Model | Framework | Purpose |
|--------|-------|-----------|---------|
| STT | Qwen3-ASR-1.7B | MLX 4-bit | Speech-to-text |
| LLM | Qwen3.5 (2B / 4B / 35B-A3B) | MLX 4-bit | Conversation, tool use |
| TTS | Kokoro-82M (hexgrad) | KokoroSwift/MLX float32 | Text-to-speech (pre-computed voice embeddings, 24 kHz) |
| VLM | 35B-A3B (shared) or Qwen3-VL-4B | MLXVLM 4-bit | Vision — shared on 32+ GB; separate on 16 GB |
| Embedding | Hash-384 | MLX | Semantic memory search |
| Speaker | ECAPA-TDNN | Core ML fp16 | Voice identity (1024-dim x-vectors) |

**Auto model selection** (single LLM, via `voiceModelPreset: "auto"`):

| System RAM | Model | Context |
|------------|-------|---------|
| ≥64 GB | Qwen3.5-35B-A3B MoE (3B active) | 128K |
| ≥32 GB | Qwen3.5-35B-A3B MoE (3B active) | 32K |
| ≥16 GB | Qwen3.5-4B | 32K |
| <16 GB | saorsa-1.1-tiny (fine-tuned 2B) | 32K |

Presets: `qwen3_5_35b_a3b`, `qwen3_5_4b`, `saorsa_1_1_tiny`. Unknown presets → auto. Legacy presets silently resolve to auto.

Context scaling: `FaeConfig.recommendedMaxHistory()` = `(contextSize - 5000 - maxTokens) / 400`, clamped [6, 100]. `maxTokens` capped at `contextSize / 2`.

LLM engine lives in `Sources/FaeInference/MLXLLMEngine.swift` (separate target). Main app accesses via `typealias MLXLLMEngine = FaeInference.MLXLLMEngine` in `Core/FaeInferenceAliases.swift`.

### Unified pipeline

1. **Audio capture** (16kHz mono) → 2. **VAD** (SileroVAD + keyword spotter) → 3. **Speaker ID** (ECAPA-TDNN) → 4. **Echo suppression** → 5. **STT** (Qwen3-ASR) → 6. **LLM** (Qwen3.5, native tool calling, max 5 tool turns) → 7. **TTS** (Kokoro-82M, sentence-queued) → 8. **Playback** (with barge-in)

**Latency**: 3s (greetings) to 30s (multi-tool queries). Orb visual state + thinking tone provide feedback throughout.

**Two-lane tool execution**: The LLM can emit either `<tool_call>` blocks (single tool calls, max 5 per turn) or `<tool_program>` blocks (JavaScript programs executed via JSCRuntime, no call cap). Script blocks run through the same governance stack (ToolExecutor, TrustedActionBroker, DamageControlPolicy) with additional budget enforcement (ScriptBudget) and optional dry-run preview (DryRunPlan).

### Post-ASR vocabulary correction

Qwen3-ASR has no prompt conditioning or hot-word biasing, so all name corrections happen post-transcription via two layers:

1. **Static corrections** (`TextProcessing.nameCorrections`): hardcoded patterns for "Fae" name garbles (faith→Fae, phase→Fae, etc.). Applied first via `correctNameRecognition()`.

2. **Dynamic corrections** (`DynamicVocabularyCorrector`): phonetic variants generated from the user's known vocabulary. Rebuilt at pipeline start from:
   - Owner name (config + memory + speaker profile)
   - Entity graph (persons, orgs, locations from memory)
   - Enrolled speaker display names

   Generates vowel swaps (a↔e, i↔e), consonant confusion (th↔t, ph↔f, s↔z), and trailing letter variants for each known name. Applied after static corrections, before LLM sees the text.

Key files: `Pipeline/TextProcessing.swift` (static), `Pipeline/DynamicVocabularyCorrector.swift` (dynamic), `Memory/MemoryOrchestrator.swift:entityNamesForVocabulary()`.

**Future improvements** (documented, not yet implemented):
- Contextual biasing / hot words at decode time (requires STT model support)
- Apple SFSpeechRecognizer custom language model as secondary validation
- LoRA fine-tuning of STT model from conversation correction pairs

### Thinking mode

- **Qwen3.5**: suppress via `enable_thinking: false` in `UserInput.additionalContext`. NEVER use `/no_think` suffix.
- With thinking enabled: model emits `<think>...</think>` as literal text; `ThinkTagStripper` handles it.
- Config: `llm.thinking_enabled`. Key files: `FaeInference/MLXLLMEngine.swift`, `Pipeline/TextProcessing.swift`, `Pipeline/PipelineCoordinator.swift`.

## Memory

SQLite with GRDB (`~/Library/Application Support/fae/fae.db`). Hybrid recall: 60% ANN neural + 40% FTS5 lexical. Automatic capture after each turn. Entity graph for persons/orgs/locations.

Memory capture patterns: episode (always), forget, remember, profile (name/preferences), interest, commitment, event, person.

Truth sources: `SOUL.md`, `fae.db`, `docs/guides/Memory.md`.

## Scheduler

Tick interval: 60s. Tasks are spread across repeating timers and daily checks.

**Repeating tasks**: `memory_reflect` (6h), `memory_reindex` (3h), `memory_migrate` (1h), `memory_inbox_ingest` (5min), `memory_digest` (6h), `check_fae_update` (6h), `skill_health_check` (5min).

**Daily tasks** (via scheduler_tick): `memory_backup` (02:00), `vault_backup` (02:30), `memory_gc` (03:30), `noise_budget_reset` (00:00), `morning_briefing` (configurable, default 08:00, suppressed when enhanced briefing active), `skill_proposals` (11:00), `skill_distill` (13:00), `stale_relationships` (weekly Sun 10:00), `capability_discovery` (every 3 days, 14:00), `embedding_reindex` (weekly Sun 03:00).

**Awareness tasks** (only when `awareness.enabled = true` + consent): `camera_presence_check` (30s), `screen_activity_check` (19s).

**Proactive tasks** (via `proactiveQueryHandler`): `overnight_work` (22:00-06:00), `enhanced_morning_briefing` (deferred until user detected after 07:00), `training_data_export`, `training_cycle`.

## Tool system

37 tools registered in `ToolRegistry.buildDefault()`:

| Category | Tools |
|----------|-------|
| Core | `read`, `write`, `edit`, `bash`, `self_config`, `channel_setup`, `window_control`, `session_search`, `web_search`, `fetch_url` |
| Skills | `activate_skill`, `run_skill`, `manage_skill` |
| Delegation | `delegate_agent`, `agent_session` |
| User Input | `input_request` |
| Apple | `calendar`, `reminders`, `contacts`, `mail`, `notes` |
| Scheduler | `scheduler_list`, `scheduler_create`, `scheduler_update`, `scheduler_delete`, `scheduler_trigger` |
| Roleplay | `roleplay` |
| Vision | `screenshot`, `camera`, `read_screen` |
| Computer Use | `click`, `type_text`, `scroll`, `find_element` |
| Task Tracking | `till_done` |
| Voice Identity | `voice_identity` |

**Tool access model**: Voice identity is the primary gate. Primary user (owner) gets `full` tool access. Guests get no tool access unless explicitly granted by the primary user. Pre-enrollment: no tool calls except voice enrollment.

**Tool modes** (internal): `off`/`read_only` (read tools only), `read_write` (+ write/edit/self_config), `full` (all including bash), `full_no_approval` (all, skip approval for verified owner).

**Native MLX tool calling**: tool specs passed via `UserInput.tools` → Qwen3.5 chat template. No separate intent classifier.

### Tool security (8-layer model)

| Layer | Implementation | Purpose |
|-------|---------------|---------|
| Voice identity | `SpeakerProfileStore` | Primary user verification — only recognized voices get tool access |
| Damage control | `DamageControlPolicy` | Pre-broker: block/disaster/confirm for catastrophic ops |
| Tool mode filtering | `ToolRegistry` | LLM never sees blocked tools |
| Execution guard | `PipelineCoordinator` | Rejects hallucinated tool calls |
| Path validation | `PathPolicy` | Blocks writes to dotfiles, system paths |
| Rate limiting | `ToolRateLimiter` | Per-tool sliding-window limits |
| TrustedActionBroker | `TrustedActionBroker` | Default-deny policy chokepoint |
| Outbound guard | `OutboundExfiltrationGuard` | Novel recipient + sensitive payload detection |

**PolicyProfile modes**: balanced (default), moreAutonomous, moreCautious.

**Apple tool reads are INTENTIONALLY ungated** — only writes/mutations need approval. macOS permission is the only read gate.

### Skill manifest contract

All executable built-in skills MUST have: `schemaVersion: 1`, `capabilities: ["execute"]`, `allowedTools: ["run_skill"]`, SHA-256 checksums in `integrity.checksums`.

Recompute checksums after modifying skill scripts:
```bash
cd native/macos/Fae/Sources/Fae/Resources/Skills/<skill-name>
for f in SKILL.md scripts/*.py; do echo "\"$f\": \"$(shasum -a 256 "$f" | cut -d' ' -f1)\""; done
```

## Built-in skills (21)

| Skill | Type | Purpose |
|-------|------|---------|
| `voice-identity` | Instruction | Speaker enrollment, introduction flow, re-verification |
| `voice-tools` | Executable | Audio file processing (normalize, prepare, compare, quality) |
| `proactive-awareness` | Instruction | Camera observation: greetings, mood, presence |
| `screen-awareness` | Instruction | Silent screen context monitoring |
| `overnight-research` | Instruction | Quiet-hours web research |
| `morning-briefing-v2` | Instruction | Enhanced briefing: calendar, mail, research |
| `first-launch-onboarding` | Instruction | 8-step consent-first onboarding flow |
| `capability-discovery` | Instruction | Surface unconfigured capabilities |
| `self-update` | Instruction | Fae self-update guidance |
| `secure-input` | Instruction | Secure input handling |
| `window-control` | Instruction | Window management |
| `forge` | Executable | Tool creation: scaffold, compile, test, release Zig/Python tools |
| `toolbox` | Executable | Local tool registry: install, verify, search, uninstall |
| `mesh` | Executable | Peer discovery + tool sharing via Bonjour/mDNS |
| `acp-setup` | Executable | Install and manage acpx for ACP agent delegation |
| `training-orchestrator` | Executable | Personal LoRA fine-tuning pipeline |
| `training-data-bridge` | Executable | Extract SFT/DPO training data from memory |
| `huggingface-scout` | Executable | Search HuggingFace Hub for models/datasets |
| `channel-discord` | Executable | Discord channel integration |
| `channel-whatsapp` | Executable | WhatsApp channel integration |
| `channel-imessage` | Executable | iMessage channel integration |

Skills use **progressive disclosure**: names + descriptions in system prompt, full SKILL.md body loaded on `activate_skill`.

## Channels (Discord, WhatsApp, iMessage)

Remote senders are **non-owner guests** — no tool escalation, text-only responses.
Config: `[channels]` in config.toml. Credentials in macOS Keychain via `CredentialManager`.

## Proactive awareness

**Always-on from first launch.** Camera/screen awareness start automatically after primary user enrollment.
No consent gate — these features are core to what Fae is, not optional add-ons.
`injectProactiveQuery()` with immutable `ProactiveRequestContext`. Per-task tool allowlists in `TrustedActionBroker`.
`AwarenessThrottle`: battery, thermal, quiet hours (22:00-07:00) gating.

## Prompt/identity stack

`PersonalityManager.assemblePrompt()` builds the system prompt in this order:

1. Core system prompt (identity, style, warmth, companion presence)
2. SOUL contract — `SoulManager.loadSoul()` (user copy → bundled default)
3. User name context (from memory)
4. Directive (`directive.md` — critical overriding instructions)
5. Memory context (injected by MemoryOrchestrator.recall)
6. Tool schemas (native MLX tool specs when tools available)
7. Available skills — names + descriptions (from `SkillManager.promptMetadata()`)
8. Activated skill instructions — full SKILL.md body for active skills
9. Python/uv capability prompt (when tools available)
10. Self-modification prompt (when tools available)
11. Vision + computer use prompt (when vision enabled)
12. Proactive behavior prompt (when tools available)

In **rescue mode**: step 2 uses bundled default soul, step 4 uses empty string.

## Self-modification (SelfConfigTool)

Adjustable settings (bidirectional with Settings UI, via `FaeCore.patchConfig()`):

| Key | Type | Range | Notes |
|-----|------|-------|-------|
| `tts.speed` | Float | 0.8–1.4 | |
| `llm.temperature` | Float | 0.3–1.0 | |
| `llm.thinking_enabled` | Bool | — | |
| `conversation.direct_address_followup_s` | Int | 5–60 | |
| `awareness.camera_interval_seconds` | Int | 10–120 | Intensity control (always-on) |
| `awareness.screen_interval_seconds` | Int | 10–60 | Intensity control (always-on) |
| `awareness.pause_on_battery` | Bool | — | Power management only |
| `awareness.pause_on_thermal_pressure` | Bool | — | Thermal management only |

**Always-on (no toggle):** `barge_in`, `awareness.enabled`, `awareness.camera_enabled`, `awareness.screen_enabled`, `awareness.overnight_work`, `awareness.enhanced_briefing`, `memory.enabled`, `memory.generateDigests`, `vision.enabled`, `conversation.require_direct_address` (after primary enrollment).

Directives: `get_directive`, `set_directive`, `append_directive`, `clear_directive`. Path: `~/Library/Application Support/fae/directive.md`.

## Rescue mode

| Component | Normal | Rescue Mode |
|-----------|--------|-------------|
| Soul contract | User's `soul.md` | Bundled default |
| Directive | `directive.md` | Empty (bypassed, not deleted) |
| Tool mode | config value (default: "full") | `read_only` |
| Scheduler | All tasks active | Not started |
| Memory capture | Enabled | Disabled (recall still works) |
| Orb palette | Dynamic | Forced `.silverMist` |

Activation: Help > Rescue Mode (Cmd+Opt+R). Implementation: `Core/RescueMode.swift`, `FaeApp.swift`, `FaeCore.swift`.

## Git Vault

Rolling backup at `~/.fae-vault/` — survives app deletion. Uses `/usr/bin/git` via `Process()`.

**Contents**: `fae.db` (VACUUM INTO), `scheduler.db`, `config.toml`, `directive.md`, `SOUL.md`, `speakers.json`, `skills/` mirror.
**Triggers**: daily 02:30, config change, pre-shutdown.
**Security**: PathPolicy blocks `.fae-vault` in `blockedDotfiles`; POSIX 0o555 after commit; git reflog 90-day retention.
**Restore**: Rescue mode "Restore from Vault" shows commit history.

## Configuration

Production mode uses code defaults (no config.toml). UserDefaults via Settings UI for user-adjustable values.

**New defaults (proactive-by-default):**

```toml
[llm]
maxTokens = 4096
contextSizeTokens = 0    # auto-sized by RAM
temperature = 0.7
voiceModelPreset = "auto"

[memory]
enabled = true           # ALWAYS ON — not toggleable
maxRecallResults = 6
generateDigests = true   # ALWAYS ON — not toggleable

[speaker]
threshold = 0.70
ownerThreshold = 0.75
requireOwnerForTools = true   # enforce voice identity for tool access
progressiveEnrollment = true
maxEnrollments = 50

[bargeIn]
enabled = true           # ALWAYS ON — not toggleable
minRms = 0.05
confirmMs = 150

[conversation]
requireDirectAddress = true   # after primary enrollment, wake word required
directAddressFollowupS = 20

[vision]
enabled = true           # ALWAYS ON — not toggleable

[awareness]
enabled = true           # ALWAYS ON — not toggleable
cameraEnabled = true     # ALWAYS ON — not toggleable
screenEnabled = true     # ALWAYS ON — not toggleable
cameraIntervalSeconds = 60    # adjustable intensity
screenIntervalSeconds = 30    # adjustable intensity
overnightWorkEnabled = true   # ALWAYS ON — not toggleable
enhancedBriefingEnabled = true # ALWAYS ON — not toggleable
pauseOnBattery = true         # power management (adjustable)
pauseOnThermalPressure = true # thermal management (adjustable)
```

Data paths:
- Config: `~/Library/Application Support/fae/config.toml`
- Memory: `~/Library/Application Support/fae/fae.db`
- Soul: `~/Library/Application Support/fae/soul.md`
- Directive: `~/Library/Application Support/fae/directive.md`
- Skills: `~/Library/Application Support/fae/skills/`
- Speaker profiles: `~/Library/Application Support/fae/speakers.json`
- Cache: `~/Library/Caches/fae/`
- Git Vault: `~/.fae-vault/`
- Forge: `~/.fae-forge/`

## Source targets

```
Sources/
  Fae/                    # Main app target (all UI, pipeline, tools, etc.)
  FaeInference/           # LLM inference target (MLXLLMEngine, LLMShared)
  FaeBenchmark/           # Benchmark tool
  FaePerceptionBenchmark/ # Perception benchmark
  CSQLiteVecCore/         # sqlite-vec C bridge
```

## Swift file inventory

All paths under `native/macos/Fae/Sources/Fae/` unless noted.

### Core/ (26 files)

| File | Role |
|------|------|
| `FaeCore.swift` | Facade: config, ModelManager, PipelineCoordinator, Scheduler, awareness wiring |
| `FaeConfig.swift` | Model selection, TTS config, tool mode, speaker config, awareness config, vision config |
| `FaeEventBus.swift` | Combine-based event bus |
| `FaeEvent.swift` | Event types |
| `FaeTypes.swift` | Shared types (LLMMessage with `tag` for proactive cleanup) |
| `FaeEnvironment.swift` | Runtime environment detection |
| `FaeInferenceAliases.swift` | Type aliases for FaeInference target (MLXLLMEngine, etc.) |
| `PersonalityManager.swift` | System prompt assembly (12-layer stack) |
| `MLProtocols.swift` | ML engine protocols (STT, LLM, TTS, Embedding, Speaker) |
| `SoulManager.swift` | SOUL.md lifecycle: load, save, reset, ensure user copy |
| `RescueMode.swift` | Safe boot: read_only tools, default soul, no scheduler |
| `CredentialManager.swift` | macOS Keychain credential storage |
| `GlobalHotkeyManager.swift` | Global Ctrl+Shift+A hotkey (Accessibility API) |
| `VoiceCommandParser.swift` | Voice command detection |
| `SentimentClassifier.swift` | Sentiment analysis for orb mood |
| `DiagnosticsManager.swift` | Diagnostics and debug info |
| `PermissionStatusProvider.swift` | macOS permission status checks |
| `IntroCrawl.swift` | Intro text crawl animation |
| `InferencePriorityController.swift` | GPU access serialization (operator > TTS) |
| `HeartbeatManager.swift` | Heartbeat monitoring |
| `SensitiveContentPolicy.swift` | Sensitive content detection for delegation |
| `VoiceIdentityPolicy.swift` | Voice identity gating policy |
| `CapabilitySnapshotService.swift` | Capability state snapshots |
| `ChannelSettingsStore.swift` | Channel configuration persistence |
| `SettingsCapabilityManifest.swift` | Settings capability definitions |
| `ToolToggleStore.swift` | Per-tool enable/disable persistence |

### ML/ (14 files)

| File | Role |
|------|------|
| `ModelManager.swift` | Loads STT, LLM, TTS, Speaker; on-demand VLM; degraded mode tracking |
| `MLXSTTEngine.swift` | Qwen3-ASR speech-to-text |
| `KokoroMLXTTSEngine.swift` | **Active TTS** — Kokoro-82M via KokoroSwift/MLX |
| `KokoroPythonTTSEngine.swift` | Alternative TTS — Kokoro via ONNX Python (unused) |
| `MLXTTSEngine.swift` | Legacy TTS — Qwen3-TTS (retained, not active) |
| `MLXVLMEngine.swift` | Qwen3-VL vision-language model (on-demand) |
| `MLXEmbeddingEngine.swift` | Hash-384 embedding engine |
| `NeuralEmbeddingEngine.swift` | Tiered Qwen3-Embedding (8B/4B/0.6B/hash by RAM) |
| `CoreMLSpeakerEncoder.swift` | ECAPA-TDNN Core ML inference + mel spectrogram |
| `SpeakerProfileStore.swift` | Speaker profile enrollment, matching, persistence |
| `StreamingSTTEngine.swift` | Streaming STT support |
| `CharacterVoiceLibrary.swift` | Character voice definitions for roleplay |
| `VoiceLibrary.swift` | Voice preset library |
| `WakeWordProfileStore.swift` | Wake word profile management |

### Pipeline/ (10 files)

| File | Role |
|------|------|
| `PipelineCoordinator.swift` | Unified pipeline: STT→LLM→TTS; `injectProactiveQuery()`; barge-in |
| `EchoSuppressor.swift` | Time-based + text-overlap + voice identity echo filtering |
| `VoiceActivityDetector.swift` | Voice activity detection |
| `DynamicVocabularyCorrector.swift` | Post-ASR name correction from user's known vocabulary |
| `SileroVADEngine.swift` | Silero VAD model integration |
| `KeywordSpotter.swift` | Wake word / keyword detection |
| `WakeWordAcousticDetector.swift` | Acoustic wake word detection |
| `VoiceConversationPolicy.swift` | Voice conversation gating policy |
| `VoiceTagParser.swift` | `<voice>` tag parser for multi-voice roleplay |
| `ConversationState.swift` | History management; `removeMessages(taggedWith:)` |
| `TextProcessing.swift` | ThinkTagStripper, text cleanup utilities |

### Runtime/ (11 files)

| File | Role |
|------|------|
| `JSCRuntime.swift` | Fresh-per-run JavaScriptCore runtime for `<tool_program>` scripts |
| `JSCToolBridge.swift` | `fae.*` API bridge (fae.tool, fae.log, fae.sleep) for JSC contexts |
| `JSCTypedAdapters.swift` | Typed JS adapters (fae.calendar, fae.reminders, etc.) |
| `JSCScriptResult.swift` | Script execution result type (success/failure/cancelled/budgetExceeded) |
| `JSCExecutionLog.swift` | Structured execution log for developer harness debugging |
| `JSCDeveloperHarness.swift` | Interactive harness for testing JS tool programs |
| `ScriptBudget.swift` | Resource limits (max tool calls, wall-clock time, concurrency) |
| `DryRunPlan.swift` | Dry-run plan recording: intended calls + summary formatting |
| `DependencyInstaller.swift` | Python/uv dependency installation |
| `UVRuntime.swift` | Python uv runtime for package-heavy skills |
| `FaeLocalRuntimeServer.swift` | Local HTTP runtime server |

### Tools/ (34 files)

| File | Role |
|------|------|
| `Tool.swift` | Tool protocol definition |
| `ToolRegistry.swift` | Dynamic registration, schema generation, mode filtering |
| `BuiltinTools.swift` | Core tools (read, write, edit, bash, self_config, web_search, fetch_url) |
| `AppleTools.swift` | Apple integration (calendar, contacts, mail, reminders, notes) |
| `SchedulerTools.swift` | Scheduler management tools |
| `SkillTools.swift` | activate_skill, run_skill, manage_skill |
| `VisionTools.swift` | screenshot, camera, read_screen, click, type_text, scroll, find_element |
| `VoiceIdentityTool.swift` | Voice identity management |
| `RoleplayTool.swift` | Multi-voice roleplay sessions |
| `AccessibilityBridge.swift` | macOS AXUIElement wrapper |
| `AgentDelegateTool.swift` | One-shot agent delegation |
| `AgentSessionTool.swift` | Multi-turn ACP sessions |
| `ACPProtocol.swift` | JSON-RPC 2.0 / NDJSON parser |
| `ACPSessionManager.swift` | ACP session lifecycle (max 5 concurrent) |
| `ChannelSetupTool.swift` | Channel configuration tool |
| `WindowControlTool.swift` | Window management tool |
| `SessionSearchTool.swift` | Session search tool |
| `TillDoneTool.swift` | Task-driven work with hard gating |
| `TrustedActionBroker.swift` | Default-deny policy chokepoint; scheduler per-task allowlists |
| `DamageControlPolicy.swift` | Pre-broker catastrophic operation blocking |
| `CapabilityTicket.swift` | Task-scoped temporary grants with TTL |
| `ReversibilityEngine.swift` | Pre-mutation file checkpoints and rollback |
| `SafeBashExecutor.swift` | Sandboxed bash (8-pattern denylist, process-group kill) |
| `SafeSkillExecutor.swift` | Constrained Python (ulimits, restricted cwd) |
| `PathPolicy.swift` | Write-path validation (dotfiles, system paths, `.fae-vault`) |
| `InputSanitizer.swift` | Shell metacharacter detection |
| `NetworkTargetPolicy.swift` | Blocks localhost, metadata, RFC1918 |
| `OutboundExfiltrationGuard.swift` | Novel recipient + sensitive payload detection |
| `SecurityEventLogger.swift` | Append-only JSONL security log (5MB rotation) |
| `SensitiveDataRedactor.swift` | API key/token/password redaction |
| `ToolRateLimiter.swift` | Per-tool sliding-window rate limiter |
| `ToolRiskPolicy.swift` | Risk-level → approval routing |
| `ToolAnalytics.swift` | Tool usage analytics |
| `ApprovedToolsStore.swift` | Persisted tool approval state |

### Memory/ (13 files)

| File | Role |
|------|------|
| `MemoryOrchestrator.swift` | Recall (ANN+FTS5 hybrid), capture, GC, graph context |
| `SQLiteMemoryStore.swift` | GRDB-backed SQLite: CRUD, search, retention |
| `MemoryTypes.swift` | MemoryRecord, MemoryKind, MemoryStatus |
| `MemoryBackup.swift` | Database backup and rotation |
| `VectorStore.swift` | sqlite-vec ANN tables (`memory_vec`, `fact_vec`) |
| `EntityStore.swift` | Entity graph: persons, orgs, locations with typed edges |
| `EntityLinker.swift` | Extract entities and relationships from records |
| `EntityBackfillRunner.swift` | One-time legacy person records → entity graph |
| `EmbeddingBackfillRunner.swift` | Background paged backfill into ANN index |
| `PersonQueryDetector.swift` | Detect person/org/location queries |
| `EntityContextFormatter.swift` | Format entity profiles with relationship edges |
| `MemoryDigestService.swift` | Memory digest generation |
| `MemoryInboxService.swift` | Memory inbox file ingestion |

### Scheduler/ (7 files)

| File | Role |
|------|------|
| `FaeScheduler.swift` | Background task scheduler (~23 tasks) |
| `FaeScheduler+Proactive.swift` | Proactive awareness task implementations |
| `FaeScheduler+Reliability.swift` | Task reliability and retry logic |
| `AwarenessThrottle.swift` | Battery/thermal/quiet-hours gating |
| `ProactivePolicyEngine.swift` | Proactive dispatch policy |
| `SchedulerPersistenceStore.swift` | Scheduler state persistence |
| `TaskRunLedger.swift` | Task idempotency and run tracking |

### Skills/ (7 files)

| File | Role |
|------|------|
| `SkillManager.swift` | Discovery, activation, execution, management |
| `SkillTypes.swift` | SkillMetadata, SkillRecord, SkillType, SkillTier |
| `SkillParser.swift` | YAML frontmatter parser for SKILL.md |
| `SkillMigrator.swift` | Legacy flat `.py` → directory migration |
| `SkillManifest.swift` | MANIFEST.json schema + SHA-256 integrity |
| `SkillEditorSheet.swift` | Skill editing UI |
| `SkillSecurityReview.swift` | Skill security validation |

### Channels/ (4 files)

| File | Role |
|------|------|
| `ChannelManager.swift` | Channel lifecycle, guest security model |
| `DiscordAdapter.swift` | WebSocket Gateway + REST, 2000-char split, rate limit retry |
| `WhatsAppAdapter.swift` | HTTP webhook + Graph API, HMAC-SHA256 verification |
| `iMessageAdapter.swift` | SQLite polling + AppleScript, `is_from_me = 0` echo filter |

### Cowork/ (10 files)

| File | Role |
|------|------|
| `CoworkWindowController.swift` | CoWork window management |
| `CoworkWorkspaceController.swift` | Workspace state |
| `CoworkWorkspaceView.swift` | Workspace UI |
| `CoworkWorkspaceModels.swift` | Workspace data models |
| `CoworkLLMProvider.swift` | Remote LLM provider protocol |
| `CoworkModelOption.swift` | Model option definitions |
| `CoworkModelRegistry.swift` | Available remote model registry |
| `CoworkRemoteModelCatalog.swift` | Remote model catalog |
| `CoworkExportPacket.swift` | Conversation export |
| `WorkWithFaeWorkspace.swift` | "Work with Fae" workspace integration |

### Audio/ (3 files), Backup/ (1 file), Agent/ (1 file)

| File | Role |
|------|------|
| `Audio/AudioCaptureManager.swift` | Microphone capture (16kHz mono) |
| `Audio/AudioPlaybackManager.swift` | Audio playback with barge-in support |
| `Audio/AudioToneGenerator.swift` | Thinking/listening/ready beep tones |
| `Backup/GitVaultManager.swift` | Git-based rolling backup at `~/.fae-vault/` |
| `Agent/ApprovalManager.swift` | Tool approval lifecycle (20s timeout) |

### Top-level files (74 files)

Key top-level files (all under `Sources/Fae/`):

| File | Role |
|------|------|
| `FaeApp.swift` | App entry; FaeAppDelegate owns all state; AppKit window creation |
| `ContentView.swift` | Main view: orb, progress overlay, subtitle |
| `NativeOrbView.swift` | Metal-rendered orb |
| `FogCloudOrb.metal` / `NebulaOrb.metal` | Metal shaders |
| `OrbAnimationState.swift` | Orb animation state machine |
| `OrbTypes.swift` | OrbMode, OrbFeeling, OrbPalette enums |
| `OrbStateBridgeController.swift` | Maps events to orb visual state |
| `WindowStateController.swift` | Adaptive window (120x120 collapsed / 340x500 compact) |
| `AuxiliaryWindowManager.swift` | Independent NSPanel windows (conversation, canvas) |
| `ConversationWindowView.swift` | Conversation panel content |
| `ConversationController.swift` | Conversation state (messages, streaming) |
| `ConversationBridgeController.swift` | Routes events to conversation UI |
| `ThinkingTraceViews.swift` | ThinkingCrawlView + ThinkIconBubble (inline thinking display) |
| `ApprovalOverlayController.swift` | Tool approval + input-request lifecycle |
| `ApprovalOverlayView.swift` | Floating approval/input cards |
| `SettingsView.swift` | TabView settings container |
| `Settings*.swift` | 16 settings tab files |
| `BackendEventRouter.swift` | FaeEventBus → NotificationCenter |
| `TestServer.swift` | Test server for scripted testing |
| `DebugConsoleController.swift` | Debug event log (Cmd+Shift+L, max 500 events) |
| `SparkleUpdaterController.swift` | Sparkle auto-update |
| `JitPermissionController.swift` | JIT permission requests (Screen Recording, Camera, Accessibility) |
| `OnboardingController.swift` | First-run onboarding |
| `SpeakerEnrollmentView.swift` | Native speaker enrollment UI |

## NotificationCenter names

| Name | Purpose |
|------|---------|
| `.faeBackendEvent` | Raw backend events |
| `.faeOrbStateChanged` | Orb visual state changes |
| `.faePipelineState` | Pipeline lifecycle |
| `.faeRuntimeState` | Runtime lifecycle |
| `.faeRuntimeProgress` | Model download/load progress |
| `.faeAssistantGenerating` | LLM generation active/inactive |
| `.faeAudioLevel` | Audio level updates |
| `.faeCancelGeneration` | Cancel generation (Cmd+.) |
| `.faeInputRequired` | Pipeline needs text input |
| `.faeInputResponse` | User submitted/cancelled input |

## Testing

```bash
just test                # Run all tests
just check               # Full validation (build + test)
```

**Voice TTS** (voice testing): `voice -q "test phrase"` (Kokoro TTS CLI at `~/.cargo/bin/voice`)

Known blockers: dependency fetch requires network; first app run blocks on model downloads (~8 GB).

## Version history

See `docs/CHANGELOG.md` for detailed milestone history.

Current: v1.4.2 — ACP integration, channel adapters, training pipeline, skill hardening.
