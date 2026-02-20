//! SQLite DDL definitions for the Fae memory store.
//!
//! All `CREATE TABLE` / `CREATE INDEX` statements live here so they are
//! reviewable and testable in isolation.

use rusqlite::Connection;

/// Complete DDL for the Fae memory database.
///
/// Uses `IF NOT EXISTS` throughout so `apply_schema` is idempotent.
pub(crate) const SCHEMA_SQL: &str = r#"
-- Enable WAL mode for concurrent reads during writes.
PRAGMA journal_mode = WAL;

-- Enforce foreign key constraints.
PRAGMA foreign_keys = ON;

-- Schema version tracking.
CREATE TABLE IF NOT EXISTS schema_meta (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);

-- Core memory records table — mirrors MemoryRecord fields.
CREATE TABLE IF NOT EXISTS memory_records (
    id               TEXT PRIMARY KEY,
    kind             TEXT NOT NULL,      -- snake_case MemoryKind variant
    status           TEXT NOT NULL DEFAULT 'active',
    text             TEXT NOT NULL,
    confidence       REAL NOT NULL DEFAULT 0.5,
    source_turn_id   TEXT,
    tags             TEXT NOT NULL DEFAULT '[]',  -- JSON array of strings
    supersedes       TEXT,               -- id of the record this supersedes
    created_at       INTEGER NOT NULL DEFAULT 0,
    updated_at       INTEGER NOT NULL DEFAULT 0,
    importance_score REAL,
    stale_after_secs INTEGER,
    metadata         TEXT                -- JSON blob
);

-- Indexes for common query patterns.
CREATE INDEX IF NOT EXISTS idx_records_status     ON memory_records(status);
CREATE INDEX IF NOT EXISTS idx_records_kind       ON memory_records(kind);
CREATE INDEX IF NOT EXISTS idx_records_updated_at ON memory_records(updated_at);

-- Audit trail — mirrors MemoryAuditEntry fields.
CREATE TABLE IF NOT EXISTS memory_audit (
    id        TEXT PRIMARY KEY,
    op        TEXT NOT NULL,      -- snake_case MemoryAuditOp variant
    target_id TEXT,               -- record id this audit entry refers to
    note      TEXT NOT NULL,
    at        INTEGER NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_audit_at ON memory_audit(at);

"#;

/// Apply the full schema to an open connection.
///
/// Safe to call multiple times — all statements use `IF NOT EXISTS`.
/// Inserts the current schema version into `schema_meta` if not already
/// present.
pub(crate) fn apply_schema(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(SCHEMA_SQL)?;

    // Seed schema version if this is a fresh database.
    let version_str = super::types::CURRENT_SCHEMA_VERSION.to_string();
    conn.execute(
        "INSERT OR IGNORE INTO schema_meta (key, value) VALUES ('schema_version', ?1)",
        rusqlite::params![version_str],
    )?;

    Ok(())
}

/// Embedding vector dimensions (all-MiniLM-L6-v2).
pub(crate) const EMBEDDING_DIM: usize = 384;

/// DDL for the `vec_embeddings` virtual table (requires sqlite-vec loaded).
const VEC_EMBEDDINGS_SQL: &str = r#"
CREATE VIRTUAL TABLE IF NOT EXISTS vec_embeddings USING vec0(
    record_id TEXT PRIMARY KEY,
    embedding FLOAT[384]
);
"#;

/// Create the `vec_embeddings` virtual table.
///
/// Must be called **after** `sqlite_vec::load()` has been called on the
/// connection.  Safe to call multiple times (`IF NOT EXISTS`).
pub(crate) fn apply_vec_schema(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(VEC_EMBEDDINGS_SQL)
}

/// Read the current schema version from the database.
///
/// Returns `None` if the `schema_meta` table is empty or the key is missing.
pub(crate) fn read_schema_version(conn: &Connection) -> rusqlite::Result<Option<u32>> {
    let mut stmt = conn.prepare("SELECT value FROM schema_meta WHERE key = 'schema_version'")?;
    let mut rows = stmt.query([])?;
    match rows.next()? {
        Some(row) => {
            let val: String = row.get(0)?;
            Ok(val.parse::<u32>().ok())
        }
        None => Ok(None),
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apply_schema_creates_tables() {
        let conn = Connection::open_in_memory().expect("open in-memory db");
        apply_schema(&conn).expect("first apply_schema");

        // Verify tables exist by querying sqlite_master.
        let tables: Vec<String> = conn
            .prepare("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
            .expect("prepare")
            .query_map([], |row| row.get(0))
            .expect("query")
            .filter_map(|r| r.ok())
            .collect();

        assert!(tables.contains(&"memory_records".to_owned()));
        assert!(tables.contains(&"memory_audit".to_owned()));
        assert!(tables.contains(&"schema_meta".to_owned()));
    }

    #[test]
    fn apply_schema_is_idempotent() {
        let conn = Connection::open_in_memory().expect("open in-memory db");
        apply_schema(&conn).expect("first apply_schema");
        apply_schema(&conn).expect("second apply_schema (idempotent)");
    }

    #[test]
    fn schema_version_is_seeded() {
        let conn = Connection::open_in_memory().expect("open in-memory db");
        apply_schema(&conn).expect("apply_schema");

        let version = read_schema_version(&conn)
            .expect("read_schema_version")
            .expect("version should exist");

        assert_eq!(version, super::super::types::CURRENT_SCHEMA_VERSION);
    }

    #[test]
    fn schema_version_not_overwritten_on_reapply() {
        let conn = Connection::open_in_memory().expect("open in-memory db");
        apply_schema(&conn).expect("first apply");

        // Manually bump the version to simulate a future migration.
        conn.execute(
            "UPDATE schema_meta SET value = '999' WHERE key = 'schema_version'",
            [],
        )
        .expect("bump version");

        // Re-apply schema — INSERT OR IGNORE should not overwrite.
        apply_schema(&conn).expect("second apply");

        let version = read_schema_version(&conn)
            .expect("read")
            .expect("version exists");
        assert_eq!(version, 999);
    }
}
