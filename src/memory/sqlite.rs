//! SQLite-backed memory repository.
//!
//! Implements the same public API as `MemoryRepository` (JSONL backend),
//! backed by a single SQLite database file at `{root_dir}/fae.db`.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use rusqlite::{Connection, params};

use super::schema::{EMBEDDING_DIM, apply_schema, apply_vec_schema, read_schema_version};

/// Register the sqlite-vec extension globally (once).
///
/// Must be called before any `Connection::open()` that needs vec0 support.
fn ensure_sqlite_vec_loaded() {
    use std::sync::Once;
    static INIT: Once = Once::new();
    INIT.call_once(|| {
        // SAFETY: `sqlite3_vec_init` is a valid SQLite extension entry point
        // provided by the sqlite-vec crate (statically linked). Registering it
        // as an auto-extension is the documented way to enable vec0 for all
        // connections.  The transmute is the same pattern used in sqlite-vec's
        // own test suite.
        unsafe {
            type ExtEntryPoint = unsafe extern "C" fn(
                *mut rusqlite::ffi::sqlite3,
                *mut *const i8,
                *const rusqlite::ffi::sqlite3_api_routines,
            ) -> i32;

            rusqlite::ffi::sqlite3_auto_extension(Some(std::mem::transmute::<
                *const (),
                ExtEntryPoint,
            >(
                sqlite_vec::sqlite3_vec_init as *const (),
            )));
        }
    });
}
use super::types::{
    MemoryAuditEntry, MemoryAuditOp, MemoryKind, MemoryRecord, MemorySearchHit, MemoryStatus,
    display_kind, hybrid_score, new_id, now_epoch_secs, score_record, tokenize,
    truncate_record_text,
};

/// Database filename within the memory root directory.
const DB_FILENAME: &str = "fae.db";

/// Parameters for superseding an existing record with a new one.
pub struct SupersedeParams<'a> {
    pub old_id: &'a str,
    pub kind: MemoryKind,
    pub new_text: &'a str,
    pub confidence: f32,
    pub source_turn_id: Option<&'a str>,
    pub tags: &'a [String],
    pub note: &'a str,
}

/// SQLite-backed memory repository.
///
/// Thread-safe via an internal `Mutex<Connection>`.  All writes are
/// serialized; reads can proceed concurrently with WAL mode on the
/// SQLite side, though we still acquire the mutex for simplicity.
pub struct SqliteMemoryRepository {
    root: PathBuf,
    conn: Mutex<Connection>,
}

impl std::fmt::Debug for SqliteMemoryRepository {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("SqliteMemoryRepository")
            .field("root", &self.root)
            .finish_non_exhaustive()
    }
}

impl SqliteMemoryRepository {
    /// Open (or create) the SQLite database at `{root_dir}/fae.db`.
    ///
    /// Registers the sqlite-vec extension (once, globally), then applies the
    /// full schema including the `vec_embeddings` virtual table.
    pub fn new(root_dir: &Path) -> Result<Self, SqliteMemoryError> {
        ensure_sqlite_vec_loaded();

        std::fs::create_dir_all(root_dir).map_err(|e| SqliteMemoryError::Io(e.to_string()))?;
        let db_path = root_dir.join(DB_FILENAME);
        let conn = Connection::open(&db_path).map_err(SqliteMemoryError::Sqlite)?;

        apply_schema(&conn).map_err(SqliteMemoryError::Sqlite)?;
        apply_vec_schema(&conn).map_err(SqliteMemoryError::Sqlite)?;

        let repo = Self {
            root: root_dir.to_path_buf(),
            conn: Mutex::new(conn),
        };

        // Run a fast integrity check after schema setup.  Log a warning on
        // failure but don't prevent construction — the caller decides how to
        // handle corruption.
        if let Err(e) = repo.integrity_check() {
            tracing::warn!(error = %e, "SQLite integrity check failed on startup");
        }

        Ok(repo)
    }

    /// Returns the root directory path.
    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Idempotent schema application.
    pub fn ensure_layout(&self) -> Result<(), SqliteMemoryError> {
        let conn = self.lock()?;
        apply_schema(&conn).map_err(SqliteMemoryError::Sqlite)
    }

    /// Run a fast integrity check on the database.
    ///
    /// Uses `PRAGMA quick_check` which is significantly faster than the full
    /// `PRAGMA integrity_check` — it skips verifying index ordering and
    /// uniqueness but still validates page-level B-tree structure.
    ///
    /// Returns `Ok(())` when the database passes, or
    /// `Err(SqliteMemoryError::Corrupt(...))` with a description of the issue.
    pub fn integrity_check(&self) -> Result<(), SqliteMemoryError> {
        let conn = self.lock()?;
        let result: String = conn
            .query_row("PRAGMA quick_check", [], |row| row.get(0))
            .map_err(SqliteMemoryError::Sqlite)?;
        if result == "ok" {
            Ok(())
        } else {
            Err(SqliteMemoryError::Corrupt(result))
        }
    }

    /// Read the current schema version from the database.
    ///
    /// Returns `0` if the `schema_meta` table has no version entry.
    pub fn schema_version(&self) -> Result<u32, SqliteMemoryError> {
        let conn = self.lock()?;
        let version = read_schema_version(&conn).map_err(SqliteMemoryError::Sqlite)?;
        Ok(version.unwrap_or(0))
    }

    /// Apply incremental migrations up to `target` version.
    ///
    /// No-op if already at or above `target`.
    pub fn migrate_if_needed(&self, target: u32) -> Result<(), SqliteMemoryError> {
        let current = self.schema_version()?;
        if current >= target {
            return Ok(());
        }

        let conn = self.lock()?;

        // Migration 2 → 3: create vec_embeddings virtual table.
        if current < 3 {
            apply_vec_schema(&conn).map_err(SqliteMemoryError::Sqlite)?;
        }

        // Stamp the new version.
        conn.execute(
            "UPDATE schema_meta SET value = ?1 WHERE key = 'schema_version'",
            params![target.to_string()],
        )
        .map_err(SqliteMemoryError::Sqlite)?;
        Ok(())
    }

    /// List all active records (matches JSONL `MemoryRepository::list_records()` behaviour).
    pub fn list_records(&self) -> Result<Vec<MemoryRecord>, SqliteMemoryError> {
        self.list_records_filtered(false)
    }

    /// List records, optionally including inactive (superseded, invalidated, forgotten).
    pub fn list_records_filtered(
        &self,
        include_inactive: bool,
    ) -> Result<Vec<MemoryRecord>, SqliteMemoryError> {
        let conn = self.lock()?;
        let sql = if include_inactive {
            "SELECT id, kind, status, text, confidence, source_turn_id, tags, \
             supersedes, created_at, updated_at, importance_score, stale_after_secs, \
             metadata FROM memory_records ORDER BY updated_at DESC"
        } else {
            "SELECT id, kind, status, text, confidence, source_turn_id, tags, \
             supersedes, created_at, updated_at, importance_score, stale_after_secs, \
             metadata FROM memory_records WHERE status = 'active' ORDER BY updated_at DESC"
        };
        let mut stmt = conn.prepare(sql).map_err(SqliteMemoryError::Sqlite)?;
        let rows = stmt
            .query_map([], row_to_record)
            .map_err(SqliteMemoryError::Sqlite)?;

        let mut records = Vec::new();
        for r in rows {
            records.push(r.map_err(SqliteMemoryError::Sqlite)?);
        }
        Ok(records)
    }

    /// List all audit entries, ordered by timestamp descending.
    pub fn audit_entries(&self) -> Result<Vec<MemoryAuditEntry>, SqliteMemoryError> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare("SELECT id, op, target_id, note, at FROM memory_audit ORDER BY at DESC")
            .map_err(SqliteMemoryError::Sqlite)?;
        let rows = stmt
            .query_map([], row_to_audit)
            .map_err(SqliteMemoryError::Sqlite)?;

