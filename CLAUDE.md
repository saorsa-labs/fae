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

Behavioral truth sources:

- `Prompts/system_prompt.md`
- `SOUL.md`
- `~/.fae/memory/`
- `docs/Memory.md`

Implementation touchpoints (not behavioral truth):

- `src/memory.rs`
- `src/pipeline/coordinator.rs`
- `src/runtime.rs`
- `src/scheduler/tasks.rs`

## Scheduler timing (actual current cadence)

- Scheduler loop tick: every 60s
- Update check: every 6h
- Memory migrate: every 1h
- Memory reindex: every 3h
- Memory reflect: every 6h
- Memory GC: daily at 03:30 local time

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

1. system prompt (`Prompts/system_prompt.md`)
2. SOUL contract (`SOUL.md`)
3. memory context (from `~/.fae/memory/`)
4. skills/tool instructions
5. user message/add-on

Human contract document:

- `SOUL.md`

## Platform module (App Sandbox)

`src/platform/` provides cross-platform security-scoped bookmark support:

- `mod.rs`: `BookmarkManager` trait, `create_manager()` factory, `bookmark_and_persist()`, `restore_all_bookmarks()`
- `macos.rs`: Real implementation using `objc2-foundation` NSURL bookmark APIs
- `stub.rs`: No-op for non-macOS (bookmark create/restore return errors, access ops are no-ops)

Bookmarks are persisted in `config.toml` under `[[bookmarks]]` (base64-encoded, labeled).
On startup, `restore_all_bookmarks()` re-establishes access; stale bookmarks are refreshed, invalid ones pruned.

File picker flows (`gui.rs`) call `bookmark_and_persist()` after user selection.

## Delivery quality requirements

Always run:

```bash
cargo fmt --all
cargo clippy --all-features -- -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used
cargo test --all-features
```

When changing memory logic, add tests first (TDD), then implementation.
