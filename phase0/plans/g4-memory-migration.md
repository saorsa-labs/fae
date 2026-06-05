# G4 Memory Migration Plan — Swift `fae.db` → Rust Core

> **Status:** DRAFT for Phase 0 review  
> **Purpose:** Satisfy G4 acceptance criteria from `docs/architecture/headless-core-impl-plan-2026-06-01.md`  
> **Non-negotiable:** Zero data loss, reversibility, full backup/restore path, audit/supersession preservation

---

## 1. Schema Summary (Swift Runtime, Schema v9)

### 1.1 Storage Locations

| Asset | Path | Format |
|-------|------|--------|
| Memory database | `~/Library/Application Support/fae/fae.db` | SQLite (GRDB) |
| Backups | `~/Library/Application Support/fae/backups/` | Atomic SQLite copies |
| Speaker profiles | `~/Library/Application Support/fae/speakers.json` | JSON |
| SOUL contract | bundled `SOUL.md` | Markdown |
| System prompt | bundled `Prompts/system_prompt.md` | Markdown |

### 1.2 Core Tables

#### `memory_records` (primary memory store)
```sql
CREATE TABLE memory_records (
    id               TEXT PRIMARY KEY,
    kind             TEXT NOT NULL,           -- profile|episode|fact|event|person|interest|commitment|digest
    status           TEXT NOT NULL DEFAULT 'active', -- active|superseded|invalidated|forgotten
    text             TEXT NOT NULL,
    confidence       REAL NOT NULL DEFAULT 0.5,
    source_turn_id   TEXT,
    tags             TEXT NOT NULL DEFAULT '[]', -- JSON array
    supersedes       TEXT,                    -- FK to old record ID (supersession lineage)
    created_at       INTEGER NOT NULL,
    updated_at       INTEGER NOT NULL,
    importance_score REAL,
    stale_after_secs INTEGER,
    metadata         TEXT,                    -- JSON: utterance_at, source, task_id, etc.
    embedding        BLOB,                    -- cached embedding vector
    speaker_id       TEXT                     -- FK to speaker profile
);
```

#### `memory_audit` (edit history, supersession audit trail)
```sql
CREATE TABLE memory_audit (
    id        TEXT PRIMARY KEY,
    op        TEXT NOT NULL,    -- insert|patch|supersede|invalidate|forget_soft|forget_hard|migrate
    target_id TEXT,
    note      TEXT NOT NULL,
    at        INTEGER NOT NULL
);
```

#### `memory_artifacts` (imported content: paste, file, PDF, URL, attachments)
```sql
CREATE TABLE memory_artifacts (
    id           TEXT PRIMARY KEY,
    source_type  TEXT NOT NULL,   -- pasted_text|file|pdf|url|cowork_attachment|proactive
    title        TEXT,
    origin       TEXT,            -- file path or URL
    mime_type    TEXT,
    raw_text     TEXT NOT NULL,
    content_hash TEXT NOT NULL,   -- SHA-256 for deduplication
    created_at   INTEGER NOT NULL,
    updated_at   INTEGER NOT NULL,
    metadata     TEXT
);
```

#### `memory_record_sources` (provenance links: record → artifact or source record)
```sql
CREATE TABLE memory_record_sources (
    id               TEXT PRIMARY KEY,
    record_id        TEXT NOT NULL REFERENCES memory_records(id),
    artifact_id      TEXT REFERENCES memory_artifacts(id),
    source_record_id TEXT REFERENCES memory_records(id),
    role             TEXT NOT NULL,   -- artifact|digest_support
    created_at       INTEGER NOT NULL
);
```

#### `entities` (person/org/location knowledge graph)
```sql
CREATE TABLE entities (
    id                TEXT PRIMARY KEY,
    canonical_name    TEXT NOT NULL,
    aliases           TEXT NOT NULL DEFAULT '[]',  -- JSON array
    relation_type     TEXT,           -- family|friend|colleague|romantic|acquaintance
    relation_label    TEXT,           -- "sister", "boss", etc.
    notes             TEXT,
    first_seen_at     INTEGER NOT NULL,
    last_mentioned_at INTEGER NOT NULL,
    mention_count     INTEGER NOT NULL DEFAULT 0,
    strength_score    REAL NOT NULL DEFAULT 0.0,
    entity_type       TEXT NOT NULL DEFAULT 'person'  -- person|organisation|location|skill|project|concept
);
```

