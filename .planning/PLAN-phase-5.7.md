# Phase 5.7: Installer Integration & Testing

## Overview
Platform installers bundle Pi binary at build time for offline first-run.
Cross-platform testing validates the full lifecycle: install, detect, update,
schedule. Documentation for users and contributors.

## Dependencies
- All previous Phase 5.x phases

## Tasks

### Task 1: macOS installer (.dmg) — bundle Pi
**Files:** CI/build scripts, `build/macos/`

macOS .dmg packaging:
- Download Pi's macOS binary during CI build
- Include in `Fae.app/Contents/Resources/pi`
- Post-install: copy to `~/.local/bin/pi` if not already present
- Sign Pi binary with Fae's code signing certificate (or mark as from identified developer)
- `xattr -c` in post-install to clear quarantine
- Bundle for both arm64 (Apple Silicon) and x64 (Intel)

### Task 2: Linux installer (.deb / .AppImage) — bundle Pi
**Files:** CI/build scripts, `build/linux/`

Linux packaging:
- **.deb**: Include Pi binary in package, post-install script copies to `/usr/local/bin/pi` or `~/.local/bin/pi`
- **.AppImage**: Bundle Pi binary inside, extract on first run to `~/.local/bin/pi`
- Download Pi's linux-x64 and linux-arm64 binaries during CI
- `chmod +x` in post-install

### Task 3: Windows installer (.msi) — bundle Pi
**Files:** CI/build scripts, `build/windows/`

Windows MSI packaging:
- Include Pi binary (`pi.exe`) in the MSI
- Install to `%LOCALAPPDATA%\Programs\pi\pi.exe`
- Add install directory to user PATH via MSI custom action
- No admin rights required (per-user install)

### Task 4: CI pipeline — download Pi assets
**Files:** `.github/workflows/build.yml` (or equivalent)

GitHub Actions workflow additions:
- Step: download Pi release binary for target platform
- Use `curl` to fetch from `https://github.com/badlogic/pi-mono/releases/latest/download/pi-coding-agent-{platform}`
- Cache downloaded binary between CI runs
- Verify download checksum (if available from Pi releases)
- Support pinning Pi version for reproducible builds

### Task 5: First-run detection and Pi extraction
**Files:** `src/pi/manager.rs`

When Fae starts and Pi not found on PATH:
- Check if bundled Pi exists in app resources directory
- If bundled Pi found → copy to standard install location
- Mark as Fae-managed
- Skip GitHub download (offline-friendly first run)
- Bundled Pi used as fallback if download fails

### Task 6: Cross-platform integration tests
**Files:** `tests/integration/`

End-to-end tests (can run in CI):
- PiManager finds bundled Pi
- PiManager installs from GitHub (with mock server)
- PiSession starts and communicates via RPC
- UpdateChecker detects new version
- Scheduler triggers update check
- LLM server responds to chat completions request
- Full flow: voice command → Pi delegation → result

### Task 7: User documentation
**Files:** Update README.md, create docs/

Documentation additions:
- "Getting Started" section for non-technical users
- Pi integration explanation (what Pi does, why Fae uses it)
- Troubleshooting: Pi not found, update failures, LLM server issues
- Configuration reference: models.json, scheduler.json, update preferences
- Platform-specific notes (macOS Gatekeeper, Windows PATH, Linux permissions)

### Task 8: Final verification and cleanup
**Files:** All Phase 5.x files

Verification checklist:
- `cargo clippy` zero warnings across all new code
- `cargo test` all new tests pass
- `cargo build --features gui` succeeds
- GUI launches with Pi status displayed
- LLM server starts and serves requests
- models.json written correctly
- Scheduler runs background tasks
- Update checker detects mock releases
- No saorsa-ai references remain in codebase

**Acceptance:**
- Installers bundle Pi for all three platforms
- First-run works offline (bundled Pi)
- All integration tests pass
- Documentation complete
- `cargo clippy` zero warnings
- Clean build on all platforms
