# CLAUDE.md — Fae Implementation Guide

> **Current workflow:** Orb-first. The Rust orb host (`native/rust/fae-ui-shell`, tao + wgpu + muda + wry) is the ONLY product UI; the Swift app (`native/macos/Fae`) hosts the voice pipeline, memory, tools, and skills. `just run-dev` and `just run-native-with-ui-shell` (top-level justfile) both build and embed the orb host into the app bundle. The daemon LLM lane (`llm.useDaemonEngine`) routes conversation turns to `fae-daemon` (`crates/`) running Gemma 4 E4B via mistral.rs; the in-process Swift MLX engine is the fallback + training substrate.

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

All commands run from the **repo root** (top-level justfile). Use `just <recipe>` — never raw `swift`/`cargo` commands.

```bash
just --list                   # Show all available recipes
just build                    # Build Fae (debug, xcodebuild — compiles Metal shaders)
just build-release            # Build release
just test                     # Run all tests (swift test)
just check                    # Full validation (build + test)
just build-ui-shell           # Build the Rust orb host (native/rust/fae-ui-shell)
just check-ui-shell           # fmt + clippy -D warnings + check for the orb host
just run-dev                  # DEV profile: orb host embedded, isolated config/memory (fae-dev)
just run-native               # Build, bundle, sign, launch (production)
just run-native-with-ui-shell # Production launch with the orb host embedded
just clean                    # Clean build artifacts
```

Daemon workspace: `cd crates && just check` (fmt + clippy -D warnings + tests).

**Launch from project root**: `source ~/.secrets && just run-dev` — NEVER open `.build/` artifacts directly.

## Release-validation contract

Canonical validation source: `docs/checklists/app-release-validation.md`.

Required for: model swaps, prompt/routing changes, voice capture/STT/TTS/playback changes, approval/permission/popup changes, memory/scheduler/skills/settings changes, orb-shell behavior changes.

## Architecture overview

Swift app (voice pipeline, memory, tools, skills) + Rust orb host (only product UI) + Rust daemon (`crates/fae-daemon`, primary LLM lane). All intelligence runs locally — no cloud, no API keys, no data leaves the machine. The Swift MLX engine remains the macOS fallback and LoRA training substrate.

```
orb click / hotkey → mic capture (16kHz) → WAV → fae-daemon
(Gemma 4 E4B: ASR + LLM + tools in one request) → TTS → Speaker
                                      │
                                      ├── Memory (SQLite + ANN + FTS5)
                                      ├── Tools (36 built-in)
                                      ├── Skills (27 built-in)
                                      ├── Scheduler (~23 tasks)
                                      ├── Backup (Git Vault)
                                      └── Self-Config
```

> S18 (2026-06-11): push-to-talk is the primary capture model. The always-on
> VAD/speaker-ID/wake-word path is bypassed; voice identity is retired
> (teardown plan: docs/architecture/voice-identity-teardown-plan-2026-06-11.md).

### Model stack

| Engine | Model | Framework | Purpose |
|--------|-------|-----------|---------|
| STT | Qwen3-ASR-1.7B | MLX 4-bit | Speech-to-text |
| LLM (primary) | Gemma 4 E4B | fae-daemon + mistral.rs (Metal/CPU; llama.cpp fallback planned for Vulkan-class hardware) | Conversation, tool use — when `llm.useDaemonEngine = true` |
| LLM (fallback) | Qwen3.5 (2B / 4B / 35B-A3B) | MLX 4-bit | macOS in-process fallback + LoRA training substrate |
| TTS | Kokoro-82M (hexgrad) | MLXAudioTTS float32 | Text-to-speech (FaeTTSAdapter, pre-computed voice embeddings, 24 kHz) |
| VLM (fast) | SmolVLM2-256M | MLXVLM mlx | Always-on vision — presence detection, screen triage (<1GB) |
| VLM (deep) | SmolVLM2-500M | MLXVLM mlx | On-demand vision — detailed screenshot/camera analysis (1.8GB) |
| Embedding | Hash-384 | MLX | Semantic memory search |
| Speaker | ECAPA-TDNN | Core ML fp16 | Voice identity (1024-dim x-vectors) |
| Keyword | 1D-CNN (~200K params) | MLX float32 | Barge-in interrupt keyword detection (5-class: interrupt/wake/speech/silence/noise) |

