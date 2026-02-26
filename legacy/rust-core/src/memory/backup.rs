//! SQLite database backup and rotation utilities.
//!
//! Uses `VACUUM INTO` for atomic, consistent backups and provides a simple
//! rotation strategy that keeps the N most recent backup files.

use std::path::{Path, PathBuf};

use super::sqlite::SqliteMemoryError;

/// Database filename within the memory root directory (must match `sqlite.rs`).
const DB_FILENAME: &str = "fae.db";

/// Prefix for backup filenames used by `backup_database` and `rotate_backups`.
const BACKUP_PREFIX: &str = "fae-backup-";

/// Extension for backup files.
const BACKUP_EXT: &str = ".db";

/// Create an atomic backup of the SQLite database using `VACUUM INTO`.
///
/// The backup file is named `fae-backup-{YYYYMMDD-HHMMSS}.db` inside
/// `backup_dir`. The directory is created if it does not exist.
///
/// # Errors
///
/// Returns an error if the database cannot be opened, `VACUUM INTO` fails, or
/// the backup directory cannot be created.
pub fn backup_database(db_path: &Path, backup_dir: &Path) -> Result<PathBuf, SqliteMemoryError> {
    // Ensure the backup directory exists.
    std::fs::create_dir_all(backup_dir).map_err(|e| SqliteMemoryError::Io(e.to_string()))?;

    // Generate timestamped filename using UTC to avoid DST ambiguity.
    let now = chrono::Utc::now();
    let filename = format!("{BACKUP_PREFIX}{}{BACKUP_EXT}", now.format("%Y%m%d-%H%M%S"));
    let backup_path = backup_dir.join(&filename);

    // Open source database and run VACUUM INTO.
    // VACUUM INTO does not support parameter binding, so we escape single
    // quotes in the path to prevent syntax errors (the path is generated
    // internally, not from user input).
    super::sqlite::ensure_sqlite_vec_loaded();
    let conn = rusqlite::Connection::open(db_path).map_err(SqliteMemoryError::Sqlite)?;
    let escaped = backup_path.display().to_string().replace('\'', "''");
    conn.execute_batch(&format!("VACUUM INTO '{escaped}'"))
        .map_err(SqliteMemoryError::Sqlite)?;

    Ok(backup_path)
}

/// Rotate backup files, keeping at most `keep_count` recent backups.
///
/// Lists all files matching `fae-backup-*.db` in `backup_dir`, sorts them by
/// name descending (newest first since names are timestamped), and deletes any
/// beyond `keep_count`.
///
/// Returns the number of deleted files.
///
/// # Errors
///
/// Returns an error if the directory cannot be read. Individual file deletion
/// failures are logged but do not stop the rotation.
pub fn rotate_backups(backup_dir: &Path, keep_count: usize) -> Result<usize, SqliteMemoryError> {
    if !backup_dir.exists() {
        return Ok(0);
    }

    let entries =
        std::fs::read_dir(backup_dir).map_err(|e| SqliteMemoryError::Io(e.to_string()))?;

    // Collect matching backup files.
    let mut backups: Vec<PathBuf> = entries
        .filter_map(|entry| {
            let entry = entry.ok()?;
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with(BACKUP_PREFIX) && name.ends_with(BACKUP_EXT) {
                Some(entry.path())
            } else {
                None
            }
        })
        .collect();

    // Sort by filename descending (newest first due to timestamp format).
    backups.sort_by(|a, b| b.cmp(a));

    let mut deleted = 0;
    for old in backups.iter().skip(keep_count) {
        match std::fs::remove_file(old) {
            Ok(()) => deleted += 1,
            Err(e) => {
                tracing::warn!(path = %old.display(), error = %e, "failed to delete old backup");
            }
        }
    }

    Ok(deleted)
}

