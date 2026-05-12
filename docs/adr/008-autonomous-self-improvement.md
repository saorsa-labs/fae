# ADR-008: Autonomous Self-Improvement (Meta-Optimization)

**Status:** Accepted
**Date:** 2026-04-05
**Scope:** Nightly improvement loop — `Scheduler/MetaOptimizer.swift`, `Scheduler/MetaOptTypes.swift`, `Scheduler/MetaOptHypothesisGenerator.swift`, `Scheduler/MetaOptSkillGenerator.swift`, `Scheduler/MetaOptMemorySeedGenerator.swift`, `Scheduler/MetaOptNarrator.swift`, `Scheduler/ImprovementCycleCoordinator.swift`, `Memory/ImprovementStore.swift`

> Inspired by [kevinrgu/autoagent](https://github.com/kevinrgu/autoagent). Full spec: `docs/specs/meta-optimization-architecture.md`.

## Context

Fae's original improvement loop (`ImprovementCycleCoordinator`) operated on two surfaces:

1. **Model weights** — LoRA adapters trained via mlx-tune (hours per cycle)
2. **Directive text** — pattern-based amendments every 7th cycle via `DirectiveFastTuner`

AutoAgent demonstrated that **"prompt tuning alone has diminishing returns; adding specialized tools is a high-leverage improvement axis."** Fae has several runtime-mutable surfaces beyond weights and directive that were never systematically optimized:
- Config knobs (temperature, recall limits)
- Instruction-only skills
- Memory recall (strategic fact seeding)

The gap: no mechanism to **test** whether a change to any surface actually improves measured performance, then keep or discard it based on evidence.

## Decision

### Hill-climbing on runtime-mutable surfaces

Add a `metaOptimizing` state to the improvement cycle state machine, between `collecting` and `training`. Each nightly cycle:

1. **Meta-optimize first** (fast, minutes): generate candidate changes from feedback patterns, test each against FaeBenchmark, keep improvements, rollback regressions
2. **Then optionally train weights** (slow, hours): only if enough correction data accumulated

### Four optimization surfaces

| Surface | Change Type | Rollback |
|---------|------------|----------|
| **Directive** (Layer 4) | Append instruction text | Restore previous text |
| **Config knobs** | Adjust temperature, maxRecallResults | Restore old value |
| **Skills** | Create instruction-only `auto-*` skills | Deactivate + delete |
| **Memory seeds** | Insert `meta_opt_seed` tagged facts | Delete record |

### Measured evaluation

Every candidate change is tested against FaeBenchmark's 4 dimensions (toolCalling, faeCapability, assistantFit, serialization). Decision rules:
- Any dimension regresses > 5% -> discard
- Target dimension improves >= 1% -> keep
- No significant change -> discard

Budget: max 10 benchmark runs, 30 min wall clock, 3 consecutive discard plateau detection.

### Companion-language UX

All user-facing communication uses natural language via `MetaOptNarrator`:
- Directive change -> "I learned to keep things brief"
- Config change -> "I'm being more careful and precise"
- Skill -> "I picked up a better routine"
- Memory seed -> "I made a mental note"

Morning briefing weaves results naturally. Settings UI shows timeline with per-change undo. Voice rollback via `self_config(action: "rollback_improvement")`.

## Alternatives considered

1. **LLM-only self-reflection** — have the LLM evaluate its own responses and propose changes. Rejected: no objective measurement, prone to hallucinated improvements.
2. **User-driven tuning** — require the user to explicitly configure every behavior. Rejected: too much burden for a companion; most users won't engage with settings.
3. **Weight training only** — optimize everything through LoRA adapters. Rejected: too slow (hours), can't create new tools or modify config, and prompt/config changes often have more impact than weight changes.
4. **AutoAgent verbatim** — modify source code at runtime. Rejected: Fae is compiled Swift; runtime surfaces are the correct analogue.

## Consequences

### Positive

- Fae measurably improves every night across 4 dimensions
- Changes are tested before deployment — no blind application
- Every change is reversible (user can undo via voice or Settings)
- Meta-optimization is fast (minutes) vs training (hours) — cycles can complete even without enough data for weight training
- Skill auto-generation addresses capability gaps automatically

### Negative

- Benchmark evaluation adds ~90s per candidate (budget limits this)
- Directive can grow via amendments — size limit (4000 chars) prevents runaway
- Memory seeds add records to the database — cap at 10 active, 30-day expiry
- Same benchmark questions used nightly could lead to overfitting — mitigated by 4-dimension regression check

### Risks

- **Eval contamination**: directive could overfit to benchmark MCQs. Mitigation: regression check across all dimensions; future work: expand question banks.
- **Cascade effects**: two individually-good changes might conflict. Mitigation: sequential testing with updated baselines.
- **LLM self-optimization loop**: if the LLM generates hypotheses about its own directive, it might optimize for its own biases. Future mitigation: use base model (no adapter) for hypothesis generation.

## References

- [kevinrgu/autoagent](https://github.com/kevinrgu/autoagent) — source methodology
- `docs/specs/meta-optimization-architecture.md` — full implementation spec
- `docs/specs/continuous-self-improvement-architecture.md` — original training loop spec
- ADR-005 — Self-modification safety model (meta-opt operates within SAL layer)
