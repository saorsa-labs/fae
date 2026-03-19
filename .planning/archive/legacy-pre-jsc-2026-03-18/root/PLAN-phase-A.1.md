# Phase A.1: Apple Sandbox & Entitlements

## Objective
Enable macOS App Sandbox with all required entitlements, implement security-scoped bookmarks for persistent file access, and ensure the app can function correctly under sandbox restrictions.

## Current State
- `Entitlements.plist` has ONLY `com.apple.security.device.audio-input`
- `Info.plist` has permission descriptions for mic, desktop, documents, downloads
- `rfd::FileDialog` used at 3 locations without bookmark handling
- No platform abstraction module exists
- No `objc2`, `core-foundation`, or `security-framework` crates in dependencies

## Tasks

### Task 1: Update Entitlements.plist with sandbox entitlements
- **Description**: Add all required entitlements for App Sandbox operation
- **Files**:
  - `Entitlements.plist`
- **Changes**:
  1. Add `com.apple.security.app-sandbox` = true
  2. Add `com.apple.security.files.user-selected.read-write` = true
  3. Add `com.apple.security.files.bookmarks.app-scope` = true
  4. Add `com.apple.security.network.client` = true (required for LLM API calls, web search)
  5. Keep existing `com.apple.security.device.audio-input` = true
- **Verification**: plist file is valid XML

### Task 2: Add security-framework dependency and create platform module
- **Description**: Add the `security-framework` crate and create a cross-platform abstraction module
- **Files**:
  - `Cargo.toml` — add `security-framework` as macOS-only dep
  - `src/platform/mod.rs` — module root with cross-platform API
  - `src/platform/macos.rs` — macOS-specific bookmark implementation
  - `src/platform/stub.rs` — no-op implementation for non-macOS
  - `src/lib.rs` or `src/main.rs` — add `mod platform;`
- **Changes**:
  1. Add `[target.'cfg(target_os = "macos")'.dependencies]` section with `core-foundation = "0.10"` and `objc2 = "0.6"` and `objc2-foundation = "0.3"`
  2. Create `src/platform/mod.rs` with `BookmarkManager` trait and `create_manager()` factory
  3. Create `src/platform/stub.rs` implementing `BookmarkManager` as no-op for non-macOS
  4. Create `src/platform/macos.rs` (empty impl stub for now)
  5. Wire `mod platform` into the crate
- **Verification**: `cargo check` passes on current platform

### Task 3: Implement macOS security-scoped bookmark operations
- **Description**: Implement bookmark create, restore, start/stop accessing in the macOS platform module
- **Files**:
  - `src/platform/macos.rs`
- **Changes**:
  1. Implement `create_bookmark(path: &Path) -> Result<Vec<u8>>` using NSURLBookmarkCreationWithSecurityScope
  2. Implement `restore_bookmark(data: &[u8]) -> Result<(PathBuf, bool)>` returning resolved path and staleness flag
  3. Implement `start_accessing(path: &Path) -> Result<()>` calling startAccessingSecurityScopedResource
  4. Implement `stop_accessing(path: &Path)` calling stopAccessingSecurityScopedResource
  5. Use objc2/objc2-foundation for Objective-C bridging (NSURL, NSData)
  6. Proper error handling — no unwrap/expect, use anyhow::Result
- **Verification**: `cargo check` passes, unit tests for serialization

### Task 4: Add bookmark persistence to config
- **Description**: Store bookmarks in config so they survive app restarts
- **Files**:
  - `src/config.rs` — add BookmarkEntry and bookmark storage to SpeechConfig
  - `src/platform/mod.rs` — add BookmarkStore trait
- **Changes**:
  1. Add `BookmarkEntry { path: String, bookmark_data: String (base64), created_at: u64, label: String }`
  2. Add `bookmarks: Vec<BookmarkEntry>` to SpeechConfig (with serde default)
  3. Add `save_bookmark(label, path, data)` and `load_bookmarks()` and `remove_bookmark(label)` to config helpers
  4. Base64 encode/decode bookmark data for TOML storage
  5. Add tests for bookmark config round-trip (serialize → deserialize)
- **Verification**: `cargo test` passes, TOML round-trip works

### Task 5: Integrate bookmarks into file picker flows
- **Description**: After file/folder picker selection, create and persist security-scoped bookmarks
- **Files**:
  - `src/bin/gui.rs` — 3 file picker locations (lines ~5783, ~6686, ~6708)
- **Changes**:
  1. After `pick_file()` at line 5783 (voice sample): create bookmark, persist, start accessing
  2. After `pick_file()` at line 6686 (ingestion file): create bookmark, persist, start accessing
  3. After `pick_folder()` at line 6708 (ingestion folder): create bookmark, persist, start accessing
  4. On app startup: restore all bookmarks and start accessing them
  5. Add bookmark restoration in startup sequence (before any file access)
  6. Use platform::create_manager() so non-macOS builds compile
- **Verification**: `cargo check` passes, file picker still functional

### Task 6: Add bookmark restoration on startup
- **Description**: On app launch, restore all persisted bookmarks to regain access to user-selected files
- **Files**:
  - `src/bin/gui.rs` or `src/startup.rs` — startup sequence
  - `src/platform/mod.rs` — add restore_all_bookmarks helper
- **Changes**:
  1. In app startup (before any file access), load config bookmarks
  2. For each bookmark: call restore_bookmark(), check staleness, start_accessing()
  3. Log stale bookmarks (user will need to re-select those files)
  4. Remove invalid/corrupted bookmarks from config automatically
  5. Handle gracefully when bookmark restore fails (don't crash, just log)
- **Verification**: `cargo check` passes

### Task 7: Tests for bookmark lifecycle
- **Description**: Comprehensive tests for the bookmark system
- **Files**:
  - `src/platform/macos.rs` — platform-specific tests (cfg(test) + cfg(target_os = "macos"))
  - `src/platform/mod.rs` — cross-platform trait tests
  - `src/config.rs` — bookmark config tests
- **Changes**:
  1. Test BookmarkManager trait with stub implementation
  2. Test BookmarkEntry serialization round-trip
  3. Test bookmark add/remove/load from config
  4. Test base64 encoding/decoding of bookmark data
  5. Test stale bookmark handling
  6. On macOS: test actual bookmark create/restore cycle with a temp file
- **Verification**: All tests pass on current platform

### Task 8: Verify full build and update documentation
- **Description**: Run full validation suite and update docs
- **Files**:
  - `CLAUDE.md` (project) — update with platform module info
  - `Prompts/system_prompt.md` — note sandbox awareness
- **Verification**:
  1. `cargo fmt --all -- --check`
  2. `cargo clippy --all-features --all-targets -- -D warnings`
  3. `cargo nextest run --all-features`
  4. Verify Entitlements.plist is valid
  5. Verify no cfg(feature) gates on bookmark code (always compiled)