        let mut entries = Vec::new();
        for r in rows {
            entries.push(r.map_err(SqliteMemoryError::Sqlite)?);
        }
        Ok(entries)
    }

    /// Insert a new memory record, returning the full record.
    pub fn insert_record(
        &self,
        kind: MemoryKind,
        text: &str,
        confidence: f32,
        source_turn_id: Option<&str>,
        tags: &[String],
    ) -> Result<MemoryRecord, SqliteMemoryError> {
        let conn = self.lock()?;
        let now = now_epoch_secs();
        let id = new_id(display_kind(kind));
        let text = truncate_record_text(text);
        let tags_json = serde_json::to_string(tags).unwrap_or_else(|_| "[]".to_owned());
        let kind_str = kind_to_str(kind);

        conn.execute(
            "INSERT INTO memory_records \
             (id, kind, status, text, confidence, source_turn_id, tags, created_at, updated_at) \
             VALUES (?1, ?2, 'active', ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                id,
                kind_str,
                text,
                confidence,
                source_turn_id,
                tags_json,
                now,
                now
            ],
        )
        .map_err(SqliteMemoryError::Sqlite)?;

        let audit_id = new_id("audit");
        conn.execute(
            "INSERT INTO memory_audit (id, op, target_id, note, at) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![audit_id, "insert", id, format!("insert {kind_str}"), now],
        )
        .map_err(SqliteMemoryError::Sqlite)?;

        Ok(MemoryRecord {
            id,
            kind,
            status: MemoryStatus::Active,
            text,
            confidence: confidence.clamp(0.0, 1.0),
            source_turn_id: source_turn_id.map(ToOwned::to_owned),
            tags: tags.to_vec(),
            supersedes: None,
            created_at: now,
            updated_at: now,
            importance_score: None,
            stale_after_secs: None,
            metadata: None,
        })
    }

    /// Insert a pre-existing record verbatim (for JSONL→SQLite migration).
    ///
    /// Preserves the original `id`, `created_at`, `updated_at`, `status`,
    /// `supersedes`, `tags`, and all other fields. Also creates an audit
    /// entry with `op = Migrate`.
    pub fn insert_record_raw(&self, record: &MemoryRecord) -> Result<(), SqliteMemoryError> {
        let conn = self.lock()?;
        let kind_str = kind_to_str(record.kind);
        let status_str = status_to_str(record.status);
        let tags_json = serde_json::to_string(&record.tags).unwrap_or_else(|_| "[]".to_owned());
        let metadata_json = record
            .metadata
            .as_ref()
            .and_then(|m| serde_json::to_string(m).ok());

        conn.execute(
            "INSERT OR IGNORE INTO memory_records \
             (id, kind, status, text, confidence, source_turn_id, tags, supersedes, \
              created_at, updated_at, importance_score, stale_after_secs, metadata) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)",
            params![
                record.id,
                kind_str,
                status_str,
                record.text,
                record.confidence,
                record.source_turn_id,
                tags_json,
                record.supersedes,
                record.created_at,
                record.updated_at,
                record.importance_score,
                record.stale_after_secs,
                metadata_json,
            ],
        )
        .map_err(SqliteMemoryError::Sqlite)?;

        let audit_id = new_id("audit");
        let now = now_epoch_secs();
        conn.execute(
            "INSERT INTO memory_audit (id, op, target_id, note, at) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                audit_id,
                "migrate",
                record.id,
                format!("migrated {kind_str} from JSONL"),
                now,
            ],
        )
        .map_err(SqliteMemoryError::Sqlite)?;

        Ok(())
    }

    /// Insert a pre-existing audit entry verbatim (for JSONL→SQLite migration).
    pub fn insert_audit_raw(&self, entry: &MemoryAuditEntry) -> Result<(), SqliteMemoryError> {
        let conn = self.lock()?;
        let op_str = audit_op_to_str(entry.op);

        conn.execute(
            "INSERT OR IGNORE INTO memory_audit (id, op, target_id, note, at) \
             VALUES (?1, ?2, ?3, ?4, ?5)",
            params![entry.id, op_str, entry.target_id, entry.note, entry.at],
        )
        .map_err(SqliteMemoryError::Sqlite)?;

        Ok(())
    }

    /// Patch record text and update timestamp.
    pub fn patch_record(
        &self,
        id: &str,
        new_text: &str,
        note: &str,
    ) -> Result<(), SqliteMemoryError> {
        let conn = self.lock()?;
        let now = now_epoch_secs();
        let text = truncate_record_text(new_text);

        let rows = conn
            .execute(
                "UPDATE memory_records SET text = ?1, updated_at = ?2 WHERE id = ?3",
                params![text, now, id],
            )
            .map_err(SqliteMemoryError::Sqlite)?;

        if rows == 0 {
            return Err(SqliteMemoryError::NotFound(id.to_owned()));
        }

        let audit_id = new_id("audit");
        conn.execute(
            "INSERT INTO memory_audit (id, op, target_id, note, at) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![audit_id, "patch", id, note, now],
        )
        .map_err(SqliteMemoryError::Sqlite)?;

        Ok(())
    }

    /// Supersede an old record with a new one (transactional).
    ///
    /// Caller provides the kind explicitly via `SupersedeParams`.
    pub fn supersede_record(
        &self,
        p: &SupersedeParams<'_>,
    ) -> Result<MemoryRecord, SqliteMemoryError> {
        let conn = self.lock()?;
        let now = now_epoch_secs();
        let new_id_val = new_id(display_kind(p.kind));
        let text = truncate_record_text(p.new_text);
        let tags_json = serde_json::to_string(p.tags).unwrap_or_else(|_| "[]".to_owned());
        let kind_str = kind_to_str(p.kind);

        let tx = conn
            .unchecked_transaction()
            .map_err(SqliteMemoryError::Sqlite)?;

        // Mark old record as superseded.
        tx.execute(
            "UPDATE memory_records SET status = 'superseded', updated_at = ?1 WHERE id = ?2",
            params![now, p.old_id],
        )
        .map_err(SqliteMemoryError::Sqlite)?;

        // Insert the new record.
        tx.execute(
            "INSERT INTO memory_records \
             (id, kind, status, text, confidence, source_turn_id, tags, supersedes, \
              created_at, updated_at) \
             VALUES (?1, ?2, 'active', ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                new_id_val,
                kind_str,
                text,
                p.confidence,
                p.source_turn_id,
                tags_json,
                p.old_id,
                now,
                now
            ],
        )
        .map_err(SqliteMemoryError::Sqlite)?;

        // Audit both operations.
        let audit1 = new_id("audit");
        tx.execute(
            "INSERT INTO memory_audit (id, op, target_id, note, at) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![audit1, "supersede", p.old_id, p.note, now],
        )
        .map_err(SqliteMemoryError::Sqlite)?;

        let audit2 = new_id("audit");
        tx.execute(
            "INSERT INTO memory_audit (id, op, target_id, note, at) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![
                audit2,
                "insert",
                new_id_val,
                format!("supersedes {}", p.old_id),
                now
            ],
        )
        .map_err(SqliteMemoryError::Sqlite)?;

        tx.commit().map_err(SqliteMemoryError::Sqlite)?;

        Ok(MemoryRecord {
            id: new_id_val,
            kind: p.kind,
            status: MemoryStatus::Active,
            text,
            confidence: p.confidence.clamp(0.0, 1.0),
            source_turn_id: p.source_turn_id.map(ToOwned::to_owned),
            tags: p.tags.to_vec(),
            supersedes: Some(p.old_id.to_owned()),
            created_at: now,
            updated_at: now,
            importance_score: None,
            stale_after_secs: None,
            metadata: None,
        })
    }

    /// Supersede by looking up the old record's kind automatically.
    ///
    /// Matches the JSONL `MemoryRepository::supersede_record` signature.
    pub fn supersede_record_by_id(
        &self,
        old_id: &str,
        new_text: &str,
        confidence: f32,
        source_turn_id: Option<&str>,
        tags: &[String],
        note: &str,
    ) -> Result<MemoryRecord, SqliteMemoryError> {
        // Look up the old record's kind.
        let conn = self.lock()?;
        let kind_str: String = conn
            .query_row(
                "SELECT kind FROM memory_records WHERE id = ?1",
                params![old_id],
                |row| row.get(0),
            )
            .map_err(|e| match e {
                rusqlite::Error::QueryReturnedNoRows => {
                    SqliteMemoryError::NotFound(old_id.to_owned())
                }
                other => SqliteMemoryError::Sqlite(other),
            })?;
        drop(conn); // Release lock before calling supersede_record

        let kind = str_to_kind(&kind_str);
        self.supersede_record(&SupersedeParams {
            old_id,
            kind,
            new_text,
            confidence,
            source_turn_id,
            tags,
            note,
        })
    }

    /// Invalidate a record (set status to `invalidated`).
    pub fn invalidate_record(&self, id: &str, note: &str) -> Result<(), SqliteMemoryError> {
        self.set_status(
            id,
            MemoryStatus::Invalidated,
            MemoryAuditOp::Invalidate,
            note,
        )
    }

    /// Soft-forget a record (set status to `forgotten`).
    pub fn forget_soft_record(&self, id: &str, note: &str) -> Result<(), SqliteMemoryError> {
        self.set_status(id, MemoryStatus::Forgotten, MemoryAuditOp::ForgetSoft, note)
    }

    /// Hard-forget: DELETE the record from the database.
    pub fn forget_hard_record(&self, id: &str, note: &str) -> Result<(), SqliteMemoryError> {
        let conn = self.lock()?;
        let now = now_epoch_secs();

        let rows = conn
            .execute("DELETE FROM memory_records WHERE id = ?1", params![id])
            .map_err(SqliteMemoryError::Sqlite)?;

        if rows == 0 {
            return Err(SqliteMemoryError::NotFound(id.to_owned()));
        }

        let audit_id = new_id("audit");
        conn.execute(
            "INSERT INTO memory_audit (id, op, target_id, note, at) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![audit_id, "forget_hard", id, note, now],
        )
        .map_err(SqliteMemoryError::Sqlite)?;

        Ok(())
    }

    /// Find all active records that contain the given tag.
    pub fn find_active_by_tag(&self, tag: &str) -> Result<Vec<MemoryRecord>, SqliteMemoryError> {
        let conn = self.lock()?;
        // Tags are stored as a JSON array, so match with LIKE on the serialized form.
        let pattern = format!("%\"{tag}\"%");
        let mut stmt = conn
            .prepare(
                "SELECT id, kind, status, text, confidence, source_turn_id, tags, \
                 supersedes, created_at, updated_at, importance_score, stale_after_secs, \
                 metadata FROM memory_records WHERE status = 'active' AND tags LIKE ?1",
            )
            .map_err(SqliteMemoryError::Sqlite)?;
        let rows = stmt
            .query_map(params![pattern], row_to_record)
            .map_err(SqliteMemoryError::Sqlite)?;

        let mut records = Vec::new();
        for r in rows {
            records.push(r.map_err(SqliteMemoryError::Sqlite)?);
        }
        Ok(records)
    }

    /// Search records by text query with scoring and limit.
    pub fn search(
        &self,
        query: &str,
        limit: usize,
        include_inactive: bool,
    ) -> Result<Vec<MemorySearchHit>, SqliteMemoryError> {
        let records = self.list_records_filtered(include_inactive)?;
        let query_tokens = tokenize(query);

        let mut hits: Vec<MemorySearchHit> = records
            .into_iter()
            .map(|record| {
                let score = score_record(&record, &query_tokens);
                MemorySearchHit { record, score }
            })
            .filter(|h| h.score > 0.0)
            .collect();

        hits.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        hits.truncate(limit);
        Ok(hits)
    }

    /// Retrieve active records by a set of IDs.
    fn get_records_by_ids(&self, ids: &[String]) -> Result<Vec<MemoryRecord>, SqliteMemoryError> {
        if ids.is_empty() {
            return Ok(Vec::new());
        }
        let conn = self.lock()?;
        let placeholders: String = (1..=ids.len())
            .map(|i| format!("?{i}"))
            .collect::<Vec<_>>()
            .join(", ");
        let sql = format!(
            "SELECT id, kind, status, text, confidence, source_turn_id, tags, \
             supersedes, created_at, updated_at, importance_score, stale_after_secs, \
             metadata FROM memory_records \
             WHERE status = 'active' AND id IN ({placeholders})"
        );
        let mut stmt = conn.prepare(&sql).map_err(SqliteMemoryError::Sqlite)?;
        let params: Vec<&dyn rusqlite::types::ToSql> = ids
            .iter()
            .map(|id| id as &dyn rusqlite::types::ToSql)
            .collect();
        let rows = stmt
            .query_map(params.as_slice(), row_to_record)
            .map_err(SqliteMemoryError::Sqlite)?;
        let mut records = Vec::new();
        for r in rows {
            records.push(r.map_err(SqliteMemoryError::Sqlite)?);
        }
        Ok(records)
    }

    /// Hybrid search combining semantic vector similarity with structural scoring.
    ///
    /// Uses sqlite-vec KNN to find semantically similar records, then re-ranks
    /// with confidence, freshness, and kind bonuses.  Falls back to lexical
    /// `search()` if the vector search returns no results (e.g. no embeddings
    /// stored yet).
    pub fn hybrid_search(
        &self,
        query_vec: &[f32],
        query: &str,
        limit: usize,
        semantic_weight: f32,
    ) -> Result<Vec<MemorySearchHit>, SqliteMemoryError> {
        // Fetch an oversized candidate set from vector search.
        let candidates = self.search_by_vector(query_vec, limit.saturating_mul(3).max(20))?;

        if candidates.is_empty() {
            // No embeddings at all — fall back to lexical search.
            return self.search(query, limit, false);
        }

        // Build distance map: record_id → L2 distance.
        let distance_map: HashMap<String, f64> = candidates.into_iter().collect();

        // Load the actual records (active only).
        let ids: Vec<String> = distance_map.keys().cloned().collect();
        let records = self.get_records_by_ids(&ids)?;

        // Score each record with hybrid scoring.
        let mut hits: Vec<MemorySearchHit> = records
            .into_iter()
            .filter_map(|record| {
                let distance = distance_map.get(&record.id).copied()?;
                let score = hybrid_score(&record, distance, semantic_weight);
                Some(MemorySearchHit { record, score })
            })
            .collect();

        // Sort by score descending.
        hits.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        hits.truncate(limit);
        Ok(hits)
    }

    /// Apply retention policy: soft-forget active episodes older than `retention_days`.
    pub fn apply_retention_policy(&self, retention_days: u64) -> Result<usize, SqliteMemoryError> {
        let conn = self.lock()?;
        let now = now_epoch_secs();
        let cutoff = now.saturating_sub(retention_days.saturating_mul(86_400));

        let rows = conn
            .execute(
                "UPDATE memory_records SET status = 'forgotten', updated_at = ?1 \
                 WHERE status = 'active' AND kind = 'episode' AND updated_at < ?2",
                params![now, cutoff],
            )
            .map_err(SqliteMemoryError::Sqlite)?;

        if rows > 0 {
            let audit_id = new_id("audit");
            conn.execute(
                "INSERT INTO memory_audit (id, op, target_id, note, at) \
                 VALUES (?1, ?2, NULL, ?3, ?4)",
                params![
                    audit_id,
                    "forget_soft",
                    format!("retention policy: soft-forgot {rows} episode(s) older than {retention_days}d"),
                    now,
                ],
            )
            .map_err(SqliteMemoryError::Sqlite)?;
        }

        Ok(rows)
    }

    // -----------------------------------------------------------------------
    // Vector embedding operations
    // -----------------------------------------------------------------------

    /// Store a 384-dim embedding for a memory record.
    ///
    /// Replaces any existing embedding for the same record.
    pub fn store_embedding(
        &self,
        record_id: &str,
        embedding: &[f32],
    ) -> Result<(), SqliteMemoryError> {
        if embedding.len() != EMBEDDING_DIM {
            return Err(SqliteMemoryError::Io(format!(
                "embedding dimension mismatch: expected {EMBEDDING_DIM}, got {}",
                embedding.len()
            )));
        }
        let conn = self.lock()?;
        // Convert f32 slice to byte blob (little-endian).
        let blob: Vec<u8> = embedding.iter().flat_map(|f| f.to_le_bytes()).collect();
        // Delete existing embedding first (UPSERT not supported on vec0).
        conn.execute(
            "DELETE FROM vec_embeddings WHERE record_id = ?1",
            params![record_id],
        )
        .map_err(SqliteMemoryError::Sqlite)?;
        conn.execute(
            "INSERT INTO vec_embeddings (record_id, embedding) VALUES (?1, ?2)",
            params![record_id, blob],
        )
        .map_err(SqliteMemoryError::Sqlite)?;
        Ok(())
    }

    /// Retrieve the stored embedding for a record.
    pub fn get_embedding(&self, record_id: &str) -> Result<Option<Vec<f32>>, SqliteMemoryError> {
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare("SELECT embedding FROM vec_embeddings WHERE record_id = ?1")
            .map_err(SqliteMemoryError::Sqlite)?;
        let mut rows = stmt
            .query(params![record_id])
            .map_err(SqliteMemoryError::Sqlite)?;
        match rows.next().map_err(SqliteMemoryError::Sqlite)? {
            Some(row) => {
                let blob: Vec<u8> = row.get(0).map_err(SqliteMemoryError::Sqlite)?;
                if blob.len() != EMBEDDING_DIM * std::mem::size_of::<f32>() {
                    return Err(SqliteMemoryError::Io(format!(
                        "stored embedding size mismatch: expected {} bytes, got {}",
                        EMBEDDING_DIM * std::mem::size_of::<f32>(),
                        blob.len()
                    )));
                }
                // SAFETY: blob is the correct length for EMBEDDING_DIM f32 values.
                let floats: Vec<f32> = blob
                    .chunks_exact(4)
                    .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
                    .collect();
                Ok(Some(floats))
            }
            None => Ok(None),
        }
    }

    /// Find the nearest record embeddings to a query vector.
    ///
    /// Returns `(record_id, distance)` pairs ordered by ascending distance.
    pub fn search_by_vector(
        &self,
        query_vec: &[f32],
        limit: usize,
    ) -> Result<Vec<(String, f64)>, SqliteMemoryError> {
        if query_vec.len() != EMBEDDING_DIM {
            return Err(SqliteMemoryError::Io(format!(
                "query vector dimension mismatch: expected {EMBEDDING_DIM}, got {}",
                query_vec.len()
            )));
        }
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare(
                "SELECT record_id, distance FROM vec_embeddings \
                 WHERE embedding MATCH ?1 \
                 ORDER BY distance \
                 LIMIT ?2",
            )
            .map_err(SqliteMemoryError::Sqlite)?;

        let blob: Vec<u8> = query_vec.iter().flat_map(|f| f.to_le_bytes()).collect();

        let results = stmt
            .query_map(params![blob, limit as i64], |row| {
                let record_id: String = row.get(0)?;
                let distance: f64 = row.get(1)?;
                Ok((record_id, distance))
            })
            .map_err(SqliteMemoryError::Sqlite)?
            .collect::<Result<Vec<_>, _>>()
            .map_err(SqliteMemoryError::Sqlite)?;

        Ok(results)
    }

    /// Check whether an embedding exists for the given record.
    pub fn has_embedding(&self, record_id: &str) -> Result<bool, SqliteMemoryError> {
        let conn = self.lock()?;
        let count: i64 = conn
            .query_row(
                "SELECT count(*) FROM vec_embeddings WHERE record_id = ?1",
                params![record_id],
                |row| row.get(0),
            )
            .map_err(SqliteMemoryError::Sqlite)?;
        Ok(count > 0)
    }

    /// Count total stored embeddings.
    pub fn count_embeddings(&self) -> Result<usize, SqliteMemoryError> {
        let conn = self.lock()?;
        let count: i64 = conn
            .query_row("SELECT count(*) FROM vec_embeddings", [], |row| row.get(0))
            .map_err(SqliteMemoryError::Sqlite)?;
        Ok(count as usize)
    }

    /// Batch embed all active records that don't have embeddings yet.
    ///
    /// Fetches records without embeddings, batches them (~32 per batch),
    /// embeds them using the provided engine, and stores their vectors.
    ///
    /// Returns the count of newly embedded records.
    ///
    /// # Errors
    ///
    /// Returns an error if database queries fail. Embedding failures for
    /// individual records are logged but don't stop the batch process.
    pub fn batch_embed_missing(
        &self,
        engine: &mut super::embedding::EmbeddingEngine,
    ) -> Result<usize, SqliteMemoryError> {
        use tracing::info;

        const BATCH_SIZE: usize = 32;

        // Fetch all active records without embeddings.
        let conn = self.lock()?;
        let mut stmt = conn
            .prepare(
                "SELECT id, text FROM memory_records
                 WHERE status = 'active' AND id NOT IN (SELECT record_id FROM vec_embeddings)
                 ORDER BY created_at DESC LIMIT 1000",
            )
            .map_err(SqliteMemoryError::Sqlite)?;

        let records: Vec<(String, String)> = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))
            .map_err(SqliteMemoryError::Sqlite)?
            .collect::<std::result::Result<Vec<_>, _>>()
            .map_err(SqliteMemoryError::Sqlite)?;
        drop(stmt);
        drop(conn);

        if records.is_empty() {
            info!("batch_embed_missing: no records to embed");
            return Ok(0);
        }

        info!(
            "batch_embed_missing: embedding {} active records",
            records.len()
        );

        let mut embedded_count = 0;

        // Process in batches.
        for chunk in records.chunks(BATCH_SIZE) {
            let ids: Vec<&str> = chunk.iter().map(|(id, _)| id.as_str()).collect();
            let texts: Vec<&str> = chunk.iter().map(|(_, text)| text.as_str()).collect();

            // Embed the batch.
            match engine.embed_batch(&texts) {
                Ok(embeddings) => {
                    // Store each embedding.
                    for (record_id, embedding) in ids.iter().zip(&embeddings) {
                        if let Err(e) = self.store_embedding(record_id, embedding) {
                            tracing::warn!(
                                record_id = %record_id,
                                error = %e,
                                "failed to store embedding for record"
                            );
                        } else {
                            embedded_count += 1;
                        }
                    }
                }
                Err(e) => {
                    tracing::warn!(
                        batch_size = chunk.len(),
                        error = %e,
                        "batch embedding failed, skipping batch"
                    );
                }
            }
        }

        info!("batch_embed_missing: embedded {} records", embedded_count);

        Ok(embedded_count)
    }

    // -----------------------------------------------------------------------
    // Private helpers
    // -----------------------------------------------------------------------

    /// Acquire the connection mutex.
    fn lock(&self) -> Result<std::sync::MutexGuard<'_, Connection>, SqliteMemoryError> {
        self.conn
            .lock()
            .map_err(|e| SqliteMemoryError::Lock(e.to_string()))
    }

    /// Generic status transition with audit.
    fn set_status(
        &self,
        id: &str,
        status: MemoryStatus,
        op: MemoryAuditOp,
        note: &str,
    ) -> Result<(), SqliteMemoryError> {
        let conn = self.lock()?;
        let now = now_epoch_secs();
        let status_str = status_to_str(status);
        let op_str = audit_op_to_str(op);

        let rows = conn
            .execute(
                "UPDATE memory_records SET status = ?1, updated_at = ?2 WHERE id = ?3",
                params![status_str, now, id],
            )
            .map_err(SqliteMemoryError::Sqlite)?;

        if rows == 0 {
            return Err(SqliteMemoryError::NotFound(id.to_owned()));
        }

        let audit_id = new_id("audit");
        conn.execute(
            "INSERT INTO memory_audit (id, op, target_id, note, at) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![audit_id, op_str, id, note, now],
        )
        .map_err(SqliteMemoryError::Sqlite)?;

        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Error type
// ---------------------------------------------------------------------------

/// Errors from the SQLite memory backend.
#[derive(Debug, thiserror::Error)]
pub enum SqliteMemoryError {
    #[error("SQLite error: {0}")]
    Sqlite(#[from] rusqlite::Error),

    #[error("I/O error: {0}")]
    Io(String),

    #[error("record not found: {0}")]
    NotFound(String),

    #[error("lock poisoned: {0}")]
    Lock(String),

    #[error("database corrupt: {0}")]
    Corrupt(String),
}

impl From<SqliteMemoryError> for crate::SpeechError {
    fn from(e: SqliteMemoryError) -> Self {
        crate::SpeechError::Memory(e.to_string())
    }
}

// ---------------------------------------------------------------------------
// Row conversion helpers
// ---------------------------------------------------------------------------

fn row_to_record(row: &rusqlite::Row<'_>) -> rusqlite::Result<MemoryRecord> {
    let kind_str: String = row.get(1)?;
    let status_str: String = row.get(2)?;
    let tags_json: String = row.get(6)?;
    let metadata_str: Option<String> = row.get(12)?;

    Ok(MemoryRecord {
        id: row.get(0)?,
        kind: str_to_kind(&kind_str),
        status: str_to_status(&status_str),
        text: row.get(3)?,
        confidence: row.get(4)?,
        source_turn_id: row.get(5)?,
        tags: serde_json::from_str(&tags_json).unwrap_or_default(),
        supersedes: row.get(7)?,
        created_at: row.get(8)?,
        updated_at: row.get(9)?,
        importance_score: row.get(10)?,
        stale_after_secs: row.get(11)?,
        metadata: metadata_str.and_then(|s| serde_json::from_str(&s).ok()),
    })
}

fn row_to_audit(row: &rusqlite::Row<'_>) -> rusqlite::Result<MemoryAuditEntry> {
    let op_str: String = row.get(1)?;
    Ok(MemoryAuditEntry {
        id: row.get(0)?,
        op: str_to_audit_op(&op_str),
        target_id: row.get(2)?,
        note: row.get(3)?,
        at: row.get(4)?,
    })
}

// ---------------------------------------------------------------------------
// Enum ↔ string conversions
// ---------------------------------------------------------------------------

fn kind_to_str(kind: MemoryKind) -> &'static str {
    match kind {
        MemoryKind::Profile => "profile",
        MemoryKind::Episode => "episode",
        MemoryKind::Fact => "fact",
        MemoryKind::Event => "event",
        MemoryKind::Person => "person",
        MemoryKind::Interest => "interest",
        MemoryKind::Commitment => "commitment",
    }
}

fn str_to_kind(s: &str) -> MemoryKind {
    match s {
        "profile" => MemoryKind::Profile,
        "episode" => MemoryKind::Episode,
        "fact" => MemoryKind::Fact,
        "event" => MemoryKind::Event,
        "person" => MemoryKind::Person,
        "interest" => MemoryKind::Interest,
        "commitment" => MemoryKind::Commitment,
        _ => MemoryKind::Episode, // safe fallback
    }
}

fn status_to_str(status: MemoryStatus) -> &'static str {
    match status {
        MemoryStatus::Active => "active",
        MemoryStatus::Superseded => "superseded",
        MemoryStatus::Invalidated => "invalidated",
        MemoryStatus::Forgotten => "forgotten",
    }
}

