# Fae

> ## :warning: UNDER HEAVY DEVELOPMENT — DO NOT USE AS THIS COULD BE DANGEROUS SOFTWARE :warning:
>
> This project is in active early development. APIs, functionality, and behavior may change without notice. **Do not use in production or any environment where safety is a concern.** Use at your own risk.

![Fae](assets/fae.jpg)

Fae is a personal AI companion who listens, remembers, and helps — like having a knowledgeable friend who is always in the room. Fae Local runs entirely on your Mac, and Work with Fae can optionally connect selected remote providers under explicit user control.

**The vision is simple:** imagine a computer that your grandmother could use. Fae handles the complexity — setting up software, managing files, scheduling reminders, researching topics, and keeping track of the people and events that matter to you. You just talk to her.

> **Note:** Fae is not a real-time chatbot. She is a thoughtful voice-first assistant that prioritises correctness and thorough tool use over speed. When you ask Fae something, she thinks carefully — searching her memory, consulting the web, reading files, running tools — and then responds with a considered answer. The orb breathes and glows while she works, and a gentle thinking tone plays so you always know she heard you and is on it. As local models improve, conversational latency will naturally decrease, but Fae will always favour getting things right over getting things fast.

**Website:** [the-fae.com](https://the-fae.com)

## Platform

Fae is a **pure Apple-native app** built with Swift and MLX. Fae Local runs on-device using Apple Silicon's Neural Engine and GPU. Work with Fae can also attach optional remote providers such as OpenAI-compatible endpoints, OpenRouter, and Anthropic, while keeping local-only context and approvals under Fae's control.

| Platform | Status | Role |
|---|---|---|
| **macOS** (Apple Silicon) | Primary | Full app — on-device Fae Local runtime, STT, TTS, voice identity, memory, tools, and optional remote specialist backends |
| **iOS / iPadOS** | Planned | Lightweight companion via Handoff |

**No web version. No Windows. No Linux builds.**

## What Fae Does

### Always Listening, Never Intrusive

Fae is an always-present companion, not a summoned assistant. She listens continuously and decides when to speak:

- **Direct conversation** — talk to Fae naturally and she responds with warmth and clarity.
- **Overheard conversations** — if people nearby are discussing something Fae can help with, she may politely offer useful information.
- **Background noise** — Fae stays quiet when the TV is on, music is playing, or conversations don't involve her.
- **Idle noise guard** — short out-of-context snippets (one or two words/click-like artifacts) are ignored after silence, while brief replies still work naturally during active follow-up windows.
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
- **Owner enrollment required** — if owner gating is enabled and no owner voiceprint exists yet, Fae withholds tool execution until enrollment completes.
- **Owner gating** — known non-owner voices don't see tool schemas, preventing strangers from running commands.
- **Self-echo rejection** — Fae's own voice is enrolled as `fae_self` and filtered from the pipeline.
- **Text injection** — always trusted (physical device access implies owner).

Configure via `[speaker]` in config.toml. See [Voice Identity Guide](docs/guides/voice-identity.md).

### Self-Improvement & Adaptive Growth

Fae is not a static assistant — she is a **companion agent** that learns, adapts, and grows with her user over time. The design principle is simple: **we build the harness, not the destination.** We don't know what Fae will become for any given user. A developer's Fae will look nothing like an artist's Fae or a parent's Fae. Our job is to ensure the mechanisms for growth are sound, the safety rails are firm, and the architecture doesn't impose a ceiling.

#### Five Concurrent Improvement Loops

Fae improves across five loops, each operating at a different timescale:

| Loop | Timescale | Mechanism | Status |
|------|-----------|-----------|--------|
| **Turn-level** | Seconds | Memory recall → better context → better response → memory capture | Implemented |
| **Session-level** | Minutes | User feedback → directive/skill/setting update → immediate behavior change | Implemented |
| **Daily** | Hours | Overnight research on interests, morning briefings, skill proposals, capability discovery | Implemented |
| **Weekly** | Days | Export conversation history → LoRA fine-tuning → evaluate → deploy improved model | Training scripts implemented; autonomous orchestration designed |
| **Community** | Ongoing | Forge builds tools → Toolbox registers → Mesh shares with other Fae instances | Skills implemented |

The composition is the key: each loop feeds the others. Memory improves tool use → tool use generates better training data → better models improve memory recall → the cycle continues. Meanwhile, Fae builds tools to solve problems she couldn't solve before, researches topics her user cares about, and shares what she learns with other Fae instances.

#### Self-Modification

Fae can change her own behavior across three layers:

- **Live settings** (21 adjustable keys) — say "speak faster", "be more creative", "let me interrupt you" and Fae calls `self_config` to change parameters immediately. No restart required.
- **Directives** — persistent standing orders at `~/Library/Application Support/fae/directive.md`, loaded every turn. "Always check my calendar before suggesting times", "Greet me in French." Safety-gated: 4000-char limit, jailbreak pattern detection.
- **Skill self-modification** — Fae can create, update, and patch her own skills via `manage_skill`. If a user says "stop checking my mood on camera," Fae modifies the `proactive-awareness` skill's instructions. The change persists across restarts.
- **Skill creation** — Fae can build entirely new skills (instruction or executable Python) to extend her own capabilities, either on request or proactively via the Forge.

#### Memory-Driven Learning

After every turn, Fae automatically extracts and stores: your name, preferences, interests, commitments, relationships, events, and the full conversation episode — 9 structured extraction patterns running without being asked. Before every turn, she recalls relevant memories using hybrid search (60% neural similarity + 40% lexical). An entity graph tracks people, organisations, and locations with typed relationships (works_at, lives_in, knows, reports_to).

As SOUL.md says: *"Fae remembers without being asked to. That's the point."*

#### Model Self-Training (The Personalisation Bridge)

The most ambitious improvement loop: Fae can train improved versions of herself using her own conversation history.

**What exists today:**
- `prepare_training_data.py` — exports conversations to SFT and DPO format with quality scoring
- `train_mlx_lora_chunked.sh` — LoRA fine-tuning on Qwen3.5 via MLX
- `train_mlx_tune_preference.sh` — ORPO preference training from user corrections
- `fuse_and_benchmark_candidate.sh` — evaluate and merge candidate models
- Personalised benchmark generation from the user's own memory records

**The autonomous pipeline (designed, not yet orchestrated):**
1. Weekly: export high-quality conversation turns + implicit correction pairs (DPO)
2. Overnight: LoRA training during quiet hours, resource-gated (power + thermal)
3. Morning: benchmark new checkpoint against current model on both standard and personalised tests
4. Proposal: "I trained an improved model overnight. It scores 82% vs 76% on our benchmarks — especially better at the Rust questions you've been asking. Want me to switch?"
5. User decides. Never auto-deployed.

Over months, the weights absorb the user's communication style, domain expertise, emotional calibration, and working patterns. The system prompt does less work because the model *thinks* in the user's style. This is the three-layer design (weights → soul → prompt) fully realised.

See: [Memory→Training Bridge](docs/specs/memory-to-training-bridge.md), [Continuous Self-Improvement Architecture](docs/specs/continuous-self-improvement-architecture.md).

#### Proactive Intelligence

Fae doesn't wait to be spoken to:

- **Camera presence** — detects you arriving, greets you warmly, notices mood (consent-gated)
- **Screen monitoring** — understands your current work context silently (consent-gated)
- **Overnight research** — searches the web about your interests during quiet hours
- **Enhanced morning briefing** — calendar + mail + research findings + birthdays, triggered when you're first detected after 07:00
- **Skill proposals** — detects repeated patterns and suggests new skills ("I noticed you keep asking about weather — want me to build a skill for that?")
- **Capability discovery** — surfaces one undiscovered capability every few days, grounded in your actual behavior, never more than one per session
- **Stale relationships** — gently reminds you about people you haven't mentioned in a while
- **Noise control** — daily delivery budgets and quiet hours prevent Fae from ever becoming annoying

All proactive features are gated by explicit consent, resource awareness (battery, thermal, quiet hours), and strict per-task tool allowlists. Fae earns presence over time — she doesn't demand it.

#### Skill-First Extensibility

**Canonical preference:** Prefer skill contracts over hardcoded code paths; prefer asking Fae conversationally for setup/changes over manual config editing.

- Skills follow the [Agent Skills](https://agentskills.io/specification) open standard
- Three tiers: built-in (bundled), personal (user-created), community (imported)
- Progressive disclosure: names + descriptions in base prompt, full body loaded only on activation
- Tools: `activate_skill`, `run_skill`, `manage_skill`
- **Forge** — tool creation workshop: scaffold Zig/Python/hybrid projects, compile, test, release
- **Toolbox** — local registry with SHA-256 integrity verification
- **Mesh** — peer-to-peer tool sharing via Bonjour/mDNS with TOFU trust model

See [Self-Modification Guide](docs/guides/self-modification.md).

For the full technical analysis of all five improvement loops, memory capture, proactive awareness, skill creation, training pipeline, and the growth architecture — see **[Self-Improvement & Proactive Architecture](docs/guides/self-improvement-and-proactive-architecture.md)**.

For how Fae compares to other AI assistant projects — including what makes the local-first approach unique and where the gaps are — see **[Landscape Analysis](docs/guides/self-improvement-and-proactive-architecture.md#11-landscape-analysis)** in that same document.

### Agent Orchestration (ACP)

Fae can delegate complex coding tasks to external AI agents — Claude Code, Codex, Gemini CLI, Copilot, and any [ACP-compatible agent](https://agentclientprotocol.com) — via the bundled `acpx` client. Fae understands your intent, routes the task to the right specialist, monitors progress, and synthesises the result. The local LLM handles personality and judgment; the external agent handles code.

See the **[ACP Integration Design](docs/specs/acp-integration-design.md)** for the protocol architecture, the **[Continuous Self-Improvement Architecture](docs/specs/continuous-self-improvement-architecture.md)** for how all capabilities compose into a closed self-improvement loop, and the **[Memory→Training Bridge](docs/specs/memory-to-training-bridge.md)** for how Fae's conversations become personalised model weights.

### Vision + Computer Use

Fae can see your screen, use the webcam, and interact with apps — all locally, all private:

- **Screenshot** — capture the screen or a specific app window and describe what's visible via on-device VLM (Qwen3-VL).
- **Camera** — capture a webcam frame and describe what Fae sees.
- **Read screen** — combines screenshot with the macOS Accessibility tree to produce a numbered element list for interaction.
- **Click, type, scroll** — interact with apps using element-based or coordinate-based actions via macOS Accessibility API.
- **Find element** — search the UI tree for buttons, fields, and links by text or role.

Vision requires enabling in Settings > Models and sufficient RAM (24+ GB). The VLM loads on-demand — not at startup — to conserve RAM.

### Desktop Automation

Fae can manage applications on your Mac through desktop automation tools:

- Open, close, and interact with desktop applications.
- Read and write files, configure software, and manage system settings.
- Prefer skill-based configuration contracts (channels/settings) over hardcoded one-off code paths when implementing new capabilities.
- Execute shell commands with a safety-first approval model.

Tool modes control how much access Fae has:

| Mode | What Fae Can Do |
|---|---|
| `off` | Conversation only — no computer access |
| `read_only` | Read files and check system state |
| `read_write` | Read and write files |
| `full` | Full access including shell commands (with approval) |
| `full_no_approval` | Full access without approval prompts |

Approval UX in `full` mode is explicit: Fae asks in plain language, says "yes or no" out loud, and shows Yes/No buttons in the overlay. If a tool-backed request cannot be executed (denied, unavailable, or no schema access), Fae states that clearly instead of inventing results.

For read-only lookups (calendar/notes/mail/contacts/web/read), Fae can run tool calls as deferred background jobs: she acknowledges immediately, keeps the conversation responsive, and posts the grounded result back into the conversation when the tools finish. See `docs/guides/deferred-tool-execution.md`.

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
| `skill_health_check` | Every 5 minutes | Validate skill runtime health |
| `embedding_reindex` | Weekly (Sun 03:00) | Re-embed records missing ANN vectors |
| `vault_backup` | Daily at 02:30 | Rolling git-based backup to `~/.fae-vault/` |

### Work with Fae

Work with Fae is Fae’s conversation-first project workspace.

Current documented capabilities:

- separate visible conversation surface from the main Fae window
- per-conversation folders, indexed files, attachments, drag/drop, and paste
- conversation forks for branching work without losing the original thread
- provider-aware agent setup for Fae Local, OpenAI-compatible backends, OpenRouter, and Anthropic
- searchable model selection with visible current model
- mid-conversation model switching that preserves the same thread
- Fast / Balanced / Deep thinking levels that can be changed mid-conversation
- per-workspace strict-local vs remote execution policy
- multi-agent compare with local Fae synthesis when available
- fast local secret preflight before remote egress
- remote models never get direct local tool access; Fae Local remains the only actor that can touch files, apps, approvals, and local memory

See: [Work with Fae Guide](docs/guides/work-with-fae.md)

## Architecture

Fae is a **pure Swift app** powered by [MLX](https://github.com/ml-explore/mlx-swift) and Core ML for on-device inference. There is no Rust runtime in the active path. The UI process and local workers are all Swift-native on Apple Silicon.

```
┌──────────────────────────────────────────────────────────────┐
│                       Fae.app (Swift)                         │
│                                                               │
│  Mic (16kHz) → VAD → Speaker ID → STT → LLM → TTS → Speaker │
│                         │              │                      │
│                         │              ├── Memory (SQLite)     │
│                         │              ├── Tools (33 built-in) │
│                         │              ├── Scheduler           │
│                         │              └── Self-Config         │
│                         │                                     │
│                         └── Voice Identity (Core ML)          │
│                                                               │
│  ML Engines (all MLX, on-device):                             │
│  ┌───────────┐ ┌────────────┐ ┌───────────┐ ┌─────────────┐  │
│  │ STT       │ │ LLM        │ │ TTS       │ │ Speaker     │  │
│  │ Qwen3-ASR │ │ Qwen3.5    │ │ Kokoro    │ │ ECAPA-TDNN  │  │
│  │ 0.6/1.7B  │ │ 2B/4B/9B   │ │ 82M       │ │ Core ML     │  │
│  └───────────┘ └────────────┘ └───────────┘ └─────────────┘  │
│  ┌───────────┐                                                │
│  │ VLM       │  (on-demand, vision tools only)                │
│  │ Qwen3-VL  │                                                │
│  │ 4B 4/8bit │                                                │
│  └───────────┘                                                │
└──────────────────────────────────────────────────────────────┘
```

### Model Stack

| Engine | Model | Framework | Precision | Purpose |
|---|---|---|---|---|
| STT | Qwen3-ASR-1.7B | MLX | 4-bit | Speech-to-text |
| LLM | Qwen3.5 single-model local stack: `2B`, `4B`, or `9B` via `Auto`; `27B` as the manual quality tier | MLX | 4-bit | Main conversation, reasoning, tool use |
| TTS | Kokoro-82M | KokoroSwift / MLX | mixed | Text-to-speech |
| VLM | Qwen3-VL-4B on-demand (`4-bit` or `8-bit`) | MLXVLM | 4/8-bit | Vision — screen/camera understanding (on-demand) |
| Embedding | Hash-384 | MLX | - | Semantic memory search |
| Speaker | ECAPA-TDNN | Core ML | fp16 | Voice identity (1024-dim x-vectors) |

Current local default:
- Fae now prioritizes a single local Qwen3.5 text model.
- `auto` text model selection:
  - `8–15 GB`: `Qwen3.5 2B`
  - `16–31 GB`: `Qwen3.5 4B`
  - `32+ GB`: `Qwen3.5 9B`
- manual quality tiers:
  - `Qwen3.5 27B` on `32+ GB`
- `auto` vision selection:
  - `<16 GB`: disabled
  - `16–31 GB`: `Qwen3-VL-4B` `4-bit`
  - `32+ GB`: `Qwen3-VL-4B` `8-bit`
- the dual / concierge path remains only as a legacy compatibility path and is not the recommended local architecture
- external PARO benchmarks currently favor `Qwen3.5 9B` and `27B`, but Fae's Swift-native runtime cannot load PARO checkpoints yet, so the app still ships the standard MLX Qwen3.5 ladder
- canonical local model guide: [Local model strategy](docs/guides/local-model-strategy.md)

### Benchmark reports

The latest benchmark reports used to guide local model selection are checked into the repo.
People should look at both:

#### What we test

- [Local model benchmark report — 2026-03-07](docs/benchmarks/local-model-eval-2026-03-07.md)

This is the concrete evaluation surface we run today:
- RAM
- TTFT
- throughput
- tool-calling
- MMLU-style mini eval
- Fae-specific capability eval
- assistant-fit eval (tool use, instruction following, memory discipline, tool-result handling)
- structured output compliance for JSON / XML / YAML

`FaeBenchmark` now uses the same shared local inference path as the app (`FaeInference` / `MLXLLMEngine`), so runtime fixes to MLX/Qwen behavior land in benchmarking too. Run benchmark binaries through the native `just benchmark*` recipes rather than `swift run FaeBenchmark`.

Canonical local model cache: `~/.cache/huggingface/hub`. The app runtime, training scripts, and benchmark path now all resolve base models from that shared cache first. Legacy duplicates under `~/Library/Caches/models/...` can be removed with `bash scripts/cleanup_legacy_model_caches.sh --apply`.

#### What matters for Fae

- [Fae-priority local model evaluation — 2026-03-07](docs/benchmarks/fae-priority-eval-2026-03-07.md)

This re-ranks models using Fae's actual product priorities:
- tool use
- strict instruction following
- memory discipline
- tool-result handling
- speed
- RAM efficiency

#### Scoreboard / overview

- [LLM benchmark overview / scoreboard](docs/benchmarks/llm-benchmarks.md)

#### Post-training strategy and eval workflow

- [Post-Training Strategy And Evaluation](docs/guides/post-training-and-evaluation.md)

This is the canonical guide for:

- which post-training methods Fae should use
- why some methods fit Fae better than others
- how to compare base `Qwen3.5 4B` and `9B` models against fine-tuned candidates
- how `mlx-tune` fits into the plan

### Pipeline

The unified pipeline handles everything in a single pass — the LLM decides when to use tools via `<tool_call>` markup inline:

1. **Audio capture** (16kHz mono)
2. **VAD** — voice activity detection, barge-in support
3. **Speaker ID** — ECAPA-TDNN embedding, owner verification
4. **Echo suppression** — time-based + text-overlap + voice identity filtering
5. **STT** — Qwen3-ASR transcription
6. **LLM** — one active Qwen3.5 text model with inline tool calling (max 5 tool turns per query), plus deferred background execution for eligible read-only lookups
7. **TTS** — Qwen3-TTS with voice cloning, sentence-level streaming
8. **Playback** — with barge-in interruption support

**Latency profile:** End-to-end response time depends on request complexity. Simple greetings take a few seconds; tool-heavy tasks (web search + memory recall + file operations) can take 10-30 seconds. The orb and thinking tone provide continuous feedback throughout. Fae favours correctness over speed — she will search, verify, and cross-reference rather than guess.

### Tools (Built-in)

| Category | Tools |
|---|---|
| Core + Web | `read`, `write`, `edit`, `bash`, `self_config`, `web_search`, `fetch_url`, `channel_setup` |
| Skills | `activate_skill`, `run_skill`, `manage_skill` |
| Apple | `calendar`, `reminders`, `contacts`, `mail`, `notes` |
| Scheduler | `scheduler_list`, `scheduler_create`, `scheduler_update`, `scheduler_delete`, `scheduler_trigger` |
| Vision | `screenshot`, `camera`, `read_screen` |
| Computer Use | `click`, `type_text`, `scroll`, `find_element` |
| Roleplay | `roleplay` |

The active Qwen3.5 model decides when to use tools — no separate local router or concierge handoff is required in the default path.

### Adaptive Window

| Mode | Size | Style |
|---|---|---|
| Collapsed | 120x120 | Borderless floating orb, always-on-top |
| Compact | 340x500 | Borderless window with conversation |

Conversation and canvas are independent `NSPanel` windows positioned adjacent to the orb.

## Privacy

**Fae is local-first, and Fae Local is fully on-device.** Optional remote providers can be attached in Work with Fae, but they do not receive local-only workspace context when Fae marks that context as local-only.

- Audio is processed locally — no cloud transcription.
- Fae Local runs on-device with no API dependency.
- Work with Fae can optionally send shareable prompts to configured remote providers.
- Memories stored locally in SQLite — no sync, no backup to cloud.
- Voice biometrics stored locally — speaker profiles never leave the device.
- Web search uses DuckDuckGo HTML endpoint — the most privacy-friendly option.
- No external telemetry or tracking. Security analytics remain local-only on your device.

## Security

Fae now uses a **core-enforced security spine** (not prompt-only safety):

- **Single chokepoint broker** for all tool actions (`allow / allow_with_transform / confirm / deny`) with default-deny for uncovered actions.
- **Capability tickets** required for executable actions (including `run_skill`) to prevent bypass paths.
- **Reversible mutation wrappers** via checkpoints/rollback metadata for high-impact file and skill operations.
- **Safe executors** for high-risk runtimes:
  - constrained `bash` execution (restricted environment, cwd scope, denylist, timeout)
  - constrained executable skill runtime (timeout + CPU/memory ceilings)
- **Path and network invariants** in core code:
  - canonical path + anti-symlink escape checks
  - localhost/private/link-local/metadata target blocking
- **Outbound exfiltration guardrails** for send-like actions:
  - novel recipient confirmation
  - sensitive payload deny
- **Skills trust hardening**:
  - required executable `MANIFEST.json`
  - manifest validation + integrity checksum/tamper verification
- **Relay trust hardening**:
  - trust-on-first-use with local confirmation challenge
  - allowlist/revocation controls
  - relay actions routed through same broker/capability policy
- **Append-only security logging** with reason codes, redaction, rotation/retention, and forensic mode.
- **Local security dashboard** (Developer tab) to inspect allow/confirm/deny distribution, reason codes, and action categories.
- **External Review**: [Deep Analysis: Security, Memory, and the Local-First Paradigm — Reviewed by Gemini 3.1 Pro High](docs/verification/fae-security-review.md)

See: [Security Index](docs/guides/security-index.md), [Security Autonomy Boundary + Execution Plan](docs/guides/security-autonomy-boundary-and-execution-plan.md), [Security Launch SLOs](docs/guides/security-autonomy-launch-slos.md), and [Security PR Review Checklist](docs/checklists/security-pr-review-checklist.md).

### Safety & Autonomy Boundaries

Fae is designed to be highly autonomous — that is the point. But some operations are destructive enough that no amount of autonomy justifies executing them silently.

**Layer-zero Damage Control** runs before every tool call, before the broker, before any progressive approval logic. It enforces a three-tier response model:

| Tier | UI | Examples |
|---|---|---|
| **Block** | Hard deny, no dialog, no override | `rm -rf /`, disk format (`mkfs`, `diskutil erase`), raw disk write (`dd of=/dev/*`), `chmod -R 000 /` |
| **Disaster Warning** | Red-border overlay, physical click required, voice not accepted | `rm -rf ~/`, `rm -rf ~/Documents`, `rm -rf ~/Library` |
| **Confirm Manual** | Orange-border overlay, physical click required, voice not accepted | `sudo rm -rf`, `curl \| bash`, `wget \| bash`, `launchctl disable system/`, `osascript System Events` |

**Dual trust model for credential access:**

When a non-local (API/cloud co-work) model is active, the following paths are zero-access — reads and writes are hard-blocked, no dialog:

`~/.ssh` · `~/.gnupg` · `~/.aws` · `~/.azure` · `~/.kube` · `~/.docker/config.json` · `~/.netrc` · `~/.npmrc`

These credential blocks are inactive when the local MLX model is running. Fae's own data vault (`~/.fae-vault`) and data directory are always protected from deletion without manual confirmation.

See: [Damage Control Policy](docs/guides/damage-control.md) for the full three-tier model, default rules, dual trust model, rollback story, and YAML schema reference.

## Configuration

**Canonical preference:** Prefer skill contracts over hardcoded code paths; prefer asking Fae conversationally for setup/changes over manual config editing.

**Preferred:** ask Fae in chat to change settings. She will use skill/tool contracts, request missing values in plain English, and open guided forms when needed.

Raw config remains available for advanced troubleshooting:

Config file: `~/Library/Application Support/fae/config.toml` (macOS)

```toml
[llm]
maxTokens = 512
contextSizeTokens = 16384
temperature = 0.7
voiceModelPreset = "auto"
thinkingLevel = "balanced" # fast | balanced | deep
remoteProviderPreset = "openrouter"
remoteBaseURL = "https://openrouter.ai/api"
remoteModel = "anthropic/claude-sonnet-4.6"

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

[vision]
enabled = false
modelPreset = "auto"
```

## Documentation

### Architecture Decision Records

- [ADR-001: Cascaded Voice Pipeline](docs/adr/001-cascaded-voice-pipeline.md)
- [ADR-002: Embedded Rust Core](docs/adr/002-embedded-rust-core.md) (historical)
- [ADR-003: Local-Only LLM Inference](docs/adr/003-local-llm-inference.md)
- [ADR-004: Fae Identity and Personality](docs/adr/004-fae-identity-and-personality.md)
- [ADR-005: Self-Modification Safety](docs/adr/005-self-modification-safety.md)

### Guides

- [Security Index](docs/guides/security-index.md)
- [Damage Control Policy](docs/guides/damage-control.md)
- [Memory Guide](docs/guides/Memory.md)
- [Post-Training Strategy And Evaluation](docs/guides/post-training-and-evaluation.md)
- [Voice Identity Guide](docs/guides/voice-identity.md)
- [Self-Modification Guide](docs/guides/self-modification.md)
- [Channel Setup Guide](docs/guides/channels-setup.md)
- [Security Autonomy Boundary + Execution Plan](docs/guides/security-autonomy-boundary-and-execution-plan.md)
- [Security Launch SLOs](docs/guides/security-autonomy-launch-slos.md)
- [Security Contributor Guidelines](docs/guides/security-contributor-guidelines.md)
- [User Security Behavior Contract](docs/guides/user-security-behavior-contract.md)
- [Skills Manifest Migration Plan](docs/guides/skills-manifest-migration-plan.md)
- [Security Confirmation Copy](docs/guides/security-confirmation-copy.md)
- [Shadow Mode Dogfood Runbook](docs/guides/shadow-mode-dogfood-runbook.md)
- [Shadow Mode Threshold Tuning](docs/guides/shadow-mode-threshold-tuning.md)
- [Security Rollout Plan](docs/guides/security-rollout-plan.md)
- [Security Post-Release Iteration Loop](docs/guides/security-postrelease-iteration-loop.md)
- [Security PR Review Checklist](docs/checklists/security-pr-review-checklist.md)
- [Adversarial Security Suite Plan](docs/tests/adversarial-security-suite-plan.md)

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
