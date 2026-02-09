# Phase 2.1: Self-Update System

## Overview
Fae checks her own GitHub releases for newer versions, prompts the user, and applies updates. This is the foundation — the same `UpdateChecker` and `UpdateState` types are reused in Phase 2.2 for Pi updates and Phase 2.3 for the scheduler.

---

## Task 1: Create UpdateState with version tracking and preferences

**Description**: Create `src/update/state.rs` with types for tracking installed versions, auto-update preferences, and dismissed notifications. Persisted as JSON at `~/.config/fae/state.json` (Linux/macOS) or `%APPDATA%\fae\state.json` (Windows).

**Files to create**: `src/update/state.rs`
**Files to modify**: `src/lib.rs` (add `pub mod update;`)

**Types to define**:
- `UpdateState` struct: `fae_version`, `pi_version`, `pi_managed`, `auto_update`, `last_check`, `dismissed_release`
- `AutoUpdatePreference` enum: `Ask` (default), `Always`, `Never`
- `impl UpdateState`: `load()`, `save()`, `state_path()`, setters

**Tests**: Load/save roundtrip, default values, missing file handling.

**Dependencies**: None. Add `dirs = "5"` to Cargo.toml if not already present.

---

## Task 2: Create UpdateChecker with GitHub release API

**Description**: Create `src/update/checker.rs` that queries `https://api.github.com/repos/{owner}/{repo}/releases/latest` and compares semver versions.

**Files to create**: `src/update/checker.rs`

**Types to define**:
- `GitHubRelease` struct (Deserialize): `tag_name`, `name`, `body`, `assets`, `published_at`
- `GitHubAsset` struct (Deserialize): `name`, `browser_download_url`, `size`
- `UpdateChecker` struct: `repo`, `current_version`
- `UpdateChecker::for_fae()` — uses `env!("CARGO_PKG_VERSION")` and `saorsa-labs/fae`
- `UpdateChecker::for_pi()` — uses `badlogic/pi-mono`
- `UpdateChecker::check()` → `Result<Option<GitHubRelease>>`
- `is_newer(latest, current)` — semver comparison

**Tests**: Version comparison edge cases (0.1.0 vs 0.2.0, 1.0.0 vs 0.9.9, equal versions, pre-release tags).

**Dependencies**: Task 1. Uses `ureq` (already in Cargo.toml).

---

## Task 3: Create platform-specific update application

**Description**: Create `src/update/apply.rs` with `apply_fae_update()` that downloads a release asset and replaces the running binary. Platform-specific:
- **Linux**: rename current binary to `.old`, write new binary, delete `.old`
- **macOS**: same, plus `xattr -cr` on the .app bundle
- **Windows**: write a `.bat` script that replaces the binary after Fae exits

**Files to create**: `src/update/apply.rs`

**Functions**:
- `apply_fae_update(release: &GitHubRelease) -> Result<()>`
- `fae_platform_asset_name() -> &'static str`
- `download_to_file(url: &str, dest: &Path) -> Result<()>` — uses `ureq` + streaming write
- `extract_and_place(archive: &Path, dest: &Path) -> Result<()>` — handles .tar.gz and .zip

**Dependencies**: Tasks 1, 2. Add `tempfile = "3"` and `flate2 = "1"` and `tar = "0.4"` and `zip = "2"` to Cargo.toml.

---

## Task 4: Create update module public API

**Description**: Create `src/update/mod.rs` that re-exports the public types and provides a high-level `check_and_prompt()` function that coordinates checking, state management, and user notification.

**Files to create**: `src/update/mod.rs`

**Public API**:
```rust
pub use checker::{UpdateChecker, GitHubRelease, GitHubAsset};
pub use state::{UpdateState, AutoUpdatePreference};
pub use apply::apply_fae_update;

/// Check for Fae update and return prompt if available
pub async fn check_for_fae_update() -> Option<UpdateNotification>;

pub struct UpdateNotification {
    pub current_version: String,
    pub new_version: String,
    pub release_notes: String,
    pub download_size: u64,
}
```

**Dependencies**: Tasks 1, 2, 3.

---

## Task 5: Add background update check on startup

**Description**: On GUI startup, spawn a non-blocking background task that:
1. Waits 30 seconds (don't slow startup)
2. Checks `UpdateState::last_check` — skip if checked within last 24 hours
3. Calls `check_for_fae_update()`
4. If update available, sends notification to GUI via Dioxus signal/channel
5. Updates `last_check` timestamp

**Files to modify**: `src/bin/gui.rs` (or wherever the Dioxus app initializes)

**Implementation**:
- Use `tokio::spawn` for background check
- Use `tokio::sync::mpsc` channel or Dioxus `Signal` to communicate with GUI
- Gracefully handle offline (log debug, don't error)

**Dependencies**: Task 4.

---

## Task 6: Add update notification to GUI

**Description**: When an update notification arrives, show a non-intrusive banner in the Fae GUI:
- "A new version of Fae is available (v0.X.Y). Update now?"
- [Update Now] [Later] buttons
- "Later" dismisses and records the version in state (won't nag again for this version)
- "Update Now" calls `apply_fae_update()`, shows progress, then prompts restart

**Files to modify**: GUI component files (Dioxus)

**Implementation**:
- Dioxus component: `UpdateBanner`
- Receives `UpdateNotification` via signal
- Download progress indicator during update
- Post-update: "Update complete. Restart Fae to apply." with [Restart] button

**Dependencies**: Task 5.

---

## Task 7: Add update preferences to settings UI

**Description**: Add an "Updates" section to Fae's settings screen with radio buttons for:
- "Ask me before updating" (default)
- "Always update automatically"
- "Don't check for updates"

Changes are persisted to `UpdateState` immediately.

**Files to modify**: Settings GUI component

**Implementation**:
- Read current preference from `UpdateState`
- Radio button group for `AutoUpdatePreference`
- On change: update `UpdateState` and save
- If set to "Always", the next scheduler check will auto-apply without prompting

**Dependencies**: Task 1.

---

## Task 8: Tests and verification

**Description**: Comprehensive tests for the update system.

**Tests to write**:
- `UpdateState` load/save roundtrip
- `UpdateState` handles missing file gracefully
- `UpdateChecker::is_newer()` edge cases
- `UpdateChecker::check()` with mock HTTP (use `mockito` or similar)
- `apply_fae_update()` with mock download (verify file operations)
- Platform asset name selection
- Integration test: full check → download → apply cycle (mocked)

**Verification**:
- `cargo check --all-targets`
- `cargo check --features gui --all-targets`
- `cargo clippy --all-targets -- -D warnings`
- `cargo clippy --features gui --all-targets -- -D warnings`
- `cargo fmt --all -- --check`
- `cargo test`

**Dependencies**: All previous tasks.
