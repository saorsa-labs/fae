//! Model file integrity verification.
//!
//! Before starting the pipeline, model files can be verified against
//! expected SHA-256 checksums. Corrupt or missing files are detected
//! early, triggering a re-download rather than a cryptic pipeline error.
//!
//! # Example
//!
//! ```rust
//! use fae::model_integrity::{verify, IntegrityResult};
//! use std::path::Path;
//!
//! let result = verify(Path::new("/nonexistent/model.gguf"), None);
//! assert_eq!(result, IntegrityResult::Missing);
//! ```

use sha2::{Digest, Sha256};
use std::fmt;
use std::io::{self, Read};
use std::path::Path;
use tracing::{info, warn};

/// Result of a model file integrity check.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IntegrityResult {
    /// File exists and (if a checksum was provided) matches the expected hash.
    Ok,
    /// File does not exist at the given path.
    Missing,
    /// File exists but its SHA-256 digest does not match the expected value.
    Corrupt,
    /// File exists but no expected checksum was provided — verification skipped.
    NoChecksum,
}

impl fmt::Display for IntegrityResult {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Ok => write!(f, "ok"),
            Self::Missing => write!(f, "missing"),
            Self::Corrupt => write!(f, "corrupt"),
            Self::NoChecksum => write!(f, "no_checksum"),
        }
    }
}

/// Verify a model file against an optional expected SHA-256 hex digest.
///
/// # Arguments
///
/// - `path` — path to the model file
/// - `expected_sha256` — optional 64-character lowercase hex digest;
///   when `None` the function returns [`IntegrityResult::NoChecksum`]
///   without reading the file
///
/// # Returns
///
/// - [`IntegrityResult::Missing`] if the file does not exist or is not a file
/// - [`IntegrityResult::NoChecksum`] if `expected_sha256` is `None`
/// - [`IntegrityResult::Ok`] if the file's digest matches
/// - [`IntegrityResult::Corrupt`] if the digest does not match
pub fn verify(path: &Path, expected_sha256: Option<&str>) -> IntegrityResult {
    if !path.exists() || !path.is_file() {
        info!(path = %path.display(), "model integrity: file missing");
        return IntegrityResult::Missing;
    }

    let expected = match expected_sha256 {
        Some(h) => h,
        None => {
            info!(
                path = %path.display(),
                "model integrity: no checksum provided, skipping verification"
            );
            return IntegrityResult::NoChecksum;
        }
    };

    match sha256_hex(path) {
        Ok(actual) => {
            if actual.eq_ignore_ascii_case(expected) {
                info!(
                    path = %path.display(),
                    "model integrity: checksum ok"
                );
                IntegrityResult::Ok
            } else {
                warn!(
                    path = %path.display(),
                    expected,
                    actual = %actual,
                    "model integrity: checksum mismatch — file corrupt"
                );
                IntegrityResult::Corrupt
            }
        }
        Err(e) => {
            warn!(
                path = %path.display(),
                error = %e,
                "model integrity: failed to read file for checksum"
            );
            IntegrityResult::Corrupt
        }
    }
}

/// Compute the SHA-256 hex digest of a file's contents.
///
/// Reads the file in 64 KiB chunks to avoid loading large model files into
/// memory all at once.
fn sha256_hex(path: &Path) -> io::Result<String> {
    let mut file = std::fs::File::open(path)?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 65_536];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    let digest = hasher.finalize();
    Ok(format!("{digest:x}"))
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    fn write_temp(content: &[u8]) -> NamedTempFile {
        let mut f = NamedTempFile::new().expect("create temp file");
        f.write_all(content).expect("write content");
        f
    }

    #[test]
    fn missing_file_returns_missing() {
        let result = verify(Path::new("/nonexistent/path/model.gguf"), None);
        assert_eq!(result, IntegrityResult::Missing);
    }

    #[test]
    fn no_checksum_returns_no_checksum() {
        let f = write_temp(b"model data");
        let result = verify(f.path(), None);
        assert_eq!(result, IntegrityResult::NoChecksum);
    }

    #[test]
    fn correct_checksum_returns_ok() {
        let content = b"fae model data test";
        let f = write_temp(content);

        // Compute expected hash.
        let mut hasher = Sha256::new();
        hasher.update(content);
        let expected = format!("{:x}", hasher.finalize());

        let result = verify(f.path(), Some(&expected));
        assert_eq!(result, IntegrityResult::Ok);
    }

    #[test]
    fn wrong_checksum_returns_corrupt() {
        let f = write_temp(b"model data");
        let result = verify(
            f.path(),
            Some("deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"),
        );
        assert_eq!(result, IntegrityResult::Corrupt);
    }

    #[test]
    fn case_insensitive_checksum_comparison() {
        let content = b"case test";
        let f = write_temp(content);

        let mut hasher = Sha256::new();
        hasher.update(content);
        let lower = format!("{:x}", hasher.finalize());
        let upper = lower.to_uppercase();

        // Both lowercase and uppercase should succeed.
        assert_eq!(verify(f.path(), Some(&lower)), IntegrityResult::Ok);
        assert_eq!(verify(f.path(), Some(&upper)), IntegrityResult::Ok);
    }

    #[test]
    fn integrity_result_display() {
        assert_eq!(IntegrityResult::Ok.to_string(), "ok");
        assert_eq!(IntegrityResult::Missing.to_string(), "missing");
        assert_eq!(IntegrityResult::Corrupt.to_string(), "corrupt");
        assert_eq!(IntegrityResult::NoChecksum.to_string(), "no_checksum");
    }
}