/// Convenience: path to the main database file given the memory root.
pub fn db_path(root_dir: &Path) -> PathBuf {
    root_dir.join(DB_FILENAME)
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backup_creates_valid_sqlite_file() {
        let dir = tempfile::TempDir::new().expect("tempdir");
        let root = dir.path();
        let backup_dir = root.join("backups");

        // Create a database with some data.
        let repo = super::super::sqlite::SqliteMemoryRepository::new(root).expect("repo");
        repo.insert_record(
            super::super::types::MemoryKind::Fact,
            "test backup data",
            0.9,
            None,
            &[],
        )
        .expect("insert");

        let db = db_path(root);
        let backup = backup_database(&db, &backup_dir).expect("backup");

        // Backup file should exist and be a valid SQLite database.
        assert!(backup.exists(), "backup file should exist");
        assert!(
            backup.metadata().expect("metadata").len() > 0,
            "backup should be non-empty"
        );

        // Open the backup and verify the data is there.
        super::super::sqlite::ensure_sqlite_vec_loaded();
        let conn = rusqlite::Connection::open(&backup).expect("open backup");
        let count: i64 = conn
            .query_row(
                "SELECT count(*) FROM memory_records WHERE text = 'test backup data'",
                [],
                |row| row.get(0),
            )
            .expect("query");
        assert_eq!(count, 1, "backup should contain the inserted record");
    }

    #[test]
    fn rotate_keeps_correct_count() {
        let dir = tempfile::TempDir::new().expect("tempdir");
        let backup_dir = dir.path().join("backups");
        std::fs::create_dir_all(&backup_dir).expect("mkdir");

        // Create 5 fake backup files with sequential timestamps.
        for i in 1..=5 {
            let name = format!("{BACKUP_PREFIX}2026010{i}-120000{BACKUP_EXT}");
            std::fs::write(backup_dir.join(&name), format!("backup {i}")).expect("write");
        }

        // Keep only 3.
        let deleted = rotate_backups(&backup_dir, 3).expect("rotate");
        assert_eq!(deleted, 2, "should delete 2 oldest");

        // Verify remaining files.
        let remaining: Vec<String> = std::fs::read_dir(&backup_dir)
            .expect("readdir")
            .filter_map(|e| Some(e.ok()?.file_name().to_string_lossy().to_string()))
            .collect();
        assert_eq!(remaining.len(), 3);
        // Newest 3 should survive.
        assert!(remaining.iter().any(|f| f.contains("20260105")));
        assert!(remaining.iter().any(|f| f.contains("20260104")));
        assert!(remaining.iter().any(|f| f.contains("20260103")));
    }

    #[test]
    fn rotate_on_nonexistent_dir_returns_zero() {
        let dir = tempfile::TempDir::new().expect("tempdir");
        let result = rotate_backups(&dir.path().join("does-not-exist"), 7);
        assert_eq!(result.expect("rotate"), 0);
    }

    #[test]
    fn rotate_ignores_non_backup_files() {
        let dir = tempfile::TempDir::new().expect("tempdir");
        let backup_dir = dir.path().join("backups");
        std::fs::create_dir_all(&backup_dir).expect("mkdir");

        // Create 2 backup files and 1 non-backup file.
        std::fs::write(
            backup_dir.join(format!("{BACKUP_PREFIX}20260101-120000{BACKUP_EXT}")),
            "b1",
        )
        .expect("write");
        std::fs::write(
            backup_dir.join(format!("{BACKUP_PREFIX}20260102-120000{BACKUP_EXT}")),
            "b2",
        )
        .expect("write");
        std::fs::write(backup_dir.join("other-file.txt"), "not a backup").expect("write");

        // Keep 1 → should delete 1 backup, leave the non-backup alone.
        let deleted = rotate_backups(&backup_dir, 1).expect("rotate");
        assert_eq!(deleted, 1);

        let remaining: Vec<String> = std::fs::read_dir(&backup_dir)
            .expect("readdir")
            .filter_map(|e| Some(e.ok()?.file_name().to_string_lossy().to_string()))
            .collect();
        assert_eq!(remaining.len(), 2); // 1 backup + 1 other file
        assert!(remaining.iter().any(|f| f == "other-file.txt"));
    }
}
