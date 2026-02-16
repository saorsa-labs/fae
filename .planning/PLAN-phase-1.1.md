# Phase 1.1: Backup Core

## Goal
Add `export_all_data()` function to `src/diagnostics.rs` that creates a complete ZIP backup of all user data to a user-specified destination path. Reuses existing ZIP infrastructure.

## Tasks

### Task 1: Make add_directory_to_zip recursive
- Current `add_directory_to_zip` only handles flat directories (skips subdirectories)
- Add recursive traversal so nested dirs like `soul_versions/`, `memory/` are fully included
- Preserve directory structure in ZIP paths
- **Files:** `src/diagnostics.rs`

### Task 2: Make chrono_timestamp public
- Change `fn chrono_timestamp()` to `pub fn chrono_timestamp()`
- GUI code in Phase 1.2 needs this for default backup filename
- **Files:** `src/diagnostics.rs`

### Task 3: Add export_all_data function
- Add `pub fn export_all_data(destination: &Path) -> Result<PathBuf>`
- Takes user-chosen destination path (from save-file picker)
- Collects: config dir (config.toml, scheduler.json), data dir root files (SOUL.md, onboarding.md, manifest.toml), logs/, skills/, memory/, external_apis/, wakeword/, voices/, soul_versions/
- Excludes: cache dir (models), diagnostics dir (old zips)
- Writes BACKUP_INFO.txt with version, date, OS, contents manifest
- Returns the destination path on success
- **Files:** `src/diagnostics.rs`

### Task 4: Add tests for export_all_data
- Use `tempfile::TempDir` for both source dirs (via env overrides) and destination
- Test that ZIP is created and contains expected entries
- Test with empty directories (graceful handling)
- Test with nested subdirectories
- Test BACKUP_INFO.txt contents
- **Files:** `src/diagnostics.rs` (test module)

### Task 5: Full validation
- `cargo fmt --all`
- `cargo clippy --all-features -- -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used`
- `cargo test --all-features`
- Zero errors, zero warnings
- **Files:** all
