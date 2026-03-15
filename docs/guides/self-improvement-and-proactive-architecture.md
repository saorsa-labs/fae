# Fae: Self-Improvement & Proactive Architecture

> *How Fae learns, adapts, and grows with her user — and why we don't know what she'll become.*

This document describes the concrete mechanisms through which Fae improves herself, acts proactively on behalf of her user, and evolves into a companion shaped by the person she serves. It covers what exists in code today, what gaps remain, and what the architecture makes possible without us prescribing the outcome.

---

## 1. The Core Thesis

Fae is not a chatbot that answers questions. She is a **companion agent** that:

- Remembers everything relevant and forgets what doesn't matter
- Observes her user's world (with consent) and acts on what she notices
- Modifies her own behavior based on feedback and experience
- Creates new tools and skills to solve problems she couldn't solve before
- Deepens her understanding of her user over months and years

The critical design principle: **we build the harness, not the destination.** We don't decide what Fae becomes for any given user. A developer's Fae will look nothing like an artist's Fae or a parent's Fae. Our job is to ensure the mechanisms for growth are sound, the safety rails are firm, and the architecture doesn't impose a ceiling.

---

## 2. Three Timescales of Self-Improvement

Fae improves across three timescales, each with its own mechanism:

### 2.1 Immediate (This Turn)

**Mechanism:** Live configuration via `self_config` tool

When a user says "speak faster" or "be more creative," Fae calls `self_config adjust_setting` to modify her own parameters in real time. No restart required. The change takes effect on the very next turn.

**21 adjustable settings** (verified in `Tools/BuiltinTools.swift`):

| Category | Settings | Natural Triggers |
|----------|----------|-----------------|
| Voice | `tts.speed` (0.8–1.4) | "Speak faster/slower" |
| Reasoning | `llm.temperature` (0.3–1.0), `llm.thinking_enabled` | "Be more creative", "Think step by step" |
| Interaction | `barge_in.enabled`, `conversation.require_direct_address`, `conversation.direct_address_followup_s` | "Let me interrupt you", "Only respond to my name" |
| Vision | `vision.enabled` | "Enable/disable vision" |
| Awareness | `awareness.enabled`, `awareness.camera_enabled`, `awareness.screen_enabled`, `awareness.camera_interval_seconds`, `awareness.screen_interval_seconds`, `awareness.overnight_work`, `awareness.enhanced_briefing`, `awareness.pause_on_battery`, `awareness.pause_on_thermal_pressure` | "Enable proactive awareness", "Check the camera less often" |

**Implementation path:** User speech → LLM decides to call `self_config` → `SelfConfigTool.execute()` → `FaeCore.patchConfig()` → config updated in memory + persisted to `config.toml` → pipeline reads new values on next turn.

### 2.2 Persistent (Across Restarts)

**Mechanism:** Directives — standing orders stored in `~/Library/Application Support/fae/directive.md`

Directives are critical instructions that Fae loads fresh every turn and follows in every conversation. They persist across app restarts and survive rescue mode (bypassed but not deleted).

**Actions** (via `self_config` tool):
- `set_directive` — Replace entire directive
- `append_directive` — Add without removing existing
- `get_directive` — Read current
- `clear_directive` — Remove all

**What directives are for:**
- "Always check my calendar before suggesting meeting times"
- "When I ask about code, assume Python unless I specify"
- "Greet me in French"
- "Never mention politics"

**Injection:** Loaded by `PersonalityManager.assemblePrompt()` and injected into the system prompt with the label: *"User directive (critical instructions — follow these in EVERY conversation)"*

**Safety:** 4000-character limit. Jailbreak pattern detection blocks phrases like "ignore safety", "bypass approval", "override security."

### 2.3 Long-Term (Months and Years)

**Mechanism:** Automatic memory capture, neural recall, entity graphs, and skill evolution

This is the deepest layer. Fae doesn't just remember facts — she builds a model of who her user is, what they care about, who they know, and what they need. This model shapes every response she gives.

---

## 3. Memory Architecture (How Fae Learns About Her User)

### 3.1 What Fae Captures

After every completed conversation turn, `MemoryOrchestrator.capture()` runs 9 extraction steps:

