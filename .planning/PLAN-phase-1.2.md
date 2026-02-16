# Phase 1.2: GUI Integration

## Goal
Add "Export Data..." and "Import Data..." menu items to the Fae app menu. Wire up file pickers and async operations with status feedback.

## Tasks

### Task 1: Add menu constants and menu items
- Add `FAE_MENU_EXPORT_DATA` and `FAE_MENU_IMPORT_DATA` const IDs
- Add "Export Data..." and "Import Data..." MenuItems in `build_menu_bar()`
- Place them in the app menu after the Channels item, before the separator
- **Files:** `src/bin/gui.rs`

### Task 2: Add export handler
- In the menu event handler, handle `FAE_MENU_EXPORT_DATA`
- Open save-file picker via `rfd::FileDialog::save_file()` in `spawn_blocking`
- Default filename: `fae-backup-{chrono_timestamp}.zip`
- Call `export_all_data()` in spawn_blocking
- Show subtitle status: "Exporting..." → "Backup saved to ..." / "Export failed: ..."
- **Files:** `src/bin/gui.rs`

### Task 3: Add import handler
- Handle `FAE_MENU_IMPORT_DATA` in menu handler
- Open file picker via `rfd::FileDialog::pick_file()` in `spawn_blocking`
- Filter for `.zip` files
- Call `import_all_data()` in spawn_blocking
- Show subtitle status: "Importing..." → "Data restored from ..." / "Import failed: ..."
- **Files:** `src/bin/gui.rs`

### Task 4: Full validation
- `cargo fmt --all`
- `cargo clippy --all-features -- -D clippy::panic -D clippy::unwrap_used -D clippy::expect_used`
- `cargo test --all-features`
- Zero errors, zero warnings
- **Files:** all
