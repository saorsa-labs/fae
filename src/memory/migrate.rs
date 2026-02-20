//! One-time JSONL → SQLite data migration.
//!
//! Called on startup when JSONL data files exist but no SQLite database.
//! Creates backup copies of JSONL files before migrating, verifies counts
//! after import, and is idempotent (safe to run multiple times).

use std::path::Path;

use super::jsonl::MemoryRepository;
use super::sqlite::SqliteMemoryRepository;
use crate::SpeechError;

/// Subdirectory where JSONL files live (must match `jsonl.rs` MemoryRepository).
const MEMORY_SUBDIR: &str = "memory";

/// JSONL filenames (must match `jsonl.rs` constants).
const RECORDS_FILE: &str = "records.jsonl";
const AUDIT_FILE: &str = "audit.jsonl";

/// SQLite database filename (must match `sqlite.rs` constant).
const DB_FILENAME: &str = "fae.db";

/// Backup suffix appended to JSONL files before migration.
const BACKUP_SUFFIX: &str = ".pre-sqlite-backup";

/// Summary of a completed migration.
#[derive(Debug)]
pub(crate) struct MigrationReport {
    pub records_migrated: usize,
    pub audit_entries_migrated: usize,
    pub records_backup: Option<std::path::PathBuf>,
    pub audit_backup: Option<std::path::PathBuf>,
}

/// Returns `true` if JSONL data files exist and the SQLite database either
/// does not exist or contains no records.
pub(crate) fn needs_migration(root_dir: &Path) -> bool {
    let memory_dir = root_dir.join(MEMORY_SUBDIR);
    let records_path = memory_dir.join(RECORDS_FILE);
    if !records_path.exists() {
        return false;
    }

    let db_path = root_dir.join(DB_FILENAME);
    if !db_path.exists() {
        return true;
    }

    // Database file exists — check if it has records.
    let Ok(repo) = SqliteMemoryRepository::new(root_dir) else {
        return true; // Can't open → treat as needing migration
    };
    let Ok(records) = repo.list_records_filtered(true) else {
        return true;
    };
    records.is_empty()
}

/// Migrate all JSONL data into SQLite.
///
/// 1. Backs up JSONL files (`.pre-sqlite-backup` suffix).
/// 2. Reads all records and audit entries from the JSONL store.
/// 3. Inserts them into a new (or existing) SQLite database.
/// 4. Verifies that record counts match.
///
/// Idempotent: `insert_record_raw` / `insert_audit_raw` use `INSERT OR IGNORE`,
/// so running this twice will not create duplicates.
pub(crate) fn run_jsonl_to_sqlite(root_dir: &Path) -> Result<MigrationReport, SpeechError> {
    // --- Step 1: backup ---
    let memory_dir = root_dir.join(MEMORY_SUBDIR);
    let records_backup = backup_file(&memory_dir, RECORDS_FILE);
    let audit_backup = backup_file(&memory_dir, AUDIT_FILE);

    // --- Step 2: read JSONL data ---
    let jsonl_repo = MemoryRepository::new(root_dir);
    let records = jsonl_repo.list_records()?;
    let audit_entries = jsonl_repo.audit_entries()?;

    // --- Step 3: write to SQLite ---
    let sqlite_repo = SqliteMemoryRepository::new(root_dir)?;

    for record in &records {
        sqlite_repo.insert_record_raw(record)?;
    }

    for entry in &audit_entries {
        sqlite_repo.insert_audit_raw(entry)?;
    }

    // --- Step 4: verify ---
    let sqlite_records = sqlite_repo.list_records_filtered(true)?;
    if sqlite_records.len() < records.len() {
        return Err(SpeechError::Memory(format!(
            "migration verification failed: expected {} records, SQLite has {}",
            records.len(),
            sqlite_records.len()
        )));
    }

    Ok(MigrationReport {
        records_migrated: records.len(),
        audit_entries_migrated: audit_entries.len(),
        records_backup,
        audit_backup,
    })
}

