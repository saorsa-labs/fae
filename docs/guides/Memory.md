# Fae Memory (Swift Runtime)

This guide documents memory behavior in the current Swift app.

## Storage

Memory lives in:

- `~/Library/Application Support/fae/fae.db` (SQLite via GRDB)
- `~/Library/Application Support/fae/backups/` (rotating backups)

### Schema v9 tables

| Table | Purpose |
|-------|---------|
| `memory_artifacts` | Raw imported artifacts from paste, file, PDF, URL, and attachment flows |
| `memory_record_sources` | Provenance links from any memory record back to artifacts or source records |
| `memory_records` | Core episodic/factual/profile records |
| `memory_audit` | Edit history and supersession lineage |
| `entities` | Persons, organisations, locations (typed) |
| `entity_facts` | Key-value facts per entity with temporal scope |
| `entity_record_links` | Memory records → entity cross-reference |
| `entity_relationships` | Typed, temporal edges between entities |
| `memory_vec` | sqlite-vec ANN table for record embeddings |
| `fact_vec` | sqlite-vec ANN table for entity fact embeddings |
| `schema_meta` | Key-value store for schema version, embedding model ID/dim |

## Record model

Kinds:

- `profile`, `fact`, `episode`, `event`, `person`, `interest`, `commitment`, `digest`

Lifecycle status:

- `active`, `superseded`, `invalidated`, `forgotten`

## Runtime lifecycle

Per completed turn:

1. Recall relevant memory before generation (ANN + FTS5 hybrid)
2. Prefer recent `digest` records first, then durable records, then episodes
3. Inject bounded `<memory_context>` including entity profiles and provenance labels
4. Capture episode + durable candidates
5. Resolve conflicts through supersession lineage
6. Apply retention cleanup for episodic records

Imported artifacts follow a parallel path:

1. `MemoryInboxService` stores the raw artifact in `memory_artifacts`
2. Fae creates or reuses a linked seed memory record tagged `imported`
3. `MemoryDigestService` periodically synthesizes digest records from recent imported/proactive memories
4. Digest records link back to their supporting records through `memory_record_sources`

When two imports share the same content but come from different origins, Fae now keeps separate artifact rows so recall can cite both provenance sources while still reusing the same imported memory record.

## Retrieval

Hybrid scoring: **60% ANN (cosine via sqlite-vec) + 40% FTS5 (lexical)**

- ANN search uses `NeuralEmbeddingEngine` (Qwen3-Embedding) via `VectorStore.searchRecords`
- Lexical search uses FTS5 in `SQLiteMemoryStore.search`
- Scores blended: `annScore = 1.0 - distance/2.0` (cosine in [0,2]), then weighted average
- Falls back to lexical-only if embedding engine not yet loaded
- `digest` records receive a freshness/importance boost so "what have you learned recently?" style queries surface synthesized context first

## Entity knowledge graph

`EntityLinker` processes each `.person` record and extracts:

- Canonical entity (person, organisation, location) via fuzzy name matching
- Typed relationship edges: `works_at`, `lives_in`, `knows`, `reports_to`
- Temporal facts with `started_at`/`ended_at` scope

Entity query patterns (`PersonQueryDetector`):

- `"who works at X"` → `EntityStore.findEntities(connectedTo: "X", via: "works_at")`
- `"who lives in X"` → `EntityStore.findEntities(connectedTo: "X", via: "lives_in")`
- `"what do you know about Sarah"` → full entity profile with edges

Entity profile output (`EntityContextFormatter`) includes relationship edges with temporal annotation:

```
[Sarah (sister, family): employer: Google. Mentioned 7×. Last 3 days ago.
  Works at: Google (since 2022)
  Lives in: London (since 2023)
  Commitment: call her by Friday.]
```

## Embedding engine tiers

`NeuralEmbeddingEngine` selects by system RAM:

| RAM | Model | Dimension |
|-----|-------|-----------|
| ≥64 GB | `mlx-community/Qwen3-Embedding-8B-4bit` | 4096 |
| ≥32 GB | `mlx-community/Qwen3-Embedding-4B-4bit` | 2048 |
| ≥16 GB | `mlx-community/Qwen3-Embedding-0.6B-4bit` | 1024 |
| <16 GB | `HashEmbeddingEngine` (FNV-1a hash projection) | 384 |

On model change, `EmbeddingBackfillRunner` drops and rebuilds the vec0 tables, then re-embeds all records and facts.

## Capture

`MemoryOrchestrator.capture(...)` automatically extracts:

- explicit remember/forget directives
- name/profile preferences
- interests
- commitments
- events
- person relationships → also triggers entity extraction and edge creation

Episode embeddings are stored non-blocking after each capture via `VectorStore.upsertRecordEmbedding`.

`MemoryInboxService` additionally supports:

- pasted text
- local text-like files
- PDFs via `PDFKit` text extraction
- URLs via fetched page content
- watched inbox folder ingestion from `~/Library/Application Support/fae/memory-inbox/pending/`

## Maintenance tasks

`FaeScheduler` runs:

| Task | Schedule | Purpose |
|------|----------|---------|
| `memory_migrate` | hourly | Schema migration checks |
| `memory_inbox_ingest` | every 5m | Import queued files from the inbox pending folder |
| `memory_reindex` | every 3h | Health check + integrity verification |
| `memory_digest` | every 6h | Synthesize recent imported/proactive records into digest memories |
| `memory_reflect` | every 6h | Consolidate duplicate memories |
| `memory_gc` | daily 03:30 | Retention cleanup (episode expiry) |
| `memory_backup` | daily 02:00 | Atomic backup with rotation |
| `embedding_reindex` | weekly Sun 03:00 | Re-embed records missing ANN vectors |

## Config

**Canonical preference:** Prefer skill contracts over hardcoded code paths; prefer asking Fae conversationally for setup/changes over manual config editing.

Preferred path: ask Fae to change memory settings conversationally (for example, enable/disable memory or adjust max recall results). Raw config editing remains available for advanced/manual workflows.

Memory config in `config.toml`:

```toml
[memory]
enabled = true
maxRecallResults = 6
autoIngestInbox = true
generateDigests = true
```

The embedding model tier is selected automatically by RAM. To override, see `EmbeddingModelTier.recommendedTier(ramGB:)` in `NeuralEmbeddingEngine.swift`.

## Source files

| File | Role |
|------|------|
| `Memory/MemoryOrchestrator.swift` | Recall (ANN+FTS5 hybrid), capture, GC, graph context |
| `Memory/SQLiteMemoryStore.swift` | GRDB-backed SQLite: insert, search, supersede, retain |
| `Memory/MemoryTypes.swift` | MemoryRecord, MemoryKind, MemoryStatus, constants |
| `Memory/MemoryInboxService.swift` | Artifact intake from paste/file/PDF/URL and watched inbox folder |
| `Memory/MemoryDigestService.swift` | Periodic digest generation with record-to-record provenance links |
| `Memory/MemoryBackup.swift` | Database backup and rotation |
| `Memory/VectorStore.swift` | sqlite-vec ANN tables (`memory_vec`, `fact_vec`) |
| `Memory/EntityStore.swift` | Entity graph: persons, orgs, locations, typed relationships |
| `Memory/EntityLinker.swift` | Extract and persist entities/edges from person records |
| `Memory/EntityBackfillRunner.swift` | One-time backfill: legacy person records → entity graph |
| `Memory/EmbeddingBackfillRunner.swift` | Background paged backfill of all records/facts into ANN |
| `Memory/PersonQueryDetector.swift` | Detect person/org/location queries |
| `Memory/EntityContextFormatter.swift` | Format entity profiles including relationship edges |
| `ML/NeuralEmbeddingEngine.swift` | Tiered Qwen3-Embedding with hash fallback |
