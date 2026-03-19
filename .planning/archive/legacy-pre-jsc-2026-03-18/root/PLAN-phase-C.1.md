# Phase C.1: SOUL.md Version Control

## Overview
Implement automatic versioning, backup, diff viewing, and rollback capability for SOUL.md to provide audit trail and recovery options for this critical configuration file.

## Tasks

### Task 1: SoulVersion Module & Tests
**Files**:
- `src/soul_version.rs` (new)
- `src/lib.rs` (add module declaration)

**Description**: Create the core version control module with types and storage. Implements file-based versioning with timestamped backups stored in `~/.fae/soul_versions/`. Each version is a copy with metadata (timestamp, hash).

**TDD**: Write tests first in `src/soul_version.rs::tests`:
- `test_version_path_format()` - verify naming scheme
- `test_version_metadata_roundtrip()` - serialize/deserialize metadata
- `test_list_versions_empty()` - handle empty directory
- `test_list_versions_order()` - verify chronological ordering

**Implementation**: Define `SoulVersion` struct with timestamp, hash, path. Implement `list_versions()`, `ensure_versions_dir()`, metadata JSON serialization.

### Task 2: Backup Creation Logic
**Files**:
- `src/soul_version.rs` (extend)

**Description**: Implement the backup creation function that copies current SOUL.md to versions directory before any save operation. Uses SHA-256 hash to detect duplicate content and avoid redundant backups.

**TDD**: Add tests:
- `test_create_backup_success()` - creates backup file and metadata
- `test_create_backup_duplicate_content()` - skips if hash matches last version
- `test_create_backup_io_error()` - handles write errors gracefully

**Implementation**: Add `create_backup(soul_content: &str) -> Result<Option<SoulVersion>>`. Returns None if content unchanged. Uses BLAKE3 for fast hashing.

### Task 3: Auto-Backup Integration in GUI
**Files**:
- `src/bin/gui.rs` (modify save handler at line ~6417)
- `src/soul_version.rs` (add convenience function)

**Description**: Hook the backup creation into the existing SOUL.md save flow. Before calling `write_text_file`, create a backup. Show backup status in the GUI status line.

**TDD**: Integration test in `src/soul_version.rs::tests`:
- `test_backup_before_save_flow()` - simulates full save with backup
- `test_backup_failure_does_not_block_save()` - save proceeds even if backup fails

**Implementation**: Modify the `onclick` handler to call `soul_version::backup_before_save()` which wraps `create_backup`. Update status messages to indicate backup success/failure.

### Task 4: Version List API & Load
**Files**:
- `src/soul_version.rs` (extend)

**Description**: Add functions to list all versions with metadata and load content from a specific version. Supports the diff viewer and rollback UI.

**TDD**: Add tests:
- `test_load_version_success()` - reads content from version file
- `test_load_version_not_found()` - handles missing version gracefully
- `test_list_versions_with_metadata()` - returns full version info sorted by date

**Implementation**: Add `load_version(version_id: &str) -> Result<String>` and extend `list_versions()` to return full `SoulVersion` objects with metadata.

### Task 5: Diff Calculation Backend
**Files**:
- `src/soul_version.rs` (extend)
- `Cargo.toml` (add `similar` crate dependency)

**Description**: Implement unified diff generation between two versions (or current vs. version). Uses the `similar` crate for text diffing with context lines.

**TDD**: Add tests:
- `test_diff_identical()` - returns empty diff
- `test_diff_added_lines()` - shows additions
- `test_diff_removed_lines()` - shows deletions
- `test_diff_modified_lines()` - shows changes

**Implementation**: Add `calculate_diff(old: &str, new: &str) -> Vec<DiffLine>` where `DiffLine` has fields: line_num, operation (add/remove/context), content.

### Task 6: Diff Viewer GUI Component
**Files**:
- `src/bin/gui.rs` (add diff viewer modal/panel)
- `src/soul_version.rs` (public API for GUI)

**Description**: Add a diff viewer UI that displays side-by-side or unified diff between current SOUL.md and a selected version. Accessible from the SOUL settings section.

**TDD**: Integration test verifying:
- `test_diff_viewer_renders()` - component renders with mock versions
- `test_diff_viewer_selects_version()` - version selection updates diff

**Implementation**: Add `div { class: "soul-diff-viewer" }` with textarea showing unified diff output. Use monospace font and syntax highlighting for +/- lines.

### Task 7: Rollback UI & Restore Logic
**Files**:
- `src/bin/gui.rs` (add rollback UI)
- `src/soul_version.rs` (add restore function)

**Description**: Add a version history panel showing all backups with timestamps. Each entry has a "Restore" button that loads that version as current SOUL.md (after creating a backup of current state).

**TDD**: Add tests:
- `test_restore_version_success()` - restores old version
- `test_restore_creates_backup()` - current version backed up before restore
- `test_restore_invalid_version()` - handles errors

**Implementation**: Add `restore_version(version_id: &str) -> Result<()>` that calls `backup_before_save()` then writes the old version content to `soul_path()`.

### Task 8: Audit Trail Display & Cleanup
**Files**:
- `src/bin/gui.rs` (extend version history panel)
- `src/soul_version.rs` (add cleanup/retention logic)

**Description**: Display full audit trail with version metadata (timestamp, content hash, change summary). Add optional cleanup to limit retention (e.g., keep last 50 versions or 30 days).

**TDD**: Add tests:
- `test_audit_trail_format()` - metadata display format
- `test_cleanup_old_versions()` - removes versions beyond retention limit
- `test_cleanup_preserves_recent()` - keeps recent versions

**Implementation**: Extend version list UI to show hash prefix, timestamp, file size. Add config option `soul_version_retention_count` (default 100). Implement `cleanup_old_versions(keep_count: usize) -> Result<usize>`.

## Quality Gates
- Zero clippy warnings
- All tests pass (cargo nextest run)
- No .unwrap() in production code (tests OK)
- Integration with existing GUI maintains all current functionality

## Integration Points
- `src/personality.rs::soul_path()` - path to current SOUL.md
- `src/bin/gui.rs` line 6417 - save handler
- `src/fae_dirs.rs::data_dir()` - base directory for versions storage
