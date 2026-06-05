> NON-AUTHORITATIVE SCRATCH ARTIFACT. This file was produced by a planning subagent and may overstate Phase 0 authorization. Do not use it as implementation authority; use docs/architecture/headless-core-impl-plan-2026-06-01.md and phase0/worker/phase0-artifacts.md instead.

# G4 Memory Migration — Meta-Prompt for Implementation

## Goal

Implement the Rust memory store that reads the Swift `fae.db` SQLite database and `speakers.json` with **zero data loss**, supporting full backup/restore and preserving audit/supersession lineage.

## Context/Evidence

### Source of Truth
- **Migration plan:** `phase0/plans/g4-memory-migration.md` (this sprint's output)
- **Schema authority:** `native/macos/Fae/Sources/Fae/Memory/SQLiteMemoryStore.swift:applySchema()`
- **Test fixtures:** `native/macos/Fae/Tests/HandoffTests/Fixtures/Memory/`

### Schema v9 Core Tables
```sql
memory_records    -- 15 columns, supersedes FK for lineage
memory_audit      -- 5 columns, every mutation logged
memory_artifacts  -- 10 columns, imported content
memory_record_sources -- 6 columns, provenance
entities          -- 11 columns, knowledge graph
entity_facts      -- 10 columns, temporal facts
entity_relationships -- 10 columns, typed edges
schema_meta       -- key-value (schema_version, embedding_model_id, embedding_dim)
memory_vec        -- sqlite-vec ANN (record embeddings)
fact_vec          -- sqlite-vec ANN (entity fact embeddings)
memory_fts        -- FTS5 full-text index
```

### Critical Invariants
1. **Audit completeness:** Every write → `memory_audit` entry
2. **Supersession lineage:** `supersedes` FK chain never broken
3. **Status immutability:** `superseded`/`forgotten` records stay that way
4. **Timestamp monotonicity:** `updated_at` only increases

### Storage Paths
- macOS: `~/Library/Application Support/fae/fae.db`, `speakers.json`
- Linux: `~/.local/share/fae/fae.db`, `speakers.json`

---

## Success Criteria

1. **Schema reader:** Rust can open `fae.db`, read `schema_version`, verify v9
2. **Record deserialization:** All 8 `MemoryKind` variants deserialize correctly
3. **Audit read/write:** Audit entries append on every mutation
4. **Supersession:** Can follow `supersedes` chain to root
5. **Search:** FTS5 and vec0 queries work from Rust
6. **Backup/restore:** `VACUUM INTO` backup, rollback via file copy
7. **Speaker profiles:** JSON deserialization matches Swift structure
8. **Test coverage:** Unit tests for all record types, integration test for full workflow

---

## Hard Constraints

1. **No schema rewrite:** Read existing SQLite directly; only extend via `ALTER TABLE`
2. **Forward compatibility:** Swift must be able to fall back if Rust fails
3. **sqlite-vec required:** Bundle statically if not available system-wide
4. **No silent data loss:** If migration fails, rollback automatically

---

## Suggested Approach

### Phase 1: Rust Structs
```rust
// In fae-core/src/memory/types.rs
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum MemoryKind {
    Profile, Episode, Fact, Event, Person, Interest, Commitment, Digest
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum MemoryStatus {
    Active, Superseded, Invalidated, Forgotten
}

#[derive(Debug, Clone)]
pub struct MemoryRecord {
    pub id: String,
    pub kind: MemoryKind,
    pub status: MemoryStatus,
    pub text: String,
    pub confidence: f32,
    pub source_turn_id: Option<String>,
    pub tags: Vec<String>,
    pub supersedes: Option<String>,
    pub created_at: u64,
    pub updated_at: u64,
    pub importance_score: Option<f32>,
    pub stale_after_secs: Option<u64>,
    pub metadata: Option<String>,
    pub embedding: Option<Vec<f32>>,
    pub speaker_id: Option<String>,
}
```

### Phase 2: SQLite Connection
```rust
// In fae-core/src/memory/store.rs
use rusqlite::{Connection, params};

pub struct MemoryStore {
    conn: Connection,
}

impl MemoryStore {
    pub fn open(path: &Path) -> Result<Self> {
        let conn = Connection::open(path)?;
        conn.load_extension("sqlite_vec")?;
        // Verify schema version
        let version: u32 = conn.query_row(
            "SELECT value FROM schema_meta WHERE key = 'schema_version'",
            [],
            |row| row.get(0),
        )?;
        ensure!(version == 9, "Unsupported schema version {}", version);
        Ok(Self { conn })
    }
}
```

### Phase 3: Backup Implementation
```rust
pub fn backup(db_path: &Path, backup_dir: &Path) -> Result<BackupManifest> {
    let timestamp = Utc::now().format("%Y%m%d-%H%M%S");
    let backup_path = backup_dir.join(format!("fae-backup-{}.db", timestamp));
    
    let conn = Connection::open(db_path)?;
    conn.execute(&format!("VACUUM INTO '{}'", backup_path.display()), [])?;
    
    // Generate manifest with checksums
    Ok(BackupManifest { ... })
}
```

### Phase 4: Tests
Create fixtures from existing Swift test data:
- `v9-full-sample.db` — complete database with all tables
- `v9-with-entities.db` — entity graph populated
- `speakers-sample.json` — voice profiles

---

## Validation

1. **Unit tests pass:** `cargo test -p fae-memory`
2. **Integration test:** Open real Swift-generated `fae.db`, verify record counts
3. **Roundtrip test:** Swift writes → Rust reads → verify identical
4. **Backup/restore test:** Corrupt DB, restore from backup, verify counts

---

## Stop/Escalation Rules

- **STOP if:** Schema version > 9 (forward protection)
- **STOP if:** `integrity_check` fails on source database
- **ESCALATE if:** sqlite-vec fails to load on target platform
- **ESCALATE if:** Record count mismatch after migration

---

## Output Expectations

1. `fae-core/src/memory/` module with:
   - `types.rs` — Rust equivalents of Swift types
   - `store.rs` — SQLite connection, read/write ops
   - `backup.rs` — backup/restore implementation
   - `search.rs` — FTS5 and vec0 queries
   - `audit.rs` — audit trail operations

2. Tests in `fae-core/tests/memory/`:
   - `schema_tests.rs`
   - `record_tests.rs`
   - `audit_tests.rs`
   - `migration_tests.rs`

3. Fixtures in `fae-core/tests/fixtures/`:
   - `v9-sample.db`
   - `speakers-sample.json`
   - `migration-manifest.json`

---

## Resolved Questions

- **Q: Rewrite or extend schema?** A: Extend only; direct read of Swift SQLite
- **Q: Bundle sqlite-vec?** A: Yes, statically link
- **Q: Support schema < 9?** A: No; Swift upgrades before Rust reads
- **Q: Concurrent access?** A: Single writer; Swift yields via IPC
