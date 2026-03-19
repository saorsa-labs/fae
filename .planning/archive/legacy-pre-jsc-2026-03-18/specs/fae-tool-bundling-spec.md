# Fae Self-Update, Tool Integration & Scheduler — Technical Specification

> **Document Version**: 2.0
> **Date**: 2026-02-09
> **Status**: Ready for Implementation
> **Supersedes**: v1.0 (Tool Bundling System)

---

## 1. Executive Summary

### What Changed from v1.0

v1.0 proposed bundling 5 tools (Pi, Bun, fd, ripgrep, uv) as renamed binaries (`fae-pi`, `fae-bun`, etc.) with a complex CI pipeline to compile Pi from source using Bun. That approach had three problems:

1. **Pi moves too fast** — bundling a snapshot means shipping stale software within weeks
2. **Compiled Pi binaries break native modules** — clipboard and other platform-specific modules fail when Bun embeds them (Pi issues #556, #533)
3. **Too much scope for a small team** — the bundling spec was 1800 lines of CI pipelines, manifest formats, and checksumming for tools that don't all need bundling

### v2.0 Approach

| Concern | v1.0 | v2.0 |
|---------|------|------|
| Pi distribution | Compile to standalone, rename to `fae-pi` | Install Pi's own binary to standard location |
| Pi updates | Rebuild + ship new Fae release | Auto-update via scheduler |
| Fae updates | Not addressed | Self-update from GitHub releases |
| rg, fd, uv | Bundle all three | Don't bundle — Pi uses bash with grep/find |
| Bun runtime | Bundle for extensions | Not needed — Pi binary is self-contained |
| JS runtime needed | Yes (Bun, ~50MB) | No |
| Total added size | ~170MB+ | ~90MB (Pi binary only) |
| Maintenance burden | High (CI pipeline for 5 tools x 5 platforms) | Low (download one binary per platform) |

### Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Pi installation | Pre-built binary from Pi's own releases | Self-contained (Bun embedded), no JS runtime needed, maintained by Pi community |
| Pi location | Standard system location, called `pi` | Interoperates with user-installed Pi, not hidden |
| Pi config | `~/.pi/agent/` (Pi's standard) | Users who later use Pi directly find their config |
| Pi updates | Scheduler checks GitHub releases | Always current, user controls auto-update |
| Fae updates | Self-update from GitHub releases | Standard pattern for desktop apps |
| rg, fd, uv | Not bundled | Pi works with grep/find via bash; add later if profiling shows need |
| Scheduler | Built into Fae | Reusable for future user tasks (calendar, research) |

---

## 2. System Overview

### Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                              FAE                                     │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                      Voice Pipeline                            │ │
│  │   Mic → VAD → STT → LLM (Fae Brain) → TTS → Speaker          │ │
│  └──────────────────────────┬─────────────────────────────────────┘ │
│                              │                                       │
│                              ▼                                       │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                    Pi Manager                                   │ │
│  │                                                                 │ │
│  │   find_pi() → spawn pi --mode rpc → JSON stdin/stdout          │ │
│  │                                                                 │ │
│  │   Pi handles: read, write, edit, bash (grep, find, etc.)       │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                    Self-Updater                                 │ │
│  │                                                                 │ │
│  │   Checks GitHub releases for Fae updates                       │ │
│  │   Downloads + replaces binary (platform-specific)              │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐ │
│  │                    Scheduler                                    │ │
│  │                                                                 │ │
│  │   Periodic tasks:                                               │ │
│  │     - Check for Pi updates (daily)                              │ │
│  │     - Check for Fae updates (daily)                             │ │
│  │     - User-defined tasks (future: calendar, research, etc.)    │ │
│  └────────────────────────────────────────────────────────────────┘ │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘

                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     System (user's machine)                          │
│                                                                      │
│  ~/.local/bin/pi          ← Pi binary (standard location)           │
│  ~/.pi/agent/             ← Pi config, auth, extensions (standard)  │
│  ~/.config/fae/           ← Fae config                              │
│  ~/.config/fae/state.json ← Installed versions, update preferences  │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. Pi Integration

### 3.1 Pi Detection

Fae looks for Pi in this order:

1. **User's PATH** — if they installed Pi themselves, use it (respect their version)
2. **Standard install location** — where Fae's installer put it
3. **Not found** — install it

```rust
// src/tools/pi_manager.rs

use std::path::PathBuf;

pub struct PiManager {
    /// Where Fae installs Pi if not already present
    install_dir: PathBuf,
    /// State file tracking installed version
    state: UpdateState,
}

impl PiManager {
    pub fn new() -> Self {
        let install_dir = Self::platform_install_dir();
        let state = UpdateState::load();
        Self { install_dir, state }
    }

    /// Find Pi binary — prefer user-installed version
    pub fn find_pi(&self) -> Option<PathBuf> {
        // 1. Check PATH (user's own installation takes priority)
        if let Ok(path) = which::which("pi") {
            return Some(path);
        }

        // 2. Check our install location
        let ours = self.install_path();
        if ours.exists() {
            return Some(ours);
        }

        None
    }

    /// Full path to where we install Pi
    fn install_path(&self) -> PathBuf {
        let name = if cfg!(windows) { "pi.exe" } else { "pi" };
        self.install_dir.join(name)
    }

    /// Platform-specific standard install directory
    fn platform_install_dir() -> PathBuf {
        if cfg!(target_os = "macos") || cfg!(target_os = "linux") {
            // ~/.local/bin/ — standard user-level bin directory
            // Most distros include this in PATH by default
            dirs::home_dir().unwrap().join(".local").join("bin")
        } else {
            // Windows: %LOCALAPPDATA%\Programs\pi\
            dirs::data_local_dir().unwrap().join("Programs").join("pi")
        }
    }

    /// Is Pi managed by us (vs user-installed)?
    pub fn is_fae_managed(&self) -> bool {
        match self.find_pi() {
            Some(path) => path.starts_with(&self.install_dir),
            None => false,
        }
    }
}
```

### 3.2 Pi Installation

When Pi is not found, download from Pi's GitHub releases:

```rust
impl PiManager {
    /// Download and install Pi binary
    pub async fn install(&self) -> Result<()> {
        // 1. Get latest release info
        let release = self.fetch_latest_release().await?;

        // 2. Download platform-specific binary
        let archive = self.download_release(&release).await?;

        // 3. Extract binary
        let binary = self.extract_binary(&archive)?;

        // 4. Create install directory
        std::fs::create_dir_all(&self.install_dir)?;

        // 5. Write binary
        let dest = self.install_path();
        std::fs::write(&dest, &binary)?;

        // 6. Make executable (unix)
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&dest, std::fs::Permissions::from_mode(0o755))?;
        }

        // 7. macOS: remove quarantine flag
        #[cfg(target_os = "macos")]
        {
            let _ = tokio::process::Command::new("xattr")
                .args(["-c", dest.to_str().unwrap()])
                .output()
                .await;
        }

        // 8. Verify
        let output = tokio::process::Command::new(&dest)
            .arg("--version")
            .output()
            .await?;
        if !output.status.success() {
            anyhow::bail!("Pi installation verification failed");
        }

        // 9. Record installed version
        let version = String::from_utf8_lossy(&output.stdout).trim().to_string();
        self.state.set_pi_version(&version);
        self.state.set_pi_managed(true);
        self.state.save()?;

        Ok(())
    }

    /// Fetch latest release metadata from GitHub
    async fn fetch_latest_release(&self) -> Result<GitHubRelease> {
        let url = "https://api.github.com/repos/badlogic/pi-mono/releases/latest";
        let response: GitHubRelease = ureq::get(url)
            .set("User-Agent", "fae")
            .set("Accept", "application/vnd.github+json")
            .call()?
            .into_json()?;
        Ok(response)
    }

    /// Get the correct asset name for this platform
    fn platform_asset_name(&self) -> &'static str {
        if cfg!(target_os = "macos") && cfg!(target_arch = "aarch64") {
            "pi-darwin-arm64.tar.gz"
        } else if cfg!(target_os = "macos") && cfg!(target_arch = "x86_64") {
            "pi-darwin-x64.tar.gz"
        } else if cfg!(target_os = "linux") && cfg!(target_arch = "x86_64") {
            "pi-linux-x64.tar.gz"
        } else if cfg!(target_os = "linux") && cfg!(target_arch = "aarch64") {
            "pi-linux-arm64.tar.gz"
        } else if cfg!(target_os = "windows") {
            "pi-windows-x64.zip"
        } else {
            panic!("Unsupported platform")
        }
    }
}
```

### 3.3 Pi RPC Integration

Unchanged from v1.0 — Fae spawns Pi as a subprocess and communicates via JSON over stdin/stdout:

```rust
pub struct PiSession {
    process: tokio::process::Child,
    request_id: u64,
}

impl PiSession {
    pub async fn start(pi_manager: &PiManager, cwd: &Path) -> Result<Self> {
        let pi_path = pi_manager.find_pi()
            .ok_or_else(|| anyhow::anyhow!("Pi not found — run install first"))?;

        let process = tokio::process::Command::new(&pi_path)
            .args(["--mode", "rpc", "--no-session"])
            .current_dir(cwd)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()?;

        Ok(Self { process, request_id: 0 })
    }

    pub async fn prompt(&mut self, text: &str) -> Result<PiPromptResult> {
        self.request_id += 1;
        let id = self.request_id;
        let request = serde_json::json!({
            "id": id,
            "type": "prompt",
            "text": text
        });
        self.send_request(&request).await?;
        self.read_until_result(id).await
    }

    // ... send_request, read_until_result, abort, kill unchanged from v1.0
}
```

### 3.4 API Key Management

Fae passes API keys to Pi via environment variables. Pi stores its own auth in `~/.pi/agent/auth.json` (standard location). Fae does not manage Pi's auth — if the user configures Pi directly, that's respected.

```rust
pub async fn start_pi_with_keys(
    pi_manager: &PiManager,
    cwd: &Path,
    api_keys: &ApiKeyConfig,
) -> Result<PiSession> {
    let pi_path = pi_manager.find_pi()
        .ok_or_else(|| anyhow::anyhow!("Pi not found"))?;

    let mut cmd = tokio::process::Command::new(&pi_path);
    cmd.args(["--mode", "rpc", "--no-session"])
        .current_dir(cwd)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());

    // Pass API keys via environment (Pi reads these)
    if let Some(key) = &api_keys.anthropic {
        cmd.env("ANTHROPIC_API_KEY", key);
    }
    if let Some(key) = &api_keys.openai {
        cmd.env("OPENAI_API_KEY", key);
    }
    if let Some(key) = &api_keys.google {
        cmd.env("GOOGLE_API_KEY", key);
    }

    let process = cmd.spawn()?;
    Ok(PiSession { process, request_id: 0 })
}
```

---

## 4. Self-Update System

### 4.1 Overview

Fae checks her own GitHub releases for newer versions. The flow:

1. **Check** — compare current version against latest GitHub release
2. **Prompt** — show update notification in GUI (or auto-update if preference set)
3. **Download** — fetch platform-specific binary from release assets
4. **Apply** — replace running binary (platform-specific)
5. **Restart** — prompt user to restart Fae

### 4.2 Update State

```rust
// src/update/state.rs

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

#[derive(Debug, Serialize, Deserialize)]
pub struct UpdateState {
    /// Currently installed Fae version
    pub fae_version: String,

    /// Installed Pi version (if Fae-managed)
    pub pi_version: Option<String>,

    /// Whether Fae installed Pi (vs user-installed)
    pub pi_managed: bool,

    /// User's auto-update preference
    pub auto_update: AutoUpdatePreference,

    /// Last time we checked for updates
    pub last_check: Option<String>,  // ISO 8601

    /// Release we've already notified about (don't nag)
    pub dismissed_release: Option<String>,
}

#[derive(Debug, Serialize, Deserialize, Default)]
pub enum AutoUpdatePreference {
    /// Ask before updating (default)
    #[default]
    Ask,
    /// Always update automatically
    Always,
    /// Never update (user manages manually)
    Never,
}

impl UpdateState {
    fn state_path() -> PathBuf {
        dirs::config_dir().unwrap()
            .join("fae")
            .join("state.json")
    }

    pub fn load() -> Self {
        let path = Self::state_path();
        if path.exists() {
            let data = std::fs::read_to_string(&path).unwrap_or_default();
            serde_json::from_str(&data).unwrap_or_default()
        } else {
            Self::default()
        }
    }

    pub fn save(&self) -> Result<()> {
        let path = Self::state_path();
        std::fs::create_dir_all(path.parent().unwrap())?;
        let data = serde_json::to_string_pretty(self)?;
        std::fs::write(&path, data)?;
        Ok(())
    }
}
```

### 4.3 GitHub Release Checker

```rust
// src/update/checker.rs

use serde::Deserialize;

#[derive(Debug, Deserialize)]
pub struct GitHubRelease {
    pub tag_name: String,
    pub name: String,
    pub body: String,
    pub assets: Vec<GitHubAsset>,
    pub published_at: String,
}

#[derive(Debug, Deserialize)]
pub struct GitHubAsset {
    pub name: String,
    pub browser_download_url: String,
    pub size: u64,
}

pub struct UpdateChecker {
    /// GitHub repo in "owner/repo" format
    repo: String,
    current_version: String,
}

impl UpdateChecker {
    pub fn for_fae() -> Self {
        Self {
            repo: "saorsa-labs/fae".to_string(),
            current_version: env!("CARGO_PKG_VERSION").to_string(),
        }
    }

    pub fn for_pi() -> Self {
        Self {
            repo: "badlogic/pi-mono".to_string(),
            current_version: String::new(), // filled from state
        }
    }

    /// Check if a newer version is available
    pub async fn check(&self) -> Result<Option<GitHubRelease>> {
        let url = format!(
            "https://api.github.com/repos/{}/releases/latest",
            self.repo
        );
        let response: GitHubRelease = ureq::get(&url)
            .set("User-Agent", "fae")
            .set("Accept", "application/vnd.github+json")
            .call()?
            .into_json()?;

        let latest = response.tag_name.trim_start_matches('v');
        let current = self.current_version.trim_start_matches('v');

        if Self::is_newer(latest, current) {
            Ok(Some(response))
        } else {
            Ok(None)
        }
    }

    fn is_newer(latest: &str, current: &str) -> bool {
        // Semantic version comparison
        let parse = |s: &str| -> (u32, u32, u32) {
            let parts: Vec<u32> = s.split('.')
                .filter_map(|p| p.parse().ok())
                .collect();
            (
                parts.first().copied().unwrap_or(0),
                parts.get(1).copied().unwrap_or(0),
                parts.get(2).copied().unwrap_or(0),
            )
        };
        parse(latest) > parse(current)
    }
}
```

### 4.4 Platform-Specific Update Application

```rust
// src/update/apply.rs

pub async fn apply_fae_update(release: &GitHubRelease) -> Result<()> {
    let asset_name = fae_platform_asset_name();
    let asset = release.assets.iter()
        .find(|a| a.name == asset_name)
        .ok_or_else(|| anyhow::anyhow!("No asset for this platform"))?;

    // Download to temp file
    let temp = tempfile::NamedTempFile::new()?;
    download_to_file(&asset.browser_download_url, temp.path()).await?;

    // Platform-specific replacement
    #[cfg(target_os = "linux")]
    {
        // Linux: replace binary in-place
        let current_exe = std::env::current_exe()?;
        let backup = current_exe.with_extension("old");
        std::fs::rename(&current_exe, &backup)?;
        extract_and_place(&temp, &current_exe)?;
        std::fs::remove_file(&backup)?;
    }

    #[cfg(target_os = "macos")]
    {
        // macOS: replace within .app bundle, remove quarantine
        let current_exe = std::env::current_exe()?;
        let backup = current_exe.with_extension("old");
        std::fs::rename(&current_exe, &backup)?;
        extract_and_place(&temp, &current_exe)?;
        let _ = tokio::process::Command::new("xattr")
            .args(["-cr", current_exe.parent().unwrap()
                .parent().unwrap()  // up to .app
                .to_str().unwrap()])
            .output().await;
        std::fs::remove_file(&backup)?;
    }

    #[cfg(target_os = "windows")]
    {
        // Windows: can't replace running binary — schedule replacement
        // Write update script that runs after Fae exits
        let script = format!(
            r#"@echo off
timeout /t 2 /nobreak >nul
copy /y "{}" "{}"
start "" "{}"
del "%~f0"
"#,
            temp.path().display(),
            std::env::current_exe()?.display(),
            std::env::current_exe()?.display(),
        );
        let script_path = std::env::temp_dir().join("fae-update.bat");
        std::fs::write(&script_path, script)?;
        tokio::process::Command::new("cmd")
            .args(["/C", "start", "/min", script_path.to_str().unwrap()])
            .spawn()?;
    }

    Ok(())
}

fn fae_platform_asset_name() -> &'static str {
    if cfg!(target_os = "macos") && cfg!(target_arch = "aarch64") {
        "fae-darwin-arm64.tar.gz"
    } else if cfg!(target_os = "macos") && cfg!(target_arch = "x86_64") {
        "fae-darwin-x64.tar.gz"
    } else if cfg!(target_os = "linux") && cfg!(target_arch = "x86_64") {
        "fae-linux-x64.tar.gz"
    } else if cfg!(target_os = "linux") && cfg!(target_arch = "aarch64") {
        "fae-linux-arm64.tar.gz"
    } else if cfg!(target_os = "windows") {
        "fae-windows-x64.zip"
    } else {
        panic!("Unsupported platform")
    }
}
```

---

## 5. Scheduler

### 5.1 Overview

A lightweight background scheduler that runs periodic tasks. Initially used for update checks, designed to support future user tasks (calendar sync, research, reminders).

### 5.2 Design

```rust
// src/scheduler/mod.rs

use std::time::Duration;
use tokio::time;

pub struct Scheduler {
    tasks: Vec<ScheduledTask>,
}

pub struct ScheduledTask {
    pub name: String,
    pub interval: Duration,
    pub task: Box<dyn Fn() -> Pin<Box<dyn Future<Output = TaskResult>>> + Send + Sync>,
    pub last_run: Option<std::time::Instant>,
}

pub enum TaskResult {
    /// Nothing to report
    Ok,
    /// Show notification to user
    Notify(String),
    /// Show prompt requiring user action
    Prompt(UserPrompt),
}

pub struct UserPrompt {
    pub title: String,
    pub message: String,
    pub actions: Vec<PromptAction>,
}

pub struct PromptAction {
    pub label: String,
    pub callback: Box<dyn Fn() -> Pin<Box<dyn Future<Output = ()>>> + Send + Sync>,
}

impl Scheduler {
    pub fn new() -> Self {
        Self { tasks: Vec::new() }
    }

    /// Add built-in update check tasks
    pub fn with_update_checks(mut self, pi_manager: Arc<PiManager>) -> Self {
        // Check for Fae updates daily
        self.add_task(ScheduledTask {
            name: "fae-update-check".to_string(),
            interval: Duration::from_secs(24 * 60 * 60), // daily
            task: Box::new(|| Box::pin(check_fae_update())),
            last_run: None,
        });

        // Check for Pi updates daily
        self.add_task(ScheduledTask {
            name: "pi-update-check".to_string(),
            interval: Duration::from_secs(24 * 60 * 60), // daily
            task: Box::new(move || {
                let pm = pi_manager.clone();
                Box::pin(check_pi_update(pm))
            }),
            last_run: None,
        });

        self
    }

    pub fn add_task(&mut self, task: ScheduledTask) {
        self.tasks.push(task);
    }

    /// Run the scheduler loop (call from tokio::spawn)
    pub async fn run(&mut self) {
        let mut interval = time::interval(Duration::from_secs(60)); // check every minute
        loop {
            interval.tick().await;
            for task in &mut self.tasks {
                if task.is_due() {
                    let result = (task.task)().await;
                    task.last_run = Some(std::time::Instant::now());
                    match result {
                        TaskResult::Ok => {},
                        TaskResult::Notify(msg) => {
                            // Send notification to GUI
                            tracing::info!("Scheduler notification: {}", msg);
                        },
                        TaskResult::Prompt(prompt) => {
                            // Send prompt to GUI for user action
                            tracing::info!("Scheduler prompt: {}", prompt.title);
                        },
                    }
                }
            }
        }
    }
}
```

### 5.3 Update Check Tasks

```rust
async fn check_fae_update() -> TaskResult {
    let state = UpdateState::load();
    if matches!(state.auto_update, AutoUpdatePreference::Never) {
        return TaskResult::Ok;
    }

    let checker = UpdateChecker::for_fae();
    match checker.check().await {
        Ok(Some(release)) => {
            // Skip if user already dismissed this version
            if state.dismissed_release.as_deref() == Some(&release.tag_name) {
                return TaskResult::Ok;
            }

            if matches!(state.auto_update, AutoUpdatePreference::Always) {
                // Auto-update
                if let Err(e) = apply_fae_update(&release).await {
                    tracing::error!("Fae auto-update failed: {}", e);
                }
                return TaskResult::Notify(format!(
                    "Fae has been updated to {}. Restart to apply.",
                    release.tag_name
                ));
            }

            // Prompt user
            TaskResult::Prompt(UserPrompt {
                title: "Fae Update Available".to_string(),
                message: format!(
                    "Version {} is available (you have {}). Update now?",
                    release.tag_name,
                    env!("CARGO_PKG_VERSION")
                ),
                actions: vec![
                    PromptAction {
                        label: "Update Now".to_string(),
                        callback: Box::new(move || Box::pin(async move {
                            let _ = apply_fae_update(&release).await;
                        })),
                    },
                    PromptAction {
                        label: "Later".to_string(),
                        callback: Box::new(|| Box::pin(async {})),
                    },
                ],
            })
        },
        Ok(None) => TaskResult::Ok,
        Err(e) => {
            tracing::debug!("Update check failed (offline?): {}", e);
            TaskResult::Ok
        },
    }
}

async fn check_pi_update(pi_manager: Arc<PiManager>) -> TaskResult {
    // Only check if we manage Pi (not user-installed)
    if !pi_manager.is_fae_managed() {
        return TaskResult::Ok;
    }

    let state = UpdateState::load();
    let checker = UpdateChecker::for_pi();
    // ... similar logic to check_fae_update
    // Downloads new Pi binary, replaces in standard location
    TaskResult::Ok
}
```

### 5.4 User Update Preferences

Exposed in Fae's settings GUI:

```
┌─ Settings ──────────────────────────────────────────────┐
│                                                          │
│  Updates                                                 │
│                                                          │
│  Fae updates:                                           │
│    ○ Ask me before updating                             │
│    ● Always update automatically                         │
│    ○ Don't check for updates                            │
│                                                          │
│  Coding assistant (Pi) updates:                         │
│    ○ Ask me before updating                             │
│    ● Always update automatically                         │
│    ○ Don't check for updates                            │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

---

## 6. Installer Integration

### 6.1 macOS (.dmg with .app bundle)

The Fae.app bundle includes Pi's binary at build time:

```
Fae.app/
├── Contents/
│   ├── MacOS/
│   │   └── fae                    # Main Fae binary
│   ├── Resources/
│   │   ├── pi                     # Pi binary (bundled at build time)
│   │   └── fae.icns
│   └── Info.plist
```

**Post-install (first launch)**:
1. Check if `pi` exists on PATH → if yes, skip
2. Copy `Fae.app/Contents/Resources/pi` to `~/.local/bin/pi`
3. Create `~/.local/bin/` if it doesn't exist
4. `chmod +x ~/.local/bin/pi`
5. `xattr -c ~/.local/bin/pi`
6. Verify: `~/.local/bin/pi --version`

**Note**: `~/.local/bin/` is in the default PATH on most macOS configurations since Ventura. If not, Fae still finds Pi directly via `PiManager::install_path()`.

### 6.2 Linux (.deb / .AppImage)

**.deb package**:
```
/usr/lib/fae/fae                   # Main Fae binary
/usr/lib/fae/pi                    # Pi binary
/usr/bin/fae -> /usr/lib/fae/fae   # Symlink
```

Post-install script copies Pi to `~/.local/bin/pi` for the installing user.

**AppImage**:
Pi bundled inside the AppImage. On first run, extracts Pi to `~/.local/bin/pi`.

### 6.3 Windows (.msi)

```
C:\Program Files\Fae\
├── fae.exe
├── pi.exe                         # Bundled Pi
└── uninstall.exe
```

Post-install: copies `pi.exe` to `%LOCALAPPDATA%\Programs\pi\pi.exe` and adds that directory to user PATH.

### 6.4 CI: Fetching Pi for Installers

```yaml
# .github/workflows/build-fae.yml

jobs:
  build:
    strategy:
      matrix:
        include:
          - os: macos-14
            target: aarch64-apple-darwin
            pi_asset: pi-darwin-arm64.tar.gz
          - os: macos-13
            target: x86_64-apple-darwin
            pi_asset: pi-darwin-x64.tar.gz
          - os: ubuntu-latest
            target: x86_64-unknown-linux-gnu
            pi_asset: pi-linux-x64.tar.gz
          - os: windows-latest
            target: x86_64-pc-windows-msvc
            pi_asset: pi-windows-x64.zip

    runs-on: ${{ matrix.os }}

    steps:
      - uses: actions/checkout@v4

      - name: Build Fae
        run: cargo build --release --target ${{ matrix.target }}

      - name: Download Pi binary
        run: |
          PI_VERSION=$(curl -s https://api.github.com/repos/badlogic/pi-mono/releases/latest | jq -r '.tag_name')
          curl -L "https://github.com/badlogic/pi-mono/releases/download/${PI_VERSION}/${{ matrix.pi_asset }}" -o pi-archive
          # Extract pi binary from archive

      - name: Package installer
        run: |
          # Platform-specific packaging (dmg, deb, msi)
          # Includes both fae binary and pi binary
```

This is the entire CI pipeline for Pi integration. Compare with v1.0's multi-job, multi-tool pipeline — this is a single `curl` command per platform.

---

## 7. Module Structure

```
src/
├── tools/
│   ├── mod.rs              # pub use pi_manager, pi_session
│   ├── pi_manager.rs       # PiManager: detect, install, update Pi
│   └── pi_session.rs       # PiSession: RPC protocol over stdin/stdout
│
├── update/
│   ├── mod.rs              # pub use checker, apply, state
│   ├── checker.rs          # UpdateChecker: GitHub release API
│   ├── apply.rs            # Platform-specific update application
│   └── state.rs            # UpdateState: versions, preferences
│
├── scheduler/
│   ├── mod.rs              # Scheduler: periodic task runner
│   └── tasks.rs            # Built-in tasks: update checks
│
└── ... (existing modules unchanged)
```

---

## 8. Platform Considerations

### 8.1 macOS

| Concern | Mitigation |
|---------|-----------|
| Gatekeeper blocks Pi binary | `xattr -c` on install; code-sign in CI when budget allows |
| `~/.local/bin` not in PATH | Fae finds Pi directly via known path; also works if on PATH |
| Notarization | Notarize Fae.app bundle including bundled Pi |

### 8.2 Linux

| Concern | Mitigation |
|---------|-----------|
| `~/.local/bin` not in PATH on some distros | Fae finds Pi directly via known path |
| Permissions | `chmod +x` on install |
| ARM64 | Pi publishes linux-arm64 builds |

### 8.3 Windows (Future)

| Concern | Mitigation |
|---------|-----------|
| Pi requires bash | Pi detects Git Bash automatically; evaluate busybox-w32 as bundled fallback |
| PATH management | Add Pi directory to user PATH during install |
| Can't replace running binary | Update script runs after Fae exits |
| SmartScreen | Code-sign with EV certificate when budget allows |

---

## 9. Implementation Phases

### Phase 2.1: Self-Update System

- [ ] Create `src/update/state.rs` — UpdateState with version tracking and preferences
- [ ] Create `src/update/checker.rs` — UpdateChecker with GitHub release API
- [ ] Create `src/update/apply.rs` — platform-specific binary replacement (macOS, Linux)
- [ ] Create `src/update/mod.rs` — public API
- [ ] Add update check on startup (non-blocking, background)
- [ ] Add update notification to GUI (Dioxus signal)
- [ ] Add update preferences to settings UI
- [ ] Tests: mock GitHub API, verify version comparison, verify state persistence

### Phase 2.2: Pi Detection & Installation

- [ ] Create `src/tools/pi_manager.rs` — PiManager with find/install/update
- [ ] Create `src/tools/pi_session.rs` — PiSession with RPC protocol
- [ ] Create `src/tools/mod.rs` — public API
- [ ] Implement `find_pi()` — PATH detection + known install location
- [ ] Implement `install()` — download from GitHub releases, extract, verify
- [ ] Implement `is_fae_managed()` — detect user-installed vs Fae-installed
- [ ] Add first-run Pi setup flow in GUI
- [ ] Tests: mock GitHub API, verify install flow, verify PATH detection

### Phase 2.3: Scheduler & Pi Auto-Update

- [ ] Create `src/scheduler/mod.rs` — Scheduler with task registration and run loop
- [ ] Create `src/scheduler/tasks.rs` — built-in update check tasks
- [ ] Implement Fae update check task (daily)
- [ ] Implement Pi update check task (daily, only if Fae-managed)
- [ ] Wire scheduler into Fae startup (tokio::spawn)
- [ ] Connect scheduler notifications to GUI
- [ ] Implement auto-update preference (Ask / Always / Never)
- [ ] Tests: scheduler timing, task execution, preference handling

### Phase 2.4: Installer Integration

- [ ] macOS: include Pi in Fae.app/Contents/Resources/
- [ ] macOS: post-install copies Pi to ~/.local/bin/
- [ ] Linux: include Pi in .deb package
- [ ] Linux: post-install copies Pi to ~/.local/bin/
- [ ] CI: download latest Pi binary during Fae build
- [ ] CI: package platform-specific installers
- [ ] Detect existing Pi installation and skip
- [ ] Tests: install flow on clean system, existing Pi detection

### Phase 2.5: Testing & Documentation

- [ ] Cross-platform self-update testing (macOS, Linux)
- [ ] Cross-platform Pi install testing
- [ ] Edge cases: offline, existing Pi, permission denied, corrupt download
- [ ] Update failure recovery (rollback to previous version)
- [ ] GUI documentation for update preferences
- [ ] Integration tests for full update cycle
- [ ] Integration tests for Pi session lifecycle
- [ ] Final verification: zero warnings, all tests pass

---

## 10. Future Considerations (Not in Scope)

| Feature | When | Notes |
|---------|------|-------|
| Windows support | Phase 3 | Needs bash solution, MSI packaging |
| ripgrep/fd bundling | If profiling shows need | Pi works fine with grep/find for typical user workloads |
| Pi extension support | When users request it | Pi extensions need Bun runtime — add then |
| Scheduled user tasks | Phase 3+ | Calendar sync, research, reminders — uses same scheduler |
| Delta updates | When binary size matters | Only download changed bytes |
| Rollback on update failure | Phase 2.5 | Keep previous version as backup |

---

## Appendix A: Decision Log

### 2026-02-09: Switched from Bundling to Detect-Install-Update

**Context**: v1.0 spec proposed bundling 5 tools (Pi, Bun, fd, rg, uv) as renamed binaries with a complex CI pipeline.

**Problems identified**:
1. Pi moves too fast — bundled version goes stale within weeks
2. Compiled Pi binary breaks native modules (clipboard: issues #556, #533)
3. Bundling adds ~170MB+ and requires maintaining CI for 5 tools x 5 platforms
4. Small team doesn't have capacity for ongoing security audits anyway
5. Non-technical users shouldn't need fae-pi in a hidden directory — Pi should be Pi

**Decision**: Install Pi's own pre-built binary to standard location. Auto-update via scheduler. Don't bundle rg/fd/uv (Pi uses bash with standard tools). Don't bundle Bun (Pi binary is self-contained).

**Trade-offs accepted**:
- First-run requires internet (unless Pi was bundled in installer)
- Pi's native module issues in compiled binary still exist (but don't affect RPC mode)
- No security audit of Pi (but we weren't realistically going to do this anyway)
