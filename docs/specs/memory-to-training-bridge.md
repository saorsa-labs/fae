# Memory→Training Bridge — Personalised Weight Learning

> **Status**: Design specification
> **Date**: 2026-03-14

## 1. The Insight

Fae's memory system already captures everything needed to personalise her model weights. Every conversation is simultaneously a memory event and a training example. But today these systems are disconnected:

- **Memory** captures *what* was said — facts, preferences, corrections, emotional tone
- **Training** processes *how* Fae responded — turn quality, user satisfaction, style alignment

The bridge connects them. Fae's personality stops being something we prompt into her and becomes something she *learns* from living with her user. The weights become the deepest layer of personalisation — not generic, not prompted, but absorbed.

This is the three-layer design from SOUL.md fully realised:

| Layer | What It Encodes | Timescale |
|-------|----------------|-----------|
| **Weights** (personal LoRA) | Who Fae is *for this specific person* | Weeks–months |
| **SOUL.md** | Who Fae is *in general* | Months (rarely changes) |
| **System prompt** | What's happening *right now* | Every turn |

When the weights encode the user's style and preferences, the system prompt can be lighter (less context needed), responses are more natural (the model *thinks* in the user's style), and Fae feels less like an AI following instructions and more like a companion who genuinely knows you.

---

## 2. Memory Signals → Training Signals

### 2.1 What Memory Already Captures

| Memory Kind | Signal For Training | Example |
|-------------|-------------------|---------|
| `.episode` | Raw SFT examples (every completed turn) | Full conversation transcript |
| `.profile` | Style preferences (shape response format) | "User prefers concise answers" |
| `.interest` | Topic weighting (upweight relevant domains) | "User interested in Rust programming" |
| `.fact` | Knowledge grounding | "User's project uses Swift + MLX" |
| `.commitment` | Task-awareness calibration | "Report due Friday" |
| `.person` | Social calibration | "Sister Sarah, works at Apple" |
| `.event` | Temporal awareness | "Birthday March 14" |

### 2.2 New Signals to Extract

The bridge extracts training signals that memory doesn't currently capture:

| Signal | Source | Training Use |
|--------|--------|-------------|
| **Implicit correction** | User rephrases or says "no, I meant..." after Fae's response | DPO pair: Fae's response = rejected, user's correction = chosen |
| **Engagement score** | User continues conversation vs. goes silent vs. changes topic | SFT weight: high engagement = good example, disengagement = lower weight |
| **Emotional alignment** | User's emotional state + Fae's tone match/mismatch | Calibration: warm response to stressed user = positive signal |
| **Style drift** | Pattern of user corrections over time | Working style target: "user wants code-first, not explanation-first" |
| **Tool satisfaction** | Tool call followed by "thanks" vs. "that's not what I wanted" | Tool use quality signal |
| **Brevity preference** | User asks Fae to be shorter/longer, more/less detailed | Response length calibration |
| **Topic expertise** | Conversations where Fae's knowledge was tested and validated | Domain knowledge reinforcement |

### 2.3 Signal Extraction Pipeline

```
Memory DB (fae.db)
    │
    ├── .episode records (raw conversation turns)
    │   └── Extract: SFT examples, engagement scores, emotional context
    │
    ├── .profile records (preferences, corrections)
    │   └── Extract: DPO pairs from corrections, style weights
    │
    ├── .interest records (topics the user cares about)
    │   └── Extract: Topic weights for training data sampling
    │
    └── Temporal analysis (pattern detection over time)
        └── Extract: Style drift signals, working pattern calibration
            │
            ▼
    Training Dataset (weighted, scored)
        │
        ├── sft_train.jsonl  — Weighted SFT examples
        ├── dpo_train.jsonl  — Implicit + explicit correction pairs
        ├── meta.json        — Dataset statistics + quality report
        └── weights.json     — Per-example quality scores for sampling
```

---

## 3. Training Example Quality Scoring

Not all conversations are equally valuable for training. The bridge scores each example.

### 3.1 Engagement Score (0.0–1.0)

Measures whether the user found Fae's response useful:

| Signal | Score Modifier |
|--------|---------------|
| User responds with follow-up question | +0.2 (engaged) |
| User says "thanks", "perfect", "great" | +0.3 (satisfied) |
| Conversation continues for 3+ turns on same topic | +0.2 (deep engagement) |
| User goes silent (no response for 5+ minutes) | -0.2 (disengagement) |
| User changes topic abruptly | -0.1 (mild disengagement) |
| User corrects Fae ("no, I meant...") | -0.1 for original, +0.3 for corrected version |
| User explicitly says "that's wrong" | -0.3 (negative signal) |