/// Copy `{root_dir}/{filename}` to `{root_dir}/{filename}.pre-sqlite-backup`.
///
/// Returns the backup path if the source file existed and was copied.
fn backup_file(root_dir: &Path, filename: &str) -> Option<std::path::PathBuf> {
    let src = root_dir.join(filename);
    if !src.exists() {
        return None;
    }
    let dst = root_dir.join(format!("{filename}{BACKUP_SUFFIX}"));
    // Don't overwrite an existing backup (from a previous migration attempt).
    if dst.exists() {
        return Some(dst);
    }
    std::fs::copy(&src, &dst).ok()?;
    Some(dst)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;
    use crate::memory::types::{MemoryAuditEntry, MemoryKind, MemoryRecord};

    /// Helper: seed a JSONL repo with test records.
    fn seed_jsonl(root: &Path) -> (Vec<MemoryRecord>, Vec<MemoryAuditEntry>) {
        let repo = MemoryRepository::new(root);
        let r1 = repo
            .insert_record(
                MemoryKind::Profile,
                "Name: Alice",
                0.95,
                Some("turn-1"),
                vec!["onboarding:name".to_owned()],
            )
            .expect("insert r1");
        let r2 = repo
            .insert_record(
                MemoryKind::Fact,
                "Likes hiking",
                0.8,
                Some("turn-2"),
                vec![],
            )
            .expect("insert r2");
        let r3 = repo
            .insert_record(
                MemoryKind::Episode,
                "Talked about weather",
                0.5,
                None,
                vec![],
            )
            .expect("insert r3");

        let records = repo.list_records().expect("list");
        let audit = repo.audit_entries().expect("audit");
        assert_eq!(records.len(), 3);
        drop((r1, r2, r3));
        (records, audit)
    }

    #[test]
    fn migration_imports_all_records() {
        let dir = tempfile::TempDir::new().expect("temp dir");
        let (jsonl_records, _) = seed_jsonl(dir.path());

        let report = run_jsonl_to_sqlite(dir.path()).expect("migration");
        assert_eq!(report.records_migrated, 3);
        assert!(report.audit_entries_migrated >= 3); // At least one audit per insert

        let sqlite_repo = SqliteMemoryRepository::new(dir.path()).expect("open sqlite");
        let sqlite_records = sqlite_repo.list_records_filtered(true).expect("list");
        assert_eq!(sqlite_records.len(), jsonl_records.len());
    }

    #[test]
    fn migration_preserves_record_fields() {
        let dir = tempfile::TempDir::new().expect("temp dir");
        let (jsonl_records, _) = seed_jsonl(dir.path());

        run_jsonl_to_sqlite(dir.path()).expect("migration");

        let sqlite_repo = SqliteMemoryRepository::new(dir.path()).expect("open sqlite");
        let sqlite_records = sqlite_repo.list_records_filtered(true).expect("list");

        for jsonl_rec in &jsonl_records {
            let sqlite_rec = sqlite_records
                .iter()
                .find(|r| r.id == jsonl_rec.id)
                .unwrap_or_else(|| panic!("missing record {}", jsonl_rec.id));

            assert_eq!(sqlite_rec.kind, jsonl_rec.kind);
            assert_eq!(sqlite_rec.status, jsonl_rec.status);
            assert_eq!(sqlite_rec.text, jsonl_rec.text);
            assert_eq!(sqlite_rec.confidence, jsonl_rec.confidence);
            assert_eq!(sqlite_rec.source_turn_id, jsonl_rec.source_turn_id);
            assert_eq!(sqlite_rec.tags, jsonl_rec.tags);
            assert_eq!(sqlite_rec.supersedes, jsonl_rec.supersedes);
            assert_eq!(sqlite_rec.created_at, jsonl_rec.created_at);
            assert_eq!(sqlite_rec.updated_at, jsonl_rec.updated_at);
        }
    }

    #[test]
    fn migration_creates_backups() {
        let dir = tempfile::TempDir::new().expect("temp dir");
        seed_jsonl(dir.path());

        let report = run_jsonl_to_sqlite(dir.path()).expect("migration");

        assert!(report.records_backup.is_some());
        let backup_path = report.records_backup.as_ref().expect("records backup");
        assert!(backup_path.exists());
        assert!(
            backup_path
                .file_name()
                .expect("name")
                .to_string_lossy()
                .ends_with(".pre-sqlite-backup")
        );

        // audit backup too
        assert!(report.audit_backup.is_some());
        let audit_backup = report.audit_backup.as_ref().expect("audit backup");
        assert!(audit_backup.exists());
    }

    #[test]
    fn migration_is_idempotent() {
        let dir = tempfile::TempDir::new().expect("temp dir");
        seed_jsonl(dir.path());

        let report1 = run_jsonl_to_sqlite(dir.path()).expect("first migration");
        let report2 = run_jsonl_to_sqlite(dir.path()).expect("second migration");

        // Both should report same count (INSERT OR IGNORE prevents dups).
        assert_eq!(report1.records_migrated, report2.records_migrated);

        let sqlite_repo = SqliteMemoryRepository::new(dir.path()).expect("open sqlite");
        let records = sqlite_repo.list_records_filtered(true).expect("list");
        // Should not have duplicates.
        assert_eq!(records.len(), 3);
    }

    #[test]
    fn needs_migration_false_when_no_jsonl() {
        let dir = tempfile::TempDir::new().expect("temp dir");
        // Fresh directory with no JSONL files.
        assert!(!needs_migration(dir.path()));
    }

    #[test]
    fn needs_migration_true_when_jsonl_exists_no_db() {
        let dir = tempfile::TempDir::new().expect("temp dir");
        seed_jsonl(dir.path());
        // JSONL exists, no fae.db yet.
        assert!(needs_migration(dir.path()));
    }

    #[test]
    fn needs_migration_false_after_migration() {
        let dir = tempfile::TempDir::new().expect("temp dir");
        seed_jsonl(dir.path());
        assert!(needs_migration(dir.path()));

        run_jsonl_to_sqlite(dir.path()).expect("migration");

        // After migration, DB has records → no longer needs migration.
        assert!(!needs_migration(dir.path()));
    }
}
