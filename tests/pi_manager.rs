//! Integration tests for the Pi coding agent manager.
//!
//! Tests that require network access (GitHub API) are marked `#[ignore]`.
//! Run them manually with `cargo test -- --ignored`.

#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use fae::config::PiConfig;
use fae::pi::manager::{
    PiAsset, PiInstallState, PiManager, PiRelease, parse_pi_version, platform_asset_name,
    select_platform_asset, version_is_newer,
};
use std::path::PathBuf;

// ---------------------------------------------------------------------------
// PiConfig tests
// ---------------------------------------------------------------------------

#[test]
fn pi_config_defaults() {
    let config = PiConfig::default();
    assert!(config.auto_install);
    assert!(config.install_dir.is_none());
}

#[test]
fn pi_config_toml_round_trip() {
    let toml_str = r#"
[pi]
auto_install = false
install_dir = "/custom/path"
"#;
    let config: fae::config::SpeechConfig = toml::from_str(toml_str).unwrap();
    assert!(!config.pi.auto_install);
    assert_eq!(
        config.pi.install_dir.as_deref(),
        Some(std::path::Path::new("/custom/path"))
    );
}

#[test]
fn pi_config_toml_defaults_when_missing() {
    let toml_str = "";
    let config: fae::config::SpeechConfig = toml::from_str(toml_str).unwrap();
    assert!(config.pi.auto_install);
    assert!(config.pi.install_dir.is_none());
}

// ---------------------------------------------------------------------------
// PiInstallState tests
// ---------------------------------------------------------------------------

#[test]
fn pi_install_state_not_found_display() {
    assert_eq!(PiInstallState::NotFound.to_string(), "not installed");
}

#[test]
fn pi_install_state_user_installed_display() {
    let state = PiInstallState::UserInstalled {
        path: PathBuf::from("/usr/local/bin/pi"),
        version: "0.52.9".to_owned(),
    };
    let display = state.to_string();
    assert!(display.contains("user-installed"));
    assert!(display.contains("0.52.9"));
    assert!(display.contains("/usr/local/bin/pi"));
}

#[test]
fn pi_install_state_fae_managed_display() {
    let state = PiInstallState::FaeManaged {
        path: PathBuf::from("/home/user/.local/bin/pi"),
        version: "0.52.9".to_owned(),
    };
    let display = state.to_string();
    assert!(display.contains("fae-managed"));
    assert!(display.contains("0.52.9"));
}

// ---------------------------------------------------------------------------
// Version parsing tests
// ---------------------------------------------------------------------------

#[test]
fn parse_version_formats() {
    assert_eq!(parse_pi_version("0.52.9"), Some("0.52.9".to_owned()));
    assert_eq!(parse_pi_version("v0.52.9"), Some("0.52.9".to_owned()));
    assert_eq!(
        parse_pi_version("Pi Agent\nv0.52.9\n"),
        Some("0.52.9".to_owned())
    );
    assert_eq!(parse_pi_version("1.0"), Some("1.0".to_owned()));
    assert_eq!(parse_pi_version("garbage"), None);
    assert_eq!(parse_pi_version(""), None);
}

// ---------------------------------------------------------------------------
// Version comparison tests
// ---------------------------------------------------------------------------

#[test]
fn version_comparison_comprehensive() {
    // Newer
    assert!(version_is_newer("0.52.8", "0.52.9"));
    assert!(version_is_newer("0.52.9", "0.53.0"));
    assert!(version_is_newer("0.52.9", "1.0.0"));
    assert!(version_is_newer("0.9.99", "0.10.0"));

    // Equal
    assert!(!version_is_newer("0.52.9", "0.52.9"));
    assert!(!version_is_newer("1.0.0", "1.0.0"));

    // Older
    assert!(!version_is_newer("0.52.9", "0.52.8"));
    assert!(!version_is_newer("1.0.0", "0.99.99"));

    // Mismatched part counts
    assert!(version_is_newer("1.0", "1.0.1"));
    assert!(!version_is_newer("1.0.1", "1.0"));
}

// ---------------------------------------------------------------------------
// Platform asset selection tests
// ---------------------------------------------------------------------------

#[test]
fn platform_asset_name_is_some_on_supported() {
    // Running on macOS or Linux in CI should always have a platform match.
    if cfg!(any(
        target_os = "macos",
        target_os = "linux",
        target_os = "windows"
    )) {
        assert!(platform_asset_name().is_some());
    }
}

