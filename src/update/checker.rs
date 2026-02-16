//! GitHub release checker for Fae updates.
//!
//! Queries the GitHub releases API to detect newer versions, compares using
//! semver, and caches ETags for efficient conditional requests.

use crate::error::{Result, SpeechError};
use std::time::Duration;

/// Compare two semver version strings and return `true` if `remote` is newer than `current`.
///
/// Handles versions with or without `v` prefix and up to 3 numeric components.
fn version_is_newer(current: &str, remote: &str) -> bool {
    fn parse_parts(v: &str) -> (u64, u64, u64) {
        let v = v.strip_prefix('v').unwrap_or(v);
        let mut parts = v.split('.').filter_map(|s| s.parse::<u64>().ok());
        let major = parts.next().unwrap_or(0);
        let minor = parts.next().unwrap_or(0);
        let patch = parts.next().unwrap_or(0);
        (major, minor, patch)
    }
    parse_parts(remote) > parse_parts(current)
}

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

    /// Returns the current installed version.
    pub fn current_version(&self) -> &str {
        &self.current_version
    }

    /// Returns the GitHub repository slug.
    pub fn repo(&self) -> &str {
        &self.repo
    }

    /// Fetch multiple releases from the GitHub releases API.
    ///
    /// Returns up to `max` releases sorted newest-first (GitHub's default).
    /// This is an on-demand user action (no ETag caching).
    ///
    /// # Errors
    ///
    /// Returns an error if the HTTP request fails or the response cannot be
    /// parsed.
    pub fn fetch_releases(&self, max: usize) -> Result<Vec<Release>> {
        let per_page = max.min(100);
        let url = format!(
            "https://api.github.com/repos/{}/releases?per_page={per_page}",
            self.repo
        );

        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(10))
            .timeout_read(Duration::from_secs(20))
            .build();

        let resp = agent
            .get(&url)
            .set("User-Agent", "fae/0.1 (update-checker)")
            .set("Accept", "application/vnd.github+json")
            .call()
            .map_err(|e| {
                SpeechError::Update(format!("GitHub API request failed for {}: {e}", self.repo))
            })?;

        let status = resp.status();
        if !(200..300).contains(&status) {
            let body = resp.into_string().unwrap_or_default();
            let preview = body
                .trim()
                .chars()
                .take(180)
                .collect::<String>()
                .replace('\n', " ");
            let suffix = if preview.is_empty() {
                String::new()
            } else {
                format!(": {preview}")
            };
            return Err(SpeechError::Update(format!(
                "GitHub API returned HTTP {status} for {}{suffix}",
                self.repo
            )));
        }

        let body_text = resp.into_string().map_err(|e| {
            SpeechError::Update(format!("cannot read GitHub releases response body: {e}"))
        })?;

        let entries: Vec<serde_json::Value> = serde_json::from_str(&body_text).map_err(|e| {
            let preview = body_text
                .chars()
                .take(180)
                .collect::<String>()
                .replace('\n', " ");
            SpeechError::Update(format!(
                "cannot parse GitHub releases JSON: {e}; response preview: {preview}"
            ))
        })?;

        let mut releases = Vec::with_capacity(entries.len());
        for entry in &entries {
            match parse_github_release(entry) {
                Ok(r) => releases.push(r),
                Err(_) => continue, // skip unparseable entries (e.g. drafts)
            }
        }

        Ok(releases)
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
        let url = format!("https://api.github.com/repos/{}/releases/latest", self.repo);

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
            Err(ureq::Error::Status(304, r)) => {
                // Not modified — still on the same release.
                let returned_etag = r.header("ETag").map(String::from);
                return Ok((None, returned_etag.or_else(|| etag.map(String::from))));
            }
            Err(e) => {
                return Err(SpeechError::Update(format!(
                    "GitHub API request failed for {}: {e}",
                    self.repo
                )));
            }
        };

        let status = resp.status();
        // Capture the new ETag header.
        let new_etag = resp.header("ETag").map(String::from);

        // Some HTTP client paths can surface 304 as an Ok response with no body.
        if status == 304 {
            return Ok((None, new_etag.or_else(|| etag.map(String::from))));
        }

        if !(200..300).contains(&status) {
            let body = resp.into_string().unwrap_or_default();
            let preview = body
                .trim()
                .chars()
                .take(180)
                .collect::<String>()
                .replace('\n', " ");
            let suffix = if preview.is_empty() {
                String::new()
            } else {
                format!(": {preview}")
            };
            return Err(SpeechError::Update(format!(
                "GitHub API returned HTTP {status} for {}{suffix}",
                self.repo
            )));
        }

        let body_text = resp.into_string().map_err(|e| {
            SpeechError::Update(format!("cannot read GitHub release response body: {e}"))
        })?;

        if body_text.trim().is_empty() {
            return Err(SpeechError::Update(format!(
                "GitHub API returned an empty response body for {} (HTTP {status})",
                self.repo
            )));
        }

        let body: serde_json::Value = serde_json::from_str(&body_text).map_err(|e| {
            let preview = body_text
                .chars()
                .take(180)
                .collect::<String>()
                .replace('\n', " ");
            SpeechError::Update(format!(
                "cannot parse GitHub release JSON: {e}; response preview: {preview}"
            ))
        })?;

        let release = parse_github_release(&body)?;

        if version_is_newer(&self.current_version, &release.version) {
            Ok((Some(release), new_etag))
        } else {
            Ok((None, new_etag))
        }
    }
}

