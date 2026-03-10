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

## Release-validation contract

When working on anything user-visible or runtime-critical, the canonical validation source is
`docs/checklists/app-release-validation.md`.

That contract is not optional for:

- local model swaps or prompt/routing changes
- voice capture, STT, wake logic, TTS, or playback changes
- approval, permission, popup, or remote-egress changes
- memory, scheduler, skills, or settings behavior changes
- Cowork UI, model switching, compare/fork, or remote-provider behavior changes

Use both sides of the workflow:

- `just run-native` or `just rebuild` for the real app experience
- `just test-serve` plus `scripts/test-comprehensive.sh` for scripted phase coverage

For voice features, use real audio playback/capture, not text injection, and capture screenshots plus test-server evidence for failures.

The step-by-step live scenario script is
`docs/checklists/main-and-cowork-live-test-scenarios.md`.
Keep it in sync with the release-validation contract whenever main-window,
Cowork, popup, voice, scheduler, skills, or remote-provider behavior changes.

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
│                         │              ├── Tools (30 built-in)│
│                         │              ├── Skills (v2)        │
│                         │              ├── Scheduler          │
│                         │              ├── Backup (Git Vault) │
│                         │              └── Self-Config        │
│                         │                                    │
│                         └── Voice Identity (Core ML)         │
│                                                              │
│  ML Engines (all MLX/CoreML, on-device):                     │
│  ┌───────────┐ ┌────────────┐ ┌───────────┐ ┌────────────┐  │
│  │ STT       │ │ LLM        │ │ TTS       │ │ Speaker    │  │
│  │ Qwen3-ASR │ │ Qwen3-8B   │ │ Kokoro    │ │ ECAPA-TDNN │  │
│  │ 1.7B 4bit │ │ MLX 4bit   │ │ 82M MLX   │ │ Core ML    │  │
│  └───────────┘ └────────────┘ └───────────┘ └────────────┘  │
│  ┌───────────┐                                               │
│  │ VLM       │ ← on-demand, not loaded at startup            │
│  │ Qwen3-VL  │                                               │
│  │ 4B/8B 4bit│                                               │
│  └───────────┘                                               │
└──────────────────────────────────────────────────────────────┘
```

### Model stack

| Engine | Model | Framework | Precision | Purpose |
|--------|-------|-----------|-----------|---------|
| STT | Qwen3-ASR-1.7B | MLX | 4-bit | Speech-to-text |
| LLM (operator) | Qwen3.5 (0.8B–35B-A3B) | MLX | 4-bit | Conversation, tool use, fast turns |
| LLM (concierge) | LiquidAI/LFM2-24B-A2B | MLX | 4-bit | Rich synthesis: summaries, plans, long-form (32+ GB RAM only) |
| TTS | Kokoro-82M (hexgrad) | KokoroSwift/MLX | float32 | Text-to-speech (pre-computed voice embeddings, 24 kHz) |
| VLM | Qwen3-VL (4B/8B) | MLXVLM | 4-bit/8-bit | Vision — screen + camera understanding (on-demand) |
| Embedding | Hash-384 | MLX | - | Semantic memory search |
| Speaker | ECAPA-TDNN | Core ML | fp16 | Voice identity (1024-dim x-vectors) |

### Dual-model pipeline

When system RAM ≥ 32 GB and `dualModelEnabled = true`, Fae runs two local LLMs in separate **worker subprocesses**:

- **Operator** — the auto-selected Qwen3.5 model (fast, tool-capable)
- **Concierge** — `LiquidAI/LFM2-24B-A2B-MLX-4bit` (richer synthesis, no tools, 16K context)

**Worker subprocess architecture** (`ML/WorkerLLMEngine.swift`):
- Each engine runs as a child process (`fae --llm-worker --role [operator|concierge]`)
- Communication: JSON-lines on stdin/stdout (`LLMWorkerRequest` / `LLMWorkerResponse` in `ML/LLMWorkerProtocol.swift`)
- 30-second command timeout per request; automatic model restore after worker restart
- `restartCount` and last error persisted to UserDefaults; visible in Settings > Diagnostics
- Worker termination sweeps all in-flight continuations — no orphaned streams

**Inference priority** (`Core/InferencePriorityController.swift`):
- Actor that serialises GPU access: operator (0) > Kokoro TTS (1) > concierge (2)
- Lower-priority work parks via `CheckedContinuation` until higher-priority work ends
- Prevents Metal contention between concurrent operator + concierge inference

**Turn routing** (`Pipeline/TurnRoutingPolicy.swift`):
- **Always operator**: tool follow-ups, proactive queries, voice turns (unless `allowConciergeDuringVoiceTurns`), tool-biased queries (search, web, calendar, mail, bash, etc.)
- **Concierge**: rich-response hints (summarize, explain, brainstorm, analyze, draft, plan, …) or long prompts (≥ 220 chars)
- **Default**: operator

The concierge worker is started lazily after the main pipeline starts. If loading fails, the pipeline continues in single-model mode silently.

**Vendored packages** (`native/macos/Fae/Vendor/`):
- `Vendor/kokoro-ios` and `Vendor/MisakiSwift` — vendored and patched to remove forced `.dynamic` packaging and fix duplicate-symbol warnings that appeared during worker subprocess execution.

**Diagnostics** — `SettingsDiagnosticsTab.swift` now shows: operator/concierge loaded state, current route, fallback reason, operator/concierge runtime, restart counts, last worker errors.

Key files: `Pipeline/TurnRoutingPolicy.swift`, `ML/WorkerLLMEngine.swift`, `ML/LLMWorkerProtocol.swift`, `Core/InferencePriorityController.swift`, `ML/ModelManager.swift` (`loadConciergeIfNeeded()`), `Core/FaeConfig.swift` (`recommendedConciergeModel()`, `isDualModelEligible()`, `recommendedLocalModelStack()`), `SettingsModelsPerformanceTab.swift`, `SettingsDiagnosticsTab.swift`.

Auto mode selects the **operator** LLM (Qwen3.5). Current auto policy:
- ≥12 GiB → Qwen3.5-2B (32K context, lightweight prompt)
- <12 GiB → Qwen3.5-0.8B (32K context, lightweight prompt)

All Qwen3.5 models have a native `max_position_embeddings` of **262,144**. Fae caps context at
practical limits to keep KV-cache RAM manageable: 32K for 0.8B–4B, 128K for 9B–35B.

**Concierge** (dual-model, ≥32 GB RAM): `LiquidAI/LFM2-24B-A2B-MLX-4bit` at **128K context**.
The MLX 4-bit export was published at 128K (base model is 32K). Handles rich synthesis, long-form
output, summaries, and plans. No tool use.

Manual presets span the full Qwen3.5 lineup:
- `qwen3_5_35b_a3b` → Qwen3.5-35B-A3B (128K / native 262K)
- `qwen3_5_27b` → Qwen3.5-27B (128K / native 262K)
- `qwen3_5_9b` → Qwen3.5-9B (128K / native 262K)
- `qwen3_5_4b` → Qwen3.5-4B (32K / native 262K)
- `qwen3_5_2b` → Qwen3.5-2B (32K / native 262K)
- `qwen3_5_0_8b` → Qwen3.5-0.8B (32K / native 262K)

Context window is now properly wired from model selection through to the pipeline.
`FaeConfig.recommendedMaxHistory()` scales conversation history with context size
(formula: `(contextSize - 5000 - maxTokens) / 400`, clamped to [6, 100]).
`ConversationStateTracker` also performs token-aware truncation (chars / 3.5 estimate)
to prevent overflow when individual messages are very long.
`maxTokens` is capped at `contextSize / 2` to prevent generation budget exceeding context on small tiers.

### Unified pipeline

Single pipeline where the LLM decides tool use via `<tool_call>` markup inline — no separate intent classifier or agent loop:

1. **Audio capture** (16kHz mono)
2. **VAD** — voice activity detection, barge-in support
3. **Speaker ID** — ECAPA-TDNN embedding, owner verification
4. **Echo suppression** — time-based + text-overlap + voice identity filtering + echo-aware barge-in gating
5. **STT** — Qwen3-ASR transcription
6. **LLM** — `TurnRoutingPolicy` selects operator (Qwen3.5, tool-capable) or concierge (LFM2-24B, richer synthesis, no tools); max 5 tool turns per query
7. **TTS** — Kokoro-82M (KokoroSwift/MLX), sentence-queued (deferred until LLM finishes, then synthesised sentence-by-sentence)
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

Tick interval: 60s. All 17 built-in tasks:

| Task | Schedule | Purpose |
|------|----------|---------|
| `check_fae_update` | every 6h | Check for Fae updates (via Sparkle) |
| `memory_migrate` | every 1h | Schema migration checks |
| `memory_reflect` | every 6h | Consolidate duplicate memories |
| `memory_reindex` | every 3h | Health check + integrity verification |
| `memory_gc` | daily 03:30 | Retention cleanup (episode expiry) |
| `memory_backup` | daily 02:00 | Atomic backup with rotation |
| `vault_backup` | daily 02:30 | Git vault full snapshot |
| `noise_budget_reset` | daily 00:00 | Reset proactive interjection counter |
| `stale_relationships` | every 7d | Detect relationships needing check-in |
| `morning_briefing` | daily 08:00 | Compile and speak morning briefing (suppressed when enhanced briefing active) |
| `skill_proposals` | daily 11:00 | Detect skill opportunities from interests |
| `skill_health_check` | every 5min | Python skill health checks |
| `embedding_reindex` | weekly Sun 03:00 | Re-embed records missing ANN vectors after model change |
| `camera_presence_check` | repeating (30s default) | Camera-based user presence detection (awareness) |
| `screen_activity_check` | repeating (19s default) | Screen activity monitoring (awareness) |
| `overnight_work` | hourly 22:00-06:00 | Quiet-hours research on user interests (awareness) |
| `enhanced_morning_briefing` | deferred until user detected after 07:00 | Calendar, mail, research, reminders (awareness) |

The last 4 tasks are **awareness tasks** — only active when `awareness.enabled = true` with valid consent. They use `proactiveQueryHandler` instead of `speakHandler` to inject full LLM conversations with tool access.

### Scheduler speak handler

The scheduler can make Fae speak via `speakHandler` closure, wired by `FaeCore` to `PipelineCoordinator.speakDirect()`. Used by legacy morning briefing and stale relationship reminders.

### Scheduler proactive query handler

For awareness tasks, the scheduler uses `proactiveQueryHandler` — a 5-parameter closure `(prompt, silent, taskId, allowedTools, consentGranted)` wired by `FaeCore` to `PipelineCoordinator.injectProactiveQuery()`. This injects a full LLM conversation turn with tool access, gated by `AwarenessThrottle` and `TrustedActionBroker` per-task allowlists.

### Awareness task tracking state

The scheduler maintains per-session awareness state:
- `lastUserSeenAt: Date?` — last camera detection (drives adaptive frequency + morning briefing trigger)
- `morningBriefingDelivered: Bool` — reset daily at 00:00, prevents duplicate briefings
- `lastCameraCheckAt / lastScreenCheckAt` — interval enforcement
- `lastFrontmostAppBundleId` — smart screen gating (only observe on app change or 2min minimum)
- `lastScreenContentHash / lastScreenContextPersistedAt` — SHA256-based screen context coalescing

Implementation: `Scheduler/FaeScheduler.swift`

## Tool system

Tools are registered dynamically in `ToolRegistry.buildDefault(skillManager:)`. Full inventory (31 tools):

| Category | Tools |
|----------|-------|
| Core | `read`, `write`, `edit`, `bash`, `self_config` |
| Web | `web_search` (DuckDuckGo HTML), `fetch_url` (with content extraction) |
| Skills | `activate_skill` (load skill instructions), `run_skill` (execute Python), `manage_skill` (create/update/delete/list) |
| Apple | `calendar`, `reminders`, `contacts`, `mail`, `notes` |
| Scheduler | `scheduler_list`, `scheduler_create`, `scheduler_update`, `scheduler_delete`, `scheduler_trigger` |
| Vision | `screenshot` (screen capture → VLM), `camera` (webcam capture → VLM), `read_screen` (screenshot + accessibility tree) |
| Computer Use | `click` (element or coordinate click), `type_text` (type into element/field), `scroll` (directional scroll), `find_element` (search UI elements) |
| Voice Identity | `voice_identity` (enroll speakers, verify identity, manage profiles — beep-guided capture) |
| Roleplay | `roleplay` (multi-voice reading sessions) |
| Input | `input_request` (prompt user for text/password; 120s timeout) |

Skills use **progressive disclosure**: the LLM sees skill names + short descriptions (~50-100 tokens each)
in the system prompt. Full SKILL.md body is loaded only when the LLM activates a skill via `activate_skill`.
Skills are discovered at prompt assembly time from `SkillManager.promptMetadata()`.
Skill proposals from the scheduler now store `.commitment` memory records so the LLM
can follow up naturally in the next conversation.

Tool modes (configurable via Settings > Tools) — **enforced by ToolRegistry + PipelineCoordinator**:

| Mode | Access |
|------|--------|
| `off` | Read-only tools (read, web_search, fetch_url, Apple reads, scheduler_list, activate_skill, run_skill, roleplay) |
| `read_only` | Same as off (explicit read-only intent) |
| `read_write` | Read tools + write, edit, self_config, scheduler mutation, manage_skill |
| `full` | All tools including bash **(recommended default)** |
| `full_no_approval` | All tools, skip approval only if speaker is verified owner |

Even "off" mode keeps read tools available — Fae is local, she should always be able to read.
Tool mode is enforced at two levels: schema filtering (LLM never sees blocked tools) and
execution guard (rejected even if LLM hallucinates a tool call).

The LLM uses **native MLX tool calling** — tool specs are passed via `UserInput.tools` so the Qwen3.5 chat template activates its built-in tool calling behavior. Native `.toolCall` events are serialized back to `<tool_call>` text for the existing pipeline parser. No separate routing or intent classification.

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

### Tool security (v0.8.1 + v0.8.63 TrustedActionBroker + damage control)

**7-layer safety model** for the tool system (damage control adds layer 0):

| Layer | Implementation | Purpose |
|-------|---------------|---------|
| **Damage control** | `DamageControlPolicy.evaluate()` | Pre-broker layer-zero: block/disaster/confirm_manual for catastrophic ops; credential zero-access for non-local models |
| **Tool mode filtering** | `ToolRegistry.toolSchemas(for:)` | LLM never sees tools outside current mode |
| **Execution guard** | `PipelineCoordinator.executeTool()` | Rejects tool calls even if LLM hallucinates them |
| **Path validation** | `PathPolicy.validateWritePath()` | Blocks writes to dotfiles, system paths, Fae config |
| **Rate limiting** | `ToolRateLimiter` | Per-tool sliding-window limits with risk-aware adjustments |
| **TrustedActionBroker** | `TrustedActionBroker.evaluate()` | Default-deny policy chokepoint; all tool calls route through |
| **Outbound guard** | `OutboundExfiltrationGuard` | Novel recipient confirmation + sensitive payload detection |

**DamageControlPolicy** (layer 0, pre-broker): Intercepts every tool call before `TrustedActionBroker`. Three-tier verdict:
- `block` — hard deny, no dialog (disk format, raw disk write, root permission wipeout, `rm -rf /`)
- `disaster` — DISASTER WARNING overlay, physical click only, no voice (`rm -rf ~/`, `rm -rf ~/Documents`, `rm -rf ~/Library`)
- `confirmManual` — Manual Approval overlay, physical click only, no voice (`sudo rm -rf`, `curl|bash`, `wget|bash`, `launchctl disable system/`, `osascript System Events`)

Non-local (co-work API) model: `~/.ssh`, `~/.gnupg`, `~/.aws`, `~/.azure`, `~/.kube`, `~/.docker/config.json`, `~/.netrc`, `~/.npmrc` are zero-access (reads + writes hard-blocked). See `docs/guides/damage-control.md`.

**TrustedActionBroker** (v0.8.63, extended v0.8.82): Central policy chokepoint implementing default-deny. Every tool call is modeled as an `ActionIntent` and evaluated to a `BrokerDecision`:
- `allow` — proceed immediately
- `allowWithTransform(.checkpointBeforeMutation)` — create reversibility checkpoint then proceed
- `confirm(reason:)` — require user approval with plain-language explanation
- `deny(reason:)` — block with explanation

**Scheduler awareness bypass** (v0.8.82): `ActionIntent` includes `schedulerTaskId: String?` and `schedulerConsentGranted: Bool` for per-request consent. Scheduler-sourced intents follow a strict evaluation path with per-task tool allowlists and no fallthrough to normal policy. See "Proactive awareness system" section for details.

Three `PolicyProfile` modes (configurable via Settings > Tools):
- **balanced** (default) — production safety defaults
- **moreAutonomous** — relaxes low-risk confirmations
- **moreCautious** — halves rate limits, confirms medium-risk actions

**CapabilityTicket**: task-scoped temporary grants with TTL. Tools must hold a valid ticket to pass the broker. Tickets are issued per conversation turn and expire automatically.

**ReversibilityEngine**: pre-mutation file checkpoints in `~/Library/.../fae/recovery/`. Stores file content before writes; supports restore and automatic 24h pruning.

**SafeBashExecutor**: denylist of 8 dangerous patterns (rm -rf /, chmod 777, etc.); minimal constrained env; process-group SIGTERM/SIGKILL on timeout.

**SafeSkillExecutor**: ulimit constraints (CPU, memory 1GB, 64 FDs); restricted cwd to skill's `scripts/` directory.

**NetworkTargetPolicy**: shared policy blocking localhost, cloud metadata endpoints (169.254.169.254, metadata.google.internal), all RFC1918/loopback/link-local IPv4+IPv6. Replaces per-tool inline checks.

**OutboundExfiltrationGuard**: novel recipient confirmation (SHA256 hash set, persisted JSON). Sensitive payload detection via keyword matching + high-entropy heuristic.

**SecurityEventLogger**: append-only JSONL at `.../fae/security-events.jsonl`. SHA256 argument hashing. 5MB rotation with 3 archives. Forensic mode toggle. Redaction via SensitiveDataRedactor.

**SensitiveDataRedactor**: regex patterns for API keys, tokens, passwords (OpenAI sk-, Slack xox, GitHub ghp_, Google AIza). Length/entropy heuristic for opaque tokens.

**SkillManifest**: `MANIFEST.json` schema with capabilities, allowedTools, allowedDomains, riskTier, and SHA-256 per-file integrity checksums for tamper detection.

Additional hardening (v0.8.1):

- **SelfConfigTool**: requires approval, jailbreak pattern detection, 2000-char limit
- **BashTool**: execution via SafeBashExecutor, stderr filtered from LLM
- **EditTool**: first-occurrence-only replacement, occurrence count reporting
- **WriteTool**: content null-byte sanitization via `InputSanitizer`
- **ApprovalManager**: 20s timeout (was 58s)

Implementation files:

| File | Role |
|------|------|
| `Tools/BuiltinTools.swift` | All core + web tool implementations |
| `Tools/AppleTools.swift` | Apple integration tools (calendar, contacts, etc.) |
| `Tools/SchedulerTools.swift` | Scheduler management tools |
| `Tools/SkillTools.swift` | Skill tools (activate_skill, run_skill, manage_skill with `update` action) |
| `Tools/Tool.swift` | Tool protocol definition |
| `Tools/RoleplayTool.swift` | Multi-voice roleplay session management |
| `Tools/ToolRegistry.swift` | Dynamic tool registration, schema generation, mode filtering |
| `Tools/TrustedActionBroker.swift` | Central default-deny policy chokepoint; scheduler per-task allowlists |
| `Tools/CapabilityTicket.swift` | Task-scoped temporary grants with TTL |
| `Tools/ReversibilityEngine.swift` | Pre-mutation file checkpoints and rollback |
| `Tools/SafeBashExecutor.swift` | Sandboxed bash execution with denylist |
| `Tools/SafeSkillExecutor.swift` | Constrained Python skill execution (ulimits) |
| `Tools/NetworkTargetPolicy.swift` | Shared network target validation (blocks localhost, metadata, RFC1918) |
| `Tools/OutboundExfiltrationGuard.swift` | Novel recipient confirmation + sensitive payload detection |
| `Tools/SecurityEventLogger.swift` | Append-only JSONL security event log |
| `Tools/SensitiveDataRedactor.swift` | API key/token/password redaction |
| `Tools/PathPolicy.swift` | Write-path validation (blocklist for dotfiles, system paths) |
| `Tools/InputSanitizer.swift` | Shell metacharacter detection, bash command classification |
| `Tools/ToolRateLimiter.swift` | Per-tool sliding-window rate limiter with risk-aware adjustments |
| `Tools/ToolRiskPolicy.swift` | Risk-level → approval routing |
| `Tools/ToolAnalytics.swift` | Tool usage analytics |

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
| `ML/KokoroMLXTTSEngine.swift` | Kokoro-82M TTS via KokoroSwift/MLX; pre-computed voice embeddings, 24 kHz |
| `ML/MLXTTSEngine.swift` | Legacy Qwen3-TTS engine (mlx-audio-swift); retained but not active |
| `Pipeline/PipelineCoordinator.swift` | Routes voice segments to TTS with per-character voices |
| `Core/PersonalityManager.swift` | `roleplayPrompt` — LLM instructions for voice tag usage |

## Voice identity (speaker verification)

ECAPA-TDNN speaker encoder runs via Core ML on the Neural Engine.
Produces 1024-dim x-vector embeddings from audio for speaker verification.

Speaker recognition is **always on** — no settings toggle. The ECAPA-TDNN encoder loads unconditionally when the Core ML model exists.

| File | Role |
|------|------|
| `Core/MLProtocols.swift` | `SpeakerEmbeddingEngine` protocol |
| `ML/CoreMLSpeakerEncoder.swift` | Core ML inference + mel spectrogram (Accelerate vDSP) |
| `ML/SpeakerProfileStore.swift` | Profile enrollment, matching, JSON persistence |
| `Core/FaeConfig.swift` | `SpeakerConfig` — thresholds, gating, progressive enrollment |
| `Resources/Models/SpeakerEncoder.mlmodelc/` | Compiled Core ML model (~18MB) |
| `Tools/VoiceIdentityTool.swift` | Tool: check_status, collect_sample, confirm_identity, rename_speaker, list_speakers |
| `Resources/Skills/voice-identity/SKILL.md` | Built-in skill: enrollment choreography, introduction flow, re-verification |

Behavior:

- **First launch**: Fae detects no owner profile, auto-activates `voice-identity` skill, and conversationally guides enrollment using the `voice_identity` tool (beep → speak → enroll cycle)
- **Progressive enrollment**: each recognized interaction adds to the profile centroid (up to 50 embeddings)
- **Owner gating**: when `requireOwnerForTools = true`, *known* non-owner voices don't see tool schemas. Unknown speakers (encoder not loaded, no match) still get tools — physical device access implies trust. Only positively matched non-owner profiles are blocked.
- **Introduction flow**: "Fae, meet Alice" triggers the voice-identity skill's introduction instructions — Fae collects voice samples from the new person with beep-guided capture
- **Re-verification**: when voice confidence drops, Fae proactively offers to collect fresh samples
- **Text injection**: always trusted (physical device access)
- **Degraded mode**: if model not found or load fails, pipeline continues without voice identity — tools remain available

### VoiceIdentityTool

The `voice_identity` tool manages enrollment and verification via 5 actions:

| Action | Description |
|--------|-------------|
| `check_status` | Returns enrollment state, speaker count, confidence scores |
| `collect_sample` | Plays ready beep → captures ~3s audio → embeds → enrolls against label |
| `confirm_identity` | Matches current speaker against all profiles |
| `rename_speaker` | Updates display name for a speaker label |
| `list_speakers` | Lists all enrolled speakers with roles, counts, last-seen |

The `collect_sample` sequence: play `readyBeep()` → wait 200ms → capture 3s via `AudioCaptureManager` → embed via `CoreMLSpeakerEncoder` → enroll via `SpeakerProfileStore`.

Risk level: `.low` (read-heavy, enrollment is additive). No approval needed.

### Voice identity skill

Built-in instruction skill at `Resources/Skills/voice-identity/SKILL.md`. Covers:
- First-launch enrollment (3 samples, conversational)
- Introducing new people ("Fae, meet Alice")
- Re-verification when confidence drops
- Multi-speaker awareness

Config: `[speaker]` section in `config.toml` — see `docs/guides/voice-identity.md`.

Model conversion: `python3 scripts/convert_speaker_model.py` (ONNX → Core ML, one-time).

## Vision + computer use

Fae can see the screen and interact with apps via on-device vision (Qwen3-VL) and macOS Accessibility API. All processing is local — images never leave the Mac.

### VLM engine (on-demand)

The VLM does **not** load at startup — it loads on-demand when a vision tool first fires, to conserve RAM for the core STT+LLM+TTS pipeline.

RAM-tiered model selection:

| System RAM | VLM Model | Notes |
|-----------|-----------|-------|
| 48+ GB | Qwen3-VL-8B (8-bit) | Alongside text LLM |
| 24-47 GB | Qwen3-VL-4B (4-bit) | Alongside text LLM |
| <24 GB | Disabled (nil) | Not enough headroom |

Config: `[vision]` section in config.toml. Enable via Settings > Models or `self_config(adjust_setting, vision.enabled, true)`.

### Vision tools

| Tool | Risk | Params | Behavior |
|------|------|--------|----------|
| `screenshot` | medium | `prompt`, `app?` | Capture screen/window via ScreenCaptureKit → VLM description |
| `camera` | medium | `prompt` | Capture webcam frame via AVCaptureSession → VLM description |
| `read_screen` | high | `prompt?`, `app?` | Screenshot + Accessibility tree → VLM + numbered element list |

### Computer use tools

| Tool | Risk | Params | Behavior |
|------|------|--------|----------|
| `click` | high | `element_index` or `x`/`y` | AXUIElement press or CGEvent mouse click |
| `type_text` | high | `text`, `element_index?` | AXUIElement setValue or CGEvent keystroke synthesis |
| `scroll` | medium | `direction`, `amount?` | CGEvent scroll wheel |
| `find_element` | low | `query`, `role?`, `app?` | AXUIElement tree search with fuzzy title matching |

### Computer use workflow

The LLM follows: `read_screen` → identify target → `click`/`type_text` → `read_screen` to verify. Max 10 action steps (click/type_text/scroll) per conversation turn to prevent runaway automation.

### JIT permissions

Vision tools trigger JIT permission requests via `JitPermissionController`:
- **Screen Recording** — `CGRequestScreenCaptureAccess()` with polling
- **Camera** — `AVCaptureDevice.requestAccess(for: .video)`
- **Accessibility** — `AXIsProcessTrustedWithOptions` (may already be granted via GlobalHotkeyManager)

### TrustedActionBroker policies

| Tool | Balanced | Autonomous | Cautious |
|------|----------|------------|----------|
| `screenshot` | allow w/ ticket | allow | confirm |
| `camera` | confirm (high-impact) | confirm (high-impact) | confirm |
| `read_screen` | confirm | confirm | confirm |
| `click` | confirm | confirm | confirm |
| `type_text` | confirm | confirm | confirm |
| `scroll` | confirm (high-impact) | confirm (high-impact) | confirm |
| `find_element` | allow | allow | confirm |

### Implementation files

| File | Role |
|------|------|
| `ML/MLXVLMEngine.swift` | Qwen3-VL inference actor via MLXVLM (~120 lines) |
| `Tools/VisionTools.swift` | All 7 vision + computer use tool implementations |
| `Tools/AccessibilityBridge.swift` | macOS AXUIElement wrapper: query, press, setValue, tree search |
| `ML/ModelManager.swift` | On-demand VLM loading/unloading via `loadVLMIfNeeded()` |
| `Core/FaeConfig.swift` | `VisionConfig` struct, `recommendedVLMModel()` static method |
| `Core/PersonalityManager.swift` | `visionPrompt` + `computerUsePrompt` fragments |
| `Core/PermissionStatusProvider.swift` | Screen Recording + Camera permission checks |
| `JitPermissionController.swift` | Screen Recording + Camera JIT permission flow |
| `SettingsModelsTab.swift` | Vision section (toggle, model picker, permission badges) |

## Self-modification

Fae can modify her own behavior and learn new skills. See `docs/guides/self-modification.md`.

### SelfConfigTool

The `self_config` tool manages both live behavior settings and persistent directives.

**Behavior settings** (bidirectional with Settings UI):

| Action | Parameters | Description |
|--------|------------|-------------|
| `adjust_setting` | `key`, `value` | Change a live setting (speed, temperature, etc.) |
| `get_settings` | — | View all adjustable settings and current values |

Adjustable keys:

| Key | Type | Range | Natural language triggers |
|-----|------|-------|--------------------------|
| `tts.speed` | Float | 0.8–1.4 | "Speak faster/slower" |
| `tts.warmth` | Float | 1.0–5.0 | "Sound warmer/cooler" |
| `tts.emotional_prosody` | Bool | — | "Be more expressive" |
| `llm.temperature` | Float | 0.3–1.0 | "Be more creative/precise" |
| `llm.thinking_enabled` | Bool | — | "Think step by step" |
| `barge_in.enabled` | Bool | — | "Let me interrupt you" |
| `conversation.require_direct_address` | Bool | — | "Only respond when I say your name" |
| `conversation.direct_address_followup_s` | Int | 5–60 | "Keep listening longer" |
| `vision.enabled` | Bool | — | "Enable/disable vision" |
| `awareness.enabled` | Bool | — | "Enable/disable proactive awareness" |
| `awareness.camera_enabled` | Bool | — | "Enable/disable camera presence checks" |
| `awareness.screen_enabled` | Bool | — | "Enable/disable screen monitoring" |
| `awareness.camera_interval_seconds` | Int | 10–120 | "Check the camera every 60 seconds" |
| `awareness.screen_interval_seconds` | Int | 10–60 | "Check the screen every 30 seconds" |
| `awareness.overnight_work` | Bool | — | "Enable/disable overnight research" |
| `awareness.enhanced_briefing` | Bool | — | "Enable/disable enhanced morning briefing" |
| `awareness.pause_on_battery` | Bool | — | "Keep running on battery" |
| `awareness.pause_on_thermal_pressure` | Bool | — | "Ignore thermal pressure" |

Changes route through `FaeCore.patchConfig()` — the same pathway Settings UI uses. Fully bidirectional.
Awareness config changes trigger `refreshAwarenessRuntime()` which syncs scheduler config, restarts awareness tasks, and activates/deactivates awareness skills.

**Directives** (persistent standing orders):

| Action | Description |
|--------|-------------|
| `get_directive` | Read current directive |
| `set_directive` | Replace directive with new text |
| `append_directive` | Add without removing existing |
| `clear_directive` | Remove all, revert to defaults |

Directive path: `~/Library/Application Support/fae/directive.md`

Legacy aliases (`get_instructions`, etc.) still work for backward compatibility.

Implementation: `SelfConfigTool` in `Tools/BuiltinTools.swift`.

### Skills system (v2 — Agent Skills standard)

Directory-based skills following the [Agent Skills specification](https://agentskills.io/specification).
Each skill is a directory with a `SKILL.md` entry point containing YAML frontmatter.
Executable skills have a `scripts/` subdirectory with Python scripts (run via `uv run --script`).

**Three tiers**:
- **Built-in**: Bundled in `Resources/Skills/` — immutable.
- **Personal**: User-created in `~/Library/Application Support/fae/skills/`.
- **Community**: Imported from URL (stored alongside personal skills).

**Two types**:
- **Instruction**: Markdown-only — body injected as LLM context on activation.
- **Executable**: Has `scripts/` with Python scripts invoked via `uv run`.

**Progressive disclosure**: System prompt includes only skill names + descriptions (~50-100 tokens each).
Full SKILL.md body is loaded into context only when activated via `activate_skill` tool.

Implementation files:

| File | Role |
|------|------|
| `Skills/SkillManager.swift` | Directory-based discovery, activation, execution, management, `updateSkill()`, `deactivate()` |
| `Skills/SkillTypes.swift` | `SkillMetadata`, `SkillRecord`, `SkillType`, `SkillTier`, `SkillHealthStatus` |
| `Skills/SkillParser.swift` | YAML frontmatter parser for SKILL.md |
| `Skills/SkillMigrator.swift` | One-time migration of legacy flat `.py` files to directory format |
| `Tools/SkillTools.swift` | `ActivateSkillTool`, `RunSkillTool`, `ManageSkillTool` (with `update` action) |
| `Core/PersonalityManager.swift` | Python/uv capability prompt + self-modification prompt + awareness self-adaptation |

### Built-in skills inventory

| Skill | Type | Scripts | Purpose |
|-------|------|---------|---------|
| `voice-identity` | Instruction | — | Speaker enrollment choreography, introduction flow, re-verification |
| `voice-tools` | Executable | 4 (normalize, prepare, compare, quality) | Audio file processing and voice quality tools |
| `channel-discord` | Executable | 1 (channel_discord) | Discord channel integration |
| `forge` | Executable | 4 (init, build, test, release) | Tool creation workshop — scaffold, compile, test, and release Zig/Python tools |
| `toolbox` | Executable | 5 (list, install, search, verify, uninstall) | Local tool registry — manage installed forge-built tools |
| `mesh` | Executable | 5 (discover, serve, publish, fetch, trust) | Peer discovery and tool sharing — Fae-to-Fae tool exchange |

### Forge skill (tool creation)

The Forge turns ideas into working tools. Scaffolds projects, compiles binaries, runs tests, and packages everything into installable Fae skills.

**Supported languages:**
- **Zig** — compiles to native ARM64 macOS binaries and optionally WebAssembly (WASM)
- **Python** — scripts executed via `uv run --script` with inline dependency declarations
- **Both** — hybrid projects with Zig for performance + Python for glue

**Directory layout:**
```
~/.fae-forge/
  workspace/{tool-name}/     # Active development projects (git repos)
  tools/{tool-name}/         # Released, installable skill packages
  bundles/                   # Git bundle archives for sharing
  registry.json              # Index of all released tools
