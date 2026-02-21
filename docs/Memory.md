# Fae Memory

This is the human-readable guide to how Fae memory works today.

## What Fae remembers

Fae stores seven memory kinds:

- `profile`: durable personal context (name, stable preferences, identity details)
- `fact`: durable remembered facts
- `episode`: turn-level conversation snapshots for traceability
- `event`: calendar events, deadlines, and dated items
- `person`: people the user knows (relationships, context)
- `interest`: hobbies, topics, recurring interests
- `commitment`: promises, obligations, and follow-ups

Only durable memories (`profile`, `fact`, `event`, `person`, `interest`, `commitment`) are injected into prompts during recall. Episodes are retained for traceability but filtered during retrieval.

## Where memory lives

Memory root is `~/.fae/memory/`.

Storage:

- `~/.fae/memory/fae.db` — SQLite database (WAL mode, sqlite-vec extension)
- `~/.fae/memory/backups/` — daily automated backup files

Voice samples:

- `~/.fae/voices/`

### Database schema

| Table | Purpose |
|-------|---------|
| `memory_records` | All memory records (id, kind, status, text, confidence, tags, timestamps) |
| `memory_audit` | Operation log (insert, patch, supersede, invalidate, forget, migrate) |
| `vec_embeddings` | sqlite-vec virtual table storing 384-dim float vectors per record |
| `schema_meta` | Schema version tracking for migrations |

### Embedding

- Model: all-MiniLM-L6-v2 (ONNX, ~23 MB)
- Dimensions: 384 (float32)
- Runtime: ONNX Runtime (`ort` crate, shared with Kokoro TTS)
- Vectors are stored in the `vec_embeddings` virtual table (sqlite-vec)
- New records are embedded on insert; batch embedding catches up missing records

## Automatic lifecycle (no manual buttons)

Per completed turn:

1. **Recall** (before generation)
- query memory using user text
- hybrid retrieval: semantic similarity (0.6) + structural signals (0.4)
  - semantic: embed query text, KNN search via sqlite-vec
  - confidence weight (0.2), freshness decay (0.1), kind bonus (0.1)
- falls back to lexical search when embedding engine is unavailable
- inject bounded `<memory_context>` into prompt

2. **Capture** (after generation)
- write an `episode` record for the turn
- parse durable candidates from user statements
- apply conflict resolution (supersede lineage)
- embed new records for future semantic search
- apply retention policy for old episodic entries

3. **Telemetry**
- emit runtime events for recall, writes, conflicts, and migrations
- memory telemetry is suppressed from the main subtitle/event surface

## How memory is edited

Memory supports explicit operations:

- `insert`
- `patch`
- `supersede`
- `invalidate`
- `forget_soft`
- `forget_hard`

Conversation-driven edit patterns:

- remember commands: `remember ...`
- forget commands: `forget ...` (soft-forgets matching active memories)
- name statements: `my name is ...`, `call me ...`, etc.
- preference statements: `i prefer ...`, `i like ...`, etc.

Conflict policy:

- older contradictory records are marked `superseded`
- new active record links to predecessor via `supersedes`
- history remains auditable

## Integrity and backup

### Startup integrity check

On database open, a `PRAGMA quick_check` validates page-level B-tree structure. Failures are logged as warnings but do not block startup.

### Daily automated backups

- Runs daily at 02:00 local time via the scheduler
- Uses `VACUUM INTO` for atomic, consistent backup
- Backup files: `fae-backup-YYYYMMDD-HHMMSS.db` in `~/.fae/memory/backups/`
- Retains 7 most recent backups (configurable via `backup_keep_count`)
- Old backups are rotated automatically

### Migration

On startup, schema migrations run automatically when `schema_auto_migrate` is enabled. The one-time JSONL to SQLite migration runs if legacy `.jsonl` files are detected.

## Safety and quality controls

- max record text length is enforced
- oversized captured content is truncated safely
- confidence threshold (`memory.min_profile_confidence`) gates durable promotion and recall
- basic false-positive guards are applied to name extraction
- strict tests cover capture, recall, supersession, migration, and concurrency

## Operational knobs

In `~/.fae/config.toml`:

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
use_hybrid_search = true
semantic_weight = 0.60
integrity_check_on_startup = true
backup_keep_count = 7
```

## Background maintenance

Scheduler tasks keep memory healthy:

| Task | Schedule | Purpose |
|------|----------|---------|
| `memory_migrate` | Every 1h | Check and apply schema migrations |
| `memory_reflect` | Every 6h | Consolidate duplicate records |
| `memory_reindex` | Every 3h | Health check with integrity verification |
| `memory_gc` | Daily 03:30 | Retention policy for old episodes |
| `memory_backup` | Daily 02:00 | Atomic backup with rotation |

## Related docs

- `SOUL.md`
- `docs/architecture/native-app-v0.md`
