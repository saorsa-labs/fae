# G4 Memory Migration — Context Summary

## Relevant Files

### Core Memory Implementation (Swift)

| File | Lines | Purpose |
|------|-------|---------|
| `native/macos/Fae/Sources/Fae/Memory/MemoryTypes.swift` | ~200 | Record kinds, status enums, audit ops, scoring constants |
| `native/macos/Fae/Sources/Fae/Memory/SQLiteMemoryStore.swift` | ~650 | GRDB-backed SQLite: schema v9, all tables, FTS5, migrations |
| `native/macos/Fae/Sources/Fae/Memory/MemoryOrchestrator.swift` | ~1600 | Recall/capture logic, supersession, proactive memory |
| `native/macos/Fae/Sources/Fae/Memory/VectorStore.swift` | ~130 | sqlite-vec vec0 tables for ANN search |
| `native/macos/Fae/Sources/Fae/Memory/EntityStore.swift` | ~450 | Entity graph: persons/orgs/locations, relationships |
| `native/macos/Fae/Sources/Fae/Memory/MemoryBackup.swift` | ~60 | VACUUM INTO backup, rotation |
| `native/macos/Fae/Sources/Fae/ML/SpeakerProfileStore.swift` | ~450 | Voice identity profiles, JSON persistence |
| `native/macos/Fae/Sources/Fae/Scheduler/FaeScheduler.swift` | ~2300 | Scheduled tasks including memory_backup, memory_gc |

### Behavioral Truth Sources

| File | Purpose |
|------|---------|
| `SOUL.md` | Character contract — memory section defines "remembers without being asked" |
| `HEARTBEAT.md` | Proactive behavior — progressive disclosure, trust building |
| `Prompts/system_prompt.md` | Operational context — memory usage policy |
| `AGENTS.md` | Engineering guardrails — memory as production-critical |

### Documentation

| File | Purpose |
|------|---------|
| `docs/guides/Memory.md` | Runtime memory behavior, schema v9 tables, retrieval |
| `docs/architecture/headless-core-impl-plan-2026-06-01.md` | G4 requirements definition |

### Test Fixtures

| File | Purpose |
|------|---------|
| `native/macos/Fae/Tests/HandoffTests/Fixtures/Memory/manifest.toml` | Schema version 2 fixture |
| `native/macos/Fae/Tests/HandoffTests/Fixtures/Memory/records.jsonl` | Sample records with status variants |
| `native/macos/Fae/Tests/HandoffTests/Fixtures/Memory/audit.jsonl` | Audit trail sample |
| `native/macos/Fae/Tests/HandoffTests/MemoryMigrationCompatibilityTests.swift` | Existing migration tests |

---

## Key Schema Facts

### Schema Version: 9

Tables:
- `memory_records` — 15 columns including `supersedes` FK for lineage
- `memory_audit` — 5 columns, tracks all mutations
- `memory_artifacts` — 10 columns, imported content storage
- `memory_record_sources` — 6 columns, provenance links
- `entities` — 11 columns, knowledge graph nodes
- `entity_mentions` — 4 columns, record↔entity links
- `entity_facts` — 10 columns, temporal facts per entity
- `entity_relationships` — 10 columns, typed edges
- `schema_meta` — key-value metadata
- `memory_vec` — sqlite-vec ANN table
- `fact_vec` — sqlite-vec ANN table for entity facts
- `memory_fts` — FTS5 full-text index

### Record Status Lifecycle

```
active → superseded (via supersedes FK)
active → invalidated (user correction)
active → forgotten (soft delete)
```

### Critical Invariants (from AGENTS.md)

1. Preserve on-disk compatibility unless a migration is added
2. Never silently overwrite conflicting durable facts; use supersession lineage
3. Keep memory edits auditable
4. Keep non-test mutation paths panic-free

---

## Storage Paths

| Asset | macOS | Linux (proposed) |
|-------|-------|------------------|
| Database | `~/Library/Application Support/fae/fae.db` | `~/.local/share/fae/fae.db` |
| Backups | `~/Library/Application Support/fae/backups/` | `~/.local/share/fae/backups/` |
| Speakers | `~/Library/Application Support/fae/speakers.json` | `~/.local/share/fae/speakers.json` |

---

## Embedding Tiers

| RAM | Model | Dimension |
|-----|-------|-----------|
| ≥64 GB | Qwen3-Embedding-8B-4bit | 4096 |
| ≥32 GB | Qwen3-Embedding-4B-4bit | 2048 |
| ≥16 GB | Qwen3-Embedding-0.6B-4bit | 1024 |
| <16 GB | HashEmbeddingEngine (FNV-1a) | 384 |

---

## Dependencies

- **SQLite extensions:** sqlite-vec (vec0 virtual tables), FTS5
- **Swift libraries:** GRDB, CSQLiteVecCore
- **Rust equivalents needed:** rusqlite, sqlite-vec crate, FTS5 support
