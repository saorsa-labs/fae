# fae — Roadmap

## Milestone 1: Dioxus Desktop GUI ✅ COMPLETE

Replaced CLI-only experience with a Dioxus desktop GUI providing visual feedback during model loading and a start/stop interface with animated avatar.

---

## Milestone 2: Self-Update, Tool Integration & Scheduler

**Goal**: Fae can update herself, detect/install Pi (the coding agent she uses behind the scenes), and run scheduled background tasks — all without the user ever touching a terminal.

### Design Philosophy

- **Fae is for non-technical users.** They don't have Node.js, Homebrew, or a terminal. Everything must be handled by the installer and the app itself.
- **Install tools properly.** Pi is installed as `pi`, not `fae-pi`. Standard config location (`~/.pi/agent/`). If a technical friend later installs Pi via npm, everything interoperates.
- **Don't bundle what you can't maintain.** Pi moves fast. Instead of bundling a stale snapshot, install Pi's pre-built binary and auto-update it.
- **ripgrep and fd are optional.** Pi works fine with grep and find through its bash tool. Non-technical users working with configs and documents won't notice the difference. Don't over-engineer.

### Phase 2.1: Self-Update System (8 tasks)
Fae checks her own GitHub releases for newer versions, prompts the user, downloads and applies the update. Platform-specific update mechanics (replace binary on Linux, swap .app on macOS, MSI on Windows).

### Phase 2.2: Pi Detection & Installation (8 tasks)
On first launch (or first coding task), detect if `pi` is on PATH. If not, download Pi's latest binary from GitHub releases and install to the standard location. Verify it works via `pi --version`. Store installed version for update checks.

### Phase 2.3: Pi Auto-Update via Scheduler (8 tasks)
Background scheduler (cron-like) that periodically checks Pi's GitHub releases. If newer version available, prompt user. Support "always update automatically" preference. Same scheduler infrastructure will later support user tasks (calendar checks, research, etc.).

### Phase 2.4: Installer Integration (8 tasks)
Platform installers (macOS .dmg, Linux .deb/.AppImage, Windows .msi) bundle Pi's binary at build time so it works offline on first launch. Post-install steps place Pi in the standard location. Installer detects existing Pi and skips if already installed.

### Phase 2.5: Testing & Documentation (8 tasks)
Cross-platform testing of self-update, Pi install, Pi update, scheduler. Edge cases: offline, existing Pi installation, permission issues, update failures. User-facing documentation for the GUI.

## Success Criteria

- Fae self-updates from GitHub releases on all three platforms
- Pi is installed to standard location on first run (or bundled in installer)
- Pi auto-updates via scheduler, with user control over auto-update preference
- Scheduler infrastructure is in place for future user tasks
- Existing Pi installations are detected and respected
- Zero terminal interaction required from the user
- All tests pass, zero clippy warnings
