# Data Backup & Skills Verification — Roadmap

## Problem Statement
Fae has no way for users to backup their data (config, memory, skills, voice samples, etc.). Users need a simple export-to-ZIP mechanism accessible from the app menu. Additionally, the skills download/edit/store pipeline needs end-to-end verification to confirm skills are persisted where Fae loads them.

## Success Criteria
- "Export Data..." menu item creates a ZIP backup of all user data
- Save-file picker lets user choose download location
- Backup includes: config, SOUL.md, memory, skills, logs, voices, wakewords, external APIs, soul versions
- Backup excludes: model cache (large, re-downloadable)
- ZIP contains BACKUP_INFO.txt with metadata (version, date, contents manifest)
- Progress/status feedback during export
- Skills system verified end-to-end: download → edit → install → load
- Zero compilation errors and warnings
- All tests pass
- Production ready quality

---

## Milestone 1: Data Backup & Skills Verification

### Phase 1.1: Backup Core
Add `export_all_data()` function to `src/diagnostics.rs`, reusing existing ZIP helper infrastructure (`add_directory_to_zip`, `add_file_to_zip`). Collects all user data directories, writes ZIP with backup metadata.

**Key files:** `src/diagnostics.rs`, `src/fae_dirs.rs`

### Phase 1.2: GUI Integration
Add "Export Data..." menu item to the Fae menu bar. Wire up save-file picker dialog (`rfd::FileDialog::save_file()`) with default filename `fae-backup-{timestamp}.zip`. Run export async with progress indicator and success/failure status.

**Key files:** `src/bin/gui.rs` (menu builder, menu handler, export function)

### Phase 1.3: Skills End-to-End Verification
Verify the full skills pipeline: download from URL → edit in textarea → install to skills directory → load on startup. Add integration tests for skill storage, discovery, and loading. Fix any gaps found.

**Key files:** `src/skills.rs`, `src/bin/gui.rs` (skills_window)

---

## Dependencies Already Available
- `zip = "2"` — ZIP archive creation
- `rfd = "0.15"` — Native file dialogs (save_file)
- `chrono` — Timestamps
- `ureq = "2"` — HTTP client (skill downloads)
- `tokio` — Async runtime (background export)

## Architecture Notes
- Existing `diagnostics.rs` has `gather_diagnostic_bundle()` with ZIP helpers — reuse pattern
- Menu system: `build_menu_bar()` → const IDs → `use_future` handler → spawn async
- File picker pattern: `tokio::task::spawn_blocking(|| rfd::FileDialog::new()...)`
- Skills stored as `.md` files in `fae_dirs::skills_dir()` → `~/Library/Application Support/fae/skills/`
