//! Path validation utilities for tool security.
//!
//! Prevents directory traversal attacks and writes to system directories.

use crate::fae_llm::error::FaeLlmError;
use std::path::{Path, PathBuf};

/// System directories that tools must never write to.
///
/// Note: `/var` is excluded because macOS temp dirs live at `/var/folders/...`.
/// Specific `/var` subdirectories like `/var/log` could be added if needed.
const SYSTEM_DIRS: &[&str] = &[
    "/bin",
    "/sbin",
    "/usr/bin",
    "/usr/sbin",
    "/usr/lib",
    "/usr/local/bin",
    "/usr/local/sbin",
    "/etc",
    "/System",
    "/Library/System",
    "/proc",
    "/sys",
    "/dev",
    "/boot",
];

/// Check if a path contains traversal sequences that could escape a sandbox.
///
/// Returns `false` for paths containing `..` components.
pub fn is_path_safe(path: &str) -> bool {
    let p = Path::new(path);
    for component in p.components() {
        if let std::path::Component::ParentDir = component {
            return false;
        }
    }
    true
}

/// Check if a path is in a restricted system directory.
pub fn is_system_path(path: &Path) -> bool {
    let path_str = path.to_string_lossy();
    SYSTEM_DIRS
        .iter()
        .any(|dir| path_str.starts_with(dir) || path_str == *dir)
}

/// Validate a path is safe for reading.
///
/// Accepts both relative and absolute paths, but rejects paths with
/// `..` traversal components.
///
/// # Errors
///
/// Returns `FaeLlmError::ToolValidationError` if the path is invalid.
pub fn validate_read_path(path: &str) -> Result<PathBuf, FaeLlmError> {
    if path.is_empty() {
        return Err(FaeLlmError::ToolValidationError("path is empty".into()));
    }

    if !is_path_safe(path) {
        return Err(FaeLlmError::ToolValidationError(format!(
            "path contains directory traversal: {path}"
        )));
    }

    Ok(PathBuf::from(path))
}

/// Validate a path is safe for writing.
///
/// In addition to the read path checks, also rejects system directories.
///
/// # Errors
///
/// Returns `FaeLlmError::ToolValidationError` if the path is unsafe for writing.
pub fn validate_write_path(path: &str) -> Result<PathBuf, FaeLlmError> {
    let path_buf = validate_read_path(path)?;

    // For absolute paths, check system directories
    if path_buf.is_absolute() && is_system_path(&path_buf) {
        return Err(FaeLlmError::ToolValidationError(format!(
            "cannot write to system directory: {path}"
        )));
    }

    Ok(path_buf)
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── is_path_safe ──────────────────────────────────────────

    #[test]
    fn safe_relative_path() {
        assert!(is_path_safe("src/main.rs"));
    }

    #[test]
    fn safe_nested_path() {
        assert!(is_path_safe("src/fae_llm/tools/read.rs"));
    }

    #[test]
    fn safe_absolute_path() {
        assert!(is_path_safe("/home/user/project/src/main.rs"));
    }

    #[test]
    fn unsafe_parent_traversal() {
        assert!(!is_path_safe("../secret.txt"));
    }

    #[test]
    fn unsafe_nested_traversal() {
        assert!(!is_path_safe("src/../../etc/passwd"));
    }

    #[test]
    fn safe_empty_path() {
        assert!(is_path_safe(""));
    }

    #[test]
    fn safe_current_dir() {
        assert!(is_path_safe("./src/main.rs"));
    }

    // ── is_system_path ────────────────────────────────────────

    #[test]
    fn system_path_etc() {
        assert!(is_system_path(Path::new("/etc/passwd")));
    }

    #[test]
    fn system_path_usr_bin() {
        assert!(is_system_path(Path::new("/usr/bin/ls")));
    }

    #[test]
    fn system_path_bin() {
        assert!(is_system_path(Path::new("/bin/sh")));
    }

    #[test]
    fn system_path_dev() {
        assert!(is_system_path(Path::new("/dev/null")));
    }

    #[test]
    fn system_path_macos_system() {
        assert!(is_system_path(Path::new("/System/Library/Frameworks")));
    }

    #[test]
    fn not_system_path_home() {
        assert!(!is_system_path(Path::new("/home/user/project")));
    }

    #[test]
    fn not_system_path_tmp() {
        assert!(!is_system_path(Path::new("/tmp/test.txt")));
    }

    #[test]
    fn not_system_path_users() {
        assert!(!is_system_path(Path::new("/Users/davidirvine/project")));
    }

    // ── validate_read_path ────────────────────────────────────

    #[test]
    fn read_path_accepts_relative() {
        let result = validate_read_path("src/main.rs");
        assert!(result.is_ok());
        assert_eq!(result.unwrap_or_default(), PathBuf::from("src/main.rs"));
    }

    #[test]
    fn read_path_accepts_absolute() {
        let result = validate_read_path("/home/user/file.txt");
        assert!(result.is_ok());
    }

    #[test]
    fn read_path_rejects_traversal() {
        let result = validate_read_path("../secret.txt");
        assert!(result.is_err());
    }

    #[test]
    fn read_path_rejects_nested_traversal() {
        let result = validate_read_path("src/../../etc/passwd");
        assert!(result.is_err());
    }

    #[test]
    fn read_path_rejects_empty() {
        let result = validate_read_path("");
        assert!(result.is_err());
    }

    // ── validate_write_path ───────────────────────────────────

    #[test]
    fn write_path_accepts_relative() {
        let result = validate_write_path("src/main.rs");
        assert!(result.is_ok());
    }

    #[test]
    fn write_path_accepts_user_directory() {
        let result = validate_write_path("/Users/user/project/file.txt");
        assert!(result.is_ok());
    }

    #[test]
    fn write_path_accepts_tmp() {
        let result = validate_write_path("/tmp/test.txt");
        assert!(result.is_ok());
    }

    #[test]
    fn write_path_rejects_etc() {
        let result = validate_write_path("/etc/passwd");
        assert!(result.is_err());
    }

    #[test]
    fn write_path_rejects_usr_bin() {
        let result = validate_write_path("/usr/bin/malicious");
        assert!(result.is_err());
    }

    #[test]
    fn write_path_rejects_system() {
        let result = validate_write_path("/System/Library/evil");
        assert!(result.is_err());
    }

    #[test]
    fn write_path_rejects_traversal() {
        let result = validate_write_path("../etc/passwd");
        assert!(result.is_err());
    }
}