**Daemon LLM lane**: `llm.useDaemonEngine = true` routes turns through `ML/DaemonLLMEngine.swift` → `fae-daemon` (Unix-socket NDJSON, fail-closed `models.lock` SHA-256 verification). `FAE_DAEMON_BIN` overrides the daemon binary path. If the daemon is unavailable, the pipeline falls back to the in-process MLX engine.

**Daemon TTS lane**: `tts.useDaemonEngine = true` (requires the daemon LLM lane) routes synthesis through `ML/DaemonTTSEngine.swift` → the daemon's `tts.synthesize` (Kokoro via voice-tts, 24 kHz 16-bit PCM WAV). The engine opens a second socket connection to the same daemon — LLM turns serialize for minutes and TTS must not queue behind them. Voice names resolve daemon-side: `<fae data dir>/voices/{voice}.safetensors` first (Fae's own "fae" voice, installed from the bundle by `DaemonTTSEngine.installBundledVoices()`), then the HF repo, then `af_heart` — an unknown voice degrades, never silences. `tts.speed` is applied once at playback, never sent to the daemon. Falls back to `FaeTTSAdapter` (in-process Kokoro) loudly.

**Auto model selection for the MLX lane** (via `voiceModelPreset: "auto"`):

Target (Gemma 4 — pending [mlx-swift-lm#180](https://github.com/ml-explore/mlx-swift-lm/pull/180)):

| System RAM | Model | Mode | Context |
|------------|-------|------|---------|
| <16 GB | Gemma 4 E2B 4-bit (2.3B eff) | Unified: audio-direct ASR+LLM | 128K |
| 16-31 GB | Gemma 4 E4B 4-bit (4.5B eff) | Unified: audio-direct ASR+LLM | 128K |
| ≥32 GB | Gemma 4 E2B (ASR) + 26B-A4B (LLM) | Dual: dedicated ASR + quality LLM | 256K |

Current fallback (Qwen3.5 — active until Gemma 4 ships in mlx-swift-lm):

| System RAM | Model | HuggingFace ID | Context |
|------------|-------|----------------|---------|
| ≥16 GB | Qwen3.5-9B Unsloth (mixed-bit) | `Brooooooklyn/Qwen3.5-9B-unsloth-mlx` | 32K |
| ≥8 GB | Qwen3.5-4B (uniform 4-bit) | `mlx-community/Qwen3.5-4B-4bit` | 32K |
| <8 GB | Qwen3.5-2B OptiQ | `mlx-community/Qwen3.5-2B-OptiQ-4bit` | 32K |

Benchmarked 2026-04-02: Gemma 4 E4B 4-bit scores 100% on tool calling, Fae capability, assistant fit, and serialization (90% MMLU). Matches Qwen3.5-9B at half the effective params with native audio input. E2B scores 100% tool calling, 90% cap, 85% fit. 26B-A4B scores 98% MMLU, 100% on all Fae metrics.

Presets: `gemma_4_e2b`, `gemma_4_e4b`, `gemma_4_26b_a4b`, `qwen3_5_35b_a3b`, `qwen3_5_9b`, `qwen3_5_4b`, `qwen3_5_2b`. Unknown presets → auto. Legacy presets (`saorsa_1_1_tiny`) silently resolve to `qwen3_5_2b`.

Context scaling: `FaeConfig.recommendedMaxHistory()` = `(contextSize - 5000 - maxTokens) / 400`, clamped [6, 100]. `maxTokens` capped at `contextSize / 2`.

LLM engine lives in `Sources/FaeInference/MLXLLMEngine.swift` (separate target). Main app accesses via `typealias MLXLLMEngine = FaeInference.MLXLLMEngine` in `Core/FaeInferenceAliases.swift`.

### Unified pipeline

1. **Audio capture** (16kHz mono) → 2. **VAD** (SileroVAD + keyword spotter) → 3. **Speaker ID** (ECAPA-TDNN) → 4. **Echo suppression** → 4b. **Keyword classifier** (1D-CNN, populates interrupt keywords for barge-in) → 5. **STT** (Qwen3-ASR) → 6. **LLM** (Gemma 4 E4B via daemon lane, or Qwen3.5 MLX fallback; native tool calling, max 5 tool turns) → 7. **TTS** (Kokoro-82M, sentence-queued) → 8. **Playback** (with barge-in)

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

**Runtime correction learning**: When users say "my name is X not Y", `CorrectionDetector` detects the correction in `PipelineCoordinator.processTranscription()`, stores it as a memory record via `MemoryOrchestrator.storeCorrection()`, and feeds name corrections into `DynamicVocabularyCorrector.addCorrectionPair()` for immediate ASR improvement. Key files: `Pipeline/CorrectionDetector.swift`, `Pipeline/PipelineCoordinator.swift`.

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

**Repeating tasks**: `memory_reflect` (6h), `memory_reindex` (3h), `memory_migrate` (1h), `memory_inbox_ingest` (5min), `memory_digest` (6h), `check_fae_update` (6h), `skill_health_check` (5min), `self_diagnostic` (6h), `workspace_discovery` (12h), `tool_augmentation_check` (24h).

**Daily tasks** (via scheduler_tick): `memory_backup` (02:00), `vault_backup` (02:30), `memory_gc` (03:30), `noise_budget_reset` (00:00), `morning_briefing` (configurable, default 08:00, suppressed when enhanced briefing active), `skill_proposals` (11:00), `skill_distill` (13:00), `stale_relationships` (weekly Sun 10:00), `capability_discovery` (every 3 days, 14:00), `embedding_reindex` (weekly Sun 03:00).

**Awareness tasks** (only when `awareness.enabled = true` + consent): `camera_presence_check` (30s), `screen_activity_check` (19s).

**Proactive tasks** (via `proactiveQueryHandler`): `overnight_work` (22:00-06:00), `enhanced_morning_briefing` (deferred until user detected after 07:00), `training_data_export`, `training_cycle`.

**Improvement cycle** (via `ImprovementCycleCoordinator`): `improvement_cycle` runs nightly at 03:00 after backups complete. Runs meta-optimization first (fast, minutes), then optional weight training (slow, hours). Minimum data thresholds: 20 feedback events required to trigger cycle.

## Autonomous Self-Improvement Loop

Fae autonomously improves via a deterministic overnight loop. No human intervention for routine improvement.

```
Collect feedback → Meta-Optimize (directive, config, skills, memory seeds)
    → Export SFT/DPO data → Train LoRA adapter (mlx-tune)
    → Evaluate (FaeBenchmark, pure Swift) → External review (Codex/Claude)
    → Propose next morning → Deploy after approval
```

**Key components:**
- `ImprovementCycleCoordinator` (actor): State machine IDLE -> COLLECTING -> META_OPTIMIZING -> TRAINING -> EVALUATING -> PROPOSING -> DEPLOYING with rollback
- `MetaOptimizer` (actor): AutoAgent-inspired hill-climbing on runtime-mutable surfaces. Tests candidate changes against FaeBenchmark, keeps improvements, rolls back regressions. Budget: 10 benchmark runs, 30 min wall clock per cycle.
- `MetaOptHypothesisGenerator`: Pattern-based hypotheses for directive amendments and config knob adjustments from feedback clusters.
- `MetaOptSkillGenerator`: Generates instruction-only skills from capability gaps (5 templates: tool routing, formatting, memory precision, execution, conversation quality). Names prefixed `auto-`.
- `MetaOptMemorySeedGenerator`: Seeds strategic facts into memory recall (6 templates). Capped at 10 active seeds, 30-day expiry.
- `TrainingBridge` (actor): Calls mlx-tune Python scripts via `uv run --script`. Methods: `exportTrainingData()`, `launchTraining()`, `pollUntilComplete()`, `evaluateAdapter()`, `runBenchmark()`. Scripts from training-orchestrator and training-data-bridge skills. Optional FaeBenchmark binary for real accuracy eval.
- `ImprovementStore` (improvement.db): Separate SQLite database with 6 tables (feedback_events, improvement_baselines, improvement_state, capability_gaps, shadow_eval, meta_optimization_log)
- `ImplicitFeedbackDetector`: 7 signal types captured after each turn (re-ask, abandonment, follow-through, interruption, praise, topic_change, silence_acceptance)
- `ExternalReviewGate`: 3-provider fallback (Codex -> Claude -> internal), PASS/FAIL/CONCERN with 3-deferral max
- `ShadowEvaluator`: Overnight replay on alternate nights, 60% win rate promotion gate
- `AdapterDeploymentManager`: Semi-automatic mode (morning proposals), earned auto-deploy after 5 approved cycles

**Meta-optimization surfaces** (tested via FaeBenchmark hill-climbing):
- **Directive** (Layer 4): Conciseness, clarification, relevance-first, understanding amendments
- **Config knobs**: `llm.temperature` (0.1–1.0), `memory.maxRecallResults` (2–12)
- **Skills**: Auto-generated instruction skills from capability gaps and feedback patterns
- **Memory seeds**: Strategic facts (`meta_opt_seed` tagged) that shape recall behavior

**Training pipeline flow** (nightly at 03:00, requires 20+ feedback events with 5+ corrections):
1. `TrainingBridge.exportTrainingData()` → calls `build_dataset.py` → writes `train.jsonl` + `dpo_pairs.jsonl`
2. `TrainingBridge.launchTraining(mode:)` → calls `train.py` or `train_dpo.py` → detached mlx-tune worker
3. `TrainingBridge.pollUntilComplete()` → polls `check_status.py` every 30s (max 2h)
4. Evaluation (tiered): FaeBenchmark (real accuracy, if binary configured) → loss-based proxy (evaluate.py)
   - FaeBenchmark: runs base model + adapter, compares tool/capability/fit/serialization accuracy → real `EvalDelta`
   - Loss-based: maps training loss score (0.0–1.0) to uniform delta (fallback)
   - Baseline stored in `ImprovementStore.improvement_baselines` for historical comparison
5. `ExternalReviewGate.review()` → Codex/Claude/internal validation
6. Deploy or propose for approval (earned auto-deploy after 5 approved cycles)

**Training data paths:**
- Export data: `~/Library/Application Support/fae/training/data/` (`FaeDirectories.trainingDataDirectory`)
- Personal adapters: `~/Library/Application Support/fae/models/personal/` (`FaeDirectories.personalModelsDirectory`)
- Run metadata: `~/Library/Application Support/fae/training/run.json` (`FaeDirectories.trainingRunFile`)

**LoRA adapter loading:** MLXLLMEngine.loadAdapter(from:), unloadAdapter(), swapAdapter(to:). Uses mlx-swift-lm's built-in LoRAContainer. Hot-swap via SelfConfigTool `training.personal_adapter_path`.

**Scheduler tool access:** Scheduler tasks run as owner (isOwner=true). Proactive allowlists in `ProactiveRequestContext` limit available tools per task.

## Tool Augmentation & Workspace Discovery

`ToolAugmentationManager` (`Core/ToolAugmentationManager.swift`) manages CLI tool discovery, installation, and workspace scanning.

**Workspace discovery** (`workspace_discovery`, 12h + 30s after startup): Scans common project directories on any Mac for git repos. Uses `fd` if installed (fast), falls back to FileManager. Detects project type (Rust/Swift/JS/Python/Go/etc.) and extracts GitHub remote URLs. Stores as a `fact` memory record tagged `workspace_discovery` + `project_location`. Scans: `~/Desktop/`, `~/Documents/`, `~/Developer/`, `~/Projects/`, `~/Code/`, `~/repos/`, `~/src/`, `~/workspace/`, `~/work/`, `~/dev/`, `~/github/`, `~/git/`, plus `~` direct children. Max depth 3-4 levels.

**Tool augmentation** (`tool_augmentation_check`, 24h + 30s after startup): Checks which CLI tools are installed, installs core-tier tools via brew/zb if a package manager is available, stores inventory as a `fact` memory record tagged `tool_augmentation`.

| Tier | Tool | Binary | Purpose |
|------|------|--------|---------|
| Core | fd | `fd` | Fast file finder (replaces find) |
| Core | ripgrep | `rg` | Fast text search (replaces grep) |
| Core | jq | `jq` | JSON processor |
| Core | GitHub CLI | `gh` | GitHub issues, PRs, repos |
| Core | tree | `tree` | Directory structure viewer |
| Core | bat | `bat` | Cat with syntax highlighting |
| Extended | tokei | `tokei` | Code statistics by language |
| Extended | ffmpeg | `ffmpeg` | Audio and video processing |
| Extended | pandoc | `pandoc` | Document format conversion |
| Extended | yq | `yq` | YAML processor |
| Extended | delta | `delta` | Better git diffs |
| Extended | ImageMagick | `magick` | Image processing |

**Prompt awareness**: `PersonalityManager.assemblePrompt()` injects a compact hint about available tools so the LLM prefers `fd` over `find`, `rg` over `grep`, etc. Tool check results are cached for 5 minutes.

**SafeBashExecutor PATH**: `~/.local/bin:~/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`

## Tool system

36 tools registered in `ToolRegistry.buildDefault()`:

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
| Plugin | `plugin_manage` |

**Tool access model**: Voice identity is the primary gate. Primary user (owner) gets `full` tool access. Guests get no tool access unless explicitly granted by the primary user. Pre-enrollment: no tool calls except voice enrollment.

**Tool modes** (internal): `off`/`read_only` (read tools only), `read_write` (+ write/edit/self_config), `full` (all including bash), `full_no_approval` (all, skip approval for verified owner).

**Native MLX tool calling**: tool specs passed via `UserInput.tools` → Qwen3.5 chat template. No separate intent classifier.

### Tool security (3-layer model)

Voice identity is the security model. Owner gets full access; DamageControlPolicy is the safety net for catastrophic operations.

| Layer | Implementation | Purpose |
|-------|---------------|---------|
| Voice identity | `SpeakerProfileStore` | Primary user verification — only recognized voices get tool access |
| Damage control | `DamageControlPolicy` | Block/disaster/confirm for catastrophic bash ops + credential path protection |
| Reversibility | `ReversibilityEngine` + `ReceiptStore` | Pre-mutation file snapshots, undo support, action receipts |

**Simplified ToolExecutor flow** (replaced 14-layer pipeline):
1. Registry lookup + tool mode filtering
2. Proactive allowlist + TillDone gate + computer-use step limit
3. DamageControlPolicy evaluate (bash patterns, path rules, credential protection)
4. Execute with timeout, plugin hooks, receipt tracking

**Apple tool reads are INTENTIONALLY ungated** — only writes/mutations need approval. macOS permission is the only read gate.

**Protected paths** (zero-access via DamageControlPolicy):
- `~/.fae-vault/` — Git Vault backup
- `~/Library/Application Support/fae/speakers.json` — voice identity
- `~/Library/Application Support/fae/directive.md` — system directive

> CoWork (and its `CoworkToolExecutor` security intercept) was removed in the Great Cleanup (2026-06-11). See `docs/architecture/cowork-removal-plan-2026-06-05.md` and `docs/archive/`.

### Skill manifest contract

All executable built-in skills MUST have: `schemaVersion: 1`, `capabilities: ["execute"]`, `allowedTools: ["run_skill"]`, SHA-256 checksums in `integrity.checksums`.

Recompute checksums after modifying skill scripts:
```bash
cd native/macos/Fae/Sources/Fae/Resources/Skills/<skill-name>
for f in SKILL.md scripts/*.py; do echo "\"$f\": \"$(shasum -a 256 "$f" | cut -d' ' -f1)\""; done
```

## Built-in skills (27)

| Skill | Type | Purpose |
|-------|------|---------|
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
| `training-orchestrator` | Executable | Personal fine-tuning via mlx-tune: SFT, DPO, STT LoRA adapters |
| `training-data-bridge` | Executable | Extract SFT/DPO training data from memory |
| `huggingface-scout` | Executable | Search HuggingFace Hub for models/datasets |
| `self-diagnostic` | Instruction | Comprehensive health check: system, pipeline, memory, tools, speaker |
| `channel-discord` | Executable | Discord channel integration |
| `channel-whatsapp` | Executable | WhatsApp channel integration |
| `channel-imessage` | Executable | iMessage channel integration |
| `channel-hub` | Executable | Unified channel management hub |
| `document-analyst` | Executable | Document analysis and processing |
| `email-triage` | Executable | Email prioritization and triage |
| `file-organizer` | Executable | File organization and management |
| `focus-defender` | Executable | Focus mode and distraction blocking |
| `smart-home` | Executable | Smart home device control |
| `system-health` | Executable | System health monitoring and reporting |

Skills use **progressive disclosure**: names + descriptions in system prompt, full SKILL.md body loaded on `activate_skill`.

## Channels (Discord, WhatsApp, iMessage)

Remote senders are **non-owner guests** — no tool escalation, text-only responses.
Config: `[channels]` in config.toml. Credentials in macOS Keychain via `CredentialManager`.

### Channel architecture

```
                        ┌──────────────────────────────────────────┐
                        │           ChannelGateway (actor)          │
                        │                                          │
  DiscordAdapter ──────►│  ┌─────────────────────────────────┐     │
  WhatsAppAdapter ─────►│  │ ChannelIdentityResolver (actor) │     │
  iMessageAdapter ─────►│  │ phone normalisation, name match │     │
                        │  └─────────────────────────────────┘     │
                        │                                          │
                        │  ┌─────────────────────────────────┐     │
                        │  │ ChannelSessionStore (actor)      │     │──► ResponseHandler
                        │  │ per-sender isolation, cleanup    │     │    (LLM pipeline)
                        │  │ cross-channel LinkedSessionSummary│    │
                        │  └─────────────────────────────────┘     │
                        │                                          │
                        │  ┌─────────────────────────────────┐     │
                        │  │ ChannelHealthMonitor (actor)     │     │
                        │  │ auto-reconnect, backoff, status  │     │
                        │  └─────────────────────────────────┘     │
                        └──────────────────────────────────────────┘
```

**Message flow**: Adapter receives platform message → converts to `ChannelMessage` → calls `onMessage` callback → Gateway resolves identity (auto-links by phone/name) → resolves/creates `ChannelSession` → injects cross-channel context → dispatches to ResponseHandler → sends response back via adapter.

**Cross-channel identity**: `ChannelIdentityResolver` maps platform IDs to canonical identities. Auto-links by phone number suffix (last 10 digits) and case-insensitive display name. Linked sessions share conversation context via `LinkedSessionSummary`.

**Health monitoring**: `ChannelHealthMonitor` tracks adapter status (connected/disconnected/reconnecting/error). Auto-reconnect with exponential backoff (base 2s, max 60s, max 5 attempts). Reports via `FaeEvent.runtimeProgress`.

**ChannelAdapter protocol**: `kind`, `start()`, `stop()`, `send(response:to:)`, `onMessage` callback. All three adapters (Discord, WhatsApp, iMessage) conform. Legacy `ChannelManager` preserved for backward compatibility.

## Proactive awareness

**Always-on from first launch.** Camera/screen awareness start automatically after primary user enrollment.
No consent gate — these features are core to what Fae is, not optional add-ons.
`injectProactiveQuery()` with immutable `ProactiveRequestContext`. Per-task tool allowlists in `ProactiveRequestContext.allowedTools`.
`AwarenessThrottle`: battery, thermal, quiet hours (22:00-07:00) gating.

### Progressive identity learning

Both voice and visual identity improve over time without user action:

- **Voice**: `enrollIfBelowMax()` silently adds new speaker embeddings (up to 50) during conversation, strengthening the voice profile as Fae hears the owner in different conditions.
- **Visual**: Camera presence checks silently observe and remember the owner's appearance via `visual_identity`-tagged memory records. The reference photo (`owner_photo.jpg`) is refreshed every 3 days to capture changes (haircut, glasses, lighting). The `proactive-awareness` skill instructs the VLM to note visual details factually and silently.
- **Photo capture**: Reference photo captured during onboarding (4th step after voice enrollment). Existing users see a "Complete Setup" banner until they take a photo. Photo stored at `FaeDirectories.ownerPhotoFile`, description in `SpeakerProfile.photoDescription`.
- **Owner identification**: Camera presence check prompt includes the stored visual description so the VLM can identify whether the person at the desk is the owner.

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

Rollback: `rollback_improvement` action undoes the most recent overnight meta-optimization change. User says "undo the last change you made to yourself" → LLM invokes `self_config(action: "rollback_improvement")`. Confirmation in companion language via `MetaOptNarrator.describeRollback()`.

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
- Owner photo: `~/Library/Application Support/fae/owner_photo.jpg`
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

## Source map (directory-level)

> Per-file inventory tables were removed in the Great Cleanup (2026-06-11) — the legacy-UI
> and CoWork deletions made them stale immediately. For current file lists use `ls`/`rg`
> against the source tree; this map records each directory's role.

All paths under `native/macos/Fae/Sources/Fae/` unless noted.

| Directory | Role |
|-----------|------|
| `Core/` | App facade (`FaeCore`), config (`FaeConfig`, incl. `llm.useDaemonEngine`), event bus + types, system prompt assembly (`PersonalityManager`), soul/directive lifecycle, rescue mode, credentials, permissions, diagnostics, CLI tool augmentation + workspace discovery |
| `ML/` | Model loading (`ModelManager`), STT/TTS/VLM/embedding engines, `DaemonLLMEngine` (daemon LLM lane client), ECAPA-TDNN speaker encoder + profile store, keyword classifier, turn detector, voice libraries |
| `Pipeline/` | `PipelineCoordinator` (STT→LLM→TTS, barge-in, `injectProactiveQuery()`), VAD, echo suppression, speaker gating, tool-call/script-block parsing, correction detection, post-ASR vocabulary correction, implicit feedback, conversation state, text processing |
| `Runtime/` | JSC tool-program runtime (`JSCRuntime`, bridges, `ScriptBudget`, `DryRunPlan`), Python uv runtime + dependency installer, local runtime server, `PrivacyFilterBridge` |
| `Tools/` | Tool protocol/registry/executor (4-step flow), built-in + Apple + scheduler + skill + vision tools, ACP delegation, security stack (`DamageControlPolicy`, `ReversibilityEngine`, `SafeBashExecutor`, `PathPolicy`, `NetworkTargetPolicy`, `SecurityEventLogger`, redaction) |
| `Memory/` | `MemoryOrchestrator` (hybrid ANN+FTS5 recall/capture/GC), GRDB SQLite store, sqlite-vec vector store, entity graph + linking, digests, inbox ingestion, `ImprovementStore`, external review gate, shadow evaluator |
| `Scheduler/` | `FaeScheduler` (~23 tasks), awareness throttle, proactive policy, `ImprovementCycleCoordinator`, `TrainingBridge` (mlx-tune via uv), MetaOpt* (hill-climbing meta-optimization), adapter deployment |
| `Skills/` | Skill discovery/activation/execution (`SkillManager`), SKILL.md parsing, MANIFEST.json + SHA-256 integrity, security review |
| `Channels/` | `ChannelGateway` actor + adapters (Discord, WhatsApp, iMessage), cross-channel identity resolver, session store, health monitor with backoff reconnect |
| `Audio/` | Mic capture (16kHz mono, NaN/Inf validation), playback with barge-in, thinking/listening tones, WAV parsing |
| `Backup/` | `GitVaultManager` — rolling backup at `~/.fae-vault/` |
| Top level | App entry (`FaeApp` — AppKit windows, delegate owns state), orb-host bridge + `OrbTypes` (mode/feeling model driving the Rust orb), Settings window + tabs, approval/input overlay panels, onboarding + enrollment, debug console, `TestServer`, Sparkle updater, JIT permissions |

Sibling code outside the Swift app:

| Location | Role |
|----------|------|
| `native/rust/fae-ui-shell/` | Rust orb host (tao + wgpu + muda + wry) — the only product UI; embedded into the app bundle by `run-dev`/`run-native-with-ui-shell` |
| `crates/` | Rust daemon workspace: `fae-daemon` (Unix-socket NDJSON listener), `fae-engine` (ProviderAdapter, mistral.rs, fail-closed `models.lock`), `fae-control-plane` (authz core), `fae-envelope-gate` (typed peer boundary). See `crates/README.md` |

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

Current: v0.8.189 — Single-model Qwen3.5 path active; Gemma 4 E4B/E2B target pending mlx-swift-lm.

## Design System

Always read `DESIGN.md` before making any visual or UI decisions. All font choices, colours, spacing, and aesthetic direction are defined there. Key rules:
- Use Scottish palette colours, not system `.blue`/`.green`/`.orange`.
- Use `-text` colour variants for readable text on dark backgrounds (WCAG AA minimum).
- Use Instrument Serif for display/header text, system serif for conversation bubbles, system sans for UI controls.
- No emoji in UI headers. No purple-blue gradients. No `SF Pro Rounded` for display text.
- Do not deviate from DESIGN.md without explicit user approval.
- In QA mode, flag any code that contradicts DESIGN.md.

## Web browsing

Use the `/browse` skill from gstack for all web browsing tasks. Do NOT use `mcp__claude-in-chrome__*` tools.

Available gstack skills: `/office-hours`, `/plan-ceo-review`, `/plan-eng-review`, `/plan-design-review`, `/design-consultation`, `/review`, `/ship`, `/browse`, `/qa`, `/qa-only`, `/design-review`, `/setup-browser-cookies`, `/retro`, `/investigate`, `/document-release`, `/codex`, `/careful`, `/freeze`, `/guard`, `/unfreeze`, `/gstack-upgrade`.

## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review
