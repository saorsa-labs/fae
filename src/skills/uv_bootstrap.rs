//! UV binary discovery and version checking.
//!
//! Probes well-known locations for the `uv` binary and validates that it meets
//! the minimum required version. This is the first step in the Python skill
//! bootstrap pipeline.

use std::path::{Path, PathBuf};
use std::process::Command;

use super::error::PythonSkillError;

/// Minimum UV version required for Fae's Python skill runtime.
pub const MINIMUM_UV_VERSION: &str = "0.4.0";

/// Information about a discovered UV installation.
#[derive(Debug, Clone)]
pub struct UvInfo {
    /// Absolute path to the `uv` binary.
    pub path: PathBuf,
    /// Parsed version string (e.g. `"0.5.14"`).
    pub version: String,
}

/// UV binary discovery and version validation.
///
/// Stateless — all methods are associated functions.
pub struct UvBootstrap;

impl UvBootstrap {
    /// Discover a usable `uv` binary.
    ///
    /// Probes locations in this order:
    /// 1. `explicit_path` (if provided)
    /// 2. `PATH` lookup via [`which::which`]
    /// 3. `~/.local/bin/uv`
    /// 4. `~/.cargo/bin/uv`
    /// 5. `fae_dirs::uv_cache_dir()/bin/uv`
    ///
    /// For each candidate found on disk, runs `uv --version` and validates the
    /// output against [`MINIMUM_UV_VERSION`].
    ///
    /// # Errors
    ///
    /// - [`PythonSkillError::UvNotFound`] if no binary is found at any location.
    /// - [`PythonSkillError::UvVersionTooOld`] if a binary is found but its
    ///   version is below the minimum.
    pub fn discover(explicit_path: Option<&Path>) -> Result<UvInfo, PythonSkillError> {
        let candidates = Self::build_candidate_list(explicit_path);

        for candidate in &candidates {
            if !candidate.is_file() {
                continue;
            }

            match Self::probe_version(candidate) {
                Ok(version) => {
                    if version_at_least(&version, MINIMUM_UV_VERSION) {
                        return Ok(UvInfo {
                            path: candidate.clone(),
                            version,
                        });
                    }
                    return Err(PythonSkillError::UvVersionTooOld {
                        found: version,
                        minimum: MINIMUM_UV_VERSION.to_owned(),
                    });
                }
                Err(_) => {
                    // Binary exists but `uv --version` failed — skip to next.
                    continue;
                }
            }
        }

        Err(PythonSkillError::UvNotFound {
            reason: format!(
                "searched {} location(s): {}",
                candidates.len(),
                candidates
                    .iter()
                    .map(|p| p.display().to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        })
    }

    /// Build the ordered list of candidate paths to probe.
    fn build_candidate_list(explicit_path: Option<&Path>) -> Vec<PathBuf> {
        let mut candidates = Vec::with_capacity(5);

        // 1. Explicit config path.
        if let Some(p) = explicit_path {
            candidates.push(p.to_path_buf());
        }

        // 2. PATH lookup.
        if let Ok(found) = which::which("uv") {
            candidates.push(found);
        }

        // 3. ~/.local/bin/uv
        if let Some(home) = dirs::home_dir() {
            candidates.push(home.join(".local/bin/uv"));
        }

        // 4. ~/.cargo/bin/uv
        if let Some(home) = dirs::home_dir() {
            candidates.push(home.join(".cargo/bin/uv"));
        }

        // 5. fae uv cache dir
        candidates.push(crate::fae_dirs::uv_cache_dir().join("bin/uv"));

        candidates
    }

    /// Run `uv --version` and parse the version string from the output.
    fn probe_version(uv_path: &Path) -> Result<String, PythonSkillError> {
        let output = Command::new(uv_path)
            .arg("--version")
            .output()
            .map_err(|e| PythonSkillError::UvNotFound {
                reason: format!("failed to execute {}: {e}", uv_path.display()),
            })?;

        if !output.status.success() {
            return Err(PythonSkillError::UvNotFound {
                reason: format!(
                    "{} --version exited with {}",
                    uv_path.display(),
                    output.status
                ),
            });
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        parse_uv_version(&stdout).ok_or_else(|| PythonSkillError::UvNotFound {
            reason: format!(
                "could not parse version from `uv --version` output: {stdout}"
            ),
        })
    }
}

/// Parse a version string from `uv --version` output.
///
/// Expected formats:
/// - `"uv 0.5.14 (7b55e9cc1 2024-01-15)"`
/// - `"uv 0.5.14"`
/// - `"uv 1.0.0-beta.1"`
///
/// Returns the version portion (e.g. `"0.5.14"`) or `None` if unparseable.
pub fn parse_uv_version(output: &str) -> Option<String> {
    let trimmed = output.trim();

    // Strip optional "uv " prefix.
    let version_part = if let Some(rest) = trimmed.strip_prefix("uv ") {
        rest
    } else {
        trimmed
    };

    // Take everything up to the first space or parenthesis.
    let version = version_part
        .split(|c: char| c.is_whitespace() || c == '(')
        .next()?
        .trim();

    if version.is_empty() {
        return None;
    }

    // Basic validation: must start with a digit.
    if !version.starts_with(|c: char| c.is_ascii_digit()) {
        return None;
    }

    Some(version.to_owned())
}

/// Compare two dotted version strings (e.g. `"0.5.14"` >= `"0.4.0"`).
///
/// Compares numeric components left-to-right. Pre-release suffixes after
/// a hyphen are ignored (e.g. `"1.0.0-beta.1"` compares as `"1.0.0"`).
/// Missing trailing components are treated as zero.
pub fn version_at_least(version: &str, minimum: &str) -> bool {
    let parse = |s: &str| -> Vec<u64> {
        // Strip pre-release suffix (everything after first '-').
        let base = s.split('-').next().unwrap_or(s);
        base.split('.')
            .filter_map(|part| part.parse::<u64>().ok())
            .collect()
    };

    let v = parse(version);
    let m = parse(minimum);

    let len = v.len().max(m.len());
    for i in 0..len {
        let vn = v.get(i).copied().unwrap_or(0);
        let mn = m.get(i).copied().unwrap_or(0);
        match vn.cmp(&mn) {
            std::cmp::Ordering::Greater => return true,
            std::cmp::Ordering::Less => return false,
            std::cmp::Ordering::Equal => continue,
        }
    }
    true // equal
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    // -----------------------------------------------------------------------
    // parse_uv_version
    // -----------------------------------------------------------------------

    #[test]
    fn parse_standard_output() {
        assert_eq!(
            parse_uv_version("uv 0.5.14 (7b55e9cc1 2024-01-15)"),
            Some("0.5.14".to_owned())
        );
    }

    #[test]
    fn parse_version_only() {
        assert_eq!(
            parse_uv_version("uv 0.5.14"),
            Some("0.5.14".to_owned())
        );
    }

    #[test]
    fn parse_with_prerelease() {
        assert_eq!(
            parse_uv_version("uv 1.0.0-beta.1"),
            Some("1.0.0-beta.1".to_owned())
        );
    }

    #[test]
    fn parse_bare_version() {
        assert_eq!(
            parse_uv_version("0.4.0"),
            Some("0.4.0".to_owned())
        );
    }

    #[test]
    fn parse_with_trailing_newline() {
        assert_eq!(
            parse_uv_version("uv 0.6.0\n"),
            Some("0.6.0".to_owned())
        );
    }

    #[test]
    fn parse_empty_returns_none() {
        assert_eq!(parse_uv_version(""), None);
    }

    #[test]
    fn parse_garbage_returns_none() {
        assert_eq!(parse_uv_version("not a version"), None);
    }

    #[test]
    fn parse_uv_prefix_only_returns_none() {
        assert_eq!(parse_uv_version("uv "), None);
    }

    // -----------------------------------------------------------------------
    // version_at_least
    // -----------------------------------------------------------------------

    #[test]
    fn version_equal_is_at_least() {
        assert!(version_at_least("0.4.0", "0.4.0"));
    }

    #[test]
    fn version_greater_patch() {
        assert!(version_at_least("0.4.1", "0.4.0"));
    }

    #[test]
    fn version_greater_minor() {
        assert!(version_at_least("0.5.0", "0.4.0"));
    }

    #[test]
    fn version_greater_major() {
        assert!(version_at_least("1.0.0", "0.4.0"));
    }

    #[test]
    fn version_less_patch() {
        assert!(!version_at_least("0.3.9", "0.4.0"));
    }

    #[test]
    fn version_less_minor() {
        assert!(!version_at_least("0.3.0", "0.4.0"));
    }

    #[test]
    fn version_prerelease_strip() {
        // Pre-release should be stripped for comparison: 1.0.0-beta.1 >= 0.4.0
        assert!(version_at_least("1.0.0-beta.1", "0.4.0"));
    }

    #[test]
    fn version_missing_trailing_components() {
        // "1.0" should equal "1.0.0"
        assert!(version_at_least("1.0", "1.0.0"));
        assert!(version_at_least("1.0.0", "1.0"));
    }

    // -----------------------------------------------------------------------
    // discover — with temp dir mock
    // -----------------------------------------------------------------------

    #[test]
    fn discover_with_nonexistent_explicit_path() {
        // If uv is on PATH, discover succeeds (skips bad explicit path).
        // If uv is NOT on PATH, discover fails with UvNotFound.
        let result = UvBootstrap::discover(Some(Path::new("/nonexistent/uv")));
        match result {
            Ok(info) => {
                // uv found via PATH or other fallback — verify it's valid.
                assert!(!info.version.is_empty());
                assert!(info.path.is_file());
            }
            Err(PythonSkillError::UvNotFound { reason }) => {
                assert!(reason.contains("searched"), "reason: {reason}");
            }
            Err(other) => panic!("unexpected error variant: {other}"),
        }
    }

    #[test]
    fn discover_returns_valid_info_if_uv_available() {
        // Opportunistic test: if uv is on PATH, verify discover returns good info.
        if which::which("uv").is_err() {
            // uv not installed — skip this test.
            return;
        }
        let info = UvBootstrap::discover(None).expect("uv should be discoverable");
        assert!(!info.version.is_empty());
        assert!(info.path.is_file());
        assert!(version_at_least(&info.version, MINIMUM_UV_VERSION));
    }

    #[test]
    fn build_candidate_list_includes_explicit_first() {
        let explicit = PathBuf::from("/custom/bin/uv");
        let candidates = UvBootstrap::build_candidate_list(Some(&explicit));
        assert_eq!(candidates[0], explicit);
    }

    #[test]
    fn build_candidate_list_without_explicit() {
        let candidates = UvBootstrap::build_candidate_list(None);
        // Should have at least the home-dir candidates + cache dir.
        assert!(
            candidates.len() >= 2,
            "expected at least 2 candidates, got {}",
            candidates.len()
        );
    }
}
