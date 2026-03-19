# Phase 5.3: Pi Manager — Detection & Installation

## Overview
PiManager detects whether Pi is installed, downloads and installs it if not, and manages its lifecycle. Pi is installed as `pi` in the standard system location — interoperable with user-installed Pi.

## Tasks

### Task 1: Create `src/pi/mod.rs` — module scaffold
**Files:** `src/pi/mod.rs` (new), `src/lib.rs` (edit)

New Pi integration module:
- `pub mod manager;`
- `pub mod session;` (Phase 5.4)
- `pub mod skill;` (Phase 5.4)
- Add `pub mod pi;` to lib.rs

### Task 2: Create `src/pi/manager.rs` — PiManager struct
**Files:** `src/pi/manager.rs` (new)

Core Pi lifecycle manager:
```rust
pub struct PiManager {
    install_dir: PathBuf,     // ~/.local/bin (Linux/Mac) or %LOCALAPPDATA%\pi (Win)
    state: PiState,
}

pub struct PiState {
    pub installed: bool,
    pub version: Option<String>,
    pub path: Option<PathBuf>,
    pub managed_by_fae: bool,  // vs user-installed
}
```
- `PiManager::new() -> Self` with platform-specific install_dir
- Platform detection: `install_dir()` returns correct path per OS

### Task 3: Implement `find_pi()` — detection
**Files:** `src/pi/manager.rs`

Find existing Pi installation:
1. Check PATH via `which pi` (Unix) or `where pi` (Windows)
2. Check standard locations: `~/.local/bin/pi`, `/usr/local/bin/pi`, `%LOCALAPPDATA%\pi\pi.exe`
3. Run `pi --version` to verify it works and capture version
4. Detect if Fae-managed (check for `.fae-managed` marker file next to binary)
5. Return `PiState` with findings

### Task 4: Implement `install()` — download from GitHub
**Files:** `src/pi/manager.rs`

Download and install Pi:
- Fetch latest release from `https://api.github.com/repos/badlogic/pi-mono/releases/latest`
- Select correct asset: `pi-coding-agent-{platform}-{arch}` (darwin-arm64, darwin-x64, linux-x64, linux-arm64, windows-x64)
- Download binary to temp location
- Move to install_dir as `pi` (or `pi.exe`)
- `chmod +x` on Unix
- `xattr -c` on macOS (remove quarantine)
- Create `.fae-managed` marker file
- Verify with `pi --version`

### Task 5: Implement `update()` — update existing Pi
**Files:** `src/pi/manager.rs`

Update Pi to newer version:
- Compare installed version with latest GitHub release
- Download new binary to temp
- Replace old binary (platform-specific: rename-and-replace on Unix, .bat on Windows)
- Verify new version
- Only update Fae-managed installations (don't overwrite user-installed Pi)

### Task 6: Implement `ensure_pi()` — first-run flow
**Files:** `src/pi/manager.rs`

Called when a coding task is first requested:
- `find_pi()` → if found, return
- If not found, show GUI prompt: "Fae needs Pi to help with coding tasks. Install Pi?"
- If user agrees → `install()` with progress callback
- If user declines → return error, Fae explains she can't do coding tasks yet
- Cache result in PiState

### Task 7: Wire PiManager into GUI
**Files:** `src/bin/gui.rs`, `src/startup.rs`

- Create PiManager on app startup
- Run `find_pi()` during initialization
- Show Pi status in settings: installed/not installed, version, path, managed/user
- "Install Pi" / "Update Pi" buttons in settings
- "Check for Updates" button

### Task 8: Tests
**Files:** `src/pi/manager.rs`

- `find_pi()` returns None when Pi not on PATH
- Platform-specific install directory is correct
- GitHub release asset selection picks correct platform
- `.fae-managed` marker detection works
- Version parsing from `pi --version` output
- `install_dir()` returns valid path per platform

**Acceptance:**
- PiManager detects existing Pi installations
- Downloads and installs Pi from GitHub releases
- Installs to standard location as `pi`
- Platform-specific handling (Mac xattr, Windows .exe)
- GUI shows Pi status and install/update controls
- `cargo clippy` zero warnings
