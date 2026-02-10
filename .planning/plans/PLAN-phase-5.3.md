# Phase 5.3: Pi Manager — Detection & Installation

## Overview
Create `PiManager` that finds, installs, and manages the Pi coding agent binary.
Pi is distributed as GitHub releases at `badlogic/pi-mono` with tarballs (Linux/Mac)
and zip (Windows). The binary is `pi/pi` inside the archive.

## GitHub Release Info
- Repo: `badlogic/pi-mono`
- Latest API: `https://api.github.com/repos/badlogic/pi-mono/releases/latest`
- Asset naming:
  - `pi-darwin-arm64.tar.gz` (macOS Apple Silicon)
  - `pi-darwin-x64.tar.gz` (macOS Intel)
  - `pi-linux-x64.tar.gz` (Linux x86_64)
  - `pi-linux-arm64.tar.gz` (Linux aarch64)
  - `pi-windows-x64.zip` (Windows)
- Tarball structure: `pi/pi` is the binary, `pi/photon_rs_bg.wasm` companion file
- Install locations:
  - Linux/Mac: `~/.local/bin/pi`
  - Windows: `%LOCALAPPDATA%\pi\pi.exe`

## Tasks

### Task 1: Add Pi error variant and module skeleton
**Files**: `src/error.rs`, `src/lib.rs`, `src/pi/mod.rs`
- Add `Pi(String)` variant to `SpeechError`
- Create `src/pi/mod.rs` with `pub mod manager;`
- Add `pub mod pi;` to `src/lib.rs`
- Create empty `src/pi/manager.rs` with module doc comment

### Task 2: Define PiManager types and configuration
**Files**: `src/pi/manager.rs`, `src/config.rs`
- `PiInstallState` enum: `NotFound`, `UserInstalled { path, version }`, `FaeManaged { path, version }`
- `PiManager` struct with `install_dir: PathBuf`
- `PiConfig` struct: `auto_install: bool`, `install_dir: Option<PathBuf>`
- Add `pi: PiConfig` field to `SpeechConfig` (with default)
- `default_install_dir()` → platform-specific path
- `marker_path()` → `~/.local/share/fae/pi-managed` (indicates Fae installed Pi)
- Unit tests for default paths and config defaults

### Task 3: Implement Pi detection (find on system)
**Files**: `src/pi/manager.rs`
- `PiManager::detect()` → `Result<PiInstallState>`
- Check 1: `which` / `where` command to find `pi` in PATH
- Check 2: Check standard install locations (`~/.local/bin/pi`, `%LOCALAPPDATA%\pi\pi.exe`)
- Run `pi --version` to extract version string
- Check marker file to distinguish managed vs user-installed
- Filter out npm/npx aliases (check if resolved path contains `node_modules`)
- Unit tests for version parsing

### Task 4: Implement GitHub release API client
**Files**: `src/pi/manager.rs`
- `PiRelease` struct: `tag_name`, `assets: Vec<PiAsset>`
- `PiAsset` struct: `name`, `browser_download_url`, `size`
- `fetch_latest_release()` → `Result<PiRelease>` using ureq
- `select_platform_asset(release)` → `Option<&PiAsset>` using `std::env::consts::{OS, ARCH}`
- Map: `("macos","aarch64")→"pi-darwin-arm64.tar.gz"`, etc.
- Unit tests for asset selection logic (mock data)

### Task 5: Implement binary download and extraction
**Files**: `src/pi/manager.rs`
- `download_pi(asset, dest_dir, progress)` → `Result<PathBuf>`
- Download to temp file with progress reporting via `ProgressCallback`
- Extract: `.tar.gz` → `tar -xzf` (or pure Rust via `flate2`+`tar` crates), `.zip` → `zip` crate
- Find `pi/pi` (or `pi/pi.exe`) in extracted files
- Move binary to install location
- Set executable permissions on Unix (`chmod +x`)
- macOS: clear quarantine attribute (`xattr -c`)
- Write marker file to indicate Fae-managed installation
- Clean up temp files
- Integration test with mock (don't actually download in CI)

### Task 6: Implement version checking and update detection
**Files**: `src/pi/manager.rs`
- `PiManager::check_update()` → `Result<Option<PiRelease>>`
- Compare installed version with latest GitHub release
- Parse semver from `pi --version` output and `tag_name` (strip `v` prefix)
- Return `Some(release)` if newer version available, `None` if up-to-date
- Unit tests for version comparison

### Task 7: Implement ensure_pi() orchestrator and update()
**Files**: `src/pi/manager.rs`
- `PiManager::ensure_pi(progress)` → `Result<PiInstallState>`
  - detect() → if found, return state
  - if not found and auto_install enabled → install
  - if not found and auto_install disabled → return NotFound
- `PiManager::update(progress)` → `Result<PiInstallState>`
  - Only update Fae-managed installs (don't touch user installs)
  - check_update() → if Some → download and replace
- `PiManager::pi_path()` → `Option<&Path>` (convenience accessor)
- Integration tests for orchestration logic

### Task 8: Integration tests
**Files**: `tests/pi_manager.rs`
- Test PiConfig defaults and TOML round-trip
- Test PiInstallState display/debug
- Test platform asset selection for all platforms
- Test version comparison edge cases
- Test detect() on current system (may find or not find Pi)
- Test marker file creation and reading
- Test ensure_pi with auto_install=false returns NotFound when no Pi
