# Phase 5.5: Self-Update System

## Overview
Fae checks her own GitHub releases for newer versions, notifies the user, and
applies updates. Platform-specific update mechanics handle the binary replacement.
Same system checks Pi updates.

## Dependencies
- Phase 5.3 (PiManager) for Pi version tracking

## Tasks

### Task 1: Create `src/update/mod.rs` — module scaffold
**Files:** `src/update/mod.rs` (new), `src/lib.rs` (edit)

New update module:
- `pub mod checker;`
- `pub mod applier;`
- `pub mod state;`
- Add `pub mod update;` to lib.rs

### Task 2: Create `src/update/checker.rs` — GitHub release checker
**Files:** `src/update/checker.rs` (new)

Check GitHub releases API:
```rust
pub struct UpdateChecker {
    repo: String,           // "saorsa-labs/fae" or "badlogic/pi-mono"  
    current_version: String,
}
```
- `UpdateChecker::for_fae() -> Self` (reads version from Cargo.toml / env)
- `UpdateChecker::for_pi(current: &str) -> Self`
- `check() -> Result<Option<Release>>` queries `https://api.github.com/repos/{repo}/releases/latest`
- `Release` struct: tag, version, download_url, release_notes, published_at
- Compare versions using semver
- Respect rate limiting (conditional requests with If-None-Match/ETag)
- Cache ETag in state file to avoid redundant downloads

### Task 3: Create `src/update/state.rs` — update state persistence
**Files:** `src/update/state.rs` (new)

Persisted update state at `~/.config/fae/update-state.json`:
```rust
pub struct UpdateState {
    pub fae_version: String,
    pub pi_version: Option<String>,
    pub pi_managed: bool,
    pub auto_update: AutoUpdatePreference,
    pub last_check: Option<DateTime<Utc>>,
    pub dismissed_release: Option<String>,  // version user said "skip"
    pub etag_fae: Option<String>,
    pub etag_pi: Option<String>,
}

pub enum AutoUpdatePreference {
    Ask,          // Show dialog each time (default)
    Always,       // Auto-update without asking
    Never,        // Never auto-update, just notify
}
```
- `load() -> UpdateState` reads from disk (creates default if missing)
- `save(&self) -> Result<()>` writes to disk

### Task 4: Create `src/update/applier.rs` — platform-specific update application
**Files:** `src/update/applier.rs` (new)

Apply downloaded update:

**Linux:**
- Download new binary to temp
- `mv /tmp/fae-new ~/.local/bin/fae` (or wherever current binary is)
- `chmod +x`
- Notify user to restart

**macOS:**
- Download new binary to temp
- Replace binary inside Fae.app bundle (or standalone binary)
- `xattr -c` to remove quarantine
- Notify user to restart

**Windows:**
- Download new binary to temp
- Write a small .bat script that waits for Fae to exit, replaces the binary, and relaunches
- Execute the .bat and exit Fae

Common:
- `apply_update(download_url: &str, target_path: &Path) -> Result<()>`
- Progress callback for download progress
- Verify downloaded binary (check it runs with `--version`)

### Task 5: Implement update notification UI
**Files:** `src/bin/gui.rs`

Update notification in the GUI:
- Banner at top when update available: "Fae vX.Y.Z is available. Update now?"
- Buttons: "Update", "Later", "Skip this version"
- Progress bar during download/install
- "Restart required" message after successful update
- Same UI for Pi updates: "Pi vX.Y.Z is available. Update now?"

### Task 6: Implement auto-update preference UI
**Files:** `src/bin/gui.rs`

Settings section for updates:
- "Auto-update" dropdown: Ask / Always / Never
- "Check now" button (triggers manual check)
- Last check timestamp display
- Current Fae version display
- Current Pi version display (from PiManager)

### Task 7: Wire update checks into startup
**Files:** `src/startup.rs`, `src/bin/gui.rs`

On app launch:
- Load UpdateState
- If last_check > 24 hours ago, run background update check
- If update available and preference is Always → auto-apply
- If update available and preference is Ask → show notification
- If update available and preference is Never → log but don't show
- Don't block startup — check runs asynchronously

### Task 8: Tests
**Files:** `src/update/*.rs`

- Parse GitHub releases API response
- Version comparison (semver)
- UpdateState serialization/deserialization
- AutoUpdatePreference behavior
- Platform detection for applier
- ETag caching logic

**Acceptance:**
- Fae detects new releases from GitHub
- User notified via GUI banner
- Platform-specific update application works
- Auto-update preference respected
- `cargo clippy` zero warnings