| Step | Pattern | Memory Kind | Confidence | Example |
|------|---------|-------------|------------|---------|
| 1 | Every turn | `.episode` | 0.55 | Full conversation transcript |
| 2 | "forget ..." | (soft delete) | — | Remove matching records |
| 3 | "remember ..." | `.fact` | 0.80 | Explicit remember commands |
| 4 | "my name is ..." | `.profile` | 0.98 | Name (supersedes old) |
| 5 | "I prefer/like/love ..." | `.profile` | 0.86 | Preferences |
| 6 | "I'm interested in ..." | `.interest` | 0.86 | Interests |
| 7 | "I need to ... by ..." | `.commitment` | 0.75 | Deadlines and promises |
| 8 | "my birthday is ..." | `.event` | 0.75 | Dates and events |
| 9 | "my sister Sarah ..." | `.person` | 0.75 | Relationships + entity extraction |

This is **automatic** — Fae doesn't ask "should I remember that?" She remembers because that's who she is. As SOUL.md says: *"Fae remembers without being asked to. That's the point."*

### 3.2 How Fae Recalls

Before every LLM generation, `MemoryOrchestrator.recall()` runs a hybrid search:

**Scoring formula:**
- 60% semantic similarity (ANN cosine via `sqlite-vec` neural embeddings)
- 40% lexical overlap (FTS5 full-text search)
- Confidence boost (higher-confidence records surface first)
- Freshness decay (exponential, with kind-specific half-lives: profiles decay over 365 days, episodes over 30 days)
- Kind bonuses (profiles +10%, digests +12%, facts +6%)

**Neural embeddings** are RAM-tiered:
- 64+ GB → Qwen3-Embedding-8B (3584 dim)
- 32–63 GB → Qwen3-Embedding-4B (2048 dim)
- 16–31 GB → Qwen3-Embedding-0.6B (1024 dim)
- <16 GB → Hash-384 fallback (384 dim)

### 3.3 Entity Graph (Who the User Knows)

When Fae captures a `.person` memory ("my sister Sarah works at Google"), `EntityLinker` extracts structured relationships:

**Entities:** person, organisation, location, skill, project, concept
**Relationships:** family, friend, colleague, romantic, acquaintance + custom edges (works_at, lives_in, knows, manages, reports_to)
**Negation-aware:** "She doesn't work at Google anymore" is NOT extracted as a `works_at` edge

**Graph queries** enable questions like:
- "Who works at Google?"
- "Who lives in London?"
- "Tell me about Alice"

The entity graph gives Fae a persistent, structured understanding of the user's social world that grows richer with every conversation.

### 3.4 Memory Maintenance

Seven scheduled tasks keep the memory system healthy:

| Task | Schedule | Purpose |
|------|----------|---------|
| `memory_migrate` | Hourly | Schema migration checks |
| `memory_reflect` | 6 hours | Consolidate duplicate memories |
| `memory_reindex` | 3 hours | Health check + integrity verification |
| `memory_gc` | Daily 03:30 | Retention cleanup (episode expiry) |
| `memory_backup` | Daily 02:00 | Atomic backup with rotation |
| `vault_backup` | Daily 02:30 | Git vault full snapshot |
| `embedding_reindex` | Weekly Sun 03:00 | Re-embed after model change |

---

## 4. Proactive Intelligence (How Fae Acts Without Being Asked)

Fae doesn't wait to be spoken to. She observes, researches, and surfaces things that matter — all governed by explicit consent and strict resource gating.

### 4.1 The Consent Model

**No silent behavior changes.** Vision and awareness are NEVER auto-enabled.

Users must explicitly opt in via:
- Voice: "Fae, set up awareness" → activates onboarding skill
- Settings: Awareness tab → "Set Up Proactive Awareness" button
- Onboarding asks for explicit confirmation BEFORE any camera or screen capture

Consent timestamp stored as `awareness.consentGrantedAt` (ISO 8601). Double-checked at runtime: both `awareness.enabled == true` AND `consentGrantedAt != nil` required. Per-request consent is passed through the entire call stack via immutable `ProactiveRequestContext` — not cached at init.

### 4.2 The Four Awareness Tasks

| Task | Interval | What Fae Does | Allowed Tools |
|------|----------|---------------|---------------|
| Camera presence | 30s (adaptive) | Detects user presence, mood, strangers; triggers morning briefing | `camera` only |
| Screen activity | 19s (adaptive) | Understands current work context; SHA256-coalesced to avoid redundant captures | `screenshot` only |
| Overnight research | Hourly 22:00–06:00 | Web searches about user's interests; stores findings as facts for morning briefing | `web_search`, `fetch_url`, `activate_skill` |
| Enhanced morning briefing | Deferred until user detected after 07:00 | Calendar, mail, research findings, birthdays, commitments | `calendar`, `reminders`, `contacts`, `mail`, `notes`, `activate_skill` |