fn str_to_status(s: &str) -> MemoryStatus {
    match s {
        "active" => MemoryStatus::Active,
        "superseded" => MemoryStatus::Superseded,
        "invalidated" => MemoryStatus::Invalidated,
        "forgotten" => MemoryStatus::Forgotten,
        _ => MemoryStatus::Active, // safe fallback
    }
}

fn audit_op_to_str(op: MemoryAuditOp) -> &'static str {
    match op {
        MemoryAuditOp::Insert => "insert",
        MemoryAuditOp::Patch => "patch",
        MemoryAuditOp::Supersede => "supersede",
        MemoryAuditOp::Invalidate => "invalidate",
        MemoryAuditOp::ForgetSoft => "forget_soft",
        MemoryAuditOp::ForgetHard => "forget_hard",
        MemoryAuditOp::Migrate => "migrate",
    }
}

fn str_to_audit_op(s: &str) -> MemoryAuditOp {
    match s {
        "insert" => MemoryAuditOp::Insert,
        "patch" => MemoryAuditOp::Patch,
        "supersede" => MemoryAuditOp::Supersede,
        "invalidate" => MemoryAuditOp::Invalidate,
        "forget_soft" => MemoryAuditOp::ForgetSoft,
        "forget_hard" => MemoryAuditOp::ForgetHard,
        "migrate" => MemoryAuditOp::Migrate,
        _ => MemoryAuditOp::Insert, // safe fallback
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::super::types::{CURRENT_SCHEMA_VERSION, HYBRID_SEMANTIC_WEIGHT};
    use super::*;

    fn test_repo() -> (tempfile::TempDir, SqliteMemoryRepository) {
        let dir = tempfile::TempDir::new().expect("create temp dir");
        let repo = SqliteMemoryRepository::new(dir.path()).expect("create SqliteMemoryRepository");
        (dir, repo)
    }

    #[test]
    fn sqlite_creates_schema_and_layout() {
        let (_dir, repo) = test_repo();
        repo.ensure_layout().expect("ensure_layout");
        let version = repo.schema_version().expect("schema_version");
        assert_eq!(version, CURRENT_SCHEMA_VERSION);
    }

    #[test]
    fn sqlite_insert_returns_full_record() {
        let (_dir, repo) = test_repo();

        let record = repo
            .insert_record(
                MemoryKind::Fact,
                "The sky is blue",
                0.9,
                Some("turn-1"),
                &["color".to_owned()],
            )
            .expect("insert");

        assert_eq!(record.kind, MemoryKind::Fact);
        assert_eq!(record.text, "The sky is blue");
        assert_eq!(record.status, MemoryStatus::Active);
        assert!(!record.id.is_empty());
        assert_eq!(record.tags, vec!["color".to_owned()]);
    }

    #[test]
    fn sqlite_insert_search_and_soft_forget() {
        let (_dir, repo) = test_repo();

        let record = repo
            .insert_record(
                MemoryKind::Fact,
                "The sky is blue",
                0.9,
                Some("turn-1"),
                &["color".to_owned()],
            )
            .expect("insert");

        // Search should find it.
        let hits = repo.search("sky blue", 10, false).expect("search");
        assert!(!hits.is_empty());
        assert_eq!(hits[0].record.id, record.id);

        // Soft forget.
        repo.forget_soft_record(&record.id, "test forget")
            .expect("forget_soft");

        // Active search should NOT find it.
        let hits = repo.search("sky blue", 10, false).expect("search");
        assert!(hits.is_empty());

        // Inactive search SHOULD find it.
        let hits = repo.search("sky blue", 10, true).expect("search");
        assert!(!hits.is_empty());
        assert_eq!(hits[0].record.status, MemoryStatus::Forgotten);
    }

    #[test]
    fn sqlite_supersede_marks_old_record() {
        let (_dir, repo) = test_repo();

        let old = repo
            .insert_record(MemoryKind::Profile, "Name: Dave", 0.95, None, &[])
            .expect("insert old");

        let new_rec = repo
            .supersede_record(&SupersedeParams {
                old_id: &old.id,
                kind: MemoryKind::Profile,
                new_text: "Name: David",
                confidence: 0.98,
                source_turn_id: None,
                tags: &[],
                note: "name correction",
            })
            .expect("supersede");

        let records = repo.list_records_filtered(true).expect("list");
        let old_rec = records.iter().find(|r| r.id == old.id).expect("old record");

        assert_eq!(old_rec.status, MemoryStatus::Superseded);
        assert_eq!(new_rec.status, MemoryStatus::Active);
        assert_eq!(new_rec.supersedes.as_deref(), Some(old.id.as_str()));
    }

    #[test]
    fn sqlite_patch_updates_text() {
        let (_dir, repo) = test_repo();

        let record = repo
            .insert_record(MemoryKind::Fact, "original text", 0.8, None, &[])
            .expect("insert");

        repo.patch_record(&record.id, "updated text", "correction")
            .expect("patch");

        let records = repo.list_records().expect("list");
        let found = records.iter().find(|r| r.id == record.id).expect("record");
        assert_eq!(found.text, "updated text");
    }

    #[test]
    fn sqlite_invalidate_record() {
        let (_dir, repo) = test_repo();

        let record = repo
            .insert_record(MemoryKind::Fact, "wrong fact", 0.7, None, &[])
            .expect("insert");

        repo.invalidate_record(&record.id, "was incorrect")
            .expect("invalidate");

        let records = repo.list_records_filtered(true).expect("list");
        let found = records.iter().find(|r| r.id == record.id).expect("record");
        assert_eq!(found.status, MemoryStatus::Invalidated);
    }

    #[test]
    fn sqlite_forget_hard_removes_row() {
        let (_dir, repo) = test_repo();

        let record = repo
            .insert_record(MemoryKind::Episode, "ephemeral", 0.5, None, &[])
            .expect("insert");

        repo.forget_hard_record(&record.id, "hard forget")
            .expect("forget_hard");

        // Should not appear even in inactive listing.
        let records = repo.list_records_filtered(true).expect("list");
        assert!(records.iter().all(|r| r.id != record.id));

        // Audit trail should record the operation.
        let audit = repo.audit_entries().expect("audit");
        assert!(
            audit
                .iter()
                .any(|a| a.target_id.as_deref() == Some(&*record.id)
                    && matches!(a.op, MemoryAuditOp::ForgetHard))
        );
    }

    #[test]
    fn sqlite_find_active_by_tag() {
        let (_dir, repo) = test_repo();

        repo.insert_record(
            MemoryKind::Fact,
            "tagged fact",
            0.8,
            None,
            &["onboarding:name".to_owned()],
        )
        .expect("insert tagged");

        repo.insert_record(MemoryKind::Fact, "untagged", 0.8, None, &[])
            .expect("insert untagged");

        let tagged = repo.find_active_by_tag("onboarding:name").expect("find");
        assert_eq!(tagged.len(), 1);
        assert_eq!(tagged[0].text, "tagged fact");
    }

    #[test]
    fn sqlite_retention_policy_soft_forgets_old() {
        let (_dir, repo) = test_repo();

        let record = repo
            .insert_record(MemoryKind::Episode, "old episode", 0.5, None, &[])
            .expect("insert");

        // Backdate the record to 100 days ago.
        {
            let conn = repo.lock().expect("lock");
            let old_ts = now_epoch_secs().saturating_sub(100 * 86_400);
            conn.execute(
                "UPDATE memory_records SET updated_at = ?1 WHERE id = ?2",
                params![old_ts, record.id],
            )
            .expect("backdate");
        }

        let forgotten = repo.apply_retention_policy(30).expect("retention");
        assert_eq!(forgotten, 1);

        let records = repo.list_records_filtered(true).expect("list");
        let found = records.iter().find(|r| r.id == record.id).expect("record");
        assert_eq!(found.status, MemoryStatus::Forgotten);
    }

    #[test]
    fn sqlite_schema_version_starts_at_current() {
        let (_dir, repo) = test_repo();
        let version = repo.schema_version().expect("version");
        assert_eq!(version, CURRENT_SCHEMA_VERSION);
    }

    #[test]
    fn sqlite_migrate_if_needed_noop_when_current() {
        let (_dir, repo) = test_repo();
        repo.migrate_if_needed(CURRENT_SCHEMA_VERSION)
            .expect("migrate noop");
        let version = repo.schema_version().expect("version");
        assert_eq!(version, CURRENT_SCHEMA_VERSION);
    }

    #[test]
    fn sqlite_concurrent_insert_preserves_records() {
        let dir = tempfile::TempDir::new().expect("temp dir");
        let repo =
            std::sync::Arc::new(SqliteMemoryRepository::new(dir.path()).expect("create repo"));

        let mut handles = Vec::new();
        for i in 0..10 {
            let r = std::sync::Arc::clone(&repo);
            handles.push(std::thread::spawn(move || {
                r.insert_record(
                    MemoryKind::Episode,
                    &format!("concurrent episode {i}"),
                    0.5,
                    None,
                    &[],
                )
                .expect("concurrent insert");
            }));
        }

        for h in handles {
            h.join().expect("thread join");
        }

        let records = repo.list_records().expect("list");
        assert_eq!(records.len(), 10);
    }

    #[test]
    fn sqlite_list_records_returns_active_only() {
        let (_dir, repo) = test_repo();

        let active = repo
            .insert_record(MemoryKind::Fact, "active fact", 0.9, None, &[])
            .expect("insert");

        let forgotten = repo
            .insert_record(MemoryKind::Fact, "to forget", 0.5, None, &[])
            .expect("insert");

        repo.forget_soft_record(&forgotten.id, "test")
            .expect("forget");

        // list_records() (no args) returns only active.
        let active_list = repo.list_records().expect("list");
        assert_eq!(active_list.len(), 1);
        assert_eq!(active_list[0].id, active.id);

        // list_records_filtered(true) returns both.
        let all_list = repo.list_records_filtered(true).expect("list all");
        assert_eq!(all_list.len(), 2);
    }

    #[test]
    fn sqlite_insert_record_raw_preserves_fields() {
        let (_dir, repo) = test_repo();

        let record = MemoryRecord {
            id: "custom-id-123".to_owned(),
            kind: MemoryKind::Profile,
            status: MemoryStatus::Superseded,
            text: "migrated profile".to_owned(),
            confidence: 0.85,
            source_turn_id: Some("turn-99".to_owned()),
            tags: vec!["onboarding:name".to_owned()],
            supersedes: Some("old-id-000".to_owned()),
            created_at: 1000,
            updated_at: 2000,
            importance_score: Some(0.7),
            stale_after_secs: Some(86400),
            metadata: None,
        };

        repo.insert_record_raw(&record).expect("insert_record_raw");

        let records = repo.list_records_filtered(true).expect("list");
        let found = records
            .iter()
            .find(|r| r.id == "custom-id-123")
            .expect("find migrated");

        assert_eq!(found.kind, MemoryKind::Profile);
        assert_eq!(found.status, MemoryStatus::Superseded);
        assert_eq!(found.text, "migrated profile");
        assert_eq!(found.confidence, 0.85);
        assert_eq!(found.source_turn_id.as_deref(), Some("turn-99"));
        assert_eq!(found.tags, vec!["onboarding:name".to_owned()]);
        assert_eq!(found.supersedes.as_deref(), Some("old-id-000"));
        assert_eq!(found.created_at, 1000);
        assert_eq!(found.updated_at, 2000);
        assert_eq!(found.importance_score, Some(0.7));
        assert_eq!(found.stale_after_secs, Some(86400));

        // Audit trail should have a migrate entry.
        let audit = repo.audit_entries().expect("audit");
        assert!(
            audit
                .iter()
                .any(|a| a.target_id.as_deref() == Some("custom-id-123")
                    && matches!(a.op, MemoryAuditOp::Migrate))
        );
    }

    #[test]
    fn sqlite_insert_record_raw_is_idempotent() {
        let (_dir, repo) = test_repo();

        let record = MemoryRecord {
            id: "dup-id".to_owned(),
            kind: MemoryKind::Fact,
            status: MemoryStatus::Active,
            text: "duplicate test".to_owned(),
            confidence: 0.5,
            source_turn_id: None,
            tags: vec![],
            supersedes: None,
            created_at: 100,
            updated_at: 200,
            importance_score: None,
            stale_after_secs: None,
            metadata: None,
        };

        repo.insert_record_raw(&record).expect("first insert");
        repo.insert_record_raw(&record)
            .expect("second insert (idempotent)");

        let records = repo.list_records().expect("list");
        let matches: Vec<_> = records.iter().filter(|r| r.id == "dup-id").collect();
        assert_eq!(matches.len(), 1);
    }

    #[test]
    fn sqlite_insert_audit_raw_preserves_fields() {
        let (_dir, repo) = test_repo();

        let entry = MemoryAuditEntry {
            id: "audit-raw-1".to_owned(),
            op: MemoryAuditOp::Patch,
            target_id: Some("some-record".to_owned()),
            note: "migrated audit entry".to_owned(),
            at: 5000,
        };

        repo.insert_audit_raw(&entry).expect("insert_audit_raw");

        let audit = repo.audit_entries().expect("audit");
        let found = audit
            .iter()
            .find(|a| a.id == "audit-raw-1")
            .expect("find migrated audit");

        assert!(matches!(found.op, MemoryAuditOp::Patch));
        assert_eq!(found.target_id.as_deref(), Some("some-record"));
        assert_eq!(found.note, "migrated audit entry");
        assert_eq!(found.at, 5000);
    }

    #[test]
    fn sqlite_error_converts_to_speech_error() {
        let err = SqliteMemoryError::NotFound("test-id".to_owned());
        let speech_err: crate::SpeechError = err.into();
        let msg = speech_err.to_string();
        assert!(msg.contains("test-id"));
    }

    #[test]
    fn integrity_check_passes_on_fresh_db() {
        let (_dir, repo) = test_repo();
        repo.integrity_check().expect("integrity check should pass");
    }

    #[test]
    fn corrupt_error_variant_displays_message() {
        let err = SqliteMemoryError::Corrupt("page 42: btree cell count mismatch".to_owned());
        let msg = err.to_string();
        assert!(msg.contains("corrupt"));
        assert!(msg.contains("page 42"));
    }

    // -------------------------------------------------------------------
    // Vector embedding tests
    // -------------------------------------------------------------------

    #[test]
    fn vec_extension_loads() {
        let (_dir, repo) = test_repo();
        let conn = repo.lock().expect("lock");
        let version: String = conn
            .query_row("SELECT vec_version()", [], |r| r.get(0))
            .expect("vec_version");
        assert!(version.starts_with('v'));
    }

    #[test]
    fn store_and_retrieve_embedding() {
        let (_dir, repo) = test_repo();
        let record = repo
            .insert_record(MemoryKind::Fact, "test fact", 0.9, None, &[])
            .expect("insert");

        let mut embedding = vec![0.0_f32; super::EMBEDDING_DIM];
        embedding[0] = 1.0;
        embedding[1] = 0.5;

        repo.store_embedding(&record.id, &embedding)
            .expect("store embedding");

        let retrieved = repo
            .get_embedding(&record.id)
            .expect("get embedding")
            .expect("embedding should exist");

        assert_eq!(retrieved.len(), super::EMBEDDING_DIM);
        assert!((retrieved[0] - 1.0).abs() < 1e-6);
        assert!((retrieved[1] - 0.5).abs() < 1e-6);
        assert!((retrieved[2] - 0.0).abs() < 1e-6);
    }

    #[test]
    fn search_by_vector_returns_nearest() {
        let (_dir, repo) = test_repo();

        // Insert 3 records with known embeddings.
        let r1 = repo
            .insert_record(MemoryKind::Fact, "apples", 0.9, None, &[])
            .expect("insert");
        let r2 = repo
            .insert_record(MemoryKind::Fact, "oranges", 0.9, None, &[])
            .expect("insert");
        let r3 = repo
            .insert_record(MemoryKind::Fact, "bananas", 0.9, None, &[])
            .expect("insert");

        // e1 = [1, 0, 0, ...], e2 = [0, 1, 0, ...], e3 = [0.9, 0.1, 0, ...]
        let mut e1 = vec![0.0_f32; super::EMBEDDING_DIM];
        e1[0] = 1.0;
        let mut e2 = vec![0.0_f32; super::EMBEDDING_DIM];
        e2[1] = 1.0;
        let mut e3 = vec![0.0_f32; super::EMBEDDING_DIM];
        e3[0] = 0.9;
        e3[1] = 0.1;

        repo.store_embedding(&r1.id, &e1).expect("store e1");
        repo.store_embedding(&r2.id, &e2).expect("store e2");
        repo.store_embedding(&r3.id, &e3).expect("store e3");

        // Query close to e1 — should find r1 first, then r3 (similar), then r2.
        let mut query = vec![0.0_f32; super::EMBEDDING_DIM];
        query[0] = 1.0;
        let results = repo.search_by_vector(&query, 3).expect("search");
        assert_eq!(results.len(), 3);
        assert_eq!(results[0].0, r1.id); // Exact match
        assert_eq!(results[1].0, r3.id); // Close
        assert_eq!(results[2].0, r2.id); // Furthest
    }

    #[test]
    fn has_embedding_true_false() {
        let (_dir, repo) = test_repo();
        let record = repo
            .insert_record(MemoryKind::Fact, "test", 0.5, None, &[])
            .expect("insert");

        assert!(!repo.has_embedding(&record.id).expect("has before"));

        let embedding = vec![0.1_f32; super::EMBEDDING_DIM];
        repo.store_embedding(&record.id, &embedding).expect("store");

        assert!(repo.has_embedding(&record.id).expect("has after"));
        assert!(!repo.has_embedding("nonexistent").expect("has nonexistent"));
    }

    #[test]
    fn count_embeddings_matches() {
        let (_dir, repo) = test_repo();

        assert_eq!(repo.count_embeddings().expect("count"), 0);

        let r1 = repo
            .insert_record(MemoryKind::Fact, "a", 0.5, None, &[])
            .expect("insert");
        let r2 = repo
            .insert_record(MemoryKind::Fact, "b", 0.5, None, &[])
            .expect("insert");

        let emb = vec![0.0_f32; super::EMBEDDING_DIM];
        repo.store_embedding(&r1.id, &emb).expect("store 1");
        repo.store_embedding(&r2.id, &emb).expect("store 2");

        assert_eq!(repo.count_embeddings().expect("count"), 2);
    }

    #[test]
    fn store_embedding_replaces_existing() {
        let (_dir, repo) = test_repo();
        let record = repo
            .insert_record(MemoryKind::Fact, "test", 0.5, None, &[])
            .expect("insert");

        let mut e1 = vec![0.0_f32; super::EMBEDDING_DIM];
        e1[0] = 1.0;
        repo.store_embedding(&record.id, &e1).expect("store first");

        let mut e2 = vec![0.0_f32; super::EMBEDDING_DIM];
        e2[0] = 0.5;
        repo.store_embedding(&record.id, &e2)
            .expect("store replacement");

        // Should have only 1 embedding, and it should be the replacement.
        assert_eq!(repo.count_embeddings().expect("count"), 1);
        let retrieved = repo
            .get_embedding(&record.id)
            .expect("get")
            .expect("exists");
        assert!((retrieved[0] - 0.5).abs() < 1e-6);
    }

    #[test]
    fn store_embedding_rejects_wrong_dimension() {
        let (_dir, repo) = test_repo();
        let record = repo
            .insert_record(MemoryKind::Fact, "test", 0.5, None, &[])
            .expect("insert");

        let wrong_dim = vec![0.0_f32; 128]; // Not 384
        let result = repo.store_embedding(&record.id, &wrong_dim);
        assert!(result.is_err());
    }

    #[test]
    fn schema_version_is_3_with_vec() {
        let (_dir, repo) = test_repo();
        assert_eq!(repo.schema_version().expect("version"), 3);
    }

    #[test]
    fn hybrid_search_returns_scored_results() {
        let (_dir, repo) = test_repo();

        let r1 = repo
            .insert_record(MemoryKind::Profile, "user likes dark mode", 0.9, None, &[])
            .expect("r1");
        let r2 = repo
            .insert_record(MemoryKind::Fact, "sky is blue", 0.8, None, &[])
            .expect("r2");
        let r3 = repo
            .insert_record(
                MemoryKind::Episode,
                "had coffee this morning",
                0.5,
                None,
                &[],
            )
            .expect("r3");

        // Store mock embeddings (384-dim, L2-normalized).
        let dim = super::EMBEDDING_DIM;
        let mut e1 = vec![0.0f32; dim];
        e1[0] = 1.0; // direction: [1,0,0,...]
        let mut e2 = vec![0.0f32; dim];
        e2[1] = 1.0; // direction: [0,1,0,...]
        let mut e3 = vec![0.0f32; dim];
        e3[0] = 0.7;
        e3[1] = 0.714;
        let norm3: f32 = e3.iter().map(|x| x * x).sum::<f32>().sqrt();
        for v in &mut e3 {
            *v /= norm3;
        }

        repo.store_embedding(&r1.id, &e1).expect("store e1");
        repo.store_embedding(&r2.id, &e2).expect("store e2");
        repo.store_embedding(&r3.id, &e3).expect("store e3");

        // Query vector close to e1 → r1 should rank highest.
        let mut query = vec![0.0f32; dim];
        query[0] = 1.0;
        let results = repo
            .hybrid_search(&query, "dark mode", 10, HYBRID_SEMANTIC_WEIGHT)
            .expect("hybrid search");

        assert!(!results.is_empty(), "should return results");
        assert_eq!(
            results[0].record.id, r1.id,
            "closest vector should be first"
        );
        for hit in &results {
            assert!(hit.score > 0.0, "all scores should be positive");
        }
    }

    #[test]
    fn hybrid_search_excludes_inactive_records() {
        let (_dir, repo) = test_repo();

        let r1 = repo
            .insert_record(MemoryKind::Fact, "active record", 0.9, None, &[])
            .expect("r1");
        let r2 = repo
            .insert_record(MemoryKind::Fact, "will be forgotten", 0.9, None, &[])
            .expect("r2");

        let mut e1 = vec![0.0f32; super::EMBEDDING_DIM];
        e1[0] = 1.0;
        let mut e2 = vec![0.0f32; super::EMBEDDING_DIM];
        e2[0] = 0.99;
        e2[1] = 0.14;
        let norm2: f32 = e2.iter().map(|x| x * x).sum::<f32>().sqrt();
        for v in &mut e2 {
            *v /= norm2;
        }

        repo.store_embedding(&r1.id, &e1).expect("store e1");
        repo.store_embedding(&r2.id, &e2).expect("store e2");

        // Soft-forget r2.
        repo.forget_soft_record(&r2.id, "test").expect("forget");

        let mut query = vec![0.0f32; super::EMBEDDING_DIM];
        query[0] = 1.0;
        let results = repo
            .hybrid_search(&query, "record", 10, HYBRID_SEMANTIC_WEIGHT)
            .expect("hybrid search");

        // Only r1 should appear (r2 is inactive).
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].record.id, r1.id);
    }

    #[test]
    fn hybrid_search_falls_back_to_lexical_when_no_embeddings() {
        let (_dir, repo) = test_repo();

        repo.insert_record(MemoryKind::Fact, "cats are cool", 0.8, None, &[])
            .expect("r1");
        repo.insert_record(MemoryKind::Fact, "dogs are nice", 0.8, None, &[])
            .expect("r2");
        // No embeddings stored.

        let query_vec = vec![0.0f32; super::EMBEDDING_DIM];
        let results = repo
            .hybrid_search(&query_vec, "cats", 10, HYBRID_SEMANTIC_WEIGHT)
            .expect("hybrid search");

        // Should fall back to lexical and find "cats are cool".
        assert!(!results.is_empty(), "lexical fallback should find results");
        assert!(
            results[0].record.text.contains("cats"),
            "lexical fallback should match 'cats'"
        );
    }

    #[test]
    #[ignore] // Requires network + model download (~23 MB)
    fn batch_embed_missing_embeds_all() {
        use crate::memory::embedding::EmbeddingEngine;

        let (_dir, repo) = test_repo();

        // Insert 5 records without embeddings.
        let r1 = repo
            .insert_record(MemoryKind::Fact, "hello world", 0.8, None, &[])
            .expect("insert r1");
        let r2 = repo
            .insert_record(MemoryKind::Fact, "goodbye world", 0.8, None, &[])
            .expect("insert r2");
        let r3 = repo
            .insert_record(MemoryKind::Fact, "hello again", 0.8, None, &[])
            .expect("insert r3");
        let r4 = repo
            .insert_record(MemoryKind::Profile, "user lives in Berlin", 0.9, None, &[])
            .expect("insert r4");
        let r5 = repo
            .insert_record(MemoryKind::Profile, "user likes coding", 0.9, None, &[])
            .expect("insert r5");

        assert_eq!(repo.count_embeddings().expect("count"), 0);

        let mut engine = EmbeddingEngine::download_and_load().expect("engine");
        let embedded_count = repo.batch_embed_missing(&mut engine).expect("batch embed");

        assert_eq!(embedded_count, 5);
        assert_eq!(repo.count_embeddings().expect("count"), 5);
        assert!(repo.has_embedding(&r1.id).expect("has r1"));
        assert!(repo.has_embedding(&r2.id).expect("has r2"));
        assert!(repo.has_embedding(&r3.id).expect("has r3"));
        assert!(repo.has_embedding(&r4.id).expect("has r4"));
        assert!(repo.has_embedding(&r5.id).expect("has r5"));
    }

    #[test]
    #[ignore] // Requires network + model download (~23 MB)
    fn batch_embed_skips_already_embedded() {
        use crate::memory::embedding::EmbeddingEngine;

        let (_dir, repo) = test_repo();

        let r1 = repo
            .insert_record(MemoryKind::Fact, "hello world", 0.8, None, &[])
            .expect("insert r1");
        let r2 = repo
            .insert_record(MemoryKind::Fact, "goodbye world", 0.8, None, &[])
            .expect("insert r2");
        let r3 = repo
            .insert_record(MemoryKind::Fact, "hello again", 0.8, None, &[])
            .expect("insert r3");

        // Manually embed r1.
        let mut e1 = vec![0.0_f32; super::EMBEDDING_DIM];
        e1[0] = 1.0;
        repo.store_embedding(&r1.id, &e1).expect("store e1");
        assert_eq!(repo.count_embeddings().expect("count"), 1);

        let mut engine = EmbeddingEngine::download_and_load().expect("engine");
        let embedded_count = repo.batch_embed_missing(&mut engine).expect("batch embed");

        assert_eq!(embedded_count, 2);
        assert_eq!(repo.count_embeddings().expect("count"), 3);
        assert!(repo.has_embedding(&r1.id).expect("has r1"));
        assert!(repo.has_embedding(&r2.id).expect("has r2"));
        assert!(repo.has_embedding(&r3.id).expect("has r3"));
    }
}