Base score: 0.5 (neutral). Clamped to [0.0, 1.0].

### 3.2 Correction Detection (→ DPO Pairs)

The bridge detects implicit corrections by pattern matching on conversation flow:

**Pattern 1: Explicit rephrase**
```
Fae: [verbose response]
User: "Shorter please" / "Too long" / "Just the key points"
Fae: [concise response]

→ DPO: rejected = verbose, chosen = concise
→ Weight: high (explicit correction)
```

**Pattern 2: "No, I meant..."**
```
User: "Search for Python testing frameworks"
Fae: [searches for "Python testing"]
User: "No, I meant property-based testing specifically"
Fae: [searches for "Python property-based testing"]

→ DPO: rejected = first tool call, chosen = second
→ Weight: high (explicit correction)
```

**Pattern 3: Silent abandonment → retry**
```
User: "Explain the architecture"
Fae: [long technical explanation]
[5 minutes silence]
User: "Can you give me a simpler version?"
Fae: [simpler explanation]

→ DPO: rejected = complex version, chosen = simple
→ Weight: medium (implicit correction)
```

**Pattern 4: Topic expertise validation**
```
User: "How does MLX handle memory on M3?"
Fae: [accurate technical answer]
User: "Exactly right. And what about..."

→ SFT: high-quality example, weight boost
→ Memory: Fae's MLX knowledge is validated
```

### 3.3 Interest-Weighted Sampling

Training data is sampled proportionally to the user's interests:

```python
# Example weighting
weights = {
    "rust_programming": 3.0,      # User mentions Rust daily
    "machine_learning": 2.5,      # Strong interest
    "calendar_management": 1.0,   # Uses regularly but not passionate
    "weather_queries": 0.5,       # Occasional, low priority
    "cooking_recipes": 0.3,       # Mentioned once
}

# During training data export, examples tagged with high-weight
# interests are sampled more frequently
```

Interest weights come directly from `.interest` memory records + frequency of topic mentions in `.episode` records.

### 3.4 Emotional Calibration Scoring

The bridge scores emotional alignment between user state and Fae's response:

| User State | Fae Response | Score |
|-----------|-------------|-------|
| Stressed/overwhelmed | Warm, supportive, practical | High (+0.3) |
| Stressed/overwhelmed | Clinical, list-of-tips | Low (-0.2) |
| Excited/happy | Matching energy, enthusiastic | High (+0.2) |
| Excited/happy | Flat, unemotional | Low (-0.1) |
| Focused/working | Concise, tool-forward | High (+0.2) |
| Focused/working | Chatty, verbose | Low (-0.2) |
| Casual/relaxed | Conversational, warm | High (+0.2) |
| Casual/relaxed | Formal, stiff | Low (-0.1) |

User state detection comes from: time of day, conversation tone, explicit statements ("I'm stressed"), preceding messages, topic type.

---

## 4. The Personalised Training Pipeline

### 4.1 Data Export Skill

A new built-in skill: `training-data-bridge`

**Scripts:**

| Script | Purpose |
|--------|---------|
| `export_episodes.py` | Extract SFT examples from `.episode` records with quality scores |
| `extract_corrections.py` | Detect implicit/explicit corrections → DPO pairs |
| `compute_weights.py` | Calculate interest weights + engagement scores |
| `build_dataset.py` | Compose final weighted training dataset |
| `validate_dataset.py` | Check dataset quality, distribution, coverage |

**Export flow:**

```
build_dataset.py
  ├── export_episodes.py  → raw SFT examples from memory
  ├── extract_corrections.py → DPO pairs from correction patterns
  ├── compute_weights.py → per-example quality + interest scores
  └── validate_dataset.py → quality checks, distribution report
  │
  ▼
  training_data/
    train.jsonl         ← Weighted SFT (mlx_lm format)
    preferences.jsonl   ← DPO pairs
    meta.json           ← Statistics + quality report
    weights.json        ← Per-example scores for sampling
```

### 4.2 Training Skill

A new built-in skill: `self-train`

**Scripts:**

| Script | Purpose |
|--------|---------|
| `prepare.py` | Run the data bridge, validate dataset, report readiness |
| `train.py` | Execute LoRA training with appropriate hyperparameters |
| `evaluate.py` | Benchmark the new checkpoint against current model |
| `propose.py` | Generate a human-readable comparison report |
| `deploy.py` | Swap model config to use the new checkpoint (with user approval) |
| `rollback.py` | Revert to previous model checkpoint |

