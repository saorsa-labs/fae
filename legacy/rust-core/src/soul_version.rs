//! SOUL.md version control and backup system.
//!
//! Provides automatic backups before each SOUL.md save, with version history,
//! diff viewing, and rollback capability.

use crate::error::Result;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// Metadata for a single SOUL.md version backup.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SoulVersion {
    /// Unique version identifier (timestamp-based).
    pub id: String,
    /// When this version was created.
    pub timestamp: chrono::DateTime<chrono::Utc>,
    /// BLAKE3 hash of the content.
    pub content_hash: String,
    /// Path to the backup file.
    pub path: PathBuf,
}

/// Returns the default directory where SOUL.md version backups are stored.
fn default_versions_dir() -> PathBuf {
    crate::fae_dirs::data_dir().join("soul_versions")
}

/// Ensures the given directory exists, creating it if needed.
fn ensure_dir(dir: &Path) -> Result<PathBuf> {
    if !dir.exists() {
        std::fs::create_dir_all(dir)?;
    }
    Ok(dir.to_path_buf())
}

/// Generate a version ID from current timestamp.
fn generate_version_id() -> String {
    chrono::Utc::now().format("%Y%m%d_%H%M%S_%3f").to_string()
}

/// Get the file path for a specific version ID within a directory.
fn version_path_in(version_id: &str, dir: &Path) -> PathBuf {
    dir.join(format!("{version_id}.md"))
}

/// Get the metadata file path for a specific version ID within a directory.
fn version_metadata_path_in(version_id: &str, dir: &Path) -> PathBuf {
    dir.join(format!("{version_id}.json"))
}

/// Calculate BLAKE3 hash of content.
fn calculate_hash(content: &str) -> String {
    blake3::hash(content.as_bytes()).to_hex().to_string()
}

/// Lists all SOUL.md versions in the given directory (newest first).
fn list_versions_in(dir: &Path) -> Result<Vec<SoulVersion>> {
    let dir = ensure_dir(dir)?;

    let mut versions = Vec::new();

    for entry in std::fs::read_dir(&dir)? {
        let entry = entry?;
        let path = entry.path();

        // Only process .json metadata files
        if path.extension().and_then(|s| s.to_str()) != Some("json") {
            continue;
        }

        // Read and parse metadata
        let metadata_content = std::fs::read_to_string(&path)?;
        match serde_json::from_str::<SoulVersion>(&metadata_content) {
            Ok(version) => versions.push(version),
            Err(e) => {
                eprintln!(
                    "Warning: failed to parse version metadata {:?}: {}",
                    path, e
                );
                continue;
            }
        }
    }

    // Sort by timestamp, newest first
    versions.sort_by(|a, b| b.timestamp.cmp(&a.timestamp));

    Ok(versions)
}

/// Create a backup of SOUL.md content in the given directory.
///
/// Returns None if the content is identical to any existing backup (by hash).
fn create_backup_in(soul_content: &str, dir: &Path) -> Result<Option<SoulVersion>> {
    let content_hash = calculate_hash(soul_content);

    // Check if any existing version already has this content hash
    let existing_versions = list_versions_in(dir)?;
    if existing_versions
        .iter()
        .any(|v| v.content_hash == content_hash)
    {
        // Content already backed up, skip duplicate
        return Ok(None);
    }

    // Create new backup
    let version_id = generate_version_id();
    let timestamp = chrono::Utc::now();

    let dir = ensure_dir(dir)?;
    let backup_path = dir.join(format!("{}.md", version_id));
    let metadata_path = dir.join(format!("{}.json", version_id));

    // Write content
    std::fs::write(&backup_path, soul_content)?;

    // Write metadata
    let version = SoulVersion {
        id: version_id,
        timestamp,
        content_hash,
        path: backup_path,
    };

    let metadata_json = serde_json::to_string_pretty(&version)
        .map_err(|e| crate::error::SpeechError::Config(format!("JSON serialization: {}", e)))?;
    std::fs::write(metadata_path, metadata_json)?;

    Ok(Some(version))
}

