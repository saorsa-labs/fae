//! GitHub release checker for Fae and Pi updates.
//!
//! Queries the GitHub releases API to detect newer versions, compares using
//! semver, and caches ETags for efficient conditional requests.

use crate::error::{Result, SpeechError};
use crate::pi::manager::version_is_newer;
use std::time::Duration;

/// A release discovered from GitHub.
#[derive(Debug, Clone)]
pub struct Release {
    /// Git tag name (e.g. `"v0.2.0"`).
    pub tag_name: String,
    /// Semver version string without the `v` prefix.
    pub version: String,
    /// Direct download URL for the platform-specific asset.
    pub download_url: String,
    /// Release notes / changelog body.
    pub release_notes: String,
    /// ISO 8601 publication timestamp.
    pub published_at: String,
    /// Size of the platform-specific asset in bytes.
    pub asset_size: u64,
}

/// Checks GitHub releases for a specific repository.
pub struct UpdateChecker {
    /// GitHub repository slug (e.g. `"saorsa-labs/fae"`).
    repo: String,
    /// Currently installed version.
    current_version: String,
}

impl UpdateChecker {
    /// Create a checker for Fae updates.
    pub fn for_fae() -> Self {
        Self {
            repo: "saorsa-labs/fae".to_owned(),
            current_version: env!("CARGO_PKG_VERSION").to_owned(),
        }
    }

    /// Create a checker for Pi updates.
    pub fn for_pi(current_version: &str) -> Self {
        Self {
            repo: "badlogic/pi-mono".to_owned(),
            current_version: current_version.to_owned(),
        }
    }

    /// Returns the current installed version.
    pub fn current_version(&self) -> &str {
        &self.current_version
    }

    /// Returns the GitHub repository slug.
    pub fn repo(&self) -> &str {
        &self.repo
    }

    /// Check GitHub for a newer release.
    ///
    /// Uses conditional requests via the `If-None-Match` / `ETag` header pair
    /// to avoid redundant API calls. Pass the previously cached ETag (if any)
    /// and receive the new ETag in the return value.
    ///
    /// Returns `(Some(release), new_etag)` when a newer version is available,
    /// or `(None, etag)` if up-to-date or not modified since the last check.
    ///
    /// # Errors
    ///
    /// Returns an error if the HTTP request fails or the response cannot be
    /// parsed.
    pub fn check(&self, etag: Option<&str>) -> Result<(Option<Release>, Option<String>)> {
        let url = format!(
            "https://api.github.com/repos/{}/releases/latest",
            self.repo
        );

        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(10))
            .timeout_read(Duration::from_secs(20))
            .build();

        let mut req = agent
            .get(&url)
            .set("User-Agent", "fae/0.1 (update-checker)")
            .set("Accept", "application/vnd.github+json");

        if let Some(tag) = etag {
            req = req.set("If-None-Match", tag);
        }

        let resp = match req.call() {
            Ok(r) => r,
            Err(ureq::Error::Status(304, _)) => {
                // Not modified — still on the same release.
                return Ok((None, etag.map(String::from)));
            }
            Err(e) => {
                return Err(SpeechError::Update(format!(
                    "GitHub API request failed for {}: {e}",
                    self.repo
                )));
            }
        };

        // Capture the new ETag header.
        let new_etag = resp.header("ETag").map(String::from);

        let body: serde_json::Value = resp.into_json().map_err(|e| {
            SpeechError::Update(format!("cannot parse GitHub release JSON: {e}"))
        })?;

        let release = parse_github_release(&body, &self.repo)?;

        if version_is_newer(&self.current_version, &release.version) {
            Ok((Some(release), new_etag))
        } else {
            Ok((None, new_etag))
        }
    }
}

/// Parse a GitHub release JSON object into a [`Release`].
fn parse_github_release(body: &serde_json::Value, repo: &str) -> Result<Release> {
    let tag_name = body["tag_name"]
        .as_str()
        .ok_or_else(|| SpeechError::Update("missing tag_name in release JSON".to_owned()))?
        .to_owned();

    let version = tag_name.strip_prefix('v').unwrap_or(&tag_name).to_owned();

    let release_notes = body["body"].as_str().unwrap_or("").to_owned();
    let published_at = body["published_at"].as_str().unwrap_or("").to_owned();

    let assets = body["assets"]
        .as_array()
        .ok_or_else(|| SpeechError::Update("missing assets in release JSON".to_owned()))?;

    let (download_url, asset_size) = if repo.contains("fae") {
        select_fae_platform_asset(assets)
    } else {
        select_pi_platform_asset(assets)
    }
    .unwrap_or_default();

    Ok(Release {
        tag_name,
        version,
        download_url,
        release_notes,
        published_at,
        asset_size,
    })
}

/// Returns the expected Fae asset name for the current platform.
pub fn fae_asset_name() -> Option<&'static str> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("macos", "aarch64") => Some("fae-darwin-aarch64"),
        ("macos", "x86_64") => Some("fae-darwin-x86_64"),
        ("linux", "x86_64") => Some("fae-linux-x86_64"),
        ("linux", "aarch64") => Some("fae-linux-aarch64"),
        ("windows", "x86_64") => Some("fae-windows-x86_64.exe"),
        _ => None,
    }
}