```

**Scripts:** `init` (scaffold project), `build` (compile), `test` (run tests), `release` (build + package + git tag + bundle + registry update).

**Prerequisites:** Zig via `zb install zig`, wasmtime via `zb install wasmtime` (optional for WASM), git (pre-installed), uv (pre-installed with Fae).

Implementation: `Resources/Skills/forge/` (SKILL.md + MANIFEST.json + scripts/)

### Toolbox skill (local registry)

Manages Fae's local tool registry at `~/.fae-forge/`. Every installed tool is a skill directory containing SKILL.md, optional bin/scripts, and MANIFEST.json for integrity verification.

**Scripts:** `list` (show installed tools, detect orphans), `install` (from git bundle or directory with SHA-256 verification), `search` (local + peer catalog search), `verify` (3-layer integrity: manifest validity + file checksums + git signatures), `uninstall` (remove with optional bundle preservation).

Implementation: `Resources/Skills/toolbox/` (SKILL.md + MANIFEST.json + scripts/)

### Mesh skill (peer sharing)

Enables Fae instances to discover each other and share forge-built tools over the local network or beyond.

**Discovery methods:**
- **Bonjour/mDNS** — automatic LAN discovery via `_fae-tools._tcp` service type
- **Manual** — add peers by IP address or hostname
- **x0x network** — global discovery via x0x DHT (future)

**Trust model:** Trust-On-First-Use (TOFU). First connection stores SSH public key fingerprint; subsequent connections verify against stored key. Key changes trigger warnings.

**Catalog server:** HTTP server exposes `GET /catalog`, `/tools/{name}/metadata`, `/tools/{name}/bundle`, `/health`. Forks into background daemon. Registers Bonjour service for auto-discovery.

**Scripts:** `discover` (find peers via Bonjour/manual), `serve` (HTTP catalog server with Bonjour), `publish` (announce tool to mesh), `fetch` (download + TOFU verify + install from peer), `trust` (manage peer trust store).

Implementation: `Resources/Skills/mesh/` (SKILL.md + MANIFEST.json + scripts/)

### Forge → Toolbox → Mesh workflow

The three skills form a complete tool lifecycle:

1. **Create**: `forge init` → `forge build` → `forge test` → `forge release`
2. **Manage**: `toolbox list` / `toolbox verify` / `toolbox uninstall`
3. **Share**: `mesh serve start` → `mesh publish` → peers run `mesh discover` → `mesh fetch`

All three are built-in skills using Python scripts executed via `uv run --script`. Zero Swift code changes — they leverage Fae's existing tool system (bash, read, write, run_skill).

## Rescue mode

Safe boot that bypasses all user customizations without deleting data.

| Component | Normal | Rescue Mode |
|-----------|--------|-------------|
| Soul contract | User's `soul.md` | Bundled default |
| Directive | `directive.md` | Empty (bypassed, not deleted) |
| Tool mode | config value (default: "full") | `read_only` |
| Scheduler | All 17 tasks active | Not started |
| Memory capture | Enabled | Disabled (recall still works) |
| Orb palette | Dynamic | Forced `.silverMist` |

Activation: **Help > Rescue Mode...** (Cmd+Opt+R) — always accessible even when pipeline is stuck. Stops pipeline, activates rescue flag, restarts with overrides. Deactivation reverses the process.

Visual indicators: orb forced to `.silverMist` palette, "Rescue Mode" capsule badge on ContentView.

Implementation: `Core/RescueMode.swift` (state), `FaeApp.swift` (menu + toggle), `FaeCore.swift` (rescue-aware start), `OrbStateBridgeController.swift` (palette enforcement).

## Git Vault (rolling backup)

Git-based rolling backup at `~/.fae-vault/` — survives app deletion and data directory wipes.

**Vault contents**: `fae.db` (VACUUM INTO), `scheduler.db`, `config.toml`, `directive.md`, `SOUL.md`, `speakers.json`, `skills/` mirror.

**Commit triggers**:
- Daily at 02:30 (via `vault_backup` scheduler task)
- On config change (config files only — fast)
- Pre-shutdown (full snapshot)

**Security**: 3-layer protection:
1. `PathPolicy` blocks `.fae-vault` in `blockedDotfiles` — tools cannot write to vault
2. POSIX perms: vault `data/` set to `0o555` after each commit
3. Git reflog: 90-day retention

**Rescue mode integration**: "Restore from Vault" shows commit history with dates, user picks a snapshot, `GitVaultManager.restore()` copies files back.

Implementation: `Backup/GitVaultManager.swift` (actor, uses `/usr/bin/git` via `Process()`)

## SoulManager

Manages SOUL.md as runtime config — bundled default, user-editable copy, loaded fresh every turn.

| Method | Purpose |
|--------|---------|
| `defaultSoul()` | Read bundled `Resources/SOUL.md` |
| `loadSoul()` | Read user copy, fall back to bundled default |
| `saveSoul(_:)` | Write to user path |
| `resetToDefault()` | Copy bundled default over user copy |
| `ensureUserCopy()` | Copy bundled default if user file doesn't exist |
| `isModified` | Whether user copy differs from bundled default |
| `lineCount` | Line count of current soul |

User path: `~/Library/Application Support/fae/soul.md`

Implementation: `Core/SoulManager.swift`

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

### Legacy morning briefing

`FaeScheduler.runMorningBriefing()` runs daily at 08:00 — **suppressed when enhanced morning briefing is active** (awareness system). Queries memory for recent commitments, events, and people, compiles a brief summary (1-3 sentences), speaks via `speakHandler`.

### Noise budget

`proactiveInterjectionCount` tracks daily proactive messages. Reset at midnight by `noise_budget_reset` scheduler task.

## Proactive awareness system (v0.8.82)

Fae can proactively see users via camera, monitor screen activity, research overnight, and deliver enhanced morning briefings. Everything runs on-device. Requires explicit user consent before any camera/screen use.

### Architecture: three layers + five skills

**Swift layers** (minimal scaffolding):
1. `injectProactiveQuery()` on PipelineCoordinator — scheduler-triggered full LLM conversation with tools
2. `AwarenessConfig` in FaeConfig — consent state + per-feature toggles
3. TrustedActionBroker scheduler bypass — auto-allow camera/screenshot for consented scheduled observations

**Skills** (LLM-driven behavior):
1. `proactive-awareness` — camera observation: greetings, mood, stranger detection, presence tracking
2. `screen-awareness` — screenshot observation: activity context, task detection
3. `overnight-research` — quiet-hours research using web_search + memory
4. `morning-briefing-v2` — enhanced briefing: calendar, mail, research findings, birthdays
5. `first-launch-onboarding` — camera greeting → contact lookup → voice enrollment → awareness consent

### Consent model

**No silent behavior changes.** Vision and awareness are NEVER auto-enabled. Users must explicitly opt in via:
- Voice: "Fae, set up awareness" → activates `first-launch-onboarding` skill (interactive consent flow)
- Settings: Awareness tab → "Set Up Proactive Awareness" button → triggers onboarding flow
- Onboarding asks for explicit confirmation BEFORE any camera or screen capture

Consent timestamp stored as `awareness.consentGrantedAt` (ISO8601). Double-checked at runtime: both `awareness.enabled == true` AND `consentGrantedAt != nil` required.

### `injectProactiveQuery()` — scheduler→pipeline bridge

```swift
func injectProactiveQuery(
    prompt: String, silent: Bool, taskId: String,
    allowedTools: Set<String>, consentGranted: Bool
) async
```

Key design decisions:
- **Guards**: Returns early if `assistantGenerating || assistantSpeaking` (never interrupts active conversation)
- **Per-request immutable context**: `ProactiveRequestContext` struct passed through the call stack (processTranscription → generateWithTools → executeTool). NOT a shared mutable field — prevents actor reentrancy races.
- **Tool restriction**: `executeTool()` rejects any tool not in `proactiveContext.allowedTools`
- **Tagged messages**: Each proactive turn assigns a `conversationTag` (e.g., `"camera_presence_check-1709550000"`). Added to `LLMMessage.tag`. Cleaned up via `removeMessages(taggedWith:)` after the turn completes.
- **Thinking**: Forces `suppressThinking = true` for speed

### `ProactiveRequestContext`

```swift
struct ProactiveRequestContext: Sendable {
    let source: ActionSource        // .scheduler
    let taskId: String              // e.g. "camera_presence_check"
    let allowedTools: Set<String>   // strict per-task allowlist
    let consentGranted: Bool        // per-request consent state
    let conversationTag: String     // for tagged message cleanup
}
```

### TrustedActionBroker — scheduler policy

Scheduler-sourced actions follow a strict evaluation path with **no fallthrough** to normal policy:

1. Check `intent.schedulerConsentGranted` — deny if no consent (per-request, NOT cached at init)
2. Check `intent.schedulerTaskId` maps to a known allowlist
3. Check tool against `schedulerDeniedTools` (write, edit, bash, manage_skill, self_config) — always denied
4. Check tool against task-specific allowlist — deny if not listed

**Per-task tool allowlists** (each task gets minimum required tools):

| Task | Allowed Tools |
|------|---------------|
| `camera_presence_check` | `camera` |
| `screen_activity_check` | `screenshot` |
| `overnight_work` | `web_search`, `fetch_url`, `activate_skill` |
| `enhanced_morning_briefing` | `calendar`, `reminders`, `contacts`, `mail`, `notes`, `activate_skill` |

### AwarenessThrottle

Lightweight utility gating awareness observations. Returns `ThrottleDecision`:
- `.skip(reason:)` — don't run at all
- `.silentOnly` — run but suppress speech
- `.normal` — full behavior

Checks (in order):
1. **Master gate**: `awareness.enabled && consentGrantedAt != nil`
2. **Battery**: skip when on battery + `pauseOnBattery` (via IOKit `IOPSCopyPowerSourcesInfo`)
3. **Thermal**: skip when `.serious`/`.critical` (via `ProcessInfo.processInfo.thermalState`)
4. **Quiet hours (22:00-07:00)**: camera → `.silentOnly`, screen → `.skip`, overnight_work → `.normal`

Additional throttle helpers:
- `shouldReduceFrequency(lastUserSeenAt:)` — reduce to 5min interval when user absent >30min
- `randomJitter()` — ±5s jitter on timers to prevent synchronized VLM spikes

### Morning briefing trigger (deferred, not fixed-time)

The enhanced morning briefing does NOT fire at a fixed time. It triggers on **first user detection after 07:00**:

1. **Primary**: Camera detects user → `proactivePresenceHandler` calls `notifyUserDetectedPostQuietHours()` → triggers briefing
2. **Fallback**: If camera is disabled or user not detected by camera, `userInteractionHandler` calls `checkMorningBriefingFallback()` on first voice/text interaction after 07:00
3. **Daily reset**: `morningBriefingDelivered` flag reset at 00:00, prevents duplicate briefings

### Screen context coalescing

Screen observations run frequently (every 19s) but context is only persisted when meaningful:
- `shouldPersistScreenContext(contentHash:)` on FaeScheduler
- Only persist when SHA256 hash of VLM description changes (different app/document) OR 2 minutes elapsed
- Single updatable `screen_context_current` memory record (`.episode` kind) — not appends

### Handler closures (FaeCore wiring)

FaeCore wires three handler closures connecting PipelineCoordinator and FaeScheduler:

| Handler | Set on | Called from | Purpose |
|---------|--------|-------------|---------|
| `userInteractionHandler` | PipelineCoordinator | User voice/text turns | Morning briefing fallback trigger |
| `proactivePresenceHandler` | PipelineCoordinator | Camera observation results | Record user presence, trigger morning briefing |
| `proactiveScreenContextHandler` | PipelineCoordinator | Screen observation results | SHA256 hash-based persistence gating |

### Awareness skill lifecycle

`FaeCore.syncAwarenessSkills(skillManager:)` activates/deactivates skills based on config:
- `proactive-awareness` — activated when `awareness.enabled && cameraEnabled`
- `screen-awareness` — activated when `awareness.enabled && screenEnabled`
- `overnight-research` — activated when `awareness.enabled && overnightWorkEnabled`
- `morning-briefing-v2` — activated when `awareness.enabled && enhancedBriefingEnabled`
- `first-launch-onboarding` — activated on demand (onboarding command)

Skills can self-modify: the LLM can use `manage_skill create` to override built-in skills with personal copies, or `manage_skill update` to modify personal skills directly.

### Onboarding flow

The `first-launch-onboarding` skill guides an 8-step interactive consent flow:

1. Voice introduction (no camera yet)
2. Voice enrollment (if not already done)
3. Contact lookup (name, birthday, relationships)
4. **Awareness consent** (explicit ask BEFORE any camera use)
5. Enable awareness (only after "yes") — sets `vision.enabled`, `awareness.enabled`, all sub-features
6. Camera greeting (only AFTER consent + permissions)
7. Schedule preferences
8. Welcome

**Onboarding uses `injectText()` (interactive path)**, NOT `injectProactiveQuery()` — because the broker denies `self_config` from scheduler source, and onboarding needs to modify settings.

### Existing user upgrade

No silent behavior changes. Existing users see a one-time spoken prompt: "I've learned some new tricks..." with instructions to say "Fae, set up awareness" or visit Settings. Vision stays off, awareness stays off until explicit opt-in.

### Implementation files

| File | Role |
|------|------|
| `Core/FaeConfig.swift` | `AwarenessConfig` struct + `[awareness]` section in config.toml |
| `Pipeline/PipelineCoordinator.swift` | `injectProactiveQuery()`, `ProactiveRequestContext`, handler closures |
| `Scheduler/FaeScheduler.swift` | 4 awareness tasks, proactiveQueryHandler, tracking state, screen coalescing |
| `Scheduler/AwarenessThrottle.swift` | Battery/thermal/quiet-hours gating, adaptive frequency, jitter |
| `Tools/TrustedActionBroker.swift` | Scheduler auto-allow path, per-task allowlists, `schedulerAutoAllowed` reason code |
| `Core/FaeCore.swift` | `refreshAwarenessRuntime()`, `syncAwarenessSkills()`, handler wiring, onboarding command |
| `Core/PersonalityManager.swift` | Awareness settings in selfModificationPrompt, skill self-adaptation |
| `SettingsAwarenessTab.swift` | Awareness settings UI tab |
| `Pipeline/ConversationState.swift` | `removeMessages(taggedWith:)` for proactive message cleanup |
| `Core/FaeTypes.swift` | `LLMMessage.tag` field for proactive message tagging |
| `Resources/Skills/proactive-awareness/SKILL.md` | Camera observation: greetings, mood, presence, strangers |
| `Resources/Skills/screen-awareness/SKILL.md` | Silent screen context monitoring |
| `Resources/Skills/overnight-research/SKILL.md` | Quiet-hours web research |
| `Resources/Skills/morning-briefing-v2/SKILL.md` | Enhanced morning briefing |
| `Resources/Skills/first-launch-onboarding/SKILL.md` | 8-step consent-first onboarding flow |

## Prompt/identity stack

`PersonalityManager.assemblePrompt()` builds the system prompt:

1. Core system prompt (identity, style, warmth, companion presence)
2. SOUL contract — loaded via `SoulManager.loadSoul()` (user copy, falls back to bundled default)
3. User name context (when known from memory)
4. Directive (from `directive.md` — critical overriding instructions, usually empty)
5. Memory context (injected by MemoryOrchestrator.recall)
6. Tool schemas (when tools available — LLM sees full tool definitions inline)
7. Available skills — names + descriptions for progressive disclosure (from `SkillManager.promptMetadata()`)
8. Activated skill instructions — full SKILL.md body for active skills
9. Python/uv capability prompt (when tools available)
10. Self-modification prompt (when tools available)
11. Vision + computer use prompt (when vision enabled)
12. Proactive behavior prompt (when tools available)

In **rescue mode**, step 2 uses the bundled default soul and step 4 uses empty string (bypassed, not deleted).

Implementation: `Core/PersonalityManager.swift`

Human contract document: `SOUL.md` (bundled at `Resources/SOUL.md`, user copy at `~/Library/Application Support/fae/soul.md`)

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
- **Sentence-queued TTS**: After LLM finishes, Fae synthesises and plays sentence 1 while sentence 2 queues. Time-to-first-audio scales with sentence length, not full response length. (Kokoro-82M is non-streaming; it synthesises one complete audio buffer per call.)

These feedback mechanisms are not cosmetic — they are the primary UX that makes Fae usable despite the inherent latency of on-device ML inference.

## Echo suppression and barge-in

Fae's own voice through speakers can be picked up by the mic, causing false transcriptions and self-interruptions. The echo suppressor and barge-in system work together to prevent this.

### Echo suppressor (EchoSuppressor.swift)

- **Active suppression**: drops all speech segments while `assistantSpeaking = true`
- **Echo tail**: after speech ends, suppresses for 3500ms (no AEC) to catch room reverb
- **Short utterance guard**: 6000ms post-speech, drops segments < 0.5s
- **Amplitude ceiling**: drops segments with RMS > 0.12 (speaker bleedthrough)
- **`isInSuppression`**: computed property combining active + echo tail states — used by barge-in gating

### Barge-in (PipelineCoordinator)

Barge-in allows the user to interrupt Fae mid-speech. Echo-aware gating prevents false triggers:

- **Echo-aware**: `pendingBargeIn` only created when `!echoSuppressor.isInSuppression` — Fae's own voice cannot trigger barge-in
- **Holdoff**: `lastAssistantStart` set in `speakText()` enables 500ms grace period after speech begins
- **Confirmation**: speech must persist for `confirmMs` (150ms) at `minRms` (0.05) before barge-in fires
- **Live toggle**: `bargeInEnabledLive` override via Settings > General > Voice Interaction
- **Streaming echo text**: `lastAssistantResponseText` accumulated during streaming (not just at end) so text-overlap detector catches current-turn echo

### Settings

Settings > General > Voice Interaction:
- **Allow barge-in**: toggle on/off. Uses `@AppStorage("bargeInEnabled")` → `FaeCore.setBargeInEnabled()` → `PipelineCoordinator.setBargeInEnabled()`
- Config patch key: `"barge_in.enabled"`

## Configuration

Config file: `~/Library/Application Support/fae/config.toml`

```toml
[llm]
maxTokens = 512
contextSizeTokens = 16384
temperature = 0.7
voiceModelPreset = "auto"
dualModelEnabled = true
conciergeModelPreset = "auto"   # auto = LiquidAI/LFM2-24B-A2B-MLX-4bit on 32+ GB
dualModelMinSystemRAMGB = 32
keepConciergeHot = true
allowConciergeDuringVoiceTurns = true