/// Load content from a specific version by ID in the given directory.
fn load_version_in(version_id: &str, dir: &Path) -> Result<String> {
    let path = version_path_in(version_id, dir);

    if !path.exists() {
        return Err(crate::error::SpeechError::Config(format!(
            "Version {} not found",
            version_id
        )));
    }

    let content = std::fs::read_to_string(&path)?;
    Ok(content)
}

/// Cleanup old versions beyond retention limit in the given directory.
///
/// Keeps the most recent `keep_count` versions and deletes the rest.
fn cleanup_old_versions_in(keep_count: usize, dir: &Path) -> Result<usize> {
    let versions = list_versions_in(dir)?;

    if versions.len() <= keep_count {
        return Ok(0);
    }

    let to_delete = &versions[keep_count..];
    let mut deleted = 0;

    for version in to_delete {
        // Delete content file
        if version.path.exists() {
            std::fs::remove_file(&version.path)?;
        }

        // Delete metadata file
        let metadata_path = version_metadata_path_in(&version.id, dir);
        if metadata_path.exists() {
            std::fs::remove_file(&metadata_path)?;
        }

        deleted += 1;
    }

    Ok(deleted)
}

// ── Public API (delegates to `_in` variants with default directory) ──

/// Convenience wrapper for backup-before-save flow.
///
/// Creates a backup, then returns appropriate status message.
/// Returns an error only if backup fails critically.
pub fn backup_before_save(soul_content: &str) -> Result<String> {
    match create_backup(soul_content) {
        Ok(Some(version)) => Ok(format!("Backed up previous version ({})", version.id)),
        Ok(None) => Ok("No changes since last backup".to_string()),
        Err(e) => {
            // Log the error but don't block save
            eprintln!("Warning: backup failed: {}", e);
            Ok("Backup failed (save will proceed)".to_string())
        }
    }
}

/// Create a backup of SOUL.md content.
///
/// Returns None if the content is identical to any existing backup (by hash).
/// Otherwise creates a new timestamped backup and returns the version info.
pub fn create_backup(soul_content: &str) -> Result<Option<SoulVersion>> {
    create_backup_in(soul_content, &default_versions_dir())
}

/// A single line in a diff output.
#[derive(Debug, Clone, PartialEq)]
pub struct DiffLine {
    /// Line number (in old or new depending on operation).
    pub line_num: usize,
    /// Operation: '+' for add, '-' for remove, ' ' for context.
    pub operation: char,
    /// The actual line content.
    pub content: String,
}

/// Calculate diff between current SOUL.md and a specific version.
///
/// Convenience wrapper for GUI use.
pub fn diff_with_current(version_id: &str) -> Result<Vec<DiffLine>> {
    let current_content = crate::personality::load_soul();
    let old_content = load_version(version_id)?;
    Ok(calculate_diff(&old_content, &current_content))
}

/// Calculate unified diff between two versions.
///
/// Returns a vector of DiffLine structs representing the changes.
pub fn calculate_diff(old: &str, new: &str) -> Vec<DiffLine> {
    use similar::{ChangeTag, TextDiff};

    let diff = TextDiff::from_lines(old, new);
    let mut result = Vec::new();

    for (idx, change) in diff.iter_all_changes().enumerate() {
        let operation = match change.tag() {
            ChangeTag::Delete => '-',
            ChangeTag::Insert => '+',
            ChangeTag::Equal => ' ',
        };

        result.push(DiffLine {
            line_num: idx + 1,
            operation,
            content: change.to_string(),
        });
    }

    result
}

/// Cleanup old versions beyond retention limit.
///
/// Keeps the most recent `keep_count` versions and deletes the rest.
/// Returns the number of versions deleted.
pub fn cleanup_old_versions(keep_count: usize) -> Result<usize> {
    cleanup_old_versions_in(keep_count, &default_versions_dir())
}

/// Format version metadata for display in audit trail.
pub fn format_version_info(version: &SoulVersion) -> String {
    format!(
        "{} | {} | hash:{}...",
        version.id,
        version.timestamp.format("%Y-%m-%d %H:%M:%S UTC"),
        &version.content_hash[..8]
    )
}