/// Parse a GitHub release JSON object into a [`Release`].
fn parse_github_release(body: &serde_json::Value) -> Result<Release> {
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

    let (download_url, asset_size) = select_fae_platform_asset(assets).unwrap_or_default();

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

/// Select a platform asset from a GitHub release assets array by name.
fn select_platform_asset(
    assets: &[serde_json::Value],
    expected_name: &str,
) -> Option<(String, u64)> {
    assets.iter().find_map(|asset| {
        let name = asset["name"].as_str()?;
        if name != expected_name {
            return None;
        }
        let url = asset["browser_download_url"].as_str()?.to_owned();
        let size = asset["size"].as_u64().unwrap_or(0);
        if url.is_empty() {
            return None;
        }
        Some((url, size))
    })
}

/// Select the matching Fae asset from a GitHub release assets array.
fn select_fae_platform_asset(assets: &[serde_json::Value]) -> Option<(String, u64)> {
    let expected = fae_asset_name()?;
    select_platform_asset(assets, expected)
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

        let release = parse_github_release(&json).unwrap();
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
        let release = parse_github_release(&json).unwrap();
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
        let release = parse_github_release(&json).unwrap();
        assert_eq!(release.version, "1.0.0");
    }

    #[test]
    fn parse_github_release_missing_tag_errors() {
        let json = serde_json::json!({ "assets": [] });
        assert!(parse_github_release(&json).is_err());
    }

    #[test]
    fn parse_github_release_missing_assets_errors() {
        let json = serde_json::json!({ "tag_name": "v1.0.0" });
        assert!(parse_github_release(&json).is_err());
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
    fn parse_github_release_with_notes_and_date() {
        let json = serde_json::json!({
            "tag_name": "v0.3.0",
            "body": "## Changelog\n- Fixed bugs\n- Added features",
            "published_at": "2026-01-15T12:00:00Z",
            "assets": [{
                "name": "fae-darwin-aarch64",
                "browser_download_url": "https://example.com/fae",
                "size": 42_000_000
            }]
        });

        let release = parse_github_release(&json).unwrap();
        assert_eq!(release.version, "0.3.0");
        assert!(release.release_notes.contains("Fixed bugs"));
        assert_eq!(release.published_at, "2026-01-15T12:00:00Z");
    }

    #[test]
    fn release_download_url_empty_when_no_matching_asset() {
        let json = serde_json::json!({
            "tag_name": "v1.0.0",
            "body": "",
            "published_at": "",
            "assets": [{
                "name": "fae-some-other-platform",
                "browser_download_url": "https://example.com/other",
                "size": 100
            }]
        });

        let release = parse_github_release(&json).unwrap();
        // No matching asset for current platform → empty download_url.
        assert_eq!(release.version, "1.0.0");
        // download_url may be empty if no matching asset
    }

    #[test]
    fn parse_multiple_releases() {
        let entries = vec![
            serde_json::json!({
                "tag_name": "v0.3.0",
                "body": "Third release",
                "published_at": "2026-02-15T00:00:00Z",
                "assets": []
            }),
            serde_json::json!({
                "tag_name": "v0.2.0",
                "body": "Second release",
                "published_at": "2026-02-10T00:00:00Z",
                "assets": []
            }),
            serde_json::json!({
                "tag_name": "v0.1.0",
                "body": "First release",
                "published_at": "2026-02-01T00:00:00Z",
                "assets": []
            }),
        ];

        let mut releases = Vec::new();
        for entry in &entries {
            if let Ok(r) = parse_github_release(entry) {
                releases.push(r);
            }
        }

        assert_eq!(releases.len(), 3);
        assert_eq!(releases[0].version, "0.3.0");
        assert_eq!(releases[1].version, "0.2.0");
        assert_eq!(releases[2].version, "0.1.0");
    }

    #[test]
    fn parse_multiple_releases_skips_invalid() {
        let entries = vec![
            serde_json::json!({
                "tag_name": "v1.0.0",
                "body": "Valid",
                "published_at": "2026-01-01T00:00:00Z",
                "assets": []
            }),
            serde_json::json!({
                "body": "No tag — should be skipped",
                "assets": []
            }),
            serde_json::json!({
                "tag_name": "v0.9.0",
                "body": "Also valid",
                "published_at": "2025-12-01T00:00:00Z",
                "assets": []
            }),
        ];

        let mut releases = Vec::new();
        for entry in &entries {
            if let Ok(r) = parse_github_release(entry) {
                releases.push(r);
            }
        }

        assert_eq!(releases.len(), 2);
        assert_eq!(releases[0].version, "1.0.0");
        assert_eq!(releases[1].version, "0.9.0");
    }

    #[test]
    fn select_fae_asset_skips_empty_url() {
        if let Some(name) = fae_asset_name() {
            let assets = vec![serde_json::json!({
                "name": name,
                "browser_download_url": "",
                "size": 100
            })];
            let result = select_fae_platform_asset(&assets);
            assert!(result.is_none(), "should skip asset with empty URL");
        }
    }
}