#### `entity_mentions` (entity ↔ memory record links)
```sql
CREATE TABLE entity_mentions (
    id               TEXT PRIMARY KEY,
    entity_id        TEXT NOT NULL REFERENCES entities(id),
    memory_record_id TEXT NOT NULL,
    created_at       INTEGER NOT NULL
);
```

#### `entity_facts` (typed facts per entity with temporal scope)
```sql
CREATE TABLE entity_facts (
    id               TEXT PRIMARY KEY,
    entity_id        TEXT NOT NULL REFERENCES entities(id),
    fact_key         TEXT NOT NULL,
    fact_value       TEXT NOT NULL,
    source_record_id TEXT,
    created_at       INTEGER NOT NULL,
    updated_at       INTEGER NOT NULL,
    confidence       REAL NOT NULL DEFAULT 0.7,
    started_at       INTEGER,         -- temporal validity start
    ended_at         INTEGER,         -- temporal validity end (null = current)
    embedding        BLOB             -- fact embedding for ANN
);
```

#### `entity_relationships` (typed edges between entities)
```sql
CREATE TABLE entity_relationships (
    id             TEXT PRIMARY KEY,
    source_id      TEXT NOT NULL REFERENCES entities(id),
    target_id      TEXT NOT NULL REFERENCES entities(id),
    relation_type  TEXT NOT NULL,     -- works_at|knows|lives_in|manages|reports_to
    confidence     REAL NOT NULL DEFAULT 0.7,
    started_at     INTEGER,
    ended_at       INTEGER,
    metadata       TEXT,
    created_at     INTEGER NOT NULL,
    updated_at     INTEGER NOT NULL,
    UNIQUE(source_id, target_id, relation_type)
);
```

#### `schema_meta` (key-value metadata: version, embedding model ID/dim)
```sql
CREATE TABLE schema_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
-- Keys: schema_version, embedding_model_id, embedding_model_dim
```

### 1.3 Virtual Tables (sqlite-vec ANN)

```sql
CREATE VIRTUAL TABLE memory_vec USING vec0(
    record_id TEXT PRIMARY KEY,
    embedding FLOAT[N]   -- N = embedding dimension (1024/2048/4096)
);

CREATE VIRTUAL TABLE fact_vec USING vec0(
    fact_id TEXT PRIMARY KEY,
    embedding FLOAT[N]
);
```

### 1.4 FTS5 Full-Text Index

```sql
CREATE VIRTUAL TABLE memory_fts USING fts5(
    text, content='memory_records', content_rowid='rowid'
);
-- Kept in sync via triggers: memory_fts_insert, memory_fts_delete, memory_fts_update
```

### 1.5 Speaker Profile Store (`speakers.json`)

```json
[
  {
    "id": "uuid",
    "label": "owner",
    "displayName": "David",
    "role": "owner",               // owner|trusted|guest|fae_self
    "embeddings": [[...], [...]],  // voice embedding vectors
    "embeddingDates": ["2026-01-01T00:00:00Z", ...],
    "centroid": [...],             // averaged embedding
    "enrolledAt": "2026-01-01T00:00:00Z",
    "lastSeen": "2026-06-01T12:00:00Z",
    "photoPath": "/path/to/photo.jpg",
    "photoDescription": "VLM description"
  }
]
```

---

## 2. Record Semantics

### 2.1 Memory Kinds

| Kind | Purpose | Retention | Typical Confidence |
|------|---------|-----------|-------------------|
| `profile` | User identity/preferences | Permanent | 0.86–0.98 |
| `fact` | Durable learned facts | Permanent | 0.75–0.80 |
| `episode` | Conversation turns | 90 days | 0.55 |
| `event` | Dates/appointments | 7 days stale | 0.75 |
| `person` | Relationship mentions | Permanent | 0.75 |
| `interest` | User interests | Permanent | 0.86 |
| `commitment` | Promises/deadlines | 30 days stale | 0.75 |
| `digest` | Synthesized summaries | 14 days decay | 0.75 |

### 2.2 Status Lifecycle

