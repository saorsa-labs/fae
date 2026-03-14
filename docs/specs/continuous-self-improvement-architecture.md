# Fae: Continuous Self-Improvement Architecture

> **Status**: Vision + Design — foundational architecture document
> **Date**: 2026-03-14

## 1. The Thesis

Fae has five capabilities that, when composed, create something none of them can achieve alone:

1. **Forge** — she can build her own tools
2. **ACP** — she can delegate to specialist agents
3. **Local models** — she runs tiered inference (0.8B → 35B)
4. **Training pipeline** — she can prepare data and fine-tune models
5. **Memory** — she captures everything about her user

The composition creates a **closed self-improvement loop**: Fae's conversations generate training data → she delegates training to a coding agent → she deploys the improved model → her responses improve → she captures better conversations → the cycle continues. Meanwhile, she builds tools to solve problems she couldn't solve before, researches topics her user cares about, and shares what she learns with other Fae instances.

This document describes the architecture that makes this possible.

---

## 2. The Five Loops

Fae improves across five concurrent loops, each operating at a different timescale:

```
┌─────────────────────────────────────────────────────────────────────┐
│                                                                      │
│  LOOP 1: Turn-level (seconds)                                        │
│  Memory recall → better context → better response → memory capture   │
│                                                                      │
│  LOOP 2: Session-level (minutes–hours)                               │
│  User feedback → directive/skill update → behavior change            │
│                                                                      │
│  LOOP 3: Daily (overnight)                                           │
│  Research interests → capture findings → morning briefing            │
│  Skill proposals → Forge new tools → expand capabilities             │
│                                                                      │
│  LOOP 4: Weekly (model improvement)                                  │
│  Export training data → delegate LoRA training → evaluate →          │
│  deploy improved model → conversations improve                       │
│                                                                      │
│  LOOP 5: Community (peer-to-peer)                                    │
│  Build tool → share via Mesh → receive tools from other Fae →       │
│  capabilities expand across the network                              │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Loop 1: Turn-Level (Already Implemented)

Every conversation turn:
1. Memory recall (hybrid ANN + FTS5) injects relevant context
2. LLM generates a response grounded in user-specific knowledge
3. Memory capture extracts facts, preferences, relationships, commitments
4. Entity graph updates with new people, orgs, locations

**Timescale**: Seconds. **Status**: Fully implemented.

### Loop 2: Session-Level (Already Implemented)

During a conversation:
1. User gives feedback ("don't do that", "speak faster", "remember to always check calendar")
2. Fae updates settings (`self_config`), directives (`set_directive`), or skills (`manage_skill`)
3. Changes take effect immediately (no restart)

**Timescale**: Minutes. **Status**: Fully implemented.

### Loop 3: Daily (Partially Implemented)

Overnight and throughout the day:
1. **Research**: Web search on user interests, store findings as `.fact` memories
2. **Skill proposals**: Detect patterns → suggest new Python skills
3. **Forge**: Build new tools when existing ones can't solve a problem
4. **Morning briefing**: Calendar + mail + research findings + reminders

**Timescale**: Hours. **Status**: Research and briefing implemented. Forge exists but isn't triggered autonomously yet. Needs: proactive Forge invocation, ACP delegation for complex tool building.

### Loop 4: Weekly — Model Improvement (New)

This is the transformative loop:
1. **Export**: `prepare_training_data.py` converts conversation history to SFT/DPO format
2. **Curate**: Filter for quality, remove sensitive data, balance turn types
3. **Train**: LoRA fine-tuning on Qwen3.5 base models using `mlx_lm.lora`
4. **Evaluate**: Run benchmark suite against the new checkpoint
5. **Deploy**: If benchmarks pass, swap the model into production
6. **Observe**: The improved model generates better conversations → better training data

**Timescale**: Days to weeks. **Status**: Training scripts exist (`train_mlx_lora_smoke.sh`, `train_mlx_lora_chunked.sh`). Data preparation exists (`prepare_training_data.py`). Benchmarks exist (`scripts/benchmark-results/`). **Needs**: Orchestration layer to compose these into an autonomous pipeline, ACP delegation for heavy compute.

### Loop 5: Community (Partially Implemented)

Fae instances share capabilities:
1. **Forge** builds a tool → **Toolbox** registers it → **Mesh** shares it
2. Other Fae instances discover via Bonjour/mDNS → fetch with TOFU trust → install
3. The network's collective capability grows as any single Fae builds something useful

**Timescale**: Ongoing. **Status**: Forge, Toolbox, Mesh skills implemented. Needs: proactive sharing triggers, quality signals for community tools.

---

## 3. Subagent Delegation Architecture

The key to Loops 3–5 is **delegation** — Fae routes work to the right executor based on the task.

### 3.1 The Delegation Hierarchy

```
┌─────────────────────────────────────────────────────────┐
│                    Fae (Orchestrator)                     │
│                                                          │
│  Understands user intent, holds memory, makes decisions  │
│                                                          │
│  Delegates to:                                           │
│  ┌─────────────┐ ┌─────────────┐ ┌──────────────┐      │
│  │ Local Models │ │ ACP Agents  │ │ Forge Tools  │      │
│  │             │ │             │ │              │      │
│  │ 0.8B: quick │ │ Claude Code │ │ Zig binaries │      │
│  │ 2B: tools   │ │ Codex       │ │ Python scripts│     │
│  │ 4B: complex │ │ Gemini CLI  │ │ WASM modules │      │
│  │ 9B: analysis│ │ Copilot     │ │              │      │
│  │ 35B: synth  │ │ Custom      │ │              │      │
│  └─────────────┘ └─────────────┘ └──────────────┘      │
│                                                          │
│  Each executor has strengths. Fae learns which to use.   │
└─────────────────────────────────────────────────────────┘
```

### 3.2 Task Routing Policy

Fae decides where to route based on task characteristics:

| Task Type | Primary Executor | Fallback | Why |
|-----------|-----------------|----------|-----|
| Quick answer, greeting | Local 2B operator | — | Fastest, no network |
| Rich synthesis, summary | Local concierge (24B) | Local 9B | Deep thinking, no tools |
| File read, calendar check | Local 2B + tools | — | Simple tool use |
| Multi-file refactoring | ACP: Claude Code | ACP: Codex | Complex code changes |
| Test writing | ACP: Codex | ACP: Claude Code | Code generation |
| Build/CI debugging | ACP: Gemini CLI | ACP: Claude Code | Fast iteration |
| Data processing script | Forge: Python skill | ACP: Codex | Custom, reusable |
| Performance-critical tool | Forge: Zig binary | — | Native speed |
| Model training | ACP: Claude Code + local scripts | — | Heavy compute |
| Web research | Local 2B + web_search | ACP agent with browsing | Simple, local |
| HuggingFace model search | ACP: Claude Code | Local + fetch_url | Complex API navigation |

### 3.3 Learning Which Agent to Use

Fae doesn't have hardcoded routing rules — she learns from experience:

```swift
// After each agent delegation, memory captures:
MemoryRecord(
    kind: .fact,
    content: "Delegated Python test writing to Codex. Completed in 45s, all tests pass. User satisfied.",
    tags: ["agent_preference", "codex", "test_writing", "success"],
    confidence: 0.80
)

