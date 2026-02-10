//! Finds, installs, and manages the Pi coding agent binary.
//!
//! `PiManager` handles the full lifecycle:
//! 1. **Detection** — find Pi in PATH or standard install locations
//! 2. **Installation** — download from GitHub releases and install
//! 3. **Updates** — check for newer versions and replace managed installs
//! 4. **Tracking** — distinguish Fae-managed installs from user-installed Pi

use crate::config::PiConfig;
use crate::error::{Result, SpeechError};
use std::path::{Path, PathBuf};

/// The installation state of the Pi coding agent.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PiInstallState {
    /// Pi was not found on the system.
    NotFound,
    /// Pi was found and appears to be installed by the user (not managed by Fae).
    UserInstalled {
        /// Absolute path to the Pi binary.
        path: PathBuf,
        /// Detected version string (e.g. "0.52.9").
        version: String,
    },
    /// Pi was installed and is managed by Fae.
    FaeManaged {
        /// Absolute path to the Pi binary.
        path: PathBuf,
        /// Detected version string (e.g. "0.52.9").
        version: String,
    },
}

impl PiInstallState {
    /// Returns the path to the Pi binary, if installed.
    pub fn path(&self) -> Option<&Path> {
        match self {
            Self::NotFound => None,
            Self::UserInstalled { path, .. } | Self::FaeManaged { path, .. } => Some(path),
        }
    }

    /// Returns the version string, if installed.
    pub fn version(&self) -> Option<&str> {
        match self {
            Self::NotFound => None,
            Self::UserInstalled { version, .. } | Self::FaeManaged { version, .. } => {
                Some(version)
            }
        }
    }

    /// Returns `true` if Pi is installed (either user or Fae-managed).
    pub fn is_installed(&self) -> bool {
        !matches!(self, Self::NotFound)
    }

    /// Returns `true` if this install is managed by Fae.
    pub fn is_fae_managed(&self) -> bool {
        matches!(self, Self::FaeManaged { .. })
    }
}

impl std::fmt::Display for PiInstallState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotFound => write!(f, "not installed"),
            Self::UserInstalled { path, version } => {
                write!(f, "user-installed v{version} at {}", path.display())
            }
            Self::FaeManaged { path, version } => {
                write!(f, "fae-managed v{version} at {}", path.display())
            }
        }
    }
}

/// A GitHub release for the Pi coding agent.
#[derive(Debug, Clone)]
pub struct PiRelease {
    /// Tag name (e.g. "v0.52.9").
    pub tag_name: String,
    /// Release assets (platform binaries).
    pub assets: Vec<PiAsset>,
}

impl PiRelease {
    /// Returns the semver version string (tag without leading `v`).
    pub fn version(&self) -> &str {
        self.tag_name.strip_prefix('v').unwrap_or(&self.tag_name)
    }
}

/// A single release asset (platform binary archive).
#[derive(Debug, Clone)]
pub struct PiAsset {
    /// Asset filename (e.g. "pi-darwin-arm64.tar.gz").
    pub name: String,
    /// Direct download URL.
    pub browser_download_url: String,
    /// File size in bytes.
    pub size: u64,
}

/// Manages detection, installation, and updates of the Pi coding agent.
pub struct PiManager {
    /// Directory where Fae installs Pi (e.g. `~/.local/bin`).
    install_dir: PathBuf,
    /// Path to the marker file that indicates Fae manages the Pi installation.
    marker_path: PathBuf,
    /// Current known state.
    state: PiInstallState,
    /// Configuration.
    config: PiConfig,
}

impl PiManager {
    /// Create a new `PiManager` with the given configuration.
    ///
    /// # Errors
    ///
    /// Returns an error if platform-specific default paths cannot be determined.
    pub fn new(config: &PiConfig) -> Result<Self> {
        let install_dir = config
            .install_dir
            .clone()
            .or_else(default_install_dir)
            .ok_or_else(|| {
                SpeechError::Pi("cannot determine default Pi install directory".to_owned())
            })?;

        let marker_path = default_marker_path().ok_or_else(|| {
            SpeechError::Pi("cannot determine Pi marker file path".to_owned())
        })?;

        Ok(Self {
            install_dir,
            marker_path,
            state: PiInstallState::NotFound,
            config: config.clone(),
        })
    }

    /// Returns the current detected installation state.
    pub fn state(&self) -> &PiInstallState {
        &self.state
    }

    /// Returns the install directory.
    pub fn install_dir(&self) -> &Path {
        &self.install_dir
    }