#[test]
fn select_platform_asset_with_full_release() {
    let release = PiRelease {
        tag_name: "v0.52.9".to_owned(),
        assets: vec![
            PiAsset {
                name: "pi-darwin-arm64.tar.gz".to_owned(),
                browser_download_url: "https://example.com/pi-darwin-arm64.tar.gz".to_owned(),
                size: 27_000_000,
            },
            PiAsset {
                name: "pi-darwin-x64.tar.gz".to_owned(),
                browser_download_url: "https://example.com/pi-darwin-x64.tar.gz".to_owned(),
                size: 30_000_000,
            },
            PiAsset {
                name: "pi-linux-x64.tar.gz".to_owned(),
                browser_download_url: "https://example.com/pi-linux-x64.tar.gz".to_owned(),
                size: 44_000_000,
            },
            PiAsset {
                name: "pi-linux-arm64.tar.gz".to_owned(),
                browser_download_url: "https://example.com/pi-linux-arm64.tar.gz".to_owned(),
                size: 43_000_000,
            },
            PiAsset {
                name: "pi-windows-x64.zip".to_owned(),
                browser_download_url: "https://example.com/pi-windows-x64.zip".to_owned(),
                size: 46_000_000,
            },
        ],
    };

    let asset = select_platform_asset(&release);
    if let Some(expected_name) = platform_asset_name() {
        assert!(asset.is_some(), "should find asset for current platform");
        assert_eq!(asset.unwrap().name, expected_name);
    }
}

#[test]
fn select_platform_asset_returns_none_for_empty_release() {
    let release = PiRelease {
        tag_name: "v1.0.0".to_owned(),
        assets: vec![],
    };
    assert!(select_platform_asset(&release).is_none());
}

// ---------------------------------------------------------------------------
// PiManager tests
// ---------------------------------------------------------------------------

#[test]
fn pi_manager_defaults_are_sensible() {
    let config = PiConfig::default();
    let manager = PiManager::new(&config).unwrap();
    assert!(manager.auto_install());
    assert!(!manager.state().is_installed());
    assert!(manager.pi_path().is_none());
}

#[test]
fn pi_manager_custom_install_dir() {
    let config = PiConfig {
        install_dir: Some(PathBuf::from("/tmp/fae-test-pi-custom")),
        auto_install: false,
    };
    let manager = PiManager::new(&config).unwrap();
    assert_eq!(
        manager.install_dir(),
        std::path::Path::new("/tmp/fae-test-pi-custom")
    );
    assert_eq!(
        manager.pi_binary_path(),
        PathBuf::from("/tmp/fae-test-pi-custom/pi")
    );
}

#[test]
fn pi_manager_detect_with_nonexistent_dir() {
    let config = PiConfig {
        install_dir: Some(PathBuf::from("/nonexistent/fae-test-detect-integ")),
        auto_install: false,
    };
    let mut manager = PiManager::new(&config).unwrap();
    let state = manager.detect().unwrap();
    // May find Pi in PATH on dev machines; the key is no errors.
    assert!(
        matches!(
            state,
            PiInstallState::NotFound | PiInstallState::UserInstalled { .. }
        ),
        "unexpected state: {state}"
    );
}

#[test]
fn pi_manager_ensure_pi_no_auto_install() {
    let config = PiConfig {
        install_dir: Some(PathBuf::from("/nonexistent/fae-test-ensure-integ")),
        auto_install: false,
    };
    let mut manager = PiManager::new(&config).unwrap();
    let state = manager.ensure_pi().unwrap();
    // With auto_install disabled, should NOT attempt download.
    assert!(
        matches!(
            state,
            PiInstallState::NotFound | PiInstallState::UserInstalled { .. }
        ),
        "unexpected state: {state}"
    );
}

#[test]
fn pi_manager_marker_path_format() {
    let config = PiConfig::default();
    let manager = PiManager::new(&config).unwrap();
    let marker = manager.marker_path();
    let marker_str = marker.to_string_lossy();
    assert!(
        marker_str.contains("fae") && marker_str.contains("pi-managed"),
        "unexpected marker path: {marker_str}"
    );
}

// ---------------------------------------------------------------------------
// Network tests (require GitHub access — run with --ignored)
// ---------------------------------------------------------------------------

/// Fetch the latest Pi release from GitHub and verify structure.
#[test]
#[ignore]
fn fetch_latest_release_from_github() {
    let release = fae::pi::manager::fetch_latest_release().unwrap();
    assert!(
        release.tag_name.starts_with('v'),
        "tag should start with 'v': {}",
        release.tag_name
    );
    assert!(
        !release.assets.is_empty(),
        "release should have at least one asset"
    );
    // Should have our platform.
    let asset = select_platform_asset(&release);
    assert!(asset.is_some(), "should have asset for current platform");
}