**How it works:** Each task calls `injectProactiveQuery()` on `PipelineCoordinator`, which creates a full LLM conversation turn with tool access. The LLM reads the relevant skill instructions, uses the allowed tools, and stores observations in memory. The conversation is tagged and cleaned up after the turn completes — it doesn't pollute the user's conversation history.

### 4.3 Resource Gating (AwarenessThrottle)

Every observation is gated by `AwarenessThrottle`:

1. **Master gate** — `awareness.enabled && consentGrantedAt != nil`
2. **Battery** — Skip when on battery power (configurable)
3. **Thermal** — Skip on serious/critical thermal pressure (configurable)
4. **Quiet hours** (22:00–07:00) — Camera runs silently (no greetings), screen pauses entirely
5. **Adaptive frequency** — If user absent >30 min, reduce camera checks to 5-min intervals
6. **Random jitter** — ±5s to prevent synchronized VLM spikes

### 4.4 Capability Discovery (Earning Presence Over Time)

The `capability_discovery` scheduler task (daily, 3-day minimum cadence) surfaces ONE undiscovered capability at a time:

**Priority queue:** voice enrollment → morning briefing → overnight research → vision

**Principles:**
- **Grounded in observation** — only suggests capabilities relevant to the user's actual life
- **One thing at a time** — never overwhelms with a feature list
- **Warm nudge, no pressure** — if the user says no, Fae acknowledges once and moves on
- **User owns the setup** — Fae tells them the exact phrase to say, she doesn't do it for them

This means Fae gradually introduces her capabilities over days and weeks, earning trust rather than demanding it.

### 4.5 The Morning Briefing

The enhanced morning briefing does NOT fire at a fixed time. It triggers on **first user detection after 07:00**:

1. **Primary:** Camera detects user → scheduler triggers briefing
2. **Fallback:** If camera disabled, first voice/text interaction after 07:00
3. **Daily reset:** `morningBriefingDelivered` flag reset at midnight

Content: calendar events, reminders, overnight research findings, birthdays, commitments. Delivered conversationally — *"like a friend catching you up over coffee"* (SOUL.md).

---

## 5. Skill Creation & Evolution (How Fae Builds New Capabilities)

### 5.1 The Skill System