    /// Returns the expected Pi binary path within the install directory.
    pub fn pi_binary_path(&self) -> PathBuf {
        self.install_dir.join(pi_binary_name())
    }

    /// Returns the path to the marker file that tracks Fae-managed installs.
    pub fn marker_path(&self) -> &Path {
        &self.marker_path
    }

    /// Returns whether auto-install is enabled.
    pub fn auto_install(&self) -> bool {
        self.config.auto_install
    }

    /// Detect whether Pi is installed on the system.
    ///
    /// Checks in order:
    /// 1. The Fae-managed install location (`install_dir`)
    /// 2. Standard system locations via `which` / `where`
    ///
    /// Updates and returns the current [`PiInstallState`].
    ///
    /// # Errors
    ///
    /// Returns an error if running `pi --version` fails for a found binary.
    pub fn detect(&mut self) -> Result<&PiInstallState> {
        // Check the Fae-managed location first.
        let managed_path = self.pi_binary_path();
        if managed_path.is_file()
            && let Some(version) = run_pi_version(&managed_path)
        {
            let is_managed = self.marker_path.is_file();
            self.state = if is_managed {
                PiInstallState::FaeManaged {
                    path: managed_path,
                    version,
                }
            } else {
                PiInstallState::UserInstalled {
                    path: managed_path,
                    version,
                }
            };
            return Ok(&self.state);
        }

        // Check PATH via `which` (Unix) or `where` (Windows).
        // Filter out npm/npx shims — these are not native Pi binaries.
        if let Some(path) = find_pi_in_path()
            && !is_npm_shim(&path)
            && let Some(version) = run_pi_version(&path)
        {
            self.state = PiInstallState::UserInstalled { path, version };
            return Ok(&self.state);
        }

        self.state = PiInstallState::NotFound;
        Ok(&self.state)
    }
}

/// Returns the platform-specific Pi binary filename.
pub fn pi_binary_name() -> &'static str {
    if cfg!(target_os = "windows") {
        "pi.exe"
    } else {
        "pi"
    }
}

/// Returns the default install directory for Pi.
///
/// - Linux/macOS: `~/.local/bin`
/// - Windows: `%LOCALAPPDATA%\pi`
pub fn default_install_dir() -> Option<PathBuf> {
    #[cfg(target_os = "windows")]
    {
        std::env::var_os("LOCALAPPDATA").map(|d| PathBuf::from(d).join("pi"))
    }
    #[cfg(not(target_os = "windows"))]
    {
        std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local").join("bin"))
    }
}

/// Returns the path to the marker file indicating Fae manages the Pi install.
///
/// Location: `~/.local/share/fae/pi-managed`
fn default_marker_path() -> Option<PathBuf> {
    #[cfg(target_os = "windows")]
    {
        std::env::var_os("LOCALAPPDATA")
            .map(|d| PathBuf::from(d).join("fae").join("pi-managed"))
    }
    #[cfg(not(target_os = "windows"))]
    {
        std::env::var_os("HOME").map(|h| {
            PathBuf::from(h)
                .join(".local")
                .join("share")
                .join("fae")
                .join("pi-managed")
        })
    }
}

/// Returns the expected platform asset name for the current OS and architecture.
///
/// Maps `(std::env::consts::OS, std::env::consts::ARCH)` to the GitHub release
/// asset filename.
pub fn platform_asset_name() -> Option<&'static str> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => Some("pi-darwin-arm64.tar.gz"),
        ("macos", "x86_64") => Some("pi-darwin-x64.tar.gz"),
        ("linux", "x86_64") => Some("pi-linux-x64.tar.gz"),
        ("linux", "aarch64") => Some("pi-linux-arm64.tar.gz"),
        ("windows", "x86_64") => Some("pi-windows-x64.zip"),
        _ => None,
    }
}

/// Select the matching asset for the current platform from a release.
pub fn select_platform_asset(release: &PiRelease) -> Option<&PiAsset> {
    let expected = platform_asset_name()?;
    release.assets.iter().find(|a| a.name == expected)
}

/// Parse a version string from `pi --version` output.
///
/// Handles formats like `"0.52.9"`, `"v0.52.9"`, and multi-line output
/// where the version may be on its own line.
pub fn parse_pi_version(output: &str) -> Option<String> {
    for line in output.lines() {
        let trimmed = line.trim();
        // Try to find a semver-like pattern: digits.digits.digits
        let candidate = trimmed.strip_prefix('v').unwrap_or(trimmed);
        if candidate
            .split('.')
            .take(3)
            .all(|part| !part.is_empty() && part.chars().all(|c| c.is_ascii_digit()))
            && candidate.split('.').count() >= 2
        {
            return Some(candidate.to_owned());
        }
    }
    None
}