```
active ──┬──> superseded (replaced by newer record via `supersedes` FK)
         ├──> invalidated (user correction made old fact wrong)
         └──> forgotten (soft delete: user requested or retention policy)
```

- **Supersession lineage:** `supersedes` field links new → old record ID
- **Audit trail:** Every status change logged in `memory_audit`
- **Hard delete:** `forget_hard` only for meta-optimization rollback (internal)

### 2.3 Confidence Scoring

```swift
// From MemoryConstants
static let profileNameConfidence: Float = 0.98
static let profilePreferenceConfidence: Float = 0.86
static let factRememberConfidence: Float = 0.80
static let factConversationalConfidence: Float = 0.75
static let episodeConfidence: Float = 0.55
```

### 2.4 Temporal Decay (Retrieval Scoring)

```swift
// Half-life by kind
let halfLife: Float = switch kind {
    case .episode: 30     // days
    case .fact, .interest, .commitment, .event, .person: 180
    case .digest: 14
    case .profile: 365
}
let decay = exp(-0.693 * ageDays / halfLife)
let freshness = 0.7 + 0.3 * decay  // floors at 0.7
```

---

## 3. Migration Plan

### 3.1 Migration Strategy: In-Place SQLite Reuse

**Rationale:** The SQLite schema is stable, portable, and well-indexed. The Rust core should:
1. Read the existing `fae.db` directly
2. Apply any Rust-side schema extensions via forward-compatible ALTER TABLE
3. Never rewrite the entire database — only append/update

**Schema compatibility approach:**
- Rust reads schema_version from `schema_meta`
- If `schema_version < 9`, apply incremental SQL migrations (same pattern as Swift)
- If `schema_version > 9`, refuse to start (forward protection)

### 3.2 Data Files to Migrate

| Source | Target | Migration Action |
|--------|--------|------------------|
| `~/Library/Application Support/fae/fae.db` | Same path (Linux: `~/.local/share/fae/fae.db`) | Direct read via `rusqlite` |
| `~/Library/Application Support/fae/speakers.json` | Same path (Linux: `~/.local/share/fae/speakers.json`) | JSON deserialization |
| `SOUL.md` | Embedded in Rust binary | Compile-time `include_str!` |
| `Prompts/system_prompt.md` | Embedded in Rust binary | Compile-time `include_str!` |
| `~/Library/Application Support/fae/backups/` | Same path (Linux: `~/.local/share/fae/backups/`) | Direct use |

### 3.3 Migration Phases

#### Phase M1: Pre-Migration Validation
```rust
fn validate_pre_migration(db_path: &Path) -> Result<MigrationManifest> {
    // 1. Check schema_version in schema_meta
    // 2. Verify all expected tables exist
    // 3. Run PRAGMA integrity_check
    // 4. Count records per table
    // 5. Verify FTS5 and vec0 extensions load
    // 6. Return manifest with record counts and checksums
}
```

#### Phase M2: Full Backup
```rust
fn backup_before_migration(db_path: &Path, backup_dir: &Path) -> Result<BackupManifest> {
    // 1. VACUUM INTO timestamped backup
    // 2. Copy speakers.json
    // 3. Compute SHA-256 checksums
    // 4. Write manifest.json with:
    //    - backup_at timestamp
    //    - source schema_version
    //    - record counts per table
    //    - file checksums
}
```

#### Phase M3: Schema Extension (if needed)
```rust
fn apply_rust_schema_extensions(db: &Connection) -> Result<()> {
    // Any Rust-specific columns/indexes added here
    // Must be forward-compatible with Swift fallback
    // Update schema_meta with migration note
}
```

#### Phase M4: Post-Migration Validation
```rust
fn validate_post_migration(db: &Connection, manifest: &MigrationManifest) -> Result<()> {
    // 1. Re-count records per table
    // 2. Verify counts match manifest
    // 3. Sample random records and verify deserialization
    // 4. Run FTS5 and vec0 search tests
    // 5. Verify audit log integrity
}
```

### 3.4 Rollback Path

```rust
fn rollback_migration(backup_dir: &Path, db_path: &Path) -> Result<()> {
    // 1. Read manifest.json to find latest backup
    // 2. Verify backup checksums
    // 3. Close all database connections
    // 4. Copy backup over current db
    // 5. Copy speakers.json backup
    // 6. Log rollback to audit
    // 7. Re-validate schema
}
```