/// Select the matching Fae asset from a GitHub release assets array.
fn select_fae_platform_asset(assets: &[serde_json::Value]) -> Option<(String, u64)> {
    let expected = fae_asset_name()?;
    for asset in assets {
        let name = asset["name"].as_str().unwrap_or("");
        if name == expected {
            let url = asset["browser_download_url"]
                .as_str()
                .unwrap_or("")
                .to_owned();
            let size = asset["size"].as_u64().unwrap_or(0);
            if !url.is_empty() {
                return Some((url, size));
            }
        }
    }
    None
}

/// Select the matching Pi asset from a GitHub release assets array.
///
/// Pi uses names like `pi-darwin-arm64.tar.gz`, `pi-linux-x64.tar.gz`, etc.
fn select_pi_platform_asset(assets: &[serde_json::Value]) -> Option<(String, u64)> {
    let expected = crate::pi::manager::platform_asset_name()?;
    for asset in assets {
        let name = asset["name"].as_str().unwrap_or("");
        if name == expected {
            let url = asset["browser_download_url"]
                .as_str()
                .unwrap_or("")
                .to_owned();
            let size = asset["size"].as_u64().unwrap_or(0);
            if !url.is_empty() {
                return Some((url, size));
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    #[test]
    fn for_fae_uses_correct_repo() {
        let checker = UpdateChecker::for_fae();
        assert_eq!(checker.repo(), "saorsa-labs/fae");
        assert_eq!(checker.current_version(), env!("CARGO_PKG_VERSION"));
    }

    #[test]
    fn for_pi_uses_correct_repo() {
        let checker = UpdateChecker::for_pi("0.52.9");
        assert_eq!(checker.repo(), "badlogic/pi-mono");
        assert_eq!(checker.current_version(), "0.52.9");
    }

    #[test]
    fn fae_asset_name_returns_some_on_supported() {
        if cfg!(any(
            target_os = "macos",
            target_os = "linux",
            target_os = "windows"
        )) {
            assert!(fae_asset_name().is_some());
        }
    }

    #[test]
    fn fae_asset_name_matches_expected() {
        if let Some(name) = fae_asset_name() {
            assert!(name.starts_with("fae-"), "unexpected name: {name}");
        }
    }

    #[test]
    fn parse_github_release_fae() {
        let json = serde_json::json!({
            "tag_name": "v0.2.0",
            "body": "Bug fixes and improvements.",
            "published_at": "2026-02-10T00:00:00Z",
            "assets": [
                {
                    "name": "fae-darwin-aarch64",
                    "browser_download_url": "https://github.com/saorsa-labs/fae/releases/download/v0.2.0/fae-darwin-aarch64",
                    "size": 50_000_000
                }
            ]
        });

        let release = parse_github_release(&json, "saorsa-labs/fae").unwrap();
        assert_eq!(release.tag_name, "v0.2.0");
        assert_eq!(release.version, "0.2.0");
        assert_eq!(release.release_notes, "Bug fixes and improvements.");
        assert_eq!(release.published_at, "2026-02-10T00:00:00Z");
    }

    #[test]
    fn parse_github_release_strips_v_prefix() {
        let json = serde_json::json!({
            "tag_name": "v1.0.0",
            "body": "",
            "published_at": "",
            "assets": []
        });
        let release = parse_github_release(&json, "saorsa-labs/fae").unwrap();
        assert_eq!(release.version, "1.0.0");
    }

    #[test]
    fn parse_github_release_no_v_prefix() {
        let json = serde_json::json!({
            "tag_name": "1.0.0",
            "body": "",
            "published_at": "",
            "assets": []
        });
        let release = parse_github_release(&json, "saorsa-labs/fae").unwrap();
        assert_eq!(release.version, "1.0.0");
    }

    #[test]
    fn parse_github_release_missing_tag_errors() {
        let json = serde_json::json!({ "assets": [] });
        assert!(parse_github_release(&json, "saorsa-labs/fae").is_err());
    }

    #[test]
    fn parse_github_release_missing_assets_errors() {
        let json = serde_json::json!({ "tag_name": "v1.0.0" });
        assert!(parse_github_release(&json, "saorsa-labs/fae").is_err());
    }

    #[test]
    fn select_fae_asset_finds_match() {
        let assets = vec![serde_json::json!({
            "name": fae_asset_name().unwrap_or("fae-darwin-aarch64"),
            "browser_download_url": "https://example.com/download",
            "size": 1000
        })];

        if fae_asset_name().is_some() {
            let result = select_fae_platform_asset(&assets);
            assert!(result.is_some());
            let (url, size) = result.unwrap();
            assert_eq!(url, "https://example.com/download");
            assert_eq!(size, 1000);
        }
    }

    #[test]
    fn select_fae_asset_returns_none_for_empty() {
        let result = select_fae_platform_asset(&[]);
        assert!(result.is_none());
    }

    #[test]
    fn select_pi_asset_finds_match() {
        if let Some(expected_name) = crate::pi::manager::platform_asset_name() {
            let assets = vec![serde_json::json!({
                "name": expected_name,
                "browser_download_url": "https://example.com/pi",
                "size": 2000
            })];

            let result = select_pi_platform_asset(&assets);
            assert!(result.is_some());
        }
    }
}