[memory]
enabled = true
maxRecallResults = 6

[speaker]
# Speaker recognition is always on (no enabled toggle)
threshold = 0.70
ownerThreshold = 0.75
requireOwnerForTools = false
progressiveEnrollment = true
maxEnrollments = 50

[bargeIn]
enabled = true
minRms = 0.05
confirmMs = 150
assistantStartHoldoffMs = 500
bargeInSilenceMs = 600

[conversation]
requireDirectAddress = false
directAddressFollowupS = 20

[vision]
enabled = false
modelPreset = "auto"

[awareness]
enabled = false
cameraEnabled = false
screenEnabled = false
cameraIntervalSeconds = 30
screenIntervalSeconds = 19
overnightWorkEnabled = false
enhancedBriefingEnabled = false
pauseOnBattery = true
pauseOnThermalPressure = true
# consentGrantedAt = "2026-03-04T10:00:00Z"  # Set when user explicitly consents
```

Data paths:
- Config: `~/Library/Application Support/fae/config.toml`
- Memory: `~/Library/Application Support/fae/fae.db`
- Soul contract: `~/Library/Application Support/fae/soul.md`
- Directive: `~/Library/Application Support/fae/directive.md`
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
| `Core/FaeCore.swift` | Lightweight facade: config, ModelManager, PipelineCoordinator, Scheduler, awareness wiring |
| `Core/FaeConfig.swift` | Model selection, TTS config, tool mode, speaker config, awareness config |
| `Core/FaeEventBus.swift` | Combine-based event bus |
| `Core/FaeEvent.swift` | Event types |
| `Core/FaeTypes.swift` | Shared type definitions (LLMMessage with `tag` for proactive cleanup) |
| `Core/PersonalityManager.swift` | System prompt assembly with tool schemas, self-mod, proactive |
| `Core/MLProtocols.swift` | ML engine protocols (STT, LLM, TTS, Embedding, Speaker) |
| `Core/VoiceCommandParser.swift` | Voice command detection (show/hide conversation, etc.) |
| `Core/SentimentClassifier.swift` | Sentiment analysis for orb mood |
| `Core/CredentialManager.swift` | Keychain credential management |
| `Core/SoulManager.swift` | Soul lifecycle: load, save, reset, ensure user copy (bundled default → user dir) |
| `Core/RescueMode.swift` | Rescue mode state (ObservableObject): safe boot bypassing customizations |
| `Core/DiagnosticsManager.swift` | Diagnostics and debug info |
| `Core/InferencePriorityController.swift` | Actor serialising GPU access: operator (0) > Kokoro TTS (1) > concierge (2); parks lower-priority work via `CheckedContinuation` |
| `Core/PermissionStatusProvider.swift` | macOS permission status checks |
| `Core/IntroCrawl.swift` | Intro text crawl animation |

### ML Engines

| File | Role |
|------|------|
| `ML/ModelManager.swift` | Loads STT, LLM, TTS, Speaker engines; on-demand VLM loading; `loadConciergeIfNeeded()`; tracks degraded mode and restart diagnostics |
| `ML/WorkerLLMEngine.swift` | `actor WorkerLLMEngine: LLMEngine` — wraps a child process (`fae --llm-worker`); JSON-lines stdin/stdout protocol; 30s command timeout; auto model-restore on restart |
| `ML/LLMWorkerProtocol.swift` | `LLMWorkerRequest` + `LLMWorkerResponse` Codable types for worker IPC protocol |
| `ML/MLXSTTEngine.swift` | Qwen3-ASR speech-to-text via mlx-swift |
| `ML/MLXLLMEngine.swift` | Qwen3 LLM inference via mlx-swift (used inside worker subprocess) |
| `ML/KokoroMLXTTSEngine.swift` | **Active TTS** — Kokoro-82M via KokoroSwift/MLX; pre-computed `.bin` voice embeddings |
| `ML/KokoroPythonTTSEngine.swift` | Alternative TTS — Kokoro-82M via ONNX Runtime Python subprocess |
| `ML/MLXTTSEngine.swift` | Legacy TTS — Qwen3-TTS via mlx-audio-swift (retained, not active) |
| `ML/MLXVLMEngine.swift` | Qwen3-VL vision-language model inference via MLXVLM (on-demand) |
| `ML/MLXEmbeddingEngine.swift` | Hash-384 embedding engine for semantic search |
| `ML/CoreMLSpeakerEncoder.swift` | ECAPA-TDNN Core ML speaker embedding |
| `ML/SpeakerProfileStore.swift` | Speaker profile enrollment, matching, persistence |

### Pipeline

| File | Role |
|------|------|
| `Pipeline/PipelineCoordinator.swift` | Unified pipeline: STT → LLM (with tools) → TTS; dual-model routing via `TurnRoutingPolicy`; `injectProactiveQuery()`, `ProactiveRequestContext` |
| `Pipeline/TurnRoutingPolicy.swift` | `TurnLLMRoute` enum + `TurnRoutingPolicy.decide()` — routes turns to operator or concierge model |
| `Pipeline/EchoSuppressor.swift` | Time-based + text-overlap + voice identity echo filtering; `isInSuppression` for barge-in gating |
| `Pipeline/VoiceActivityDetector.swift` | Voice activity detection |
| `Pipeline/VoiceTagParser.swift` | `VoiceSegment` + `VoiceTagStripper` for multi-voice roleplay |
| `Pipeline/ConversationState.swift` | Conversation history management; `removeMessages(taggedWith:)` for proactive cleanup |
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
| `Tools/SkillTools.swift` | Skill tools (activate_skill, run_skill, manage_skill with `update` action) |
| `Tools/AppleTools.swift` | Apple integration tools (calendar, contacts, mail, reminders, notes) |
| `Tools/SchedulerTools.swift` | Scheduler management tools |
| `Tools/Tool.swift` | Tool protocol definition |
| `Tools/ToolRegistry.swift` | Dynamic registration, schema generation, mode filtering |
| `Tools/PathPolicy.swift` | Write-path validation (dotfile/system path blocklist; `.fae-vault` blocked) |
| `Tools/InputSanitizer.swift` | Shell metacharacter detection, bash command classification |
| `Tools/ToolRateLimiter.swift` | Per-tool sliding-window rate limiter |
| `Tools/ToolRiskPolicy.swift` | Risk-level → approval routing |
| `Tools/VisionTools.swift` | Vision + computer use tools (screenshot, camera, read_screen, click, type_text, scroll, find_element) |
| `Tools/VoiceIdentityTool.swift` | Voice identity tool: check_status, collect_sample, confirm_identity, rename_speaker, list_speakers |
| `Tools/AccessibilityBridge.swift` | macOS Accessibility API wrapper for UI interaction (AXUIElement) |

### Audio

| File | Role |
|------|------|
| `Audio/AudioCaptureManager.swift` | Microphone capture (16kHz mono) |
| `Audio/AudioPlaybackManager.swift` | Audio playback with barge-in support |
| `Audio/AudioToneGenerator.swift` | Thinking tone (A3→C4, 300ms), listening tone (C5→E5, 200ms), ready beep (G5, 150ms) |

### Scheduler, Skills & Backup

| File | Role |
|------|------|
| `Scheduler/FaeScheduler.swift` | Background task scheduler with speak handler + proactive query handler (17 tasks) |
| `Scheduler/AwarenessThrottle.swift` | Battery/thermal/quiet-hours gating for awareness observations |
| `Skills/SkillManager.swift` | Directory-based skill discovery, activation, execution, management, `updateSkill()`, `deactivate()` |
| `Skills/SkillTypes.swift` | `SkillMetadata`, `SkillRecord`, `SkillType`, `SkillTier`, `SkillHealthStatus` |
| `Skills/SkillParser.swift` | YAML frontmatter parser for SKILL.md files |
| `Skills/SkillMigrator.swift` | One-time migration of legacy flat `.py` files to directory format |
| `Skills/SkillManifest.swift` | `MANIFEST.json` schema: capabilities, allowedTools, riskTier, SHA-256 integrity |
| `Backup/GitVaultManager.swift` | Git-based rolling backup vault at `~/.fae-vault/` |

### Orb & Window

| File | Role |
|------|------|
| `NativeOrbView.swift` | Metal-rendered orb |
| `OrbAnimationState.swift` | Orb animation state machine |
| `OrbTypes.swift` | OrbMode, OrbFeeling, OrbPalette enums |
| `OrbStateBridgeController.swift` | Maps events to orb visual state |
| `WindowStateController.swift` | Adaptive window (collapsed 120x120 / compact 340x500); dynamic height expansion |
| `NSWindowAccessor.swift` | NSWindow property access from SwiftUI |
| `VisualEffectBlur.swift` | NSVisualEffectView wrapper |

### Conversation & Canvas

| File | Role |
|------|------|
| `ConversationController.swift` | Conversation state (messages, listening, streaming text) |
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
| `ApprovalOverlayController.swift` | Tool approval + input-request lifecycle |
| `ApprovalOverlayView.swift` | Floating approval card (Yes/No) + input card (text/password) |

### Settings

| File | Role |
|------|------|
| `SettingsView.swift` | TabView settings |
| `SettingsGeneralTab.swift` | General settings (audio, barge-in toggle, window behavior) |
| `SettingsModelsTab.swift` | Model selection and download |
| `SettingsModelsPerformanceTab.swift` | Dual-model toggle + concierge model picker |
| `SettingsSpeakerTab.swift` | Voice identity configuration |
| `SettingsToolsTab.swift` | Tool mode picker + PolicyProfile selector |
| `SettingsPersonalityTab.swift` | Personality: soul contract, custom instructions, rescue mode |
| `SettingsSchedulesTab.swift` | Scheduler task configuration |
| `SettingsChannelsTab.swift` | Channel configuration |
| `SettingsSkillsTab.swift` | Unified skill display with type/tier badges, Apple apps, system capabilities |
| `SettingsAwarenessTab.swift` | Proactive awareness settings (consent, camera, screen, overnight, briefing, resource toggles) |
| `SettingsAboutTab.swift` | About, version info |
| `SettingsDiagnosticsTab.swift` | Runtime diagnostics: operator/concierge loaded, current route, fallback reason, restart counts, last worker errors |
| `SettingsDeveloperTab.swift` | Developer diagnostics (Option-held) + security dashboard |
| `PersonalityEditorController.swift` | Opens soul.md / directive.md in system text editor |

### System & Misc

| File | Role |
|------|------|
| `AudioDevices.swift` | Audio device enumeration |
| `Core/GlobalHotkeyManager.swift` | Global Ctrl+Shift+A hotkey via Accessibility API |
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
| `.faeCancelGeneration` | Cancels in-flight LLM generation (Cmd+. or stop button) |
| `.faeInputRequired` | Pipeline needs text input from user (shown as overlay card) |
| `.faeInputResponse` | User submitted or cancelled the input card |

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

Auto mode selects based on system RAM (Qwen3.5 at every tier):

**Auto mode** (current policy — 2B/0.8B for low-latency operator role):

| System RAM | Auto Operator | Context | Concierge |
|------------|--------------|---------|-----------|
| ≥32 GB | Qwen3.5-2B | 32K | LFM2-24B-A2B at 128K |
| 12–31 GB | Qwen3.5-2B | 32K | — |
| <12 GB | Qwen3.5-0.8B | 32K | — |

All Qwen3.5 models have native `max_position_embeddings` = **262,144**. Fae caps at practical
limits to control KV-cache RAM. LFM2-24B MLX-4bit export supports **128K** natively.

**Manual presets** (full Qwen3.5 lineup):

| Preset | Model | Fae Context | Native Max |
|--------|-------|------------|-----------|
| `qwen3_5_35b_a3b` | Qwen3.5-35B-A3B | 128K | 262K |
| `qwen3_5_27b` | Qwen3.5-27B | 128K | 262K |
| `qwen3_5_9b` | Qwen3.5-9B | 128K | 262K |
| `qwen3_5_4b` | Qwen3.5-4B | 32K | 262K |
| `qwen3_5_2b` | Qwen3.5-2B | 32K | 262K |
| `qwen3_5_0_8b` | Qwen3.5-0.8B | 32K | 262K |

Legacy Qwen3 presets (`qwen3_8b`, `qwen3_4b`, `qwen3_1_7b`, `qwen3_0_6b`) are silently migrated to the nearest Qwen3.5 equivalent.

Key metrics: T/s at voice context, thinking suppression compliance, idle RAM, answer quality.

## Thinking Mode Implementation

**Qwen3.5-35B-A3B** (primary — NEVER use `/no_think`):
- `/no_think` per-turn suffix was removed from Qwen3.5 — has no effect
- Correct suppression: `enable_thinking: false` in `UserInput.additionalContext` (→ chat template kwargs)
- With thinking enabled: model emits `<think>...</think>` as literal text; ThinkTagStripper handles it
- `ThinkTagStripper.hasExitedThinkBlock` signals when think block exits; pipeline sets `thinkEndSeen = true`

**Qwen3 small models** (1.7B/4B/8B):
- `<think>` = special empty token (decoded to `""` — not visible text)
- `</think>` = literal text
- Handled by `thinkAccum` buffer in `PipelineCoordinator` (waits for literal `</think>`)

**Key files**: `ML/MLXLLMEngine.swift` (additionalContext), `Pipeline/TextProcessing.swift` (ThinkTagStripper), `Pipeline/PipelineCoordinator.swift` (thinkAccum + hasExitedThinkBlock), `Core/FaeTypes.swift` (GenerationOptions.suppressThinking)

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
- **v1.0.0** — UX overhaul: orb enchantment, streaming, canvas feed, stop, hotkey, input flow
  - Orb: `tremor`, `sparkleIntensity`, `liquidFlow`, `radiusBias` Metal shader params; stronger feeling presets (delight sparkles, concern trembles, playful chaotic); burst amplitude 0.06→0.12
  - Conversation streaming: live `StreamingBubble` with blinking cursor; token-by-token updates; auto-scroll
  - Canvas activity feed: `ActivityCard` system with glassmorphic cards; per-tool SF Symbols; turn archiving; auto-open on tool call
  - Stop button: red stop.fill button replaces send while generating; `PipelineCoordinator.cancel()`; Cmd+. menu shortcut
  - Global hotkey: `GlobalHotkeyManager` (Ctrl+Shift+A) via `AXIsProcessTrustedWithOptions`; Settings shortcut display
  - Message box expansion: window grows dynamically with text (max 700pt); top edge fixed; auto-releases on submit
  - Input-required flow: `InputRequestBridge` actor with 120s timeout; `InputRequestTool` for LLM; floating `InputCard` overlay with SecureField support; `.faeInputRequired`/`.faeInputResponse` notifications
  - Rescue mode: safe boot bypassing customizations (read_only tools, default soul, no scheduler, silverMist palette); Help menu toggle (Cmd+Opt+R)
  - SoulManager: SOUL.md as runtime config — bundled default, user-editable copy at `~/Library/Application Support/fae/soul.md`, loaded fresh every turn
  - Personality editor: Edit menu (Cmd+Shift+E soul, Cmd+Shift+I instructions); Settings > Personality tab with soul/instructions/rescue controls
  - PersonalityEditorController: opens soul.md and directive.md in system default text editor
- **v1.1.0** — Data Vault, Skills v2, Instruction Clarity
  - Git Vault: rolling backup at `~/.fae-vault/` using system git — survives app deletion
  - GitVaultManager actor: VACUUM INTO for SQLite, daily/config-change/pre-shutdown commits
  - PathPolicy: `.fae-vault` in blockedDotfiles — tools cannot write to vault
  - Skills v2: directory-based skills following Agent Skills specification (agentskills.io)
  - Progressive disclosure: skill names + descriptions in system prompt, full body on activation
  - Three tiers (built-in/personal/community), two types (instruction/executable)
  - SkillParser: YAML frontmatter parser for SKILL.md
  - SkillMigrator: one-time migration of legacy flat `.py` files to directory format
  - ActivateSkillTool, RunSkillTool (with multi-script support), ManageSkillTool
  - Built-in skill: voice-tools (4 scripts: normalize, prepare, compare, quality check)
  - Directive rename: `custom_instructions.txt` → `directive.md` with backward-compatible aliases
  - SelfConfigTool actions: `get_directive`, `set_directive`, `append_directive`, `clear_directive`
  - Prompt label: "User directive (critical instructions — follow these in EVERY conversation)"
  - Scheduler: 13th task `vault_backup` at 02:30 daily
  - TrustedActionBroker: default-deny policy chokepoint with 3 PolicyProfile modes
  - CapabilityTicket: per-turn scoped grants with TTL
  - ReversibilityEngine: pre-mutation file checkpoints with 24h prune
  - SafeBashExecutor + SafeSkillExecutor: sandboxed execution
  - NetworkTargetPolicy: shared localhost/metadata/RFC1918 blocklist
  - OutboundExfiltrationGuard: novel recipient confirmation + sensitive payload detection
  - SecurityEventLogger: append-only JSONL with rotation + SensitiveDataRedactor
  - SkillManifest: SHA-256 integrity verification for skill files
  - Settings: PolicyProfile picker in Tools tab, security dashboard in Developer tab
- **v0.8.62** — Echo/barge-in fix: prevent garbled speech from self-interruption
  - Fixed `lastAssistantStart` never assigned — 500ms holdoff was dead code
  - Echo-aware barge-in gating via `EchoSuppressor.isInSuppression`
  - Streaming `lastAssistantResponseText` accumulation for current-turn echo detection
  - Barge-in toggle in Settings > General > Voice Interaction
  - Live `bargeInEnabledLive` override without pipeline restart
- **v0.8.72** — Vision + Computer Use: Fae can see the screen and interact with apps
  - MLXVLMEngine: on-demand Qwen3-VL inference via MLXVLM (RAM-tiered: 48+→8B, 24-47→4B, <24→disabled)
  - 7 new tools: screenshot, camera, read_screen, click, type_text, scroll, find_element (total: 30)
  - AccessibilityBridge: macOS AXUIElement wrapper for UI interaction
  - VisionConfig: `[vision]` section in config.toml + Settings > Models UI
  - JIT permissions: Screen Recording + Camera via JitPermissionController
  - TrustedActionBroker: policies for all 7 vision/computer use tools
  - Computer use step limiter: max 10 action steps per turn
  - PersonalityManager: expanded visionPrompt + new computerUsePrompt
- **v0.8.74** — Voice Pipeline Overhaul: TTS consistency, timestamps, diarization, conversational voice identity
  - Phase 1A: Remove emotional prosody → instruct mode path (was switching from voice clone to text description)
  - Phase 1A: Remove SentimentClassifier.ttsInstruct(), Emotional Prosody toggle, Voice Warmth slider
  - Phase 1B: Add wall-clock `capturedAt` timestamps on SpeechSegment and STTResult
  - Phase 1B: Flow utterance timestamps through pipeline to memory capture (stored as `utterance_at` in metadata JSON)
  - Phase 2: Propagate speakerId to ALL memory record types (not just episodes)
  - Phase 2: Add multi-speaker awareness to system prompt
  - Phase 3: New VoiceIdentityTool (check_status, collect_sample, confirm_identity, rename_speaker, list_speakers)
  - Phase 3: New voice-identity built-in skill (SKILL.md) for Fae-driven enrollment
  - Phase 3: Ready beep tone (G5, 150ms, 0.12 vol) signals "speak now" before voice capture
  - Phase 3: Replace mechanical enrollment with conversational skill-driven flow
  - Phase 3: Speaker recognition always on (remove config.speaker.enabled gate)
  - Phase 3: Voice identity awareness + multi-speaker awareness in system prompt
  - Total: 31 tools (was 30)
- **v0.8.75** — Native Tool Calling: fix all 31 tools via MLX native tool calling integration
  - Root cause: `UserInput.tools` was never set, so Qwen3.5 chat template never activated tool calling mode
  - Tool.swift: `toolSpec` computed property converts string `parametersSchema` to native `ToolSpec` (JSON Schema format)
  - ToolRegistry.swift: `nativeToolSpecs(for:)` returns filtered `[ToolSpec]` by tool mode
  - GenerationOptions: new `tools` field carries native specs through to MLXLLMEngine
  - MLXLLMEngine: sets `UserInput.tools`, serializes `.toolCall` events back to `<tool_call>` text for existing parser
  - PipelineCoordinator: caches `currentNativeTools` for tool follow-up turns, wired alongside system prompt
  - PersonalityManager: when native tools active, uses behavioral guidance only (no inline schemas — chat template handles it)
  - Package.swift: fix resource bundle double-nesting (.copy("Resources") → individual entries)
  - ResourceBundle.swift: multi-marker bundle detection (Skills, default.metallib, SOUL.md)
- **v0.8.82** — Proactive Visual Awareness: camera presence, screen monitoring, overnight research, enhanced briefings
  - AwarenessConfig: `[awareness]` section in config.toml with master toggle, per-feature toggles, consent timestamp
  - PipelineCoordinator: `injectProactiveQuery()` with immutable `ProactiveRequestContext` passed through call stack (no shared mutable field)
  - TrustedActionBroker: scheduler auto-allow with strict per-task tool allowlists, no fallthrough, per-request consent via `intent.schedulerConsentGranted`
  - AwarenessThrottle: battery (IOKit), thermal (ProcessInfo), quiet hours (22:00-07:00), adaptive frequency, ±5s jitter
  - FaeScheduler: 4 new awareness tasks (camera_presence_check, screen_activity_check, overnight_work, enhanced_morning_briefing)
  - Screen context coalescing: SHA256 hash-based duplicate suppression, 2min minimum between persists
  - Morning briefing trigger: deferred until camera detects user after 07:00, with fallback on first voice/text interaction
  - Tagged message cleanup: `LLMMessage.tag` field + `removeMessages(taggedWith:)` — no "remove last N"
  - Handler closures: userInteractionHandler, proactivePresenceHandler, proactiveScreenContextHandler wired between PipelineCoordinator and FaeScheduler
  - Awareness skill lifecycle: `syncAwarenessSkills()` activates/deactivates skills per config toggles
  - ManageSkillTool: `update` action for personal skill modification; `SkillManager.deactivate()` method
  - 5 new built-in skills: proactive-awareness, screen-awareness, overnight-research, morning-briefing-v2, first-launch-onboarding
  - Onboarding uses interactive `injectText()` path (not scheduler source) — consent BEFORE camera, never pre-consent surveillance
  - SettingsAwarenessTab: full settings UI with consent dialog, toggles, interval pickers, resource management
  - Existing user upgrade: no silent behavior changes — spoken prompt + Settings entry point only
  - FaeCore: `refreshAwarenessRuntime()` consolidates config changes → scheduler restart → skill sync
  - Legacy morning briefing suppressed when enhanced briefing active
  - Total: 17 scheduler tasks (was 13), 31 tools (unchanged)
- **v1.2.0** — Fae Forge, Toolbox & Mesh: tool creation, registry, and peer sharing
  - Forge skill: scaffold Zig/Python/hybrid projects, compile ARM64 + WASM, test, release with git tags and bundles
  - Toolbox skill: local registry at `~/.fae-forge/`, install from git bundles, SHA-256 integrity verification, search local + peers
  - Mesh skill: Bonjour/mDNS discovery via `_fae-tools._tcp`, HTTP catalog server, TOFU trust model, peer-to-peer tool fetch
  - All implemented as built-in skills (Python scripts via `uv run`) — zero Swift code changes
  - Directory structure: `~/.fae-forge/` with workspace/, tools/, bundles/, registry.json, peers.json, trust-store.json
  - 14 new Python scripts across 3 skills (forge: 4, toolbox: 5, mesh: 5)
  - MANIFEST.json with SHA-256 per-file integrity checksums for all three skills
  - Generated `run.py` wrapper in released tools auto-selects native → WASM → Python execution
  - Total: 14 built-in skills (was 11)
- **v1.3.0** — Dual-model pipeline, worker subprocess architecture, CoWork web search, TTS switch to Kokoro
  - **Worker subprocess architecture**: each LLM engine runs as a child process (`fae --llm-worker --role [operator|concierge]`); JSON-lines stdin/stdout IPC; 30s command timeout; automatic model restore after crash/restart; restart count + last error persisted to UserDefaults
  - `WorkerLLMEngine` actor + `LLMWorkerProtocol` types (`LLMWorkerRequest`/`LLMWorkerResponse`)
  - `InferencePriorityController` actor: serialises GPU access across operator (0) > Kokoro TTS (1) > concierge (2); parks lower-priority tasks via `CheckedContinuation`
  - Dual-model: operator (Qwen3.5, fast, tool-capable) + concierge (LiquidAI/LFM2-24B-A2B-MLX-4bit, rich synthesis, no tools)
  - `TurnRoutingPolicy`: routes rich/long turns (summarize, brainstorm, ≥220 chars) to concierge; tool-biased and follow-up turns always to operator
  - New config keys: `dualModelEnabled`, `conciergeModelPreset`, `dualModelMinSystemRAMGB`, `keepConciergeHot`, `allowConciergeDuringVoiceTurns`
  - New types: `LocalPipelineMode`, `LocalLLMSelection`, `LocalModelStackPlan`; `recommendedLocalModelStack()` for settings overview
  - New files: `Pipeline/TurnRoutingPolicy.swift`, `ML/WorkerLLMEngine.swift`, `ML/LLMWorkerProtocol.swift`, `Core/InferencePriorityController.swift`
  - Vendored + patched `Vendor/kokoro-ios` + `Vendor/MisakiSwift` to remove forced `.dynamic` and fix duplicate-symbol warnings during worker execution
  - Expanded diagnostics in `SettingsDiagnosticsTab.swift`: operator/concierge load state, current route, fallback reason, restart counts, last worker errors
  - TTS switch: `KokoroMLXTTSEngine` (Kokoro-82M, KokoroSwift/MLX, pre-computed `.bin` embeddings, 24 kHz) replaces Qwen3-TTS; `MLXTTSEngine` retained as legacy
  - Sentence-queue TTS: `deferredSentenceQueue [String]` replaces single `deferredStreamingSpeech`; each sentence enqueued separately for shorter time-to-first-audio
  - CoWork web search: `CoworkWebSearchProvider` protocol; both `OpenAICompatibleCoworkProvider` and `AnthropicCoworkProvider` support native tool calling loop with `web_search`; up to 3 tool turns per submission
  - CoWork OpenRouter key fallback: `provider()` falls back to global `llm.openrouter.api_key` when per-agent key absent
  - Duplicate tool call guard: `seenToolCallSignatures: Set<String>` in PipelineCoordinator; blocks identical tool calls within a turn to prevent maxToolTurns loops
  - Deprecated calendar/reminders authorization APIs replaced in `OnboardingController.swift`
- **v1.4.0** — Thinking crawl, capability discovery, enrollment UX, code quality pass
  - **Inline thinking display**: replaced ThoughtBubbleView (floating panel) with `ThinkingCrawlView` (Star Wars text crawl inline in conversation) and `ThinkIconBubble` (brain icon after think completes). Both are `internal` so CoWork can reuse them. `ConversationBridgeController` defers `startStreaming()` to first response token so the crawl condition (`!isStreaming`) is correct during the think phase.
  - **ThoughtBubbleView removed**: `ThoughtBubbleView.swift` deleted; `AuxiliaryWindowManager` thoughtBubblePanel + observeThinkingState() removed; `SubtitleStateController` thinking-bubble methods removed; `PipelineAuxBridgeController` thinking observer removed.
  - **`TextProcessing.ThinkTagStripper`**: added `thinkChunk` property — accumulates think tokens per `process()` call for streaming display in `ConversationWindowView`.
  - **Capability discovery scheduler task**: `capability_discovery` fires at 14:00, minimum 3-day cadence; builds priority queue (voice_enrollment → morning_briefing → overnight_research → vision); uses `proactiveQueryHandler` with `activate_skill` allowed; `TrustedActionBroker` allowlist added; `surfacedDiscoveryItems` reset weekly.
  - **`capability-discovery` skill**: new built-in instruction skill. After user says yes, skill tells them the phrase to say (e.g. "Fae, set up morning briefing") — does NOT attempt setup tools directly (blocked by scheduler broker policy).
  - **`buildDiscoveryItems` refactored**: replaced file I/O + regex config parsing with injected `visionEnabled: Bool` (updated via `setVisionEnabled()`) and `speakerProfileStore?.hasOwnerProfile()` (injected via `setSpeakerProfileStore()`). Eliminated double-gate (removed `runDailyIfNeeded` wrapper, kept 3-day `lastCapabilityDiscoveryAt` check alone).
  - **`HEARTBEAT.md` updated**: added Capability Discovery section covering one-thing-at-a-time, grounded-in-observation, own-the-setup principles.
  - **Wake word threshold lowered**: `acousticWakeThreshold` 0.82 → 0.65 for better "hi Fae" reliability.
  - **Enrollment banner fix**: `hasOwnerSetUp` now initialises from `UserDefaults("fae.owner.enrolled")` so the "Let me get to know you" banner is hidden immediately on launch when already enrolled. Persisted on enrollment complete and cleared on reset.
  - **`VoiceIdentityTool.show_enrollment_panel`**: new action opens native recording panel via `.faeStartNativeEnrollmentRequested` notification. `voice-identity` SKILL.md updated to use panel-first flow.
  - **Unsolicited awareness tasks fixed**: `enhanced_morning_briefing` and `overnightWorkEnabled` disabled in config when `consentGrantedAt = nil` to prevent web search loop without consent.
  - **`VoiceIdentityTool.showEnrollmentPanel`**: removed redundant `DispatchQueue.main.async` wrapper (tool execution already on main thread).
  - **Enrollment banner persistence**: `hasOwnerSetUp` initialises from `UserDefaults("fae.owner.enrolled")` — seeded synchronously from `speakers.json` in `FaeCore.init` to avoid flash before async actor check completes. Persisted on enrollment complete, cleared on reset.
- **v1.4.1** — CoWork approval flow fixes + camera tool fix
  - **CoWork approval dialog positioning**: `AuxiliaryWindowManager.showApproval(anchor:)` now centers the panel over large windows (height > 400pt) instead of floating off the top edge. Added `clampToScreenFrame(_:screen:)` overload that accepts an explicit `NSScreen` — uses the anchor window's screen rather than the orb window's screen, fixing multi-monitor misplacement.
  - **`FaeLocalRuntimeServer.awaitOutcome()` fix**: no longer bails out immediately when an approval dialog appears. Keeps polling (120s deadline) until the turn completes after the user approves or denies. Only reports `.pendingApproval` if the deadline expires with approval still pending.
  - **Camera tool fix**: replaced `AVCapturePhotoOutput` with `AVCaptureVideoDataOutput` in `CameraFrameCapture`. The original implementation triggered an ObjC runtime crash (`NSKVONotifying_AVCapturePhotoOutput not linked into application`) because `AVCapturePhotoOutput`'s KVO proxy class is not resolved in the macOS app context. The new implementation captures the first video frame via `AVCaptureVideoDataOutputSampleBufferDelegate`, converting `CMSampleBuffer → CVPixelBuffer → CGImage` via `CIContext`.