---

## 4. Backup/Rollback Plan

### 4.1 Automatic Backup Schedule (Unchanged from Swift)

| Task | Schedule | Retention |
|------|----------|-----------|
| `memory_backup` | Daily 02:00 | 7 rotating copies |
| Pre-migration backup | Before any schema change | Until next backup |

### 4.2 Backup File Format

```
backups/
├── fae-backup-20260601-020000.db
├── fae-backup-20260531-020000.db
├── ...
├── speakers-backup-20260601-020000.json
└── migration-manifest-20260601-120000.json
```

### 4.3 Migration Manifest Schema

```json
{
  "backup_at": "2026-06-01T12:00:00Z",
  "source_schema_version": 9,
  "target_schema_version": 9,
  "migration_type": "swift_to_rust",
  "record_counts": {
    "memory_records": 1234,
    "memory_audit": 5678,
    "memory_artifacts": 42,
    "memory_record_sources": 100,
    "entities": 25,
    "entity_mentions": 150,
    "entity_facts": 75,
    "entity_relationships": 30
  },
  "file_checksums": {
    "fae.db": "sha256:...",
    "speakers.json": "sha256:..."
  },
  "embedding_model_id": "Qwen3-Embedding-4B-4bit",
  "embedding_dim": 2048,
  "validation_passed": true
}
```

### 4.4 Manual Rollback Procedure

```bash
# 1. Stop Fae daemon
pkill fae-daemon

# 2. Find latest backup
ls -la ~/Library/Application\ Support/fae/backups/

# 3. Restore database
cp ~/Library/Application\ Support/fae/backups/fae-backup-YYYYMMDD-HHMMSS.db \
   ~/Library/Application\ Support/fae/fae.db

# 4. Restore speaker profiles if needed
cp ~/Library/Application\ Support/fae/backups/speakers-backup-YYYYMMDD-HHMMSS.json \
   ~/Library/Application\ Support/fae/speakers.json

# 5. Restart daemon
fae-daemon &
```

---

## 5. Audit/Supersession Preservation

### 5.1 Critical Invariants

1. **Audit completeness:** Every record mutation MUST append to `memory_audit`
2. **Supersession lineage:** `supersedes` FK chain MUST remain unbroken
3. **Status immutability:** Once `superseded` or `forgotten`, records MUST NOT become `active`
4. **Timestamp monotonicity:** `updated_at` MUST only increase

### 5.2 Rust-Side Audit Requirements

```rust
// Every write operation must call this
fn audit_operation(
    db: &Transaction,
    op: AuditOp,
    target_id: Option<&str>,
    note: &str,
) -> Result<()> {
    db.execute(
        "INSERT INTO memory_audit (id, op, target_id, note, at) VALUES (?, ?, ?, ?, ?)",
        params![
            new_audit_id(),
            op.as_str(),
            target_id,
            note,
            unix_timestamp_now()
        ],
    )?;
    Ok(())
}

enum AuditOp {
    Insert,
    Patch,
    Supersede,
    Invalidate,
    ForgetSoft,
    ForgetHard,
    Migrate,
}
```

### 5.3 Supersession Chain Validation

```rust
fn validate_supersession_chain(db: &Connection, record_id: &str) -> Result<Vec<String>> {
    let mut chain = vec![record_id.to_string()];
    let mut current = record_id.to_string();
    
    loop {
        let supersedes: Option<String> = db.query_row(
            "SELECT supersedes FROM memory_records WHERE id = ?",
            params![&current],
            |row| row.get(0),
        ).optional()?;
        
        match supersedes {
            Some(older_id) => {
                if chain.contains(&older_id) {
                    return Err(anyhow!("Cycle detected in supersession chain"));
                }
                chain.push(older_id.clone());
                current = older_id;
            }
            None => break,
        }
    }
    
    Ok(chain)
}
```

---

## 6. Validation Tests

### 6.1 Unit Tests (Rust)

