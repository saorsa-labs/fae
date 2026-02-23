# Fae Memory

This is the consolidated guide to how Fae memory works — operational behavior, architecture decisions, and future roadmap.

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

Storage:

- `~/Library/Application Support/fae/fae.db` — SQLite database (WAL mode, sqlite-vec extension)
- `~/Library/Application Support/fae/backups/` — daily automated backup files

Voice samples:

- `~/Library/Application Support/fae/voices/`

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
- Backup files: `fae-backup-YYYYMMDD-HHMMSS.db` in backups directory
- Retains 7 most recent backups (configurable via `backup_keep_count`)
- Old backups are rotated automatically

### Migration

On startup, schema migrations run automatically when `schema_auto_migrate` is enabled. The one-time JSONL to SQLite migration runs if legacy `.jsonl` files are detected.

## Safety and quality controls

- max record text length is enforced
- oversized captured content is truncated safely (never fails the turn)
- confidence threshold (`memory.min_profile_confidence`) gates durable promotion and recall
- basic false-positive guards are applied to name extraction
- global write serialization for record/audit mutation
- strict tests cover capture, recall, supersession, migration, and concurrency
- no panic/unwrap/expect in production memory paths

## Operational knobs

In `~/Library/Application Support/fae/config.toml`:

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

Scheduler tasks keep memory healthy and power proactive intelligence:

**Memory tasks:**

| Task | Schedule | Purpose |
|------|----------|---------|
| `memory_migrate` | Every 1h | Check and apply schema migrations |
| `memory_reflect` | Every 6h | Consolidate duplicate records |
| `memory_reindex` | Every 3h | Health check with integrity verification |
| `memory_gc` | Daily 03:30 | Retention policy for old episodes |
| `memory_backup` | Daily 02:00 | Atomic backup with rotation |

**Intelligence tasks** (use memory data for proactive features):

| Task | Schedule | Purpose |
|------|----------|---------|
| `noise_budget_reset` | Daily 00:00 | Reset daily proactive delivery budget |
| `stale_relationships` | Every 7d | Detect relationships needing check-in |
| `morning_briefing` | Daily 08:00 | Prepare morning briefing from memory |
| `skill_proposals` | Daily 11:00 | Detect skill opportunities from patterns |
| `skill_health_check` | Every 5min | Python skill subprocess health checks |

## Architecture decisions

### Memory tiers

- **Working memory**: short-lived turn state and queue context
- **Durable profile memory**: stable user preferences/identity/constraints
- **Durable fact memory**: reusable factual context
- **Episodic memory**: source-linked history for traceability and promotion

### Context-budget strategy

Memory quality depends on context headroom:

1. Keep durable recall bounded (`recall_max_items`, `recall_max_chars`)
2. Keep conversation history bounded (`max_history_messages`)
3. Compact older history near context pressure threshold
4. Scale default context window from machine RAM (8K < 12 GiB, 16K < 20 GiB, 32K < 40 GiB, 64K >= 40 GiB)
5. Future: adaptive policy to reduce recall breadth when compaction frequency spikes

### Upgrade model

- strict schema version gate at startup
- migration chain by version
- automatic backup snapshot before mutate
- rollback on any failure
- idempotent migration contracts tested with fixtures

## Completed milestones

### Phase 1 — Hardening

- Strengthened extraction precision for names/preferences
- Enforced confidence gating for durable promotion/recall
- Improved oversized-turn resilience

### Phase 2 — Retrieval quality (Milestone 7)

- Added embedding index and hybrid ranker (sqlite-vec + all-MiniLM-L6-v2)
- Added dedupe by semantic near-duplicate, not only exact text
- JSONL to SQLite migration with backup preservation

## Future roadmap

### Phase 3 — Governance

- Sensitivity classes and restricted recall policy
- Explicit user namespace partitioning
- Stronger deletion/audit compliance workflows

### Phase 4 — Adaptive intelligence

- Memory-context adaptive budget controller
- Model-assisted extraction/validation pass
- Reinforcement from correction signals over time
- Recall observability dashboards (budget hit ratio, precision proxies)

### Open gaps

- **Extraction breadth**: capture currently relies on deterministic parsing; no dedicated structured extractor model pass yet
- **Governance depth**: no per-memory sensitivity classes/ACL enforcement; no tenant namespace partitioning
- **Context-budget adaptation**: prompt recall budget is char-bounded but static; no automatic adaptation from live context pressure signals

## Related docs

- `SOUL.md`
- `docs/adr/002-embedded-rust-core.md`