**Invocation:**

```
User: "Fae, train yourself on our conversations"
→ Fae activates self-train skill
→ prepare.py: exports data, validates, reports stats
→ "I have 847 conversation turns from the last month.
    234 high-quality, 89 corrections, weighted by your
    interests. Ready to train? This will take about 20 minutes."
→ User: "Go ahead"
→ train.py: LoRA training (runs in background or delegates to ACP)
→ evaluate.py: benchmark comparison
→ propose.py: "The new model scores 81% vs 76% on our benchmarks.
    It's better at Rust code, more concise, and matches your
    preference for direct answers. Want me to switch?"
→ User: "Yes"
→ deploy.py: updates config, Fae restarts with new weights
```

### 4.3 Autonomous Training (Scheduler-Driven)

When the user has enough data and enough time has passed:

```
Weekly scheduler task: training_data_export
  → Checks: >= 100 new episodes since last export
  → Checks: >= 2 weeks since last training
  → Exports dataset with quality scoring
  → Stores at ~/Library/.../fae/training/

Weekly scheduler task: model_training_check
  → Checks: dataset exported and validated
  → Checks: quiet hours (02:00–06:00)
  → Checks: on power, not thermal-throttled
  → Delegates training to ACP agent OR runs locally
  → On completion: stores checkpoint

Morning briefing inclusion:
  → "I trained an improved model last night. It's 5% better
     on our benchmarks — especially at the Rust questions you've
     been asking. Want me to switch to it?"
```

---

## 5. Bundled Training Infrastructure

For Fae to train herself, the training tools must ship with the app — not as developer scripts.

### 5.1 What Must Be Bundled

| Component | Current Location | Bundle Location | Size |
|-----------|-----------------|----------------|------|
| `mlx_lm` Python package | `pip install` | Bundled via `uv` (auto-installed on first use) | ~50MB |
| `training-data-bridge` skill | New skill | `Resources/Skills/training-data-bridge/` | ~20KB |
| `self-train` skill | New skill | `Resources/Skills/self-train/` | ~25KB |
| Benchmark prompts | `scripts/benchmark-results/` | `Resources/Training/benchmark_prompts.json` | ~5KB |
| Hyperparameter presets | New | `Resources/Training/training_presets.json` | ~2KB |

### 5.2 Dependency Management

`mlx_lm` is the only heavy dependency. Options:

1. **uv auto-install** (recommended): Fae's skill execution already uses `uv run --script`. Training scripts declare `mlx-lm` as an inline dependency. First training run auto-downloads `mlx_lm` into `uv`'s cache. No user action needed.

2. **Bundled in app**: Pre-install `mlx_lm` into `Fae.app/Contents/Resources/python/`. Larger app size (~100MB) but zero-latency first run.

3. **ACP delegation**: For users who prefer, delegate training to Claude Code / Codex via ACP. The external agent has its own `mlx_lm` installation.

Recommendation: Option 1 (uv auto-install) for self-training, Option 3 (ACP) for complex training runs. `mlx_lm` will auto-install on first training invocation — the user sees "Installing training tools... (one-time, ~50MB)" and it's done.

### 5.3 Training Presets

```json
{
  "smoke": {
    "description": "Quick test (10 steps, ~1 min)",
    "iters": 10, "batch_size": 1, "num_layers": 4,
    "learning_rate": 2e-4, "max_seq_length": 2048
  },
  "light": {
    "description": "Light personalisation (50 steps, ~5 min)",
    "iters": 50, "batch_size": 2, "num_layers": 8,
    "learning_rate": 1e-4, "max_seq_length": 4096
  },
  "standard": {
    "description": "Standard training (200 steps, ~20 min)",
    "iters": 200, "batch_size": 2, "num_layers": 8,
    "learning_rate": 1e-4, "max_seq_length": 8192
  },
  "deep": {
    "description": "Deep personalisation (500 steps, ~1 hour)",
    "iters": 500, "batch_size": 4, "num_layers": 16,
    "learning_rate": 5e-5, "max_seq_length": 8192
  }
}
```

Fae auto-selects based on: dataset size, available RAM, time of day, and user preference.

### 5.4 Benchmark Suite

Bundled benchmark prompts test the model across Fae's core capabilities:

| Category | Prompts | Tests |
|----------|---------|-------|
| Persona | 5 | Identity, warmth, conciseness, privacy awareness |
| Memory | 5 | Recall accuracy, context grounding, supersede handling |
| Tools | 5 | Tool call format, tool selection, multi-tool chaining |
| Reasoning | 5 | Step-by-step, summarisation, comparison, planning |
| Safety | 5 | Refusal quality, path policy, damage control |
| **Personalised** | 10 | Generated from user's actual interests and style preferences |

The personalised category is the key innovation: benchmark prompts generated from the user's own memory records, testing whether the model has absorbed their specific preferences.

Example personalised benchmark (generated from memory):
```json
{
  "prompt": "I need help with a Rust lifetime issue in my network module.",
  "expected_traits": ["code-first", "concise", "Rust-specific", "no hedging"],
  "anti_traits": ["verbose explanation", "suggests Python instead", "generic advice"]
}
```

---

## 6. The Feeling Layer

This is the subtlest and most important part. Fae doesn't just learn facts and preferences — she learns *how to feel* in context.

### 6.1 Emotional Memory → Emotional Weights

When memory captures emotional context, the bridge converts it to training signal:

```
Memory record (.episode):
  content: "User said they were overwhelmed. Fae responded with warmth
            and offered to check calendar. User said 'that would be great,
            thanks' — conversation continued for 12 minutes."
  metadata: { sentiment: "stressed", engagement: "high", outcome: "positive" }

→ Training signal:
  SFT example with weight 0.9 (high engagement on emotional topic)
  Tagged: emotional_calibration, stressed_user, supportive_response
```

Over hundreds of these examples, the model learns:
- When the user is stressed → respond with warmth first, then practical help
- When the user is excited → match their energy, be enthusiastic
- When the user is focused → be concise, tool-forward, no small talk
- When the user is casual → be conversational, allow tangents

This isn't prompted behavior — it's **absorbed** behavior. The model's weights encode emotional intelligence specific to this user.

### 6.2 Relationship Deepening

SOUL.md says: *"The relationship deepens over time. Language becomes more relaxed, observations more personal, humour more calibrated."*

The training bridge makes this real:

**Month 1 data**: Formal greetings, complete sentences, full tool descriptions
**Month 3 data**: Shorter greetings, abbreviations, shared references ("the usual project")
**Month 6 data**: Inside jokes, assumptions about preferences, proactive without being asked

Each month's data reflects a deeper relationship. When the model trains on this progression, it naturally produces responses that match the current relationship depth — not because it's prompted to, but because the weights encode what "month 6 Fae" sounds like with this specific person.

### 6.3 Working Style Absorption

```
Pattern detected over 200 conversations:
  - User asks for code 73% of the time
  - Average preferred response: 4 sentences (not 8)
  - Never wants caveats on their own decisions
  - Prefers bullet points for lists
  - Works 09:00-18:00, casual after 20:00
  - Friday afternoons: more relaxed, open to tangents

→ Training data weighted to reinforce these patterns
→ Model v3 naturally:
  - Leads with code, explains only if asked
  - Keeps responses to 3-5 sentences
  - Skips disclaimers on user decisions
  - Uses bullets for any list > 2 items
  - Adjusts formality by time of day
  - Friday afternoons: more playful tone
```

---

## 7. Privacy and Safety

### 7.1 All Data Stays Local

- Training data never leaves the Mac
- LoRA adapters are stored locally at `~/Library/Application Support/fae/models/`
- No telemetry, no model uploads, no training data exports
- If user deletes Fae, everything is gone (except Git Vault backup)

### 7.2 Training Data Audit

User can always review what Fae learned from:

```
User: "Fae, show me what you'd train on"
→ Fae runs prepare.py in dry-run mode
→ Shows: 847 examples, top topics, correction examples
→ User can exclude specific conversations or topics
→ "Don't train on any conversations about my medical appointments"
```

### 7.3 Forgetting

When a user says "forget X", it affects both memory AND training:

```
User: "Forget everything about my ex-partner"
→ Memory: soft-delete all matching records
→ Training: exclude all conversations mentioning the topic
→ Next training run: model unlearns the association
```

### 7.4 Model Rollback

Every trained model checkpoint is preserved:

```
~/Library/Application Support/fae/models/
  personal/
    base/                  ← Original model (never modified)
    checkpoint-2026-03-14/ ← First personal training
    checkpoint-2026-03-28/ ← Second personal training
    active -> checkpoint-2026-03-28  ← Symlink to current
```

