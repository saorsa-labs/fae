//! SQLite-backed memory repository.
//!
//! Implements the same public API as `MemoryRepository` (JSONL backend),
//! backed by a single SQLite database file at `{root_dir}/fae.db`.

use std::path::{Path, PathBuf};
use std::sync::Mutex;

use rusqlite::{Connection, params};

use super::schema::{apply_schema, read_schema_version};
use super::types::{
    MemoryAuditEntry, MemoryAuditOp, MemoryKind, MemoryRecord, MemorySearchHit, MemoryStatus,
    display_kind, new_id, now_epoch_secs, score_record, tokenize, truncate_record_text,
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

impl SqliteMemoryRepository {
    /// Open (or create) the SQLite database at `{root_dir}/fae.db`.
    ///
    /// Applies the schema if the database is new.
    pub fn new(root_dir: &Path) -> Result<Self, SqliteMemoryError> {
        std::fs::create_dir_all(root_dir).map_err(|e| SqliteMemoryError::Io(e.to_string()))?;
        let db_path = root_dir.join(DB_FILENAME);
        let conn = Connection::open(&db_path).map_err(SqliteMemoryError::Sqlite)?;
        apply_schema(&conn).map_err(SqliteMemoryError::Sqlite)?;
        Ok(Self {
            root: root_dir.to_path_buf(),
            conn: Mutex::new(conn),
        })
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

    /// Read the current schema version from the database.
    pub fn schema_version(&self) -> Result<Option<u32>, SqliteMemoryError> {
        let conn = self.lock()?;
        read_schema_version(&conn).map_err(SqliteMemoryError::Sqlite)
    }

    /// No-op if already at `target` version. Future migrations go here.
    pub fn migrate_if_needed(&self, target: u32) -> Result<(), SqliteMemoryError> {
        let current = self.schema_version()?.unwrap_or(0);
        if current >= target {
            return Ok(());
        }
        // Future: apply incremental migrations here.
        // For now, just update the version stamp.
        let conn = self.lock()?;
        conn.execute(
            "UPDATE schema_meta SET value = ?1 WHERE key = 'schema_version'",
            params![target.to_string()],
        )
        .map_err(SqliteMemoryError::Sqlite)?;
        Ok(())
    }

    /// List all records, optionally filtering by status.
    pub fn list_records(
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

    /// Insert a new memory record.
    pub fn insert_record(
        &self,
        kind: MemoryKind,
        text: &str,
        confidence: f32,
        source_turn_id: Option<&str>,
        tags: &[String],
    ) -> Result<String, SqliteMemoryError> {
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

        Ok(id)
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
    pub fn supersede_record(&self, p: &SupersedeParams<'_>) -> Result<String, SqliteMemoryError> {
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
        Ok(new_id_val)
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
        let records = self.list_records(include_inactive)?;
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
    use super::super::types::CURRENT_SCHEMA_VERSION;
    use super::*;

    fn test_repo() -> (tempfile::TempDir, SqliteMemoryRepository) {
        let dir = tempfile::TempDir::new().expect("create temp dir");
        let repo = SqliteMemoryRepository::new(dir.path()).expect("create SqliteMemoryRepository");
        (dir, repo)
    }

    #[test]
    fn sqlite_creates_schema_and_layout() {
        let (_dir, repo) = test_repo();
        // ensure_layout is idempotent
        repo.ensure_layout().expect("ensure_layout");
        let version = repo.schema_version().expect("schema_version");
        assert_eq!(version, Some(CURRENT_SCHEMA_VERSION));
    }

    #[test]
    fn sqlite_insert_search_and_soft_forget() {
        let (_dir, repo) = test_repo();

        let id = repo
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
        assert_eq!(hits[0].record.id, id);

        // Soft forget.
        repo.forget_soft_record(&id, "test forget")
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

        let old_id = repo
            .insert_record(MemoryKind::Profile, "Name: Dave", 0.95, None, &[])
            .expect("insert old");

        let new_id = repo
            .supersede_record(&SupersedeParams {
                old_id: &old_id,
                kind: MemoryKind::Profile,
                new_text: "Name: David",
                confidence: 0.98,
                source_turn_id: None,
                tags: &[],
                note: "name correction",
            })
            .expect("supersede");

        let records = repo.list_records(true).expect("list");
        let old = records.iter().find(|r| r.id == old_id).expect("old record");
        let new = records.iter().find(|r| r.id == new_id).expect("new record");

        assert_eq!(old.status, MemoryStatus::Superseded);
        assert_eq!(new.status, MemoryStatus::Active);
        assert_eq!(new.supersedes.as_deref(), Some(old_id.as_str()));
    }

    #[test]
    fn sqlite_patch_updates_text() {
        let (_dir, repo) = test_repo();

        let id = repo
            .insert_record(MemoryKind::Fact, "original text", 0.8, None, &[])
            .expect("insert");

        repo.patch_record(&id, "updated text", "correction")
            .expect("patch");

        let records = repo.list_records(false).expect("list");
        let record = records.iter().find(|r| r.id == id).expect("record");
        assert_eq!(record.text, "updated text");
    }

    #[test]
    fn sqlite_invalidate_record() {
        let (_dir, repo) = test_repo();

        let id = repo
            .insert_record(MemoryKind::Fact, "wrong fact", 0.7, None, &[])
            .expect("insert");

        repo.invalidate_record(&id, "was incorrect")
            .expect("invalidate");

        let records = repo.list_records(true).expect("list");
        let record = records.iter().find(|r| r.id == id).expect("record");
        assert_eq!(record.status, MemoryStatus::Invalidated);
    }

    #[test]
    fn sqlite_forget_hard_removes_row() {
        let (_dir, repo) = test_repo();

        let id = repo
            .insert_record(MemoryKind::Episode, "ephemeral", 0.5, None, &[])
            .expect("insert");

        repo.forget_hard_record(&id, "hard forget")
            .expect("forget_hard");

        // Should not appear even in inactive listing.
        let records = repo.list_records(true).expect("list");
        assert!(records.iter().all(|r| r.id != id));

        // Audit trail should record the operation.
        let audit = repo.audit_entries().expect("audit");
        assert!(
            audit.iter().any(|a| a.target_id.as_deref() == Some(&*id)
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

        // Insert an episode with artificially old timestamp.
        let id = repo
            .insert_record(MemoryKind::Episode, "old episode", 0.5, None, &[])
            .expect("insert");

        // Backdate the record to 100 days ago.
        {
            let conn = repo.lock().expect("lock");
            let old_ts = now_epoch_secs().saturating_sub(100 * 86_400);
            conn.execute(
                "UPDATE memory_records SET updated_at = ?1 WHERE id = ?2",
                params![old_ts, id],
            )
            .expect("backdate");
        }

        let forgotten = repo.apply_retention_policy(30).expect("retention");
        assert_eq!(forgotten, 1);

        let records = repo.list_records(true).expect("list");
        let record = records.iter().find(|r| r.id == id).expect("record");
        assert_eq!(record.status, MemoryStatus::Forgotten);
    }

    #[test]
    fn sqlite_schema_version_starts_at_current() {
        let (_dir, repo) = test_repo();
        let version = repo.schema_version().expect("version");
        assert_eq!(version, Some(CURRENT_SCHEMA_VERSION));
    }

    #[test]
    fn sqlite_migrate_if_needed_noop_when_current() {
        let (_dir, repo) = test_repo();
        // Should be a no-op since we're already at CURRENT_SCHEMA_VERSION.
        repo.migrate_if_needed(CURRENT_SCHEMA_VERSION)
            .expect("migrate noop");
        let version = repo.schema_version().expect("version");
        assert_eq!(version, Some(CURRENT_SCHEMA_VERSION));
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

        let records = repo.list_records(false).expect("list");
        assert_eq!(records.len(), 10);
    }
}
