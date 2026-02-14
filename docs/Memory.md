# Fae Memory

This is the human-readable guide to how Fae memory works today.

## What Fae remembers

Fae stores three memory kinds:

- `profile`: durable personal context (name, stable preferences, identity details)
- `fact`: durable remembered facts
- `episode`: turn-level conversation snapshots for traceability

Only durable memories (`profile`, `fact`) are injected into prompts during recall.

## Where memory lives

Memory root is `~/.fae/`.

Runtime memory files:

- `~/.fae/memory/manifest.toml` — schema metadata/version
- `~/.fae/memory/records.jsonl` — canonical records
- `~/.fae/memory/audit.jsonl` — operation log

Compatibility files:

- `~/.fae/memory/primary_user.md`
- `~/.fae/memory/people.md`

Voice samples:

- `~/.fae/voices/`

## Automatic lifecycle (no manual buttons)

Per completed turn:

1. **Recall** (before generation)
- query memory using user text
- rank by lexical overlap + confidence + freshness + kind bonus
- inject bounded `<memory_context>` into prompt

2. **Capture** (after generation)
- write an `episode` record for the turn
- parse durable candidates from user statements
- apply conflict resolution (supersede lineage)
- apply retention policy for old episodic entries

3. **Telemetry**
- emit runtime events for recall, writes, conflicts, and migrations
- memory telemetry is intentionally suppressed from the main subtitle/event surface and routed to non-primary UI surfaces

## How memory is edited

Memory supports explicit operations:

- `insert`
- `patch`
- `supersede`
- `invalidate`
- `forget_soft`
- `forget_hard`

Conversation-driven edit patterns currently include:

- remember commands: `remember ...`
- forget commands: `forget ...` (soft-forgets matching active memories)
- name statements: `my name is ...`, `call me ...`, etc.
- preference statements: `i prefer ...`, `i like ...`, etc.

Conflict policy:

- older contradictory records are marked `superseded`
- new active record links to predecessor via `supersedes`
- history remains auditable

## Upgrade and migration behavior

On startup:

1. read manifest schema version
2. if auto-migrate is enabled and version is behind target:
- create snapshot backup
- run sequential migration steps
- validate and update manifest
3. on failure:
- rollback from snapshot backup
- preserve previous consistent state

Migrations and outcomes are recorded in audit/runtime events.

## Safety and quality controls

- max record text length is enforced
- oversized captured content is truncated safely instead of failing the whole capture
- confidence threshold (`memory.min_profile_confidence`) gates durable promotion and durable recall
- basic false-positive guards are applied to name extraction
- strict tests cover capture, recall, supersession, migration, rollback, and concurrency

## Operational knobs

In `~/.config/fae/config.toml`:

```toml
[memory]
enabled = true
auto_capture = true
auto_recall = true
recall_max_items = 6
recall_max_chars = 1200
min_profile_confidence = 0.70
retention_days = 365
schema_auto_migrate = true
```

## Background maintenance

Scheduler tasks keep memory healthy:

- `memory_migrate`
- `memory_reflect`
- `memory_reindex`
- `memory_gc`

## Related docs

- `docs/memory-architecture-plan.md`
- `SOUL.md`
