# CLAUDE.md — Fae Implementation Guide

Project-specific implementation notes for AI coding agents.

## Core objective

Fae should be:

- reliable in conversation
- memory-strong over long horizons
- proactive where useful
- quiet by default (no noise/clutter)

## Memory-first architecture

Key behavior:

- automatic recall before LLM generation
- automatic capture after each completed turn
- explicit edit operations with audit history
- migration-safe storage evolution with rollback

Core files:

- `src/memory.rs`
- `src/pipeline/coordinator.rs`
- `src/runtime.rs`
- `src/scheduler/tasks.rs`
- `docs/Memory.md`

## Scheduler timing (actual current cadence)

- Scheduler loop tick: every 60s
- Update check: every 6h
- Memory migrate: every 1h
- Memory reindex: every 3h
- Memory reflect: every 6h
- Memory GC: daily at 03:30 UTC

## Quiet operation policy

Fae should work continuously without becoming noisy.

- Keep maintenance chatter off the main conversational subtitle/event surface.
- Use canvas/background surfaces for low-priority telemetry.
- Escalate only failures or high-value actionable items.
- Prefer digests over repeated single-event interruptions.

## Personalization and interview direction

Implementation strategy:

1. Add explicit onboarding interview flow with consent.
2. Persist interview outputs as tagged durable memory records with confidence/source.
3. Add periodic re-interview triggers (staleness/conflict/user request).
4. Build low-noise proactive briefings using memory + recency + urgency filters.

Detailed plan:

- `docs/personalization-interviews-and-proactive-plan.md`

## Tool system reality

Current core toolset:

- `read`
- `write`
- `edit`
- `bash`
- canvas tools when registered

Tool modes:

- `off`
- `read_only`
- `read_write`
- `full`
- `full_no_approval`

## Prompt/identity stack

Prompt assembly order:

1. `CORE_PROMPT`
2. personality profile
3. skills
4. user add-on

Human contract document:

- `SOUL.md`

## Delivery quality requirements

Always run:

```bash
cargo fmt --all
cargo clippy --all-features -- -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
cargo test --all-features
```

When changing memory logic, add tests first (TDD), then implementation.