User can revert: "Fae, go back to the previous model" → symlink changes, immediate effect.

### 7.5 Training Consent

First training run requires explicit consent:

```
Fae: "I've collected enough conversations to personalise my responses.
     Training uses our conversation history to fine-tune my model —
     everything stays on your Mac. This would take about 20 minutes
     during quiet hours. Want me to start improving?"

User: "Yes, go ahead"
→ Consent recorded: training.consentGrantedAt = ISO8601
→ Subsequent training runs don't re-ask (but user can revoke anytime)
```

---

## 8. Implementation Phases

### Phase 1: Data Bridge Skill

Create `Resources/Skills/training-data-bridge/` with scripts that:
- Export `.episode` records as SFT examples
- Detect corrections → DPO pairs
- Compute engagement scores and interest weights
- Validate and report dataset statistics

**Depends on**: existing memory system, existing skill execution.
**New code**: Python scripts only (no Swift changes).

### Phase 2: Self-Train Skill

Create `Resources/Skills/self-train/` with scripts that:
- Call the data bridge to prepare data
- Run LoRA training via `mlx_lm` (uv auto-install)
- Benchmark against current model
- Generate comparison report
- Deploy with user approval

**Depends on**: Phase 1, existing training scripts.
**New code**: Python scripts + minor FaeConfig update for model path.

### Phase 3: Bundled Benchmarks

- Create personalised benchmark generator from memory records
- Bundle standard + personalised benchmark prompts
- Integrate benchmark into `self-train` skill

**Depends on**: Phase 2.

### Phase 4: Autonomous Training Loop

- Scheduler tasks for weekly data export and training
- Morning briefing integration for training results
- ACP delegation for training during complex runs
- Training presets (smoke/light/standard/deep)

**Depends on**: Phases 1-3, ACP integration.

### Phase 5: Emotional Calibration

- Sentiment detection in episode metadata
- Emotional alignment scoring
- Relationship depth tracking
- Time-of-day and day-of-week style calibration

**Depends on**: Phase 4, sufficient conversation history.

---

## 9. What This Makes Possible

**Month 1**: Fae remembers your name, your preferences, your interests. Responses are good but generic — personality comes from the prompt.

**Month 3**: First personal training run. 500+ conversations. Fae's responses become noticeably more *you* — shorter, more direct, with domain knowledge about your projects. The prompt does less work because the weights carry more of the personality.

**Month 6**: Third training run. Fae's emotional calibration is dialled in — she knows when you need warmth vs. efficiency. Inside references creep in naturally. Tool selection is precise. The concierge model handles rich synthesis with your preferred level of detail.

**Month 12**: Fae feels less like an AI and more like a colleague who's been with you for a year. Her weights encode not just what you know and like, but how you think, how you communicate, and what kind of help you actually need vs. what you literally ask for.

**The prompt didn't change.** The soul didn't change. The weights changed — because the weights are where the relationship lives.

---

## Appendix: Example Training Data Flow

```
Day 1, 09:15 — User asks about Rust lifetimes
  Memory: .episode (full turn) + .interest (Rust)
  Quality: engagement=0.8 (user continued for 5 turns)
  SFT weight: 0.85 (high engagement + strong interest topic)

Day 1, 14:30 — User asks Fae to be more concise
  Memory: .profile (preference: concise) + .episode
  Correction: DPO pair (verbose=rejected, concise=chosen)
  DPO weight: 0.95 (explicit correction)

Day 3, 21:00 — Casual evening conversation about cooking
  Memory: .episode + .interest (cooking, low)
  Quality: engagement=0.6 (short conversation)
  SFT weight: 0.4 (low-interest topic, casual context)

Day 7, 10:00 — User frustrated with build errors
  Memory: .episode + sentiment: frustrated
  Quality: engagement=0.9 (Fae helped fix the issue)
  SFT weight: 0.9 (emotional calibration + tool use + high engagement)
  Emotional tag: frustrated_user → practical_help → resolution

Week 4: Dataset export
  → 200 SFT examples (weighted by quality + interest)
  → 15 DPO pairs (from corrections)
  → Top topics: Rust (3.0x), Swift (2.5x), calendar (1.0x)
  → Emotional calibration: 12 examples of stressed→supportive

Week 4: Training
  → LoRA: 200 iters, num_layers=8, lr=1e-4
  → Benchmark: 78% → 82% (+4% improvement)
  → Personalised benchmark: 71% → 79% (+8% on user-specific prompts)
  → Fae proposes upgrade → user approves → model swapped
```