```rust
#[cfg(test)]
mod migration_tests {
    #[test]
    fn test_schema_version_read() {
        let db = open_test_db();
        assert_eq!(read_schema_version(&db).unwrap(), 9);
    }

    #[test]
    fn test_record_deserialization() {
        let db = open_fixture_db("v9-sample.db");
        let records = list_all_records(&db).unwrap();
        assert!(!records.is_empty());
        for record in records {
            assert!(!record.id.is_empty());
            assert!(record.confidence >= 0.0 && record.confidence <= 1.0);
        }
    }

    #[test]
    fn test_audit_chain_integrity() {
        let db = open_fixture_db("v9-with-audit.db");
        let audits = list_all_audits(&db).unwrap();
        for audit in audits {
            if let Some(target_id) = &audit.target_id {
                assert!(record_exists(&db, target_id).unwrap());
            }
        }
    }

    #[test]
    fn test_supersession_no_cycles() {
        let db = open_fixture_db("v9-with-supersession.db");
        let superseded = find_records_by_status(&db, "superseded").unwrap();
        for record in superseded {
            let chain = validate_supersession_chain(&db, &record.id).unwrap();
            assert!(chain.len() >= 1);
        }
    }

    #[test]
    fn test_backup_restore_roundtrip() {
        let (db_path, backup_dir) = setup_test_dirs();
        populate_test_db(&db_path);
        
        let manifest = backup_before_migration(&db_path, &backup_dir).unwrap();
        
        // Corrupt the database
        corrupt_test_db(&db_path);
        
        // Restore
        rollback_migration(&backup_dir, &db_path).unwrap();
        
        // Validate
        let restored_manifest = validate_pre_migration(&db_path).unwrap();
        assert_eq!(manifest.record_counts, restored_manifest.record_counts);
    }

    #[test]
    fn test_speaker_profile_deserialization() {
        let json = include_str!("fixtures/speakers-sample.json");
        let profiles: Vec<SpeakerProfile> = serde_json::from_str(json).unwrap();
        assert!(!profiles.is_empty());
        for profile in profiles {
            assert!(!profile.centroid.is_empty());
            assert!(profile.embeddings.len() == profile.embedding_dates.len());
        }
    }

    #[test]
    fn test_fts5_search_after_migration() {
        let db = migrate_test_fixture("v9-sample.db");
        let results = fts_search(&db, "test query", 10).unwrap();
        // Should not panic, results may be empty
    }

    #[test]
    fn test_vec0_search_after_migration() {
        let db = migrate_test_fixture("v9-with-embeddings.db");
        let query_vec = vec![0.1; 1024];
        let results = ann_search(&db, &query_vec, 10).unwrap();
        // Should not panic, results may be empty
    }
}
```

### 6.2 Integration Tests

```rust
#[cfg(test)]
mod integration_tests {
    #[tokio::test]
    async fn test_full_migration_workflow() {
        let temp_dir = tempdir().unwrap();
        let db_path = copy_fixture_to_temp("v9-production-like.db", &temp_dir);
        
        // Pre-migration validation
        let pre_manifest = validate_pre_migration(&db_path).await.unwrap();
        
        // Backup
        let backup_manifest = backup_before_migration(&db_path, &temp_dir.path().join("backups")).await.unwrap();
        
        // Migrate (no-op for v9 → v9)
        apply_rust_schema_extensions(&db_path).await.unwrap();
        
        // Post-migration validation
        validate_post_migration(&db_path, &pre_manifest).await.unwrap();
        
        // Verify record counts unchanged
        let post_manifest = validate_pre_migration(&db_path).await.unwrap();
        assert_eq!(pre_manifest.record_counts, post_manifest.record_counts);
    }

    #[tokio::test]
    async fn test_swift_rust_roundtrip() {
        // This test requires Swift and Rust to both access the same db
        // Run as part of CI with both toolchains
    }
}
```

### 6.3 Compatibility Fixtures

The existing `native/macos/Fae/Tests/HandoffTests/Fixtures/Memory/` directory should be extended:

```
Fixtures/Memory/
├── manifest.toml           # Already exists
├── records.jsonl           # Already exists
├── audit.jsonl             # Already exists
├── README.md               # Already exists
├── v9-full-sample.db       # Add: complete SQLite with all tables
├── v9-with-entities.db     # Add: entity graph populated
├── v9-with-embeddings.db   # Add: vec0 tables with test vectors
├── speakers-sample.json    # Add: speaker profile fixture
└── migration-manifest.json # Add: expected manifest output
```

---

## 7. Recommended Content for `docs/architecture/memory-migration-plan.md`