// On next similar task, recall surfaces:
// "Last time, Codex was good at writing Python tests (45s, all passed)"
// → LLM routes to Codex for Python tests
```

Over time, Fae develops agent preferences that are:
- **User-specific** — David's Fae might prefer Claude Code for Rust, while another user's Fae prefers Codex
- **Task-specific** — different agents for different kinds of work
- **Adaptive** — if an agent starts failing, Fae learns to avoid it
- **Emergent** — no hardcoded rules, just memory and judgment

---

## 4. The Model Self-Improvement Pipeline

This is the most ambitious loop — Fae improving her own weights.

### 4.1 What Exists Today

| Component | File | Status |
|-----------|------|--------|
| Training data export | `scripts/prepare_training_data.py` | Implemented |
| SFT data format | JSONL with `messages` array | Implemented |
| DPO data format | JSONL with `prompt/chosen/rejected` | Implemented |
| LoRA training (smoke test) | `scripts/train_mlx_lora_smoke.sh` | Implemented |
| LoRA training (chunked, production) | `scripts/train_mlx_lora_chunked.sh` | Implemented |
| Preference training (ORPO) | `scripts/train_mlx_tune_preference.sh` | Implemented |
| Benchmark evaluation | `scripts/benchmark-results/*.json` | Implemented |
| Model fusion | `scripts/fuse_and_benchmark_candidate.sh` | Implemented |
| Multimodal content handling | `extract_text_content()` in prep script | Implemented |

### 4.2 What the Autonomous Pipeline Looks Like

```
Night 1 (Data Preparation):
  Fae → overnight scheduler task
  → Export recent conversations to SFT format
  → Filter: remove sensitive data, balance turn types
  → Export DPO pairs from user corrections
  → Store dataset at ~/Library/.../fae/training/

Night 2 (Training):
  Fae → ACP session with Claude Code
  → "Run LoRA training on this dataset using train_mlx_lora_chunked.sh"
  → Claude Code executes the training script
  → Monitors loss curves, reports progress
  → Fae captures: "Training run complete, loss: 0.42, 500 steps"

Night 3 (Evaluation):
  Fae → ACP session with Claude Code (or local execution)
  → "Run the benchmark suite against the new checkpoint"
  → Execute fuse_and_benchmark_candidate.sh
  → Compare against current model's scores
  → Fae captures: "New model scores 78% on targeted benchmark (was 72%)"

Day 4 (Decision):
  Fae → morning briefing
  → "I trained an improved model overnight. It scores 78% on our benchmarks,
     up from 72%. Want me to switch to it?"
  → User says yes → Fae updates model config
  → User says no → Fae keeps current model, stores the checkpoint for later
```

### 4.3 Safety Rails

Model self-improvement is powerful and needs guardrails:

1. **Never auto-deploy** — Fae proposes, user decides. Always.
2. **Benchmark gate** — new model must score >= current model on ALL benchmark categories
3. **Rollback** — previous model checkpoint preserved, one-command revert
4. **Training data audit** — user can review what data Fae used for training
5. **Frequency cap** — max one training run per week (configurable)
6. **Resource gating** — training only during quiet hours, paused on battery/thermal
7. **Separation of concerns** — training runs in an ACP session (isolated process), not in Fae's main pipeline

### 4.4 The Preference Learning Loop

Beyond SFT, Fae can learn from implicit user feedback:

```
User: "Fae, summarise this document"
Fae (model v1): [produces verbose, meandering summary]
User: "Too long. Just the key points."
Fae (model v1): [produces concise summary]

→ DPO pair extracted:
  prompt: "Summarise this document"
  chosen: [concise version]
  rejected: [verbose version]

→ Next training run includes this preference
→ Model v2 naturally produces concise summaries
```

This is already supported by `extract_dpo_pairs()` in `prepare_training_data.py`. The gap is automated extraction of implicit corrections — detecting when the user's follow-up implies dissatisfaction with the first response.

### 4.5 HuggingFace Integration

Fae can use ACP agents to interact with the HuggingFace ecosystem:

| Task | How | Agent |
|------|-----|-------|
| Search for base models | `web_search` + `fetch_url` on HF Hub | Local |
| Download model weights | ACP: Claude Code runs `huggingface-cli download` | ACP |
| Upload fine-tuned model | ACP: Claude Code runs `huggingface-cli upload` | ACP |
| Search training datasets | ACP: Claude Code browses HF datasets | ACP |
| Publish Fae's training data | ACP: Claude Code creates HF dataset repo | ACP |
| Evaluate community models | Local: run benchmark suite against HF model | Local |

**The long game**: Fae could evaluate new Qwen/Llama/Mistral releases as they drop on HuggingFace, benchmark them against her current model, and recommend upgrades. She monitors the ecosystem on behalf of her user.

---

## 5. Capability Self-Improvement (Forge + ACP)

Beyond model weights, Fae improves her *capabilities* — the tools and skills she has.

### 5.1 Proactive Forge

Today, Forge is user-triggered ("Fae, build me a tool that..."). The next step is proactive Forge:

```
Fae notices: User asks about weather 3 times this week
→ Fae decides: I should build a weather skill
→ Fae uses Forge to scaffold a Python skill
→ If complex: delegates to ACP agent for implementation
→ Fae tests the skill, verifies it works
→ Fae tells user: "I built a weather skill — want me to enable it?"
```

**Trigger**: `skill_proposals` scheduler task already detects patterns. Currently it only suggests — extending it to build via Forge is the natural next step.

### 5.2 ACP-Assisted Forge

For complex tools, Fae can delegate the coding to a specialist:

```
Fae → Forge init (scaffold the project structure)
Fae → ACP: Claude Code "Implement this tool: [spec from SKILL.md]"
     Claude Code writes the code, runs tests
Fae → Forge build (compile)
Fae → Forge test (verify)
Fae → Forge release (package + register)
```

This means Fae can build tools that are beyond her local LLM's coding ability — she uses Claude Code or Codex as the "hands" while she provides the "brain" (understanding what the user needs).

### 5.3 Skill Evolution

Skills can improve themselves over time:

1. **Instruction refinement** — Fae uses `manage_skill patch` to update skill instructions based on what works
2. **Script improvement** — Fae delegates to ACP: "Improve the voice-tools normalize script to handle edge cases"
3. **New script addition** — "Add a new script to this skill that handles [observed gap]"
4. **Version tracking** — Forge tags each release, Git Vault preserves skill history

---

## 6. The Scheduler as Orchestration Engine

The scheduler becomes the heartbeat of self-improvement:

### 6.1 New Scheduled Tasks

| Task | Schedule | Loop | Purpose |
|------|----------|------|---------|
| `training_data_export` | Weekly Sun 01:00 | Loop 4 | Export conversations to training format |
| `model_training_check` | Weekly Mon 02:00 | Loop 4 | Delegate LoRA training if new data available |
| `model_evaluation` | After training completes | Loop 4 | Benchmark new checkpoint |
| `model_proposal` | Morning after eval | Loop 4 | Propose model upgrade to user |
| `forge_opportunity_scan` | Daily 14:00 | Loop 3 | Detect patterns worth building tools for |
| `acp_session_health` | Every 5min | Infra | Monitor active ACP sessions |
| `huggingface_model_watch` | Weekly | Loop 4 | Check for new base model releases |
| `skill_quality_review` | Monthly | Loop 3 | Review and improve existing skills |

### 6.2 Task Dependencies

Some tasks depend on others:

```
training_data_export
  └→ model_training_check (only if new data exported)
      └→ model_evaluation (only if training completed)
          └→ model_proposal (only if eval passed benchmarks)
```

This requires a simple dependency graph in the scheduler — a task can specify `dependsOn: [taskId]` and only runs if the dependency succeeded recently.

---

## 7. Multi-Model Delegation

Fae already runs multiple local models. ACP extends this to external models:

### 7.1 The Model Spectrum

```
Speed ←─────────────────────────────────────────────→ Capability

0.8B       2B        4B       9B      24B      Claude/Codex
(instant)  (fast)   (good)  (great)  (rich)   (expert)
  │         │         │        │        │          │
  │         │         │        │        │          └── Complex refactoring
  │         │         │        │        └── Summaries, plans, long-form
  │         │         │        └── Analysis, multi-step reasoning
  │         │         └── Standard tool use, coding
  │         └── Quick answers, simple tools (operator)
  └── Classification, routing, simple extraction
```

### 7.2 Internal Subagent Delegation

Before going to ACP (which requires network), Fae can delegate to her own models:

```swift
// Route within local model tier
if task.complexity == .simple {
    // Use 2B operator (already loaded, fast)
    return operatorEngine.generate(prompt: task.prompt, ...)
} else if task.isRichSynthesis {
    // Use concierge (24B, richer but no tools)
    return conciergeEngine.generate(prompt: task.prompt, ...)
} else if task.requiresDeepAnalysis {
    // Temporarily load 9B for this task
    return await loadAndUse(model: "qwen3_5_9b", for: task)
}
```

**Key insight**: Loading a 9B model for 30 seconds to do one hard task, then unloading it, is cheaper than sending the task to Claude Code (which costs API tokens and requires network).

### 7.3 When to Go External (ACP)

| Go external when... | Because... |
|---------------------|-----------|
| Task involves multi-file code changes | External agents have full project context and better code understanding |
| Task requires browsing/API interaction | Claude Code / Codex have built-in browsing |
| Task is model training | External agent can supervise the training script |
| Local models can't solve it after 2 attempts | Escalation — don't waste the user's time |
| User explicitly requests it | "Use Claude Code for this" |

---

## 8. Implementation Priorities

### Phase 1: ACP Foundation (enables all other phases)

See [ACP Integration Design](acp-integration-design.md) — bundle acpx, ACPSessionManager, tools, broker rules.

### Phase 2: Subagent Routing

- Local model tier switching (temporary 9B/4B loading for complex tasks)
- Agent preference memory (which agent worked for what)
- Automatic escalation (local failed → try ACP)

### Phase 3: Autonomous Training Pipeline

- `training_data_export` scheduler task
- ACP delegation for training execution
- Benchmark comparison automation
- User-facing model proposal

### Phase 4: Proactive Forge

- Pattern detection → tool proposal → build → test → deploy
- ACP-assisted Forge for complex tools
- Skill evolution via automated improvement

### Phase 5: Ecosystem Intelligence

- HuggingFace model watching
- Community tool quality signals
- Cross-Fae learning via Mesh

---

## 9. What We're NOT Building

To stay focused, these are explicitly out of scope:

- **Self-modifying core code** — Fae improves her models, skills, and tools. She does not modify her own Swift source code.
- **Autonomous network actions** — Fae doesn't publish to HuggingFace, push to GitHub, or send messages without user approval.
- **Unbounded compute** — Training runs are capped (time, GPU, frequency). ACP sessions have timeouts.
- **Model selection without consent** — Fae proposes model changes, never auto-deploys.
- **Privacy erosion** — Training data is local. Memory is local. Nothing leaves the Mac without explicit user action.

---

## 10. The End State

When all five loops are running:

**Monday morning**: Fae greets you with a briefing. She trained a slightly better model over the weekend using your conversation history. She built a new skill for tracking your project deadlines (she noticed you kept asking about them). She found a new HuggingFace model worth evaluating. She has research findings about the topics you discussed on Friday.

**You didn't configure any of this.** Fae observed, learned, and acted — within the boundaries you set, using the tools she built, improved by the models she trained, grounded in the memory she keeps.

That's the vision. Not one feature — the composition of all of them.

---

## Appendix A: Existing Infrastructure Map

| Component | File | Status |
|-----------|------|--------|
| Memory capture (8 kinds) | `Memory/MemoryOrchestrator.swift` | Implemented |
| Hybrid recall (ANN + FTS5) | `Memory/SQLiteMemoryStore.swift` | Implemented |
| Entity graph | `Memory/EntityStore.swift` | Implemented |
| Self-config (21 settings) | `Tools/BuiltinTools.swift` | Implemented |
| Directives | `Tools/BuiltinTools.swift` | Implemented |
| Skill create/update/patch | `Tools/SkillTools.swift` | Implemented |
| Forge (Zig/Python/WASM) | `Resources/Skills/forge/` | Implemented |
| Toolbox (local registry) | `Resources/Skills/toolbox/` | Implemented |
| Mesh (peer sharing) | `Resources/Skills/mesh/` | Implemented |
| Training data export | `scripts/prepare_training_data.py` | Implemented |
| LoRA training | `scripts/train_mlx_lora_chunked.sh` | Implemented |
| ORPO preference training | `scripts/train_mlx_tune_preference.sh` | Implemented |
| Model benchmarking | `scripts/fuse_and_benchmark_candidate.sh` | Implemented |
| Overnight research | `Scheduler/FaeScheduler.swift` | Implemented |
| Morning briefing | `Scheduler/FaeScheduler.swift` | Implemented |
| Proactive query handler | `Pipeline/PipelineCoordinator.swift` | Implemented |
| Worker subprocess (LLM) | `ML/WorkerLLMEngine.swift` | Implemented |
| Dual-model pipeline | `Pipeline/TurnRoutingPolicy.swift` | Implemented |
| ACP integration | `docs/specs/acp-integration-design.md` | **Designed** |
| Subagent routing | — | **Not started** |
| Autonomous training pipeline | — | **Not started** |
| Proactive Forge | — | **Not started** |
| HuggingFace watching | — | **Not started** |

## Appendix B: The Composition Table

How each capability multiplies the others:

| | Memory | Skills | Forge | ACP | Training | Mesh |
|---|--------|--------|-------|-----|----------|------|
| **Memory** | — | Skills improve from observed patterns | Forge triggers from detected needs | Agent preferences learned | Training data from conversations | Quality signals from peer tools |
| **Skills** | Capture skill outcomes | — | Forge builds new skills | ACP agents implement skill code | Better model = better skill use | Share skills across instances |
| **Forge** | Remember what tools worked | Skills trigger Forge | — | ACP writes complex tool code | Better model = better tool design | Share tools across instances |
| **ACP** | Remember agent preferences | Skills compose agent workflows | Forge builds ACP agents | — | Agents run training pipelines | — |
| **Training** | Conversations → training data | Skills improve with better model | Better tools from better model | Agents supervise training | — | Share training insights |
| **Mesh** | — | Receive community skills | Receive community tools | — | — | — |

Every cell in this table is a concrete capability, not speculation. The infrastructure exists — the work is composition and orchestration.
