# Meta-Optimization Architecture

> AutoAgent-inspired hill-climbing optimization for Fae's runtime-mutable surfaces.
>
> **Status:** Implemented — Phases 1-3 complete + UX layer (2026-04-05)
> **References:** [kevinrgu/autoagent](https://github.com/kevinrgu/autoagent), `ImprovementCycleCoordinator.swift`, `MetaOptimizer.swift`, `MetaOptNarrator.swift`, `FaeBenchmark/`

---

## 1. Problem Statement

Fae's autonomous improvement loop (`ImprovementCycleCoordinator`) currently optimizes two surfaces:

1. **Model weights** — LoRA adapters trained via mlx-tune (hours per cycle, nightly)
2. **Directive text** — pattern-based amendments every 7th cycle via `DirectiveFastTuner`

Both are valuable but incomplete. AutoAgent's core finding is directly applicable:

> *"Prompt tuning alone has diminishing returns. Adding specialized tools is a high-leverage improvement axis."*

Fae has five runtime-mutable surfaces that are never touched by the current loop:

| Surface | Current Status | Optimization Potential |
|---------|---------------|----------------------|
| Directive (Layer 4) | Amended every 7th cycle, pattern-matched | High — continuous hill-climbing per dimension |
| Skills (Layer 7-8) | Forge proposes, user approves manually | High — auto-generate, benchmark, keep/discard |
| Config knobs | Static, user-set via Settings | Medium — tune temperature, thresholds, timing |
| Memory guidance | Organic capture only | Medium — seed strategic meta-memories |
| Tool program templates | Ad-hoc per conversation | Medium — optimized templates for common workflows |

The gap: Fae has no mechanism to **systematically test** whether a change to any of these surfaces actually improves performance, then keep or discard it based on measured evidence.

## 2. Design Principle

**Import AutoAgent's methodology, not its architecture.**

AutoAgent modifies `agent.py` source code. Fae is compiled Swift — source code is immutable at runtime. But Fae has something AutoAgent doesn't: a rich set of runtime-mutable surfaces (directive, skills, config, memory, tool programs) plus a multi-dimensional evaluation harness (`FaeBenchmark` with 4 accuracy dimensions + throughput).

The synthesis: take AutoAgent's **disciplined hill-climbing loop** (hypothesis → implement → evaluate → decide) and apply it to Fae's **runtime-mutable surfaces**, scored by `FaeBenchmark`'s multi-dimensional metrics.

## 3. Architecture Overview

### 3.1 New State: `metaOptimizing`

Add a meta-optimization phase to the existing state machine, between `collecting` and `training`:

```
Current:
  idle → collecting → training → evaluating → proposing → deploying → idle

Proposed:
  idle → collecting → metaOptimizing → training → evaluating → proposing → deploying → idle
                      │                  ↑
                      │                  │ (if enough data for weight training)
                      └──────────────────┘ (else skip to idle)
```

Meta-optimization runs **before** weight training because:
- It's faster (seconds/minutes vs hours)
- Changes are instantly reversible
- It can fix problems that weight training can't (wrong tools, missing capabilities)
- Better prompts/tools produce higher-quality training data for the subsequent weight update

### 3.2 Phase Placement

```swift
enum CycleState: String, Sendable {
    case idle
    case collecting
    case metaOptimizing  // NEW
    case training
    case evaluating
    case proposing
    case deploying

    var validSuccessors: Set<CycleState> {
        switch self {
        case .idle:            return [.collecting]
        case .collecting:      return [.metaOptimizing, .idle]
        case .metaOptimizing:  return [.training, .idle]  // can skip training
        case .training:        return [.evaluating, .idle]
        case .evaluating:      return [.proposing, .idle]
        case .proposing:       return [.deploying, .idle]
        case .deploying:       return [.idle]
        }
    }
}
```

Key: `metaOptimizing` can transition to either `training` (if enough data for weight update) or `idle` (if meta-optimization was sufficient or no training data). This means lightweight cycles can complete in minutes instead of hours.

### 3.3 Integration with Existing Cycle

The meta-optimization phase **subsumes** the current `DirectiveFastTuner` path. Instead of directive tuning running only every 7th cycle as a special case, meta-optimization runs every cycle and considers directive changes alongside config changes (Phase 1), skill generation (Phase 2), and memory seeding (Phase 3).

```
Current decision tree:
  is directive tuning cycle (7th)?
    yes → DirectiveFastTuner.runFastTuning() → idle
    no  → training → evaluating → proposing → deploying → idle

Proposed decision tree:
  always → metaOptimizing (fast, measured)
    then → has enough data for training?
      yes → training → evaluating → proposing → deploying → idle
      no  → idle (meta-opt changes already deployed, no weight update needed)
```

## 4. Meta-Optimization Loop (Detail)

### 4.1 Internal Loop Structure

The meta-optimization phase has its own internal loop, invisible to the outer state machine:

```
metaOptimizing:
  1. Cache baseline benchmark scores (one run)
  2. Cluster feedback events into failure modes
  3. Generate ranked hypotheses via pattern matching (Phase 1) or LLM (Phase 2+)
  4. For each hypothesis (up to budget):
     a. Apply candidate change to mutable surface
     b. Run dimension-specific benchmark
     c. Compute delta against baseline
     d. Decision:
        - Any dimension regressed > 5% → DISCARD, rollback
        - Target dimension improved ≥ 1% → KEEP, update baseline
        - No significant change → DISCARD (don't accumulate neutral changes)
     e. Log result
  5. Return to outer state machine
```

### 4.2 Budget and Termination

Each meta-optimization cycle operates within a strict budget:

```swift
struct MetaOptBudget: Sendable {
    /// Maximum number of benchmark evaluation runs per cycle.
    let maxBenchmarkRuns: Int            // default: 10
    /// Maximum wall-clock time for the meta-optimization phase.
    let maxWallClockSeconds: TimeInterval // default: 1800 (30 minutes)
    /// Stop after N consecutive discarded candidates (plateau detection).
    let maxConsecutiveDiscards: Int       // default: 3
    /// Minimum improvement threshold to keep a change.
    let minImprovementThreshold: Double   // default: 0.01 (1 percentage point)
    /// Regression threshold that triggers automatic discard.
    let regressionThreshold: Double       // default: 0.05 (5 percentage points)
}
```

**Termination conditions** (any one triggers exit):
1. Budget exhausted (benchmark runs or wall clock)
2. All hypotheses tested
3. Plateau detected (3 consecutive discards)
4. No hypotheses generated (no strong patterns)

### 4.3 Evaluation Strategy

Full FaeBenchmark runs all 4 dimension suites (~64 questions, ~90s). For meta-optimization to iterate fast, we need **dimension-specific evaluation** — run only the questions relevant to the change being tested:

| Target Dimension | Eval Suite | Questions | Time |
|-----------------|-----------|-----------|------|
| `toolCalling` | Tool calling accuracy | 10 tests | ~10s |
| `faeCapability` | Fae capability MCQ | 20 MCQs | ~30s |
| `assistantFit` | Assistant fit MCQ | 25 MCQs | ~40s |
| `serialization` | Structured output | 9 tests | ~15s |
| All (baseline) | All suites | 64 total | ~90s |

**Baseline caching:** The full baseline is computed once at the start of the meta-optimization phase and cached. Individual changes are evaluated only against the dimensions they target. After keeping a change, the affected dimension's baseline is updated to the new score.

**Cross-dimension regression check:** Even when targeting one dimension, we spot-check one random question from each other dimension to catch catastrophic cross-contamination. This adds ~5s per test but catches directive amendments that help tool calling while breaking serialization.

## 5. Optimization Surfaces (Phased)

### 5.1 Phase 1: Directive + Config (Low Risk, High Leverage)

**Directive hill-climbing** replaces `DirectiveFastTuner` with measured optimization:

```
Current DirectiveFastTuner:
  1. Detect patterns (verbosityTooHigh, toneMismatch, etc.)
  2. Generate hardcoded amendment strings
  3. Append to directive.md
  4. No measurement of whether it helped

Proposed MetaOptDirective:
  1. Same pattern detection (DetectedPattern types)
  2. Same amendment generation (suggestedAmendment)
  3. Apply amendment to directive.md
  4. Run FaeBenchmark for target dimension
  5. Improved? Keep. Regressed? Rollback.
```

The difference: every directive change is now **measured**. Bad amendments get discarded instead of accumulating.

**Config knob tuning** — new capability:

Tunable knobs with safe ranges:

| Key | Type | Min | Max | Default | Target Dimension |
|-----|------|-----|-----|---------|-----------------|
| `llm.temperature` | Float | 0.1 | 1.0 | 0.7 | toolCalling, serialization |
| `memory.maxRecallResults` | Int | 2 | 12 | 6 | faeCapability |
| `llm.thinkingLevel` | Enum | fast | deep | balanced | faeCapability, assistantFit |
| `conversation.directAddressFollowupS` | Int | 5 | 60 | 20 | assistantFit |
| `tts.speed` | Float | 0.8 | 1.4 | 1.1 | (no benchmark, user-feel only) |

**Config change rollback:** store `{key: oldValue}` pairs in improvement.db, restore on discard.

**Why Phase 1 first:**
- Directive changes take effect on the next LLM turn with zero restart
- Config changes take effect via `FaeCore.patchConfig()` immediately
- Both are instantly reversible
- Both have well-understood rollback mechanisms (`previousDirective`, config restore)
- Combined they cover the most common improvement patterns

### 5.2 Phase 2: Skill Auto-Generation (Medium Risk, High Leverage) — IMPLEMENTED

**Status:** Implemented 2026-04-04

`MetaOptSkillGenerator` generates instruction-only skills from two signal sources:

1. **Capability gaps** (`capability_gaps` table) — matched against 5 built-in skill templates
2. **Feedback patterns** — tool corrections and serialization failures inferred from events

**Skill Templates (5):**

| Template | Gap Category | Target Dimension |
|----------|-------------|-----------------|
| `auto-smart-tool-routing` | `tool_selection` | toolCalling |
| `auto-precise-formatting` | `structured_output` | serialization |
| `auto-memory-precision` | `memory_discipline` | faeCapability |
| `auto-precise-execution` | `instruction_following` | assistantFit |
| `auto-natural-conversation` | `conversation_quality` | assistantFit |

**Flow:**
1. Query `capability_gaps` for unaddressed gaps with `evidenceCount ≥ 3`
2. Match gap category to template → generate `MetaOptHypothesis` with `.skillCreation`
3. Also scan feedback events for tool/serialization correction patterns
4. Deduplicate against existing discovered skills and other hypotheses
5. MetaOptimizer applies via `SkillManager.createSkill()` + `activate()`
6. Benchmark evaluates with skill active in prompt stack
7. Score improved? → Keep. Regressed/neutral? → `deactivate()` + `deleteSkill()`

**Safety:**
- Only `instruction` type skills (no executable scripts)
- Names prefixed with `auto-` to distinguish from user-created skills
- Body capped at 2000 characters
- Full `SkillSecurityReviewer` runs on creation
- Rollback: deactivate + delete directory (instant, clean)

**Mutable surface:** `~/Library/Application Support/fae/skills/auto-<name>/SKILL.md`
**Key files:** `MetaOptSkillGenerator.swift`, `MetaOptimizer.swift` (skill creation in `applyChange`)

### 5.3 Phase 3: Memory Seeds + Tool Program Templates (Advanced)

**Memory seeds** — strategic facts that shape LLM behavior:
```
"David prefers file tools over web search for questions about his own projects"
"When asked about scheduling, check calendar first before asking clarifying questions"
```

**Tool program templates** — pre-built JavaScript workflows for common multi-tool patterns:
```javascript
// scheduling_workflow.js
const busy = await fae.tool("calendar", { action: "list", range: "today" });
const contact = await fae.tool("contacts", { action: "search", query: params.person });
// ...
```

These surfaces are harder to evaluate (require conversation-replay benchmarks, not MCQ). Deferred to Phase 3 pending expanded eval infrastructure.

## 6. Hypothesis Generation

### 6.1 Phase 1: Pattern-Based (No LLM Required)

Phase 1 reuses `DirectiveFastTuner.detectPatterns()` logic and adds config-specific patterns:

```swift
enum MetaOptSurface: String, Codable, Sendable {
    case directive
    case configKnob
    // Phase 2:
    // case skill
    // Phase 3:
    // case memorySeed
    // case toolTemplate
}

struct MetaOptHypothesis: Sendable {
    let id: UUID
    let surface: MetaOptSurface
    let description: String
    /// Which benchmark dimension this change targets.
    let targetDimension: EvalDimension
    /// The actual change to apply.
    let change: MetaOptChange
    /// Pattern evidence count (higher = try first).
    let evidenceCount: Int
}

enum MetaOptChange: Sendable {
    /// Append text to directive.md.
    case directiveAmendment(String)
    /// Set a config key to a new value, remembering the old value for rollback.
    case configAdjustment(key: String, oldValue: String, newValue: String)
}
```

**New config-specific patterns:**

```swift
// In MetaOptHypothesisGenerator:

// Tool call failures with high temperature suggest structured output needs lower temp.
let toolFailures = events.filter { $0.signalType == "correction" && isToolRelated($0) }
if toolFailures.count >= 3 && currentConfig.temperature > 0.5 {
    hypotheses.append(MetaOptHypothesis(
        id: UUID(),
        surface: .configKnob,
        description: "Tool call failures may be caused by temperature \(currentConfig.temperature) — try 0.4",
        targetDimension: .toolCalling,
        change: .configAdjustment(key: "llm.temperature", oldValue: "\(currentConfig.temperature)", newValue: "0.4"),
        evidenceCount: toolFailures.count
    ))
}

// Frequent re-asks with low maxRecallResults suggest memory recall is missing context.
let reasks = events.filter { $0.signalType == "re_ask" }
if reasks.count >= 4 && currentConfig.maxRecallResults < 10 {
    hypotheses.append(MetaOptHypothesis(
        id: UUID(),
        surface: .configKnob,
        description: "Frequent re-asks (\(reasks.count)) — try increasing maxRecallResults to \(currentConfig.maxRecallResults + 2)",
        targetDimension: .faeCapability,
        change: .configAdjustment(
            key: "memory.maxRecallResults",
            oldValue: "\(currentConfig.maxRecallResults)",
            newValue: "\(min(currentConfig.maxRecallResults + 2, 12))"
        ),
        evidenceCount: reasks.count
    ))
}
```

### 6.2 Phase 2+: LLM-Assisted Hypothesis Generation

When pattern matching produces no hypotheses but benchmark scores have room for improvement, invoke the local LLM itself to generate hypotheses. This is the AutoAgent-style "meta-agent" approach:

```
System prompt for hypothesis generation:

You are Fae's meta-optimization agent. Analyze feedback patterns and propose
ONE specific change to improve benchmark scores.

## Current State
- Benchmark scores: tool_calling={tc}%, fae_capability={fc}%, assistant_fit={af}%, serialization={ser}%
- Weakest dimension: {weakest}
- Feedback patterns: {clustered_summary}
- Current directive ({len} chars): {directive_excerpt}
- Current config: temperature={t}, maxRecallResults={mr}, thinkingLevel={tl}

## Available Changes
1. Directive amendment: append instruction text to directive.md (max 200 chars)
2. Config adjustment: change a config value within safe bounds

## Rules
- ONE change only (isolate variables)
- Target the weakest dimension
- Don't contradict existing directive
- Be specific: exact text or exact value

Respond with JSON:
{"surface":"directive"|"configKnob","description":"...","change":{...},"targetDimension":"..."}
```

**Important:** This LLM call uses the production Fae model with no adapter loaded (base model), to avoid the model optimizing itself into a feedback loop.

## 7. Persistence

### 7.1 New Tables in improvement.db

```sql
-- Meta-optimization results log.
-- One row per tested hypothesis.
CREATE TABLE IF NOT EXISTS meta_optimization_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    cycle_number INTEGER NOT NULL,
    hypothesis_id TEXT NOT NULL,
    surface TEXT NOT NULL,           -- 'directive' | 'configKnob' | 'skill' | ...
    description TEXT NOT NULL,       -- Human-readable hypothesis description
    target_dimension TEXT NOT NULL,  -- 'toolCalling' | 'faeCapability' | 'assistantFit' | 'serialization'
    before_scores TEXT NOT NULL,     -- JSON: {"toolCalling":0.85,"faeCapability":0.90,...}
    after_scores TEXT NOT NULL,      -- JSON: same format
    delta TEXT NOT NULL,             -- JSON: same format (after - before)
    kept INTEGER NOT NULL DEFAULT 0, -- 0 = discarded, 1 = kept
    reason TEXT NOT NULL,            -- 'improvement' | 'regression' | 'neutral' | 'budget_exhausted'
    created_at TEXT NOT NULL         -- ISO-8601
);

```

> **Note:** The originally-proposed `config_snapshots` table was not implemented. Config rollback
> is handled in-memory via the `MetaOptimizer.lastKeptRollback` closure — config changes that
> are discarded are rolled back immediately, so persistent snapshots are unnecessary.

### 7.2 ImprovementState Extension

```swift
struct ImprovementState: Sendable {
    // ... existing fields ...
    var id: Int64?
    var cycleState: String
    var lastCycleAt: String?
    var completedCycles: Int
    var userApprovedCycles: Int
    var currentAdapterPath: String?
    var previousAdapterPath: String?
    var trainingStartedAt: String?
    var lastCycleError: String?
    var deferralCount: Int
    var previousDirective: String?

    // NEW: meta-optimization tracking
    /// Lifetime count of kept meta-optimization changes.
    var metaOptKeptTotal: Int
    /// Lifetime count of tested hypotheses.
    var metaOptTestedTotal: Int
    /// ISO-8601 timestamp of last meta-optimization run.
    var metaOptLastRunAt: String?
    /// Consecutive cycles with zero kept changes (plateau detection).
    var metaOptConsecutiveNoImprovement: Int
}
```

## 8. Scoring Model

### 8.1 DimensionScores Type

```swift
/// Benchmark scores across all evaluated dimensions (0.0 – 1.0 each).
struct DimensionScores: Codable, Sendable {
    let toolCalling: Double?
    let faeCapability: Double?
    let assistantFit: Double?
    let serialization: Double?
    let throughput: Double?  // tokens/sec, not a percentage

    /// Compute improvement over a baseline. Positive = better.
    func improvement(over baseline: DimensionScores) -> DimensionScores {
        DimensionScores(
            toolCalling: delta(self.toolCalling, baseline.toolCalling),
            faeCapability: delta(self.faeCapability, baseline.faeCapability),
            assistantFit: delta(self.assistantFit, baseline.assistantFit),
            serialization: delta(self.serialization, baseline.serialization),
            throughput: delta(self.throughput, baseline.throughput)
        )
    }

    /// True if any dimension regressed more than the threshold.
    func anyRegression(over baseline: DimensionScores, threshold: Double = 0.05) -> Bool {
        let d = improvement(over: baseline)
        return [d.toolCalling, d.faeCapability, d.assistantFit, d.serialization]
            .compactMap { $0 }
            .contains { $0 < -threshold }
    }

    /// True if the target dimension improved by at least the threshold.
    func improved(dimension: EvalDimension, over baseline: DimensionScores, threshold: Double = 0.01) -> Bool {
        let d = improvement(over: baseline)
        let value: Double?
        switch dimension {
        case .toolCalling:    value = d.toolCalling
        case .faeCapability:  value = d.faeCapability
        case .assistantFit:   value = d.assistantFit
        case .serialization:  value = d.serialization
        }
        return (value ?? 0) >= threshold
    }

    private func delta(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b else { return nil }
        return a - b
    }
}

enum EvalDimension: String, Codable, Sendable {
    case toolCalling
    case faeCapability
    case assistantFit
    case serialization
}
```

### 8.2 Decision Logic

```swift
func decide(
    hypothesis: MetaOptHypothesis,
    baseline: DimensionScores,
    afterScore: DimensionScores,
    budget: MetaOptBudget
) -> MetaOptDecision {

    // Rule 1: Any dimension regressed > 5% → always discard.
    if afterScore.anyRegression(over: baseline, threshold: budget.regressionThreshold) {
        return .discard(reason: "regression")
    }

    // Rule 2: Target dimension improved ≥ 1% → keep.
    if afterScore.improved(
        dimension: hypothesis.targetDimension,
        over: baseline,
        threshold: budget.minImprovementThreshold
    ) {
        return .keep(reason: "improvement")
    }

    // Rule 3: No significant change → discard (don't accumulate neutral changes).
    return .discard(reason: "neutral")
}

enum MetaOptDecision: Sendable {
    case keep(reason: String)
    case discard(reason: String)
}
```

## 9. Safety Constraints

### 9.1 Directive Size Limit

Meta-optimization can keep appending to directive.md. Unconstrained, this leads to directive bloat.

**Guard:** Before appending, check `directive.count + amendment.count <= 4000` (existing limit). If exceeded:
1. Skip the amendment candidate
2. Log a `directive_size_limit_reached` event
3. Future phase: consolidation pass that compresses directive via LLM summarization

### 9.2 Contradiction Detection

New directive amendments must not contradict existing ones. Phase 1 mitigates this structurally:
- `DirectiveFastTuner` pattern types are non-overlapping (verbosity vs tone vs tool usage)
- Config changes are orthogonal to directive changes
- The benchmark regression check catches contradictions empirically (contradictory directives degrade scores)

Phase 2+ adds explicit contradiction detection via LLM review of proposed amendments against existing directive.

### 9.3 Config Bounds Enforcement

Every tunable config key has hard bounds enforced before applying:

```swift
struct ConfigBound: Sendable {
    let key: String
    let min: Double
    let max: Double
    let step: Double  // minimum change granularity
}

let configBounds: [ConfigBound] = [
    ConfigBound(key: "llm.temperature",                    min: 0.1, max: 1.0, step: 0.1),
    ConfigBound(key: "memory.maxRecallResults",            min: 2,   max: 12,  step: 1),
    ConfigBound(key: "conversation.directAddressFollowupS", min: 5,   max: 60,  step: 5),
    // thinkingLevel is enum: handled separately
]
```

### 9.4 Eval Contamination Prevention

If the same benchmark questions are used every cycle, directives could overfit to them (e.g., "when asked about scheduling, always answer C"). Mitigation:

1. **Phase 1:** Accept this risk — the question bank is small but representative, and we measure all 4 dimensions for regression, which makes overfitting to one dimension hard.
2. **Phase 2:** Expand question banks to 3x current size, randomly sample per run.
3. **Phase 3:** Add conversation-replay evaluation (real past conversations, not MCQ).

### 9.5 Cascade Protection

The outer state machine ensures meta-optimization changes are always applied before weight training. This means:
- If meta-opt improves scores, training data is generated with the improved prompt/config → better training
- If meta-opt makes no changes, training proceeds on the existing surface → no harm
- If meta-opt and training both improve, the effects compound

**Risk:** Meta-opt changes that help MCQ benchmarks but hurt real conversation quality. The shadow evaluator (alternate-night A/B test) catches this — it evaluates on real past conversations, not MCQ.

## 10. Morning Briefing Integration

The `enhanced_morning_briefing` task already reports improvement cycle results. Meta-optimization results should be included:

```
## Overnight Improvements

Fae tested 5 optimization hypotheses last night:
  ✅ Kept: reduced temperature to 0.4 for tool calls (+3.2% tool calling)
  ✅ Kept: added directive "prefer file tools over web search for local projects" (+1.8% assistant fit)
  ❌ Discarded: increased maxRecallResults to 10 (no significant change)
  ❌ Discarded: added directive "use bullet points by default" (-2.1% capability regression)
  ❌ Discarded: lowered temperature to 0.2 (no further improvement after 0.4)

Net change: tool calling +3.2%, assistant fit +1.8%

Adapter training also ran: +1.5% fae capability (proposed for approval)
```

This gives David visibility into what was tried, what worked, and why — maintaining the trust model that's core to Fae's improvement philosophy.

## 11. Relationship to Existing Components

| Existing Component | Phase 1 Change | Reason |
|---|---|---|
| `CycleState` enum | Add `.metaOptimizing` | New state in state machine |
| `ImprovementCycleCoordinator.runCycle()` | Insert meta-opt phase after collecting | Main integration point |
| `DirectiveFastTuner` | Still used for pattern detection; decision logic replaced | Keep detection, add measurement |
| `ImprovementStore` schema | Add 2 tables + 4 columns to ImprovementState | Persistence for meta-opt results |
| `FaeBenchmark` | Add dimension-specific execution mode | Fast evaluation for individual dimensions |
| `ExternalReviewGate` | No change (operates on weight training path) | Meta-opt uses benchmark scores directly |
| `ShadowEvaluator` | No change (still runs alternate nights) | Catches regression in real conversations |
| `PersonalityManager` | No change (directive reloaded via existing mechanism) | Already supports hot directive reload |
| `FaeConfig` / `FaeCore.patchConfig()` | No change (already supports runtime config mutation) | Already supports config hot-swap |
| `TrainingBridge` | Add `runQuickBenchmark(dimensions:)` method | Selective dimension evaluation |

## 12. Files to Create / Modify

### New Files

| File | Purpose |
|------|---------|
| `Scheduler/MetaOptimizer.swift` | Core meta-optimization loop (actor) with rollback API |
| `Scheduler/MetaOptTypes.swift` | Types: surfaces, changes, hypotheses, budgets, scores, dimensions |
| `Scheduler/MetaOptHypothesisGenerator.swift` | Pattern-based hypothesis generation (directive + config) |
| `Scheduler/MetaOptSkillGenerator.swift` | Skill template matching + feedback-based skill generation |
| `Scheduler/MetaOptMemorySeedGenerator.swift` | Memory seed templates from feedback patterns |
| `Scheduler/MetaOptNarrator.swift` | Technical → companion-language translator for briefing + Settings UI |

### Modified Files

| File | Change |
|------|--------|
| `Scheduler/ImprovementCycleCoordinator.swift` | `.metaOptimizing` state, narrative generation, `consumeMetaOptNarrative()` |
| `Scheduler/FaeScheduler.swift` | Production wiring, briefing narrative injection, `setMetaOptConfigAccessors()` |
| `Memory/ImprovementStore.swift` | `meta_optimization_log` table, 4 state columns, CRUD methods |
| `Memory/SQLiteMemoryStore.swift` | `countRecords(kind:withTag:)` + `deleteRecord(id:)` |
| `Tools/BuiltinTools.swift` | `rollback_improvement` action + `metaOptRollbackHandler` callback |
| `SettingsTrainingTab.swift` | Improvement timeline section with per-change undo |
| `Tests/HandoffTests/AdapterDeploymentManagerTests.swift` | Updated ImprovementState initializers |

### Files Unchanged

- `DirectiveFastTuner.swift` — pattern detection still used; actor kept for compatibility
- `ExternalReviewGate.swift` — operates on weight path only
- `ShadowEvaluator.swift` — independent alternate-night evaluation
- `PersonalityManager.swift` — directive reload already supported
- `FaeConfig.swift` — `patchConfig()` already supports runtime mutation
- `TrainingBridge.swift` — benchmark invocation already exists

## 13. Implementation Sequence

### Phase 1 (Directive + Config) — COMPLETE

1. ~~Add `MetaOptTypes.swift` with all type definitions~~ ✅
2. ~~Add `MetaOptHypothesisGenerator.swift` with pattern-based generation~~ ✅
3. ~~Add `MetaOptimizer.swift` actor with the core loop~~ ✅
4. ~~Extend `ImprovementStore` schema (migration)~~ ✅
5. ~~Extend `ImprovementState` struct~~ ✅
6. ~~Add `CycleState.metaOptimizing` to state machine~~ ✅
7. ~~Wire `MetaOptimizer` into `ImprovementCycleCoordinator.runCycle()`~~ ✅
8. ~~Tests (15 new)~~ ✅
9. Add `--dimensions` flag to `FaeBenchmark` — deferred (full run is fast enough for nightly)
10. Add `TrainingBridge.runQuickBenchmark(dimensions:)` wrapper — deferred (same reason)

### Phase 2 (Skill Auto-Generation) — COMPLETE

1. ~~Add `.skill` to `MetaOptSurface`~~ ✅
2. ~~Add `MetaOptSkillGenerator` — 5 templates, gap + feedback-based generation~~ ✅
3. ~~Wire skill creation/activation/deletion into MetaOptimizer~~ ✅
4. ~~Add `.skillCreation` to `MetaOptChange`~~ ✅
5. ~~Async rollback closures for actor-isolated SkillManager~~ ✅
6. ~~Tests (13 new)~~ ✅
7. Expand FaeBenchmark question banks (3x current size, random sampling) — deferred to Phase 3

### Phase 3 (Memory Seeds + Production Wiring) — COMPLETE

1. ~~Add `.memorySeed` to `MetaOptSurface`~~ ✅
2. ~~Add `MetaOptMemorySeedGenerator` — 6 templates, feedback-pattern-based~~ ✅
3. ~~Add `.memorySeedInsertion` to `MetaOptChange`~~ ✅
4. ~~Wire memory store into MetaOptimizer (insert/delete/count on SQLiteMemoryStore)~~ ✅
5. ~~Add `countRecords(kind:withTag:)` and `deleteRecord(id:)` to SQLiteMemoryStore~~ ✅
6. ~~Wire MetaOptimizer into FaeScheduler production path~~ ✅
7. ~~Add `setMetaOptConfigAccessors()` to FaeScheduler for config reader/writer injection~~ ✅
8. ~~Update CLAUDE.md with meta-optimization documentation~~ ✅
9. ~~Tests (10 new)~~ ✅
10. Conversation-replay evaluation — deferred (requires expanded FaeBenchmark)
11. LLM-assisted hypothesis generation — deferred (requires base-model inference path)
12. Tool program template library — deferred (requires JSCRuntime template storage)

## 14. Success Metrics

| Metric | Target | Measurement |
|--------|--------|-------------|
| Meta-opt phase wall time | < 30 min per cycle | `metaOptLastRunAt` delta |
| Hypothesis keep rate | 20-40% | `metaOptKeptTotal / metaOptTestedTotal` |
| Benchmark score trend | Monotonically non-decreasing over 30 days | Historical baseline comparison |
| Directive size growth | < 100 chars/week average | Directive file size tracking |
| Config stability | Converge within 5 cycles | `config_snapshots` churn rate |
| Training data quality | Post-meta-opt training produces better adapters than pre-meta-opt | Compare adapter EvalDelta before/after meta-opt adoption |

## 15. UX Layer — IMPLEMENTED

All user-facing communication uses companion language. Zero technical jargon.

### 15.1 MetaOptNarrator (`MetaOptNarrator.swift`)

Converts `MetaOptSummary` into natural language. Each surface type maps to a companion framing:

| Surface | Technical Name | User Sees |
|---------|---------------|-----------|
| Directive | "directive amendment" | "I learned to keep things brief when you're busy" |
| Config | "temperature adjustment" | "I'm being more careful and precise with tasks now" |
| Skill | "auto-skill creation" | "I picked up a better routine for finding your files" |
| Memory seed | "meta_opt_seed fact" | "I made a mental note to check your projects before searching the web" |

**Settings UI labels:** Habit / Thinking / Routine / Mental Note (via `surfaceDisplayName()`).

### 15.2 Morning Briefing Integration

The `MetaOptNarrator.narrate()` output is stored as `pendingMetaOptNarrative` on the coordinator after each cycle. The scheduler injects it into the enhanced morning briefing prompt as `[OVERNIGHT SELF-IMPROVEMENT CONTEXT]` with instructions to summarise warmly in 1-2 sentences. The LLM weaves it naturally:

> "Good morning. I made a couple of small adjustments overnight — I'm keeping my answers shorter now, and I'll check your files before searching the web. If anything feels off, just tell me to undo it."

### 15.3 Settings UI Timeline (`SettingsTrainingTab.swift`)

Added "Recent Adjustments" section to the existing Personal Learning tab:
- Timeline of changes with human-readable descriptions
- Surface tag badges (Habit / Thinking / Routine / Mental Note)
- Relative timestamps ("2 hours ago")
- Per-change "Undo" button → injects voice command

### 15.4 Voice Rollback (`SelfConfigTool.rollback_improvement`)

New `rollback_improvement` action on the `self_config` tool. User says "undo the last change you made to yourself" → LLM invokes `self_config(action: "rollback_improvement")` → `MetaOptimizer.rollbackLastChange()` → reverts the most recent kept change and confirms in companion language.

### 15.5 Trust Escalation (Design, Not Yet Coded)

Planned progression:
- **Learning** (cycles 1-3): Changes in briefing, asks "Does this feel right?"
- **Growing** (cycles 4-10): Changes in briefing, no question
- **Established** (cycles 11+): Only mentions significant changes

## 16. Open Questions

1. **LLM self-optimization feedback loop:** When the production LLM generates hypotheses about its own directive, can it inadvertently optimize for its own biases? Mitigation: use base model (no adapter) for hypothesis generation.

2. **Benchmark coverage vs speed:** Current MCQ suites are fast but narrow. Conversation replay is broader but slow. What's the right ratio for Phase 1?

3. **Multi-change interactions:** Two individually-good changes might conflict when combined. Should we test pairwise interactions? (Probably not in Phase 1 — the regression check catches the worst cases.)

4. **User override precedence:** If the user manually edits directive.md, do meta-opt changes get overwritten? Yes — user intent always wins. Meta-opt should detect manual edits and recalibrate.

5. **Temperature per-mode:** Should meta-opt be allowed to set different temperatures for different contexts (tool calling vs conversation)? This requires a config extension but could be high leverage.