> This section contains the final artifact to be placed in the repository.

```markdown
# Memory Migration Plan: Swift → Rust Core

> **Status:** Approved for Phase 1  
> **Version:** 1.0  
> **Last Updated:** 2026-06-01

## Overview

This document specifies how Fae's memory data (`fae.db`) and speaker profiles (`speakers.json`) migrate from the Swift runtime to the Rust headless core with **zero data loss**.

## Key Principles

1. **In-place reuse:** SQLite database read directly by Rust; no full rewrite
2. **Forward compatibility:** Swift can fall back if Rust daemon fails
3. **Reversibility:** Every migration is rollback-safe via atomic backup
4. **Audit preservation:** Full supersession lineage and edit history maintained

## Data Scope

| Asset | Format | Migration |
|-------|--------|-----------|
| `fae.db` (schema v9) | SQLite | Direct read via rusqlite |
| `speakers.json` | JSON | serde deserialization |
| `SOUL.md` | Markdown | Embedded at compile time |
| `system_prompt.md` | Markdown | Embedded at compile time |
| Backups | SQLite copies | Direct use |

## Migration Workflow

1. **Pre-validation:** Schema version check, integrity check, record counts
2. **Full backup:** `VACUUM INTO` + speakers.json copy + checksums
3. **Schema extension:** Apply Rust-specific columns if needed
4. **Post-validation:** Record count verification, sample deserialization
5. **Manifest write:** JSON manifest with counts, checksums, timestamps

## Rollback Procedure

```bash
# Stop daemon, restore from backup, restart
cp backups/fae-backup-LATEST.db fae.db
cp backups/speakers-backup-LATEST.json speakers.json
```

## Testing

- Unit tests for schema version read, record deserialization, audit integrity
- Integration tests for full migration workflow
- Fixture databases in `Tests/HandoffTests/Fixtures/Memory/`

## Schema Reference

See `SQLiteMemoryStore.applySchema()` for authoritative table definitions.

## Related Documents

- `docs/guides/Memory.md` — runtime memory behavior
- `SOUL.md` — character contract
- `HEARTBEAT.md` — proactive behavior prompt
- `AGENTS.md` — memory guardrails
```

---

## 8. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| sqlite-vec not available on target | Low | Critical | Bundle sqlite-vec statically; fall back to brute-force search |
| Embedding dimension mismatch | Medium | High | Store `embedding_dim` in schema_meta; rebuild vec0 on model change |
| Concurrent Swift+Rust access | Medium | High | Single writer model; Swift yields to daemon via IPC |
| FTS5 tokenizer incompatibility | Low | Medium | Use same tokenizer (porter stemmer) |
| Speaker embedding dimension drift | Medium | High | Store `embedding_dim` per profile; re-enroll on mismatch |

---

## 9. Implementation Checklist

- [ ] Define Rust structs for `MemoryRecord`, `MemoryAuditEntry`, `PersonEntity`, etc.
- [ ] Implement `rusqlite` connection wrapper with sqlite-vec registration
- [ ] Implement schema version reader and migration dispatcher
- [ ] Implement backup/restore with manifest generation
- [ ] Port FTS5 search query logic
- [ ] Port vec0 ANN search logic
- [ ] Port supersession/audit write operations
- [ ] Port speaker profile JSON deserialization
- [ ] Add unit tests for all record types
- [ ] Add integration tests for migration workflow
- [ ] Add compatibility test fixtures (v9 SQLite databases)
- [ ] Document rollback procedure in README

---

## 10. Acceptance Criteria (G4)

From `headless-core-impl-plan-2026-06-01.md`:

> How the Swift `fae.db` (SQLite/GRDB) + speaker profiles + soul/directive migrate to the Rust core **with zero loss**, reversibly, with a backup/restore path.

**This plan satisfies G4 when:**

1. ✅ Schema fully documented with all tables, columns, and semantics
2. ✅ Migration workflow defined: pre-validation → backup → extend → post-validation
3. ✅ Backup/restore path specified with manifest format and rollback procedure
4. ✅ Audit/supersession preservation rules codified
5. ✅ Validation tests specified for record integrity, audit chain, and roundtrip
6. ⏳ Implementation in Rust core (Phase 1)
7. ⏳ Test fixtures created and passing
