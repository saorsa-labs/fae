# Fae Memory Architecture Plan

## Goals

- Fully automated memory lifecycle for a conversational assistant.
- Durable, editable, and migratable memory data.
- Low-latency recall during conversation.
- Safe updates across schema and model upgrades.
- Auditable edits and conflict handling.

## Non-Goals

- Manual UI buttons for core memory operations.
- Opaque black-box memory with no on-disk visibility.

## Principles

1. Markdown and JSONL files remain human-inspectable source data.
2. Derived index data can be rebuilt at any time.
3. Memory edits are explicit operations, not blind overwrites.
4. Contradictions are tracked, not silently deleted.
5. Migration is versioned, idempotent, and reversible.

## Memory Tiers

1. Working Memory:
- Current conversation context and short rolling state.
- Ephemeral and bounded.

2. Profile Memory:
- Durable user preferences, identity traits, recurring constraints.
- High confidence, low churn.

3. Episodic Memory:
- Timestamped interaction events and notable statements.
- Source-linked for traceability.

4. Knowledge Memory:
- Normalized facts inferred from repeated episodic evidence.
- Managed with confidence and supersession.

## Data Layout

Under `~/.fae/memory/`:

- `manifest.toml`: schema and embedding/index metadata.
- `records.jsonl`: canonical memory records.
- `audit.jsonl`: append-only operation log.
- `primary_user.md`: onboarding profile (existing compatibility file).
- `people.md`: known people list (existing compatibility file).
- `voices/`: captured voice samples.
- `index.db`: derived retrieval/index state (rebuildable).

## Record Model

Each memory record includes:

- `id`: stable UUID.
- `kind`: profile | episode | fact.
- `status`: active | superseded | invalidated | forgotten.
- `text`: human-readable content.
- `confidence`: `0.0..=1.0`.
- `created_at` and `updated_at` (unix seconds).
- `source_turn_id`: conversation provenance.
- `tags`: optional typed labels.
- `supersedes`: optional predecessor record id.

## Edit Operations

Supported operations:

- `insert`: add a new record.
- `patch`: update fields in place with audit trail.
- `supersede`: replace previous truth while preserving lineage.
- `invalidate`: mark record as incorrect.
- `forget_soft`: hide from default recall (recoverable).
- `forget_hard`: permanent erase.

## Recall Pipeline

1. Candidate selection:
- Exact metadata filters and keyword match.

2. Ranking:
- Hybrid lexical and similarity ranking.
- Confidence and freshness weighting.

3. Packing:
- Enforce strict char/token budget for prompt injection.
- Include source pointers for explainability.

## Capture Pipeline

Per completed turn:

1. Persist episodic summary from user/assistant exchange.
2. Detect durable profile/fact candidates.
3. Run conflict checks against active records.
4. Apply operation(s) with audit entries.
5. Queue async index update.

## Conflict Policy

- New high-confidence user-stated facts can supersede old inferred facts.
- Contradictory facts are not deleted by default.
- Low-confidence candidates remain episodic until reinforced.

## Upgrade and Migration

`manifest.toml` contains:

- `schema_version`
- `embedder_version`
- `index_version`
- `last_migrated_at`

Startup process:

1. Load manifest.
2. If schema mismatch and auto-migrate enabled:
- backup memory dir snapshot
- run sequential migrations
- verify integrity and write new manifest
3. If migration fails:
- rollback to backup
- start in degraded read-compatible mode

Index upgrades:

- Dual-read strategy while reindex/re-embedding runs.
- Background jobs migrate old vectors/chunks incrementally.

## Automation Jobs

Scheduled tasks:

- `memory_reflect`: consolidate repeated episodes to durable facts.
- `memory_reindex`: maintain derived index integrity.
- `memory_gc`: retention and soft-delete compaction.
- `memory_migrate`: delayed or retry migrations.

## Observability

Emit runtime events for:

- recall hit count and budget use
- write operations and conflicts
- migration start/end/failure
- reflection and reindex outcomes

## Safety and Privacy

- Sensitive data tagging and optional restricted recall.
- Hard-delete path for compliance-style forgetting.
- Audit trail for all non-hard-delete operations.

## Testing Strategy (TDD)

1. Unit tests:
- record validation, scoring, operation semantics, migration steps.

2. Integration tests:
- recall/capture orchestration in pipeline.
- upgrade path with old manifests.

3. Regression tests:
- contradiction handling
- idempotent migration behavior
- retention and forget workflows

4. Quality gates:
- `cargo fmt --all`
- strict clippy (panic/unwrap/expect denied in non-test code)
- targeted and full test suite runs before release