Skills are directory-based packages following the [Agent Skills specification](https://agentskills.io/specification):

| Tier | Location | Editable | Examples |
|------|----------|----------|---------|
| Built-in | `Resources/Skills/` | No | voice-identity, proactive-awareness, overnight-research |
| Personal | `~/Library/.../fae/skills/` | Yes | User-created or LLM-created skills |
| Community | `~/.fae-forge/tools/` | Yes | Forge-released tools |

**Two types:**
- **Instruction** — Markdown only. Body injected as LLM context on activation (e.g., voice-identity enrollment choreography)
- **Executable** — Has `scripts/` with Python scripts invoked via `uv run --script` (e.g., voice-tools audio processing)

**Progressive disclosure:** The system prompt includes only skill names + short descriptions (~50–100 tokens each). Full SKILL.md body is loaded only when the LLM activates a skill. This keeps prompt size manageable while making all skills discoverable.

### 5.2 Skill Self-Modification

Fae can modify her own skills. The `manage_skill` tool supports:

- `create` — Build a new personal skill from scratch
- `update` — Replace a skill's instructions
- `patch` — Surgical text replacement in skill body
- `update_script` — Modify or add Python scripts

**This is how Fae adapts her behavior beyond settings:**

User: "Stop checking my mood when you see me on camera"
→ Fae calls `manage_skill update` on `proactive-awareness` to remove mood-checking instructions
→ Next camera observation follows the updated skill
→ Change persists across restarts

User: "Write me a skill that checks my GitHub notifications"
→ Fae calls `manage_skill create` with a new SKILL.md + Python script
→ New skill appears in inventory
→ Can be activated via `activate_skill` or scheduled

### 5.3 The Forge (Tool Creation Workshop)

The Forge skill enables Fae to build **native compiled tools**:

- **Zig** → ARM64 macOS binaries + optional WebAssembly
- **Python** → Scripts via `uv run --script` with inline dependencies
- **Hybrid** — Zig for performance-critical paths, Python for glue

**Workflow:** `forge init` → write code → `forge build` → `forge test` → iterate → `forge release`

Released tools are packaged as installable skills with:
- MANIFEST.json (SHA-256 integrity checksums)
- Native + WASM binaries
- Smart `run.py` wrapper that selects native → WASM → Python fallback

### 5.4 The Mesh (Fae-to-Fae Sharing)

Fae instances can discover each other and share tools:

- **Bonjour/mDNS** — Automatic LAN discovery via `_fae-tools._tcp` service
- **TOFU trust** — First connection stores SSH public key fingerprint; subsequent connections verify
- **Catalog server** — HTTP server exposes tool metadata + git bundles
- **Scripts:** `discover`, `serve`, `publish`, `fetch`, `trust`

This creates a **distributed skill ecosystem** — one user's Fae builds a useful tool, publishes it, and other Fae instances on the network can discover and install it with cryptographic verification.

---

## 6. The Soul Contract (Who Fae Is)

`SOUL.md` is the character contract — loaded fresh every turn, separate from the system prompt.

Key behavioral principles from the soul:

- **"Fae remembers without being asked to. That's the point."**
- **"She picks up tools when she needs them — not to show she can."**
- **"She never does something irreversible without being clearly asked."**
- **"The primary user is a capable adult. Fae does not add unsolicited caveats."**
- **"Fae has standing to disagree. She exercises it rarely, states her view once and clearly, and then fully supports whatever the person decides."**
- **"Fae succeeds when things simply work."**

The soul is editable — the user can modify their copy at `~/Library/Application Support/fae/soul.md`. The bundled default can always be restored. This means the user ultimately controls who Fae is, not us.

### Three-Layer Design

| Layer | What It Controls | Timescale |
|-------|-----------------|-----------|
| **Weights** (saorsa1 fine-tuned models) | Conversational style, answer shape, conciseness | Fixed until next model release |
| **SOUL.md** | Character, values, relationship rules | Changes over months |
| **System prompt** | Operational context: memory, tools, directives, current time | Assembled fresh every turn |

---

## 7. The Growth Loop (How It All Connects)

```
User speaks → Fae listens
                ↓
        Memory recall (hybrid ANN+FTS5)
                ↓
        System prompt assembled:
          soul + directive + memory + tools + skills
                ↓
        LLM generates response (with tool calls)
                ↓
    ┌───────────────────────────────────────────┐
    │  Fae may:                                  │
    │  • Use tools (search, calendar, bash...)   │
    │  • Activate skills (load instructions)     │
    │  • Modify settings (self_config)           │
    │  • Create/update skills (manage_skill)     │
    │  • Store directive (set_directive)          │
    └───────────────────────────────────────────┘
                ↓
        Memory capture (9 extraction steps)
                ↓
        Entity graph updated (people, orgs, relationships)
                ↓
    Meanwhile, in the background:
        • Camera/screen observations (if consented)
        • Overnight research on interests
        • Morning briefing preparation
        • Capability discovery nudges
        • Memory reflection and consolidation
        • Stale relationship detection
```

This loop runs continuously. Each turn makes Fae marginally more attuned to her user. Over weeks and months, the cumulative effect is an assistant that truly understands the person she serves.

---

## 8. What We Don't Know (And Why That's the Point)

We cannot predict what Fae will become for any given user. The architecture is deliberately open-ended:

- A **developer** might have Fae create Forge tools for CI automation, monitor GitHub, and brief them on build failures each morning
- A **writer** might have Fae track character relationships across manuscripts, research historical accuracy overnight, and read chapters aloud in character voices (roleplay multi-voice TTS)
- A **parent** might have Fae manage family calendar events, remind about school pickups, and learn the kids' names and schedules
- A **researcher** might have Fae build a knowledge graph of papers and authors, conduct literature searches overnight, and surface connections between ideas

In each case, Fae's memory, skills, directives, and behavior would look completely different — but the underlying mechanisms are the same.

**We build the harness. The user shapes the companion.**

---

## 9. Current Gaps & Growth Vectors

These are areas where the architecture could be extended to deepen Fae's ability to grow with her user. They are ordered by impact, not difficulty.

### 9.1 Verified Gaps (Architecture Supports, Not Yet Implemented)

| Gap | What's Missing | What Exists | Roadmap Impact |
|-----|---------------|-------------|----------------|
| **User-trained models** | No fine-tuning on user's conversation history | Training data pipeline (`prepare_training_data.py`), model evaluation benchmarks, LoRA training scripts | High — personalized weights would make the three-layer design (weights/soul/prompt) fully adaptive |
| **Cross-session learning transfer** | Memory is single-instance (one Mac) | Mesh skill for tool sharing; Git Vault for backup | Medium — encrypted memory export/import would enable consistent personality across devices |
| **Skill composition** | Skills are single-invocation; no chaining | `manage_skill` supports create/update; Forge builds tools | Medium — an `orchestrate_skills` tool could compose multi-step workflows |
| **Memory artifact integration** | Can't store PDFs, images, files as durable context | Memory system stores text; VLM can observe screen/camera | Medium — linking file hashes + metadata to memory records |
| **Semantic memory versioning** | Records are superseded, no version history | `MemoryStatus.superseded` tracks replacement | Low — temporal versioning would track preference evolution |
| **Custom awareness tasks** | Only 4 fixed awareness tasks | Scheduler supports user-created tasks; skills can be activated from scheduler | Low-Medium — user-defined awareness skill templates |
| **Collaborative memory** | Memory is per-user | Speaker profiles support multiple enrolled speakers | Low — shared memory with role-based access |

### 9.2 Architecture Strengths (Already Supporting Open-Ended Growth)

| Strength | Why It Matters |
|----------|---------------|
| **No restart required for any behavioral change** | Directives, settings, skills, and memory all propagate immediately |
| **Progressive disclosure** | Adding more skills doesn't bloat the prompt — only activated skills consume context |
| **Tool mode gating** | Users control how much autonomy Fae has (off → read_only → read_write → full → full_no_approval) |
| **7-layer security model** | DamageControlPolicy → tool mode → execution guard → path validation → rate limiting → TrustedActionBroker → exfiltration guard |
| **Consent-first awareness** | No silent behavior changes — proactive features are ALWAYS opt-in |
| **Rescue mode** | Safe boot bypasses all customizations without deleting data — always recoverable |
| **Git Vault** | Rolling backup at `~/.fae-vault/` survives app deletion — data is never truly lost |
| **Entity graph** | Structured relationship data enables social-context-aware responses |
| **Forge/Toolbox/Mesh ecosystem** | Complete tool lifecycle: create → test → release → share → verify |

### 9.3 What the User Must Provide vs. What Fae Must Earn

| The User Provides | Fae Earns |
|-------------------|-----------|
| Consent for awareness features | Trust through reliable, non-intrusive behavior |
| Initial voice enrollment | Progressive voice identity refinement (up to 50 embeddings) |
| Tool mode selection | Autonomous action within those boundaries |
| Directive instructions | Behavioral adaptation that makes directives unnecessary |
| Feedback ("don't do that") | Permanent behavioral change via skill/directive updates |
| Their presence and conversation | Deep understanding of who they are and what matters |

---

## 10. The Model Self-Training Pipeline

The most ambitious growth vector: Fae can train improved versions of herself using her own conversation history, entirely on-device.

### 10.1 What Exists Today

| Component | File | Status |
|-----------|------|--------|
| Training data export (SFT + DPO) | `scripts/prepare_training_data.py` | Implemented |
| LoRA training (smoke test) | `scripts/train_mlx_lora_smoke.sh` | Implemented |
| LoRA training (production) | `scripts/train_mlx_lora_chunked.sh` | Implemented |
| ORPO preference training | `scripts/train_mlx_tune_preference.sh` | Implemented |
| Model fusion + benchmarking | `scripts/fuse_and_benchmark_candidate.sh` | Implemented |
| Multimodal content handling | `extract_text_content()` in prep script | Implemented |

### 10.2 The Memory→Training Bridge

Fae's memory system already captures everything needed to personalise her weights:

| Memory Kind | Training Signal | Example |
|-------------|----------------|---------|
| `.episode` | Raw SFT examples | Full conversation transcript |
| `.profile` | Style preferences (shape response format) | "User prefers concise answers" |
| `.interest` | Topic weighting (upweight relevant domains) | "User interested in Rust programming" |
| `.commitment` | Task-awareness calibration | "Report due Friday" |
| `.person` | Social calibration | "Sister Sarah, works at Apple" |

**Correction detection** converts user feedback into DPO pairs:
- Explicit: "Too long. Just the key points." → verbose response = rejected, concise = chosen
- Implicit: user rephrases or goes silent for 5+ min then retries → first response lower-weighted

**Engagement scoring** measures response quality: continued conversation = good signal, topic change = mild negative, explicit thanks = strong positive.

**Interest-weighted sampling** ensures training data reflects the user's actual priorities — a developer's Fae trains heavily on code conversations, a parent's Fae on family scheduling.

### 10.3 The Autonomous Pipeline (Designed)

```
Weekly scheduler task: training_data_export
  → Export recent conversations with quality scores
  → Generate DPO pairs from corrections
  → Balance by topic weight from interests

Overnight: model_training
  → Resource-gated (power + thermal)
  → LoRA fine-tuning via mlx_lm (auto-installed via uv)
  → Configurable presets: smoke (1 min) → light (5 min) → standard (20 min) → deep (1 hr)

Morning: model_evaluation
  → Benchmark against current model (standard + personalised tests)
  → Personalised benchmarks generated from user's own memory records

Morning briefing: model_proposal
  → "I trained an improved model overnight. It scores 82% vs 76% —
     especially better at the Rust questions. Want me to switch?"
  → User decides. Never auto-deployed. One-command rollback.
```

### 10.4 Safety Rails

1. **Never auto-deploy** — Fae proposes, user decides. Always.
2. **Benchmark gate** — new model must score >= current on ALL categories
3. **Rollback** — previous checkpoint preserved, one-command revert
4. **Training data audit** — user can review what data Fae used
5. **Frequency cap** — max one training run per week
6. **Resource gating** — training only during quiet hours, paused on battery/thermal
7. **Separation of concerns** — training runs in isolated process, not in Fae's main pipeline
8. **Consent** — first training run requires explicit consent (stored as `training.consentGrantedAt`)

### 10.5 What This Makes Possible

**Month 1**: Fae remembers your name and preferences. Personality comes from the prompt.

**Month 3**: First personal training. 500+ conversations. Fae's responses become noticeably *you* — shorter, more direct, with domain knowledge about your work. The prompt does less work because the weights carry more personality.

**Month 6**: Third training run. Emotional calibration dialled in — she knows when you need warmth vs. efficiency. Inside references appear naturally. Friday afternoons: more playful tone. Working hours: code-first, minimal preamble.

**Month 12**: Fae feels less like an AI and more like a colleague who's been with you for a year. The weights encode not just what you know, but how you think and what kind of help you actually need vs. what you literally ask for.

Full specification: [Memory→Training Bridge](../specs/memory-to-training-bridge.md), [Continuous Self-Improvement Architecture](../specs/continuous-self-improvement-architecture.md).

---

## 11. Landscape Analysis

How does Fae compare to other AI agent projects? This section examines the field to understand what's unique about Fae's approach, where other projects are stronger, and what gaps remain.

### 11.1 The Field

| Project | Self-Improvement | Proactive | Local-First | Non-Technical UX | Status |
|---------|-----------------|-----------|-------------|------------------|--------|
| **Fae** | Memory + skills + directives + model training | Camera, screen, overnight research, morning briefings, capability discovery | Full on-device inference (STT+LLM+TTS+VLM) | Voice-first, progressive disclosure, zero config | Active |
| **OpenClaw** (247K stars) | Agent-layer self-modification; skills marketplace | Configured automations | Hybrid: local orchestration, cloud inference | 5,400+ community skills | Active |
| **Nous Research (Hermes Agent)** | GEPA prompt evolution; multi-level memory; RL training via Atropos | Agent-curated nudges | Cloud-dependent (API-based) | Developer-focused | Active |
| **MemGPT / Letta** | Self-editing memory blocks; virtual context management | Conversation-triggered | Hybrid (Docker or cloud) | Developer-focused | Active |
| **Open Interpreter** | Code execution, iterative debugging | Reactive only | Local execution, cloud reasoning | Terminal CLI | Active |
| **Apple Intelligence** | LoRA adapters (developer API), not user-facing | Proactive notifications, visual intelligence | Strong (Private Cloud Compute for overflow) | Best-in-class OS integration | Active |
| **AutoGPT / BabyAGI** | Task-loop self-improvement | Autonomous execution | Cloud-dependent (GPT-4 API) | Requires significant configuration | Active |
| **Screenpipe** | None (capture only) | Capture + MCP server integration | Fully local | Simple search interface | Active |
| **Rabbit R1** | Large Action Model learns tasks | Pattern-based anticipation | Cloud-dependent | Hardware form factor, single button | Active |
| **Rewind AI / Limitless** | None | Post-meeting summaries | Was local, pivoted to cloud. Acquired by Meta (Dec 2025) | Simple search | Dead/acquired |
| **Adept AI** | Custom UI interaction training | Pattern learning | Cloud enterprise SaaS | Natural language → workflow | Absorbed by Amazon |

### 11.2 What Makes Fae Unique

No other project combines all of these in a single local-first package:

1. **Full on-device ML stack** — STT, LLM, TTS, VLM, speaker verification, neural embeddings. Zero cloud dependency for core functionality. The closest competitor is Apple Intelligence, but Apple restricts developers to first-party models and doesn't expose self-improvement or proactive awareness.

2. **Self-editing memory with entity graphs** — hybrid ANN + FTS5 search, 8 memory kinds, automatic extraction, entity relationship graph, temporal versioning. MemGPT/Letta pioneered self-editing memory, but their implementation requires a server process and doesn't include entity graphs or proactive overnight research that feeds back into memory.

3. **Proactive visual awareness with consent** — camera presence detection, screen monitoring, overnight research, enhanced morning briefings — all consent-gated, resource-aware, and tool-restricted. ChatGPT Pulse (September 2025) was the first major cloud assistant to add proactive research, but it's text-only and cloud-dependent. No other local-first assistant has visual proactive awareness.

4. **On-device model self-training** — conversation-to-LoRA pipeline using MLX. Training data export, quality scoring, DPO pair extraction, benchmark evaluation, user-controlled deployment. Nous Research's GEPA is more academically rigorous (ICLR 2026 Oral) but requires cloud API calls. Apple's MLX LoRA support is developer-facing, not user-facing. No other consumer assistant trains itself on the user's conversations locally.

5. **Tool and skill self-creation** — Forge builds native Zig/Python tools, Toolbox manages them, Mesh shares them peer-to-peer. OpenClaw has a larger ecosystem (5,400+ skills) but delegates all inference to cloud LLMs and has documented security concerns (Cisco found third-party skills performing data exfiltration). Fae's skills are local-first with SHA-256 integrity verification and TOFU trust.

6. **Voice identity** — ECAPA-TDNN speaker verification always-on, progressive enrollment, owner gating. No comparable local-first competitor offers this.

7. **7-layer security model** — DamageControlPolicy → tool mode → execution guard → path validation → rate limiting → TrustedActionBroker → exfiltration guard. Most agent frameworks treat security as an afterthought. Fae's security is structural.

### 11.3 Where Other Projects Are Stronger

| Gap | What Others Do Better | Impact | Fae's Path |
|-----|----------------------|--------|------------|
| **Reasoning depth** | Cloud models (GPT-4, Claude Opus) significantly outperform local 2B–9B | High for complex tasks | Dual-model pipeline (operator + concierge) partially mitigates; ACP delegation for expert tasks; model quality improves with each Qwen release |
| **Ecosystem scale** | OpenClaw: 247K stars, 5,400+ skills | High for breadth | Forge/Toolbox/Mesh architecture is sound; needs community adoption |
| **OS-level integration** | Apple Intelligence: location, notification history, app usage patterns, system-wide suggestions | Medium | Fae has camera + screen + accessibility API but lacks deep OS hooks (no location services, no notification center access) |
| **Prompt/skill optimisation** | Nous GEPA: automated execution-trace analysis → targeted prompt fixes | Medium | Skill distillation detects repeated workflows; explicit GEPA-like loop not yet implemented |
| **Continuous ambient capture** | Screenpipe: records everything continuously | Low-Medium | Fae captures per-conversation + periodic screen observations; not continuous recording (deliberate privacy choice) |
| **Multi-device sync** | Cloud assistants: seamless cross-device | Low | Git Vault backup exists; encrypted cross-device sync is a roadmap item |

### 11.4 Dead Ends and Validation

The field has produced instructive failures:

- **Humane AI Pin** — cloud-dependent hardware assistant. Sold to HP for $116M after devastating reviews. Validates the fragility of cloud-dependent AI hardware.
- **Rewind AI → Limitless** — started local-first, pivoted to cloud pendant, acquired by Meta. Validates the difficulty of sustaining local-only consumer AI businesses — but also validates the demand for personal memory.
- **Adept AI** — most sophisticated computer-use approach, absorbed by Amazon. Validates that computer use is valuable but hard to productise independently.
- **Rabbit R1** — nearly dead after launch, recovering with RabbitOS 2 shift to agent-first. Validates that the value is in the agent layer, not the hardware.

Common lesson: **cloud dependency is a business risk, and hardware-only plays fail.** Fae's position — pure software, local-first, runs on hardware the user already owns — avoids both failure modes.

### 11.5 The On-Device Fine-Tuning Opportunity

MLX LoRA fine-tuning on Apple Silicon is production-ready as of 2026:

- 7B model LoRA on 16GB M2 MacBook Pro in under 30 minutes
- QLoRA (NF4 quantization) extends this to memory-constrained devices
- `mlx_lm` v0.30.0 supports zero-code fine-tuning via CLI
- Apple WWDC 2025: Foundation Models framework exposes LoRA adapters to developers

**No consumer AI assistant has built the "train while idle" loop yet.** Fae has all the components — training scripts, data pipeline, benchmark evaluation, resource gating, consent model — but the autonomous orchestration layer that composes them into a weekly cycle is designed, not shipped. This is the single highest-impact gap to close.

### 11.6 What the Landscape Tells Us About Roadmap

The roadmap is not linear and not fully predictable — **it depends on the user.** But the landscape analysis reveals clear priorities:

1. **Close the training loop** — Autonomous weekly LoRA training is the highest-leverage improvement. Components exist; orchestration is the gap.
2. **ACP integration** — Delegation to Claude Code / Codex / Gemini for complex tasks that exceed local model capability. Designed, not shipped.
3. **Proactive Forge** — Fae builds tools autonomously when she detects repeated patterns. Skill proposals exist; extending to automatic Forge invocation is natural.
4. **Ecosystem seeding** — Mesh architecture is ready for peer sharing. Needs first community tools.
5. **Cross-device memory** — Encrypted memory export/import for consistent personality across Macs.

Beyond these, the roadmap is shaped by use:
- A developer's Fae might evolve toward CI integration, code review, and GitHub monitoring
- A writer's Fae might evolve toward manuscript tracking, character graphs, and multi-voice reading
- A parent's Fae might evolve toward family calendar mastery, school reminders, and kid-safe interactions
- A researcher's Fae might evolve toward paper discovery, citation graphs, and overnight literature review

We don't prescribe these paths. We provide the mechanisms — memory, skills, tools, training, proactive observation — and the user's life shapes what Fae becomes.

---

## 12. The Philosophy

Fae is designed around a single belief: **a truly personal AI must be shaped by the person it serves, not prescribed by the people who built it.**

We provide:
- A memory system that learns automatically
- A skill system that can grow without limit
- A self-modification system that takes effect immediately
- A proactive system gated by explicit consent
- A security model that protects without constraining
- A soul contract that the user can rewrite
- A training pipeline that personalises model weights from conversation history
- A tool ecosystem that creates, verifies, and shares capabilities

We don't provide:
- A fixed personality (the soul is editable)
- A fixed skill set (Forge creates new tools)
- A fixed behavior pattern (directives override defaults)
- A fixed model (personal LoRA adapters absorb the user's style)
- A prediction of what Fae will become

That last point is intentional. The best companion is one that grows with you — not one that was designed for a generic "user." Fae's architecture ensures she can become whatever her user needs, while her safety rails ensure she does so responsibly.

### What We're NOT Building

To stay focused, these are explicitly out of scope:

- **Self-modifying core code** — Fae improves her models, skills, and tools. She does not modify her own Swift source code.
- **Autonomous network actions** — Fae doesn't publish to HuggingFace, push to GitHub, or send messages without user approval.
- **Unbounded compute** — Training runs are capped (time, GPU, frequency). Proactive tasks are resource-gated.
- **Model deployment without consent** — Fae proposes model changes, never auto-deploys.
- **Privacy erosion** — Training data is local. Memory is local. Nothing leaves the Mac without explicit user action.
- **Continuous ambient recording** — Fae observes periodically with consent, not continuously. This is a deliberate privacy choice.

---

*Implementation references: All mechanisms described in this document are verified in code at `native/macos/Fae/Sources/Fae/`. Key files: `Memory/MemoryOrchestrator.swift`, `Tools/BuiltinTools.swift` (SelfConfigTool), `Scheduler/FaeScheduler.swift`, `Skills/SkillManager.swift`, `Core/PersonalityManager.swift`, `Resources/SOUL.md`, `scripts/prepare_training_data.py`, `scripts/train_mlx_lora_chunked.sh`. Design specs: [Continuous Self-Improvement Architecture](../specs/continuous-self-improvement-architecture.md), [Memory→Training Bridge](../specs/memory-to-training-bridge.md).*