/// Run `pi --version` and parse the output into a version string.
fn run_pi_version(pi_path: &Path) -> Option<String> {
    let output = std::process::Command::new(pi_path)
        .arg("--version")
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    parse_pi_version(&stdout)
}

/// Find `pi` in the system PATH using `which` (Unix) or `where` (Windows).
fn find_pi_in_path() -> Option<PathBuf> {
    let cmd = if cfg!(target_os = "windows") {
        "where"
    } else {
        "which"
    };

    let output = std::process::Command::new(cmd)
        .arg(pi_binary_name())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;

    if !output.status.success() {
        return None;
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let path_str = stdout.lines().next()?.trim();
    if path_str.is_empty() {
        return None;
    }

    Some(PathBuf::from(path_str))
}

/// Returns `true` if the given path appears to be an npm/npx shim rather than
/// a native Pi binary.
///
/// npx-installed Pi resolves through `node_modules/.bin/pi` or similar.
fn is_npm_shim(path: &Path) -> bool {
    let path_str = path.to_string_lossy();
    // Check if the resolved path goes through node_modules or npm directories.
    path_str.contains("node_modules") || path_str.contains(".npm") || path_str.contains("npx")
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;

    #[test]
    fn pi_binary_name_is_correct() {
        let name = pi_binary_name();
        if cfg!(target_os = "windows") {
            assert_eq!(name, "pi.exe");
        } else {
            assert_eq!(name, "pi");
        }
    }

    #[test]
    fn default_install_dir_is_some() {
        // Should succeed when HOME / LOCALAPPDATA is set (always in dev/CI).
        let dir = default_install_dir();
        assert!(dir.is_some());
    }

    #[test]
    fn default_install_dir_contains_expected_path() {
        let dir = default_install_dir().unwrap();
        let path_str = dir.to_string_lossy();
        if cfg!(target_os = "windows") {
            assert!(path_str.contains("pi"));
        } else {
            assert!(path_str.contains(".local/bin"));
        }
    }

    #[test]
    fn platform_asset_name_returns_some_on_supported() {
        // This test runs on the build platform; macOS/Linux CI should pass.
        let name = platform_asset_name();
        // May be None on exotic platforms, but should be Some on CI.
        if cfg!(any(target_os = "macos", target_os = "linux", target_os = "windows")) {
            assert!(name.is_some());
        }
    }

    #[test]
    fn platform_asset_name_matches_pattern() {
        if let Some(name) = platform_asset_name() {
            assert!(name.starts_with("pi-"));
            assert!(
                name.ends_with(".tar.gz") || name.ends_with(".zip"),
                "unexpected extension: {name}"
            );
        }
    }

    #[test]
    fn select_platform_asset_finds_match() {
        let release = PiRelease {
            tag_name: "v0.52.9".to_owned(),
            assets: vec![
                PiAsset {
                    name: "pi-darwin-arm64.tar.gz".to_owned(),
                    browser_download_url: "https://example.com/pi-darwin-arm64.tar.gz".to_owned(),
                    size: 27_000_000,
                },
                PiAsset {
                    name: "pi-linux-x64.tar.gz".to_owned(),
                    browser_download_url: "https://example.com/pi-linux-x64.tar.gz".to_owned(),
                    size: 44_000_000,
                },
            ],
        };

        if let Some(name) = platform_asset_name() {
            // Only assert match if our platform has an asset in the mock data.
            if release.assets.iter().any(|a| a.name == name) {
                let asset = select_platform_asset(&release);
                assert!(asset.is_some());
                assert_eq!(asset.unwrap().name, name);
            }
        }
    }

    #[test]
    fn select_platform_asset_returns_none_for_empty() {
        let release = PiRelease {
            tag_name: "v1.0.0".to_owned(),
            assets: vec![],
        };
        assert!(select_platform_asset(&release).is_none());
    }

    #[test]
    fn parse_pi_version_simple() {
        assert_eq!(parse_pi_version("0.52.9"), Some("0.52.9".to_owned()));
    }

    #[test]
    fn parse_pi_version_with_v_prefix() {
        assert_eq!(parse_pi_version("v0.52.9"), Some("0.52.9".to_owned()));
    }

    #[test]
    fn parse_pi_version_multiline() {
        let output = "Pi Coding Agent\nv0.52.9\n";
        assert_eq!(parse_pi_version(output), Some("0.52.9".to_owned()));
    }

    #[test]
    fn parse_pi_version_two_part() {
        assert_eq!(parse_pi_version("1.0"), Some("1.0".to_owned()));
    }

    #[test]
    fn parse_pi_version_garbage() {
        assert_eq!(parse_pi_version("not a version"), None);
        assert_eq!(parse_pi_version(""), None);
    }

    #[test]
    fn pi_release_version_strips_prefix() {
        let release = PiRelease {
            tag_name: "v0.52.9".to_owned(),
            assets: vec![],
        };
        assert_eq!(release.version(), "0.52.9");
    }

    #[test]
    fn pi_release_version_no_prefix() {
        let release = PiRelease {
            tag_name: "0.52.9".to_owned(),
            assets: vec![],
        };
        assert_eq!(release.version(), "0.52.9");
    }

    #[test]
    fn pi_install_state_accessors() {
        let not_found = PiInstallState::NotFound;
        assert!(!not_found.is_installed());
        assert!(!not_found.is_fae_managed());
        assert!(not_found.path().is_none());
        assert!(not_found.version().is_none());

        let user = PiInstallState::UserInstalled {
            path: PathBuf::from("/usr/local/bin/pi"),
            version: "0.52.9".to_owned(),
        };
        assert!(user.is_installed());
        assert!(!user.is_fae_managed());
        assert_eq!(user.path().unwrap().to_str().unwrap(), "/usr/local/bin/pi");
        assert_eq!(user.version().unwrap(), "0.52.9");

        let managed = PiInstallState::FaeManaged {
            path: PathBuf::from("/home/test/.local/bin/pi"),
            version: "0.52.9".to_owned(),
        };
        assert!(managed.is_installed());
        assert!(managed.is_fae_managed());
    }

    #[test]
    fn pi_install_state_display() {
        assert_eq!(PiInstallState::NotFound.to_string(), "not installed");

        let user = PiInstallState::UserInstalled {
            path: PathBuf::from("/usr/bin/pi"),
            version: "1.0.0".to_owned(),
        };
        assert!(user.to_string().contains("user-installed"));
        assert!(user.to_string().contains("1.0.0"));

        let managed = PiInstallState::FaeManaged {
            path: PathBuf::from("/home/u/.local/bin/pi"),
            version: "0.52.9".to_owned(),
        };
        assert!(managed.to_string().contains("fae-managed"));
    }

    #[test]
    fn pi_manager_new_with_defaults() {
        let config = PiConfig::default();
        let manager = PiManager::new(&config).unwrap();
        assert!(!manager.state().is_installed());
        assert!(manager.auto_install());
    }

    #[test]
    fn pi_manager_custom_install_dir() {
        let config = PiConfig {
            install_dir: Some(PathBuf::from("/custom/path")),
            ..Default::default()
        };
        let manager = PiManager::new(&config).unwrap();
        assert_eq!(manager.install_dir(), Path::new("/custom/path"));
    }

    #[test]
    fn is_npm_shim_detects_node_modules() {
        assert!(is_npm_shim(Path::new(
            "/home/user/.nvm/versions/node/v20/lib/node_modules/.bin/pi"
        )));
        assert!(is_npm_shim(Path::new(
            "/usr/local/lib/node_modules/.bin/pi"
        )));
    }

    #[test]
    fn is_npm_shim_detects_npx() {
        assert!(is_npm_shim(Path::new("/home/user/.npm/_npx/123/node_modules/.bin/pi")));
    }

    #[test]
    fn is_npm_shim_allows_native() {
        assert!(!is_npm_shim(Path::new("/usr/local/bin/pi")));
        assert!(!is_npm_shim(Path::new("/home/user/.local/bin/pi")));
    }

    #[test]
    fn detect_returns_not_found_for_nonexistent_dir() {
        let config = PiConfig {
            install_dir: Some(PathBuf::from("/nonexistent/fae-test-pi-detect")),
            auto_install: false,
        };
        let mut manager = PiManager::new(&config).unwrap();
        let state = manager.detect().unwrap();
        // May find Pi in PATH on dev machines, but the managed location won't exist.
        // The important thing is that it doesn't error out.
        assert!(
            matches!(state, PiInstallState::NotFound | PiInstallState::UserInstalled { .. }),
            "expected NotFound or UserInstalled, got: {state}"
        );
    }

    #[test]
    fn pi_manager_marker_path_is_set() {
        let config = PiConfig::default();
        let manager = PiManager::new(&config).unwrap();
        let marker = manager.marker_path();
        let marker_str = marker.to_string_lossy();
        assert!(
            marker_str.contains("fae") && marker_str.contains("pi-managed"),
            "unexpected marker path: {marker_str}"
        );
    }
}
