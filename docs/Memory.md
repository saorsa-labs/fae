# Fae Memory

This document explains how memory works in Fae in plain language.

## What Fae remembers

Fae keeps several kinds of memory:

- Profile memory: long-term preferences and stable personal details.
- Episodic memory: important moments from conversations.
- Knowledge memory: facts learned over time from repeated evidence.

## Where memory lives

Fae stores memory under `~/.fae/memory/`.

Important files:

- `manifest.toml`: memory schema and version info.
- `records.jsonl`: core memory entries.
- `audit.jsonl`: history of memory edits.
- `primary_user.md` and `people.md`: identity and known person data.

## How memory is created

Memory is automatic. During conversation, Fae:

1. Recalls relevant memories before responding.
2. Captures important details after each turn.
3. Updates memory confidence and links to source turns.

No manual buttons are required for normal operation.

## How memory is edited

Fae supports structured memory edits:

- Add new memory.
- Correct existing memory.
- Replace old facts with newer confirmed facts.
- Mark memories invalid.
- Forget memories (soft or hard).

When memories conflict, Fae keeps history and marks older entries as superseded instead of silently deleting them.

## How upgrades are handled

When Fae is upgraded:

1. Memory schema version is checked on startup.
2. If needed, migrations run automatically.
3. A backup is created before migration.
4. If migration fails, rollback restores the previous state.

## Privacy and safety

- Sensitive entries can be tagged for restricted recall.
- Hard delete is supported for permanent removal.
- An audit trail is kept for normal memory operations.

## Reliability

Fae uses scheduled background jobs for:

- reflection and consolidation
- index maintenance
- retention cleanup
- migration retries

## Development and quality

Memory features are built with test-driven development:

1. Write failing tests first.
2. Implement behavior.
3. Run formatting, clippy, and tests.
4. Iterate until stable and regression-safe.

For full technical detail, see:
- `docs/memory-architecture-plan.md`