/// Restore a previous version as the current SOUL.md.
///
/// Creates a backup of the current state before restoring.
fn restore_version_in(
    version_id: &str,
    versions_dir: &Path,
    current_content: &str,
    soul_path: &Path,
) -> Result<()> {
    // Load the target version content first so a bad version ID fails without
    // mutating backups or the active SOUL file.
    let restored_content = load_version_in(version_id, versions_dir)?;

    // Backup current state before restoring (no-op if duplicate).
    let _ = create_backup_in(current_content, versions_dir)?;

    if let Some(parent) = soul_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(soul_path, restored_content)?;
    Ok(())
}

/// Restore a previous version as the current SOUL.md.
///
/// Creates a backup of the current state before restoring.
pub fn restore_version(version_id: &str) -> Result<()> {
    let current_content = crate::personality::load_soul();
    let soul_path = crate::personality::soul_path();
    restore_version_in(
        version_id,
        &default_versions_dir(),
        &current_content,
        &soul_path,
    )
}

/// Load content from a specific version by ID.
pub fn load_version(version_id: &str) -> Result<String> {
    load_version_in(version_id, &default_versions_dir())
}

/// Lists all SOUL.md versions in chronological order (newest first).
pub fn list_versions() -> Result<Vec<SoulVersion>> {
    list_versions_in(&default_versions_dir())
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;
    use std::path::Path;
    use tempfile::TempDir;

    /// Helper to create an isolated test versions directory.
    /// Returns the TempDir (must be held alive) and the versions path.
    fn make_test_dir() -> (TempDir, PathBuf) {
        let temp = TempDir::new().expect("create tempdir");
        let versions_dir = temp.path().join("soul_versions");
        std::fs::create_dir_all(&versions_dir).expect("create versions dir");
        (temp, versions_dir)
    }

    #[test]
    fn test_version_path_format() {
        let dir = Path::new("/tmp/test_versions");
        let id = "20260215_221500_123";
        let path = version_path_in(id, dir);
        assert_eq!(
            path,
            PathBuf::from("/tmp/test_versions/20260215_221500_123.md")
        );
    }

    #[test]
    fn test_version_metadata_path_format() {
        let dir = Path::new("/tmp/test_versions");
        let id = "20260215_221500_123";
        let path = version_metadata_path_in(id, dir);
        assert_eq!(
            path,
            PathBuf::from("/tmp/test_versions/20260215_221500_123.json")
        );
    }

    #[test]
    fn test_version_metadata_roundtrip() {
        let version = SoulVersion {
            id: "20260215_221500_123".to_string(),
            timestamp: chrono::Utc::now(),
            content_hash: "abc123".to_string(),
            path: PathBuf::from("/tmp/test.md"),
        };

        let json = serde_json::to_string(&version).expect("serialize");
        let parsed: SoulVersion = serde_json::from_str(&json).expect("deserialize");

        assert_eq!(version.id, parsed.id);
        assert_eq!(version.content_hash, parsed.content_hash);
        assert_eq!(version.path, parsed.path);
    }

    #[test]
    fn test_list_versions_empty() {
        let (_temp, dir) = make_test_dir();

        let result = list_versions_in(&dir);
        assert!(result.is_ok());

        let versions = result.expect("versions");
        assert!(
            versions.is_empty(),
            "Fresh directory should have no versions"
        );
    }

    #[test]
    fn test_generate_version_id_format() {
        let id = generate_version_id();

        // Should be in format: YYYYMMDD_HHMMSS_mmm
        assert!(id.len() >= 19); // minimum length
        assert!(id.contains('_'));

        // Should be parseable as parts
        let parts: Vec<&str> = id.split('_').collect();
        assert!(parts.len() >= 3);
    }

    #[test]
    fn test_ensure_dir_creates() {
        let temp = TempDir::new().expect("create tempdir");
        let dir = temp.path().join("new_subdir");
        assert!(!dir.exists());

        let result = ensure_dir(&dir);
        assert!(result.is_ok());
        assert!(dir.exists());
    }

    #[test]
    fn test_calculate_hash() {
        let content1 = "Hello world";
        let content2 = "Hello world";
        let content3 = "Hello world!";

        let hash1 = calculate_hash(content1);
        let hash2 = calculate_hash(content2);
        let hash3 = calculate_hash(content3);

        // Same content = same hash
        assert_eq!(hash1, hash2);

        // Different content = different hash
        assert_ne!(hash1, hash3);

        // Hash should be hex string
        assert!(hash1.chars().all(|c| c.is_ascii_hexdigit()));
    }

    #[test]
    fn test_create_backup_success() {
        let (_temp, dir) = make_test_dir();
        let content = format!("# Test SOUL.md\nTest backup at {}", chrono::Utc::now());

        let result = create_backup_in(&content, &dir);
        assert!(result.is_ok());

        let version_opt = result.expect("create backup");
        assert!(version_opt.is_some());

        let version = version_opt.expect("get version");
        assert!(version.path.exists());
        assert_eq!(version.content_hash, calculate_hash(&content));

        // Verify content was written correctly
        let written_content = std::fs::read_to_string(&version.path).expect("read backup");
        assert_eq!(written_content, content);
    }

    #[test]
    fn test_create_backup_duplicate_content() {
        let (_temp, dir) = make_test_dir();
        let content = format!("# Duplicate test {}", chrono::Utc::now());

        let result1 = create_backup_in(&content, &dir);
        assert!(result1.is_ok());
        let version1_opt = result1.expect("first backup");
        assert!(version1_opt.is_some());

        // Immediate second backup with same content should return None
        let result2 = create_backup_in(&content, &dir);
        assert!(result2.is_ok());
        let version2_opt = result2.expect("second backup");
        assert!(
            version2_opt.is_none(),
            "duplicate content should skip backup"
        );
    }

    #[test]
    fn test_create_backup_different_content() {
        let (_temp, dir) = make_test_dir();
        let content1 = format!("# First backup {}", chrono::Utc::now());
        let content2 = format!("# Second backup {}", chrono::Utc::now());

        let result1 = create_backup_in(&content1, &dir);
        assert!(result1.is_ok());
        assert!(result1.expect("first").is_some());

        // Give it a tiny delay to ensure different timestamp
        std::thread::sleep(std::time::Duration::from_millis(10));

        let result2 = create_backup_in(&content2, &dir);
        assert!(result2.is_ok());
        let version2 = result2.expect("second");
        assert!(version2.is_some(), "different content should create backup");
    }

    #[test]
    fn test_backup_before_save_flow() {
        // backup_before_save uses the default dir; just verify it doesn't panic.
        let content = format!("# GUI save test {}", chrono::Utc::now());

        let result = backup_before_save(&content);
        assert!(result.is_ok());

        let msg = result.expect("get message");
        assert!(
            msg.contains("Backed up") || msg.contains("No changes"),
            "Expected backup message, got: {}",
            msg
        );
    }

    #[test]
    fn test_backup_failure_does_not_block_save() {
        // Even if backup fails (which shouldn't happen in this test),
        // the backup_before_save function should return Ok with a warning message
        let content = "# Test content";

        let result = backup_before_save(content);
        // Should always return Ok, never Err
        assert!(result.is_ok());
    }

    #[test]
    fn test_load_version_success() {
        let (_temp, dir) = make_test_dir();
        let content = format!("# Load test {}", chrono::Utc::now());

        let backup_result = create_backup_in(&content, &dir);
        assert!(backup_result.is_ok());

        let version_opt = backup_result.expect("backup");
        assert!(version_opt.is_some());

        let version = version_opt.expect("version");

        // Load it back
        let load_result = load_version_in(&version.id, &dir);
        assert!(load_result.is_ok());

        let loaded_content = load_result.expect("loaded content");
        assert_eq!(loaded_content, content);
    }

    #[test]
    fn test_load_version_not_found() {
        let (_temp, dir) = make_test_dir();
        let result = load_version_in("nonexistent_version_id", &dir);
        assert!(result.is_err());

        let err = result.expect_err("should error");
        match err {
            crate::error::SpeechError::Config(msg) => {
                assert!(msg.contains("not found"));
            }
            _ => panic!("Expected Config error, got: {:?}", err),
        }
    }

    #[test]
    fn test_list_versions_with_metadata() {
        let (_temp, dir) = make_test_dir();
        let content1 = format!("# Version 1 {}", chrono::Utc::now());
        let _ = create_backup_in(&content1, &dir);

        std::thread::sleep(std::time::Duration::from_millis(10));

        let content2 = format!("# Version 2 {}", chrono::Utc::now());
        let _ = create_backup_in(&content2, &dir);

        // List versions
        let versions_result = list_versions_in(&dir);
        assert!(versions_result.is_ok());

        let versions = versions_result.expect("versions");

        // Should have exactly 2 versions (isolated test dir)
        assert_eq!(versions.len(), 2, "Expected exactly 2 versions");

        // Should be sorted newest first
        for i in 1..versions.len() {
            assert!(
                versions[i - 1].timestamp >= versions[i].timestamp,
                "Versions not sorted correctly"
            );
        }

        // Each version should have metadata
        for version in &versions {
            assert!(!version.id.is_empty());
            assert!(!version.content_hash.is_empty());
            assert!(version.path.exists());
        }
    }

    #[test]
    fn test_diff_identical() {
        let text = "Line 1\nLine 2\nLine 3\n";
        let diff = calculate_diff(text, text);

        // All lines should be context (no changes)
        for line in &diff {
            assert_eq!(line.operation, ' ');
        }
    }

    #[test]
    fn test_diff_added_lines() {
        let old = "Line 1\nLine 2\n";
        let new = "Line 1\nLine 2\nLine 3\n";

        let diff = calculate_diff(old, new);

        // Should have at least one '+' line
        let added = diff.iter().filter(|l| l.operation == '+').count();
        assert!(added > 0, "Expected added lines");
    }

    #[test]
    fn test_diff_removed_lines() {
        let old = "Line 1\nLine 2\nLine 3\n";
        let new = "Line 1\nLine 3\n";

        let diff = calculate_diff(old, new);

        // Should have at least one '-' line
        let removed = diff.iter().filter(|l| l.operation == '-').count();
        assert!(removed > 0, "Expected removed lines");
    }

    #[test]
    fn test_diff_modified_lines() {
        let old = "Line 1\nLine 2\nLine 3\n";
        let new = "Line 1\nLine 2 modified\nLine 3\n";

        let diff = calculate_diff(old, new);

        // Should have both removed and added lines for modification
        let removed = diff.iter().filter(|l| l.operation == '-').count();
        let added = diff.iter().filter(|l| l.operation == '+').count();

        assert!(removed > 0, "Expected removed lines");
        assert!(added > 0, "Expected added lines");
    }

    #[test]
    fn test_restore_version_success() {
        let (temp, dir) = make_test_dir();
        let soul_path = temp.path().join("SOUL.md");

        // Create a backup target to restore to.
        let original_content = format!("# Original content {}", chrono::Utc::now());
        let backup_result = create_backup_in(&original_content, &dir);
        assert!(backup_result.is_ok());
        let version_opt = backup_result.expect("backup");
        assert!(version_opt.is_some());
        let version = version_opt.expect("version");

        // Simulate edited current SOUL content.
        let modified_content = format!("# Modified content {}", chrono::Utc::now());
        std::fs::write(&soul_path, &modified_content).expect("write modified soul");

        // Restore the original version.
        let restore_result = restore_version_in(&version.id, &dir, &modified_content, &soul_path);
        assert!(restore_result.is_ok());

        // Verify restoration wrote the expected file content.
        let restored_content = std::fs::read_to_string(&soul_path).expect("read restored soul");
        assert_eq!(restored_content, original_content);
    }

    #[test]
    fn test_restore_creates_backup() {
        let (temp, dir) = make_test_dir();
        let soul_path = temp.path().join("SOUL.md");

        // Create initial version.
        let content1 = format!("# Content 1 {}", chrono::Utc::now());
        let backup1 = create_backup_in(&content1, &dir);
        assert!(backup1.is_ok());
        let version1 = backup1.expect("backup1").expect("version1");

        // Simulate current SOUL content before restore.
        let content2 = format!("# Content 2 {}", chrono::Utc::now());
        std::fs::write(&soul_path, &content2).expect("write soul content2");
        std::thread::sleep(std::time::Duration::from_millis(10));

        // Restore first version.
        let restore_result = restore_version_in(&version1.id, &dir, &content2, &soul_path);
        assert!(
            restore_result.is_ok(),
            "Restore should succeed: {:?}",
            restore_result.err()
        );

        // Verify the restored content matches version1.
        let restored = std::fs::read_to_string(&soul_path).expect("read restored soul");
        assert_eq!(restored, content1, "Restored content should match version1");

        // Verify current content was backed up before restore.
        let versions = list_versions_in(&dir).expect("list versions");
        assert_eq!(
            versions.len(),
            2,
            "Restore should create one additional backup"
        );
        assert!(
            versions
                .iter()
                .any(|version| version.content_hash == calculate_hash(&content2)),
            "Expected backup hash for pre-restore content"
        );
    }

    #[test]
    fn test_restore_invalid_version() {
        let (temp, dir) = make_test_dir();
        let soul_path = temp.path().join("SOUL.md");
        let current_content = "# current";
        let result = restore_version_in("nonexistent_version", &dir, current_content, &soul_path);
        assert!(result.is_err());
    }

    #[test]
    fn test_cleanup_old_versions() {
        let (_temp, dir) = make_test_dir();

        // Create 5 unique versions
        for i in 0..5 {
            let content = format!(
                "# Cleanup {} at {} rand={}",
                i,
                chrono::Utc::now(),
                rand::random::<u64>()
            );
            let _ = create_backup_in(&content, &dir);
            std::thread::sleep(std::time::Duration::from_millis(15));
        }

        let count_after_create = list_versions_in(&dir).expect("after create").len();
        assert_eq!(count_after_create, 5, "Should have created 5 versions");

        // Cleanup to keep only 3
        let deleted = cleanup_old_versions_in(3, &dir).expect("cleanup");

        let count_final = list_versions_in(&dir).expect("final").len();
        assert_eq!(deleted, 2, "Should have deleted 2 versions");
        assert_eq!(count_final, 3, "Should have 3 versions left");
    }

    #[test]
    fn test_cleanup_preserves_recent() {
        let (_temp, dir) = make_test_dir();
        let mut version_ids = Vec::new();
        for i in 0..3 {
            let content = format!(
                "# Preserve {} at {} rand={}",
                i,
                chrono::Utc::now(),
                rand::random::<u64>()
            );
            let backup = create_backup_in(&content, &dir).expect("backup");
            if let Some(version) = backup {
                version_ids.push(version.id.clone());
            }
            std::thread::sleep(std::time::Duration::from_millis(15));
        }

        assert_eq!(version_ids.len(), 3, "Should have created 3 versions");

        // Keep only 2 versions
        let _ = cleanup_old_versions_in(2, &dir);

        // Verify the most recent 2 of our versions still exist
        let versions = list_versions_in(&dir).expect("list versions");
        let remaining_ids: Vec<String> = versions.iter().map(|v| v.id.clone()).collect();

        assert_eq!(remaining_ids.len(), 2, "Should have 2 versions left");
        assert!(
            remaining_ids.contains(&version_ids[2]),
            "Most recent version should be preserved"
        );
        assert!(
            remaining_ids.contains(&version_ids[1]),
            "Second most recent version should be preserved"
        );
    }

    #[test]
    fn test_format_version_info() {
        let version = SoulVersion {
            id: "20260215_230000_000".to_string(),
            timestamp: chrono::Utc::now(),
            content_hash: "abc123def456".to_string(),
            path: PathBuf::from("/tmp/test.md"),
        };

        let formatted = format_version_info(&version);

        assert!(formatted.contains("20260215_230000_000"));
        assert!(formatted.contains("abc123de")); // First 8 chars of hash
        assert!(formatted.contains("UTC"));
    }
}
