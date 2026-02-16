# Data Backup & Skills Verification — Roadmap

## Problem Statement
Fae has no way for users to backup or restore their data (config, memory, skills, voice samples, etc.). Users need simple export-to-ZIP and import-from-ZIP mechanisms accessible from the app menu. Additionally, the skills download/edit/store pipeline needs end-to-end verification to confirm skills are persisted where Fae loads them.

## Success Criteria
- "Export Data..." menu item creates a ZIP backup of all user data
- "Import Data..." menu item restores a previously exported backup
- Save-file / open-file pickers let user choose locations
- Backup includes: config, SOUL.md, memory, skills, logs, voices, wakewords, external APIs, soul versions
- Backup excludes: model cache (large, re-downloadable)
- ZIP contains BACKUP_INFO.txt with metadata (version, date, contents manifest)
- Import restores all files to correct Fae directories
- Progress/status feedback during export and import
- Skills system verified end-to-end: download → edit → install → load
- Zero compilation errors and warnings
- All tests pass
- Production ready quality

---

## Milestone 1: Data Backup & Skills Verification

### Phase 1.1: Backup Core ✅
Added `export_all_data()` and `import_all_data()` functions to `src/diagnostics.rs`. Recursive ZIP with full directory traversal. E2E roundtrip test verifies byte-for-byte fidelity across 14 file types.

**Key files:** `src/diagnostics.rs`, `src/fae_dirs.rs`

### Phase 1.2: GUI Integration
Add "Export Data..." and "Import Data..." menu items to the Fae menu bar. Wire up save-file picker dialog (`rfd::FileDialog::save_file()`) for export and open-file picker (`rfd::FileDialog::pick_file()`) for import. Default export filename: `fae-backup-{timestamp}.zip`. Run both operations async with progress indicator and success/failure status. Import shows confirmation dialog before overwriting.

**Key files:** `src/bin/gui.rs` (menu builder, menu handler, export/import functions)

### Phase 1.3: Skills End-to-End Verification
Verify the full skills pipeline: download from URL → edit in textarea → install to skills directory → load on startup. Add integration tests for skill storage, discovery, and loading. Fix any gaps found.

**Key files:** `src/skills.rs`, `src/bin/gui.rs` (skills_window)

---

## Dependencies Already Available
- `zip = "2"` — ZIP archive creation and extraction
- `rfd = "0.15"` — Native file dialogs (save_file, pick_file)
- `chrono` — Timestamps
- `ureq = "2"` — HTTP client (skill downloads)
- `tokio` — Async runtime (background export/import)

## Architecture Notes
- Existing `diagnostics.rs` has `gather_diagnostic_bundle()` with ZIP helpers — reuse pattern
- `export_all_data()` and `import_all_data()` are the core functions (Phase 1.1 ✅)
- Menu system: `build_menu_bar()` → const IDs → `use_future` handler → spawn async
- File picker pattern: `tokio::task::spawn_blocking(|| rfd::FileDialog::new()...)`
- Skills stored as `.md` files in `fae_dirs::skills_dir()` → `~/Library/Application Support/fae/skills/`
