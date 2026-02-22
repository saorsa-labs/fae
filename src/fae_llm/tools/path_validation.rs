//! Path validation utilities for tool security.
//!
//! Prevents directory traversal attacks, sandbox escapes, and writes to
//! sensitive system directories.

use crate::fae_llm::error::FaeLlmError;
use std::path::{Component, Path, PathBuf};

/// System directories that tools must never write to.
///
/// Note: `/var` is excluded because macOS temp dirs live at `/var/folders/...`.
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

/// Workspace-relative core paths that must remain immutable to tool writes.
///
/// These files implement the runtime kernel / safety boundary. Allowing tools
/// to mutate them can break Fae's ability to recover from self-inflicted damage.
const PROTECTED_KERNEL_FILES: &[&str] = &[
    "src/config.rs",
    "src/runtime.rs",
    "src/ffi.rs",
    "src/permissions.rs",
    "src/approval.rs",
    "src/error.rs",
    "src/llm/mod.rs",
    "src/fae_dirs.rs",
    "src/agent/approval_tool.rs",
    "src/startup.rs",
    "src/model_integrity.rs",
    "src/models/mod.rs",
    "src/scheduler/runner.rs",
    "src/scheduler/authority.rs",
    "src/update/applier.rs",
];

/// Workspace-relative directory prefixes that are treated as protected kernel.
const PROTECTED_KERNEL_PREFIXES: &[&str] = &[
    "src/pipeline/",
    "src/host/",
    "src/memory/",
    "src/credentials/",
    "src/platform/",
    "src/bin/",
];

/// Sanitize a path for inclusion in user-facing error messages.
///
/// Strips the workspace root prefix and replaces with a generic placeholder.
/// This prevents leaking internal filesystem structure to the LLM.
pub fn sanitize_path_for_error(path: &Path, workspace_root: &Path) -> String {
    // Try to strip the workspace root
    if let Ok(root) = workspace_root.canonicalize()
        && let Ok(canonical) = path.canonicalize()
        && let Ok(stripped) = canonical.strip_prefix(&root)
    {
        return format!("<workspace>/{}", stripped.display());
    }

    // Fallback: use just the filename or last component
    path.file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "[path]".to_string())
}

/// Check if a path contains traversal sequences that could escape a sandbox.
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

/// Convert an absolute path within `workspace_root` to a normalized
/// slash-separated workspace-relative form.
fn normalize_workspace_relative_path(path: &Path, workspace_root: &Path) -> Option<String> {
    let relative = path.strip_prefix(workspace_root).ok()?;
    let mut parts = Vec::new();
    for component in relative.components() {
        match component {
            Component::Normal(part) => parts.push(part.to_string_lossy().to_string()),
            Component::CurDir => {}
            _ => return None,
        }
    }
    if parts.is_empty() {
        None
    } else {
        Some(parts.join("/"))
    }
}

/// Return true when `path` points to a protected runtime-kernel target.
fn is_protected_kernel_path(path: &Path, workspace_root: &Path) -> bool {
    let Some(relative) = normalize_workspace_relative_path(path, workspace_root) else {
        return false;
    };

    PROTECTED_KERNEL_FILES
        .iter()
        .any(|p| protected_component_eq(p, &relative))
        || PROTECTED_KERNEL_PREFIXES
            .iter()
            .any(|prefix| protected_component_starts_with(&relative, prefix))
}

#[cfg(target_os = "macos")]
fn protected_component_eq(left: &str, right: &str) -> bool {
    left.eq_ignore_ascii_case(right)
}

#[cfg(not(target_os = "macos"))]
fn protected_component_eq(left: &str, right: &str) -> bool {
    left == right
}

#[cfg(target_os = "macos")]
fn protected_component_starts_with(path: &str, prefix: &str) -> bool {
    let path_bytes = path.as_bytes();
    let prefix_bytes = prefix.as_bytes();
    path_bytes.len() >= prefix_bytes.len()
        && path_bytes[..prefix_bytes.len()].eq_ignore_ascii_case(prefix_bytes)
}

#[cfg(not(target_os = "macos"))]
fn protected_component_starts_with(path: &str, prefix: &str) -> bool {
    path.starts_with(prefix)
}

/// Resolve and canonicalize the current workspace root.
pub fn resolve_workspace_root() -> Result<PathBuf, FaeLlmError> {
    let cwd = std::env::current_dir().map_err(|_e| {
        FaeLlmError::ToolValidationError("failed to resolve working directory".into())
    })?;
    cwd.canonicalize().map_err(|_e| {
        FaeLlmError::ToolValidationError("failed to canonicalize working directory".into())
    })
}

/// Validate a path is safe for reading within the workspace root.
///
/// Returns a canonical absolute path.
pub fn validate_read_path_in_workspace(
    path: &str,
    workspace_root: &Path,
) -> Result<PathBuf, FaeLlmError> {
    if path.is_empty() {
        return Err(FaeLlmError::ToolValidationError("path is empty".into()));
    }

    if !is_path_safe(path) {
        return Err(FaeLlmError::ToolValidationError(
            "path contains directory traversal".into(),
        ));
    }

    let root = match workspace_root.canonicalize() {
        Ok(r) => r,
        Err(_) => {
            return Err(FaeLlmError::ToolValidationError(
                "invalid workspace root".into(),
            ));
        }
    };

    let input_path = PathBuf::from(path);
    let absolute = if input_path.is_absolute() {
        input_path
    } else {
        root.join(input_path)
    };

    if let Some(canonical) = canonical_if_exists(&absolute)? {
        if !canonical.starts_with(&root) {
            let safe_path = sanitize_path_for_error(&canonical, &root);
            return Err(FaeLlmError::ToolValidationError(format!(
                "path escapes workspace boundary: {safe_path}"
            )));
        }
        return Ok(canonical);
    }

    let parent = absolute
        .parent()
        .ok_or_else(|| FaeLlmError::ToolValidationError("path has no parent directory".into()))?;
    let existing_ancestor = first_existing_ancestor(parent)
        .ok_or_else(|| FaeLlmError::ToolValidationError("path parent does not exist".into()))?;
    let canonical_ancestor = match existing_ancestor.canonicalize() {
        Ok(c) => c,
        Err(_) => {
            return Err(FaeLlmError::ToolValidationError(
                "failed to resolve path parent".into(),
            ));
        }
    };
    if !canonical_ancestor.starts_with(&root) {
        let safe_path = sanitize_path_for_error(&canonical_ancestor, &root);
        return Err(FaeLlmError::ToolValidationError(format!(
            "path escapes workspace boundary: {safe_path}"
        )));
    }

    Ok(absolute)
}

/// Validate a path is safe for writing within the workspace root.
///
/// Returns an absolute path suitable for write operations.
pub fn validate_write_path_in_workspace(
    path: &str,
    workspace_root: &Path,
) -> Result<PathBuf, FaeLlmError> {
    if path.is_empty() {
        return Err(FaeLlmError::ToolValidationError("path is empty".into()));
    }

    if !is_path_safe(path) {
        return Err(FaeLlmError::ToolValidationError(
            "path contains directory traversal".into(),
        ));
    }

    let root = match workspace_root.canonicalize() {
        Ok(r) => r,
        Err(_) => {
            return Err(FaeLlmError::ToolValidationError(
                "invalid workspace root".into(),
            ));
        }
    };

    let input_path = PathBuf::from(path);
    let absolute = if input_path.is_absolute() {
        input_path
    } else {
        root.join(input_path)
    };

    if absolute.is_absolute() && is_system_path(&absolute) {
        return Err(FaeLlmError::ToolValidationError(
            "cannot write to system directory".into(),
        ));
    }

    if let Ok(metadata) = std::fs::symlink_metadata(&absolute)
        && metadata.file_type().is_symlink()
    {
        let safe_path = sanitize_path_for_error(&absolute, &root);
        return Err(FaeLlmError::ToolValidationError(format!(
            "cannot write through symlink path: {safe_path}"
        )));
    }

    if is_protected_kernel_path(&absolute, &root) {
        let safe_path = sanitize_path_for_error(&absolute, &root);
        return Err(FaeLlmError::ToolValidationError(format!(
            "cannot write to protected kernel path: {safe_path}"
        )));
    }

    if let Some(existing_target) = canonical_if_exists(&absolute)?
        && (!existing_target.starts_with(&root)
            || is_protected_kernel_path(&existing_target, &root))
    {
        if !existing_target.starts_with(&root) {
            let safe_path = sanitize_path_for_error(&existing_target, &root);
            return Err(FaeLlmError::ToolValidationError(format!(
                "path escapes workspace boundary: {safe_path}"
            )));
        }

        let safe_path = sanitize_path_for_error(&existing_target, &root);
        return Err(FaeLlmError::ToolValidationError(format!(
            "cannot write to protected kernel path: {safe_path}"
        )));
    }

    let parent = absolute
        .parent()
        .ok_or_else(|| FaeLlmError::ToolValidationError("path has no parent directory".into()))?;

    let existing_ancestor = first_existing_ancestor(parent)
        .ok_or_else(|| FaeLlmError::ToolValidationError("path parent does not exist".into()))?;
    let canonical_ancestor = match existing_ancestor.canonicalize() {
        Ok(c) => c,
        Err(_) => {
            return Err(FaeLlmError::ToolValidationError(
                "failed to resolve path parent".into(),
            ));
        }
    };
    if !canonical_ancestor.starts_with(&root) {
        let safe_path = sanitize_path_for_error(&canonical_ancestor, &root);
        return Err(FaeLlmError::ToolValidationError(format!(
            "path parent escapes workspace boundary: {safe_path}"
        )));
    }

    Ok(absolute)
}

/// Validate a path is safe for reading using the process working directory as workspace root.
pub fn validate_read_path(path: &str) -> Result<PathBuf, FaeLlmError> {
    let workspace_root = resolve_workspace_root()?;
    validate_read_path_in_workspace(path, &workspace_root)
}

/// Validate a path is safe for writing using the process working directory as workspace root.
pub fn validate_write_path(path: &str) -> Result<PathBuf, FaeLlmError> {
    let workspace_root = resolve_workspace_root()?;
    validate_write_path_in_workspace(path, &workspace_root)
}

fn canonical_if_exists(path: &Path) -> Result<Option<PathBuf>, FaeLlmError> {
    if path.exists() {
        let canonical = path.canonicalize().map_err(|e| {
            FaeLlmError::ToolValidationError(format!(
                "failed to canonicalize path {}: {e}",
                path.display()
            ))
        })?;
        Ok(Some(canonical))
    } else {
        Ok(None)
    }
}

fn first_existing_ancestor(path: &Path) -> Option<&Path> {
    path.ancestors().find(|p| p.exists())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn setup_workspace() -> tempfile::TempDir {
        tempfile::tempdir().unwrap_or_else(|_| unreachable!("tempdir creation should not fail"))
    }

    fn write_file(path: &Path, contents: &str) {
        let mut file =
            std::fs::File::create(path).unwrap_or_else(|_| unreachable!("create should succeed"));
        file.write_all(contents.as_bytes())
            .unwrap_or_else(|_| unreachable!("write should succeed"));
    }

    #[test]
    fn safe_relative_path() {
        assert!(is_path_safe("src/main.rs"));
    }

    #[test]
    fn unsafe_parent_traversal() {
        assert!(!is_path_safe("../secret.txt"));
    }

    #[test]
    fn system_path_etc() {
        assert!(is_system_path(Path::new("/etc/passwd")));
    }

    #[test]
    fn not_system_path_tmp() {
        assert!(!is_system_path(Path::new("/tmp/test.txt")));
    }

    #[test]
    fn read_path_accepts_path_within_workspace() {
        let workspace = setup_workspace();
        let file = workspace.path().join("in_workspace.txt");
        write_file(&file, "ok");
        let canonical_workspace = workspace
            .path()
            .canonicalize()
            .unwrap_or_else(|_| unreachable!());

        let result = validate_read_path_in_workspace("in_workspace.txt", workspace.path());
        assert!(result.is_ok());
        let resolved = result.unwrap_or_else(|_| unreachable!());
        assert!(resolved.starts_with(&canonical_workspace));
    }

    #[test]
    fn read_path_rejects_escape_outside_workspace() {
        let workspace = setup_workspace();
        let outside = tempfile::NamedTempFile::new()
            .unwrap_or_else(|_| unreachable!("tempfile should succeed"));

        let result = validate_read_path_in_workspace(
            outside.path().to_str().unwrap_or(""),
            workspace.path(),
        );
        assert!(result.is_err());
    }

    #[test]
    fn read_path_rejects_traversal() {
        let workspace = setup_workspace();
        let result = validate_read_path_in_workspace("../secret.txt", workspace.path());
        assert!(result.is_err());
    }

    #[test]
    fn write_path_accepts_relative_in_workspace() {
        let workspace = setup_workspace();
        let canonical_workspace = workspace
            .path()
            .canonicalize()
            .unwrap_or_else(|_| unreachable!());
        let result = validate_write_path_in_workspace("new_file.txt", workspace.path());
        assert!(result.is_ok());
        let resolved = result.unwrap_or_else(|_| unreachable!());
        assert!(resolved.starts_with(&canonical_workspace));
    }

    #[test]
    fn write_path_rejects_system_path() {
        let workspace = setup_workspace();
        let result = validate_write_path_in_workspace("/etc/passwd", workspace.path());
        assert!(result.is_err());
    }

    #[test]
    fn write_path_rejects_parent_escape() {
        let workspace = setup_workspace();
        let result = validate_write_path_in_workspace("../escape.txt", workspace.path());
        assert!(result.is_err());
    }

    #[test]
    fn write_path_rejects_outside_workspace_absolute_path() {
        let workspace = setup_workspace();
        let outside = tempfile::NamedTempFile::new()
            .unwrap_or_else(|_| unreachable!("tempfile should succeed"));
        let result = validate_write_path_in_workspace(
            outside.path().to_str().unwrap_or(""),
            workspace.path(),
        );
        assert!(result.is_err());
    }

    #[test]
    fn write_path_rejects_protected_kernel_targets() {
        let workspace = setup_workspace();
        let protected = workspace.path().join("src/pipeline/coordinator.rs");
        let parent = protected.parent().unwrap_or_else(|| unreachable!("parent"));
        std::fs::create_dir_all(parent).unwrap_or_else(|_| unreachable!("mkdir should succeed"));
        write_file(&protected, "kernel");

        let result =
            validate_write_path_in_workspace(protected.to_str().unwrap_or(""), workspace.path());
        assert!(result.is_err(), "protected kernel path should be rejected");
    }

    #[test]
    fn write_path_rejects_full_protected_kernel_surface() {
        let workspace = setup_workspace();
        let protected_rel_paths = [
            "src/ffi.rs",
            "src/permissions.rs",
            "src/approval.rs",
            "src/error.rs",
            "src/llm/mod.rs",
            "src/fae_dirs.rs",
            "src/agent/approval_tool.rs",
            "src/runtime.rs",
            "src/config.rs",
            "src/startup.rs",
            "src/model_integrity.rs",
            "src/models/mod.rs",
            "src/scheduler/runner.rs",
            "src/scheduler/authority.rs",
            "src/update/applier.rs",
            "src/memory/sqlite.rs",
            "src/credentials/manager.rs",
            "src/platform/macos.rs",
            "src/bin/host_bridge.rs",
        ];

        for rel in protected_rel_paths {
            let path = workspace.path().join(rel);
            if let Some(parent) = path.parent() {
                std::fs::create_dir_all(parent)
                    .unwrap_or_else(|_| unreachable!("mkdir should succeed"));
            }
            write_file(&path, "kernel");

            let result =
                validate_write_path_in_workspace(path.to_str().unwrap_or(""), workspace.path());
            assert!(
                result.is_err(),
                "expected protected path to be rejected: {rel}"
            );
        }
    }

    #[test]
    fn write_path_rejects_parent_dir_traversal_into_protected_kernel() {
        let workspace = setup_workspace();
        let via_parent = "src/other/../pipeline/new.rs";
        let result = validate_write_path_in_workspace(via_parent, workspace.path());
        assert!(
            result.is_err(),
            "path with parent-dir traversal should be rejected"
        );
    }

    #[test]
    fn write_path_rejects_absolute_parent_dir_traversal() {
        let workspace = setup_workspace();
        let absolute = workspace.path().join("src/other/../pipeline/new.rs");
        let result =
            validate_write_path_in_workspace(absolute.to_str().unwrap_or(""), workspace.path());
        assert!(
            result.is_err(),
            "absolute path with parent-dir traversal should be rejected"
        );
    }

    #[cfg(unix)]
    #[test]
    fn write_path_rejects_symlink_target() {
        let workspace = setup_workspace();
        let real = workspace.path().join("real.txt");
        write_file(&real, "ok");
        let link = workspace.path().join("link.txt");
        std::os::unix::fs::symlink(&real, &link).unwrap_or_else(|_| unreachable!());

        let result =
            validate_write_path_in_workspace(link.to_str().unwrap_or(""), workspace.path());
        assert!(result.is_err(), "symlink target should be rejected");
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn write_path_rejects_case_variant_of_protected_kernel_path() {
        let workspace = setup_workspace();
        let protected = workspace.path().join("SRC/PIPELINE/CoOrDiNaToR.rs");
        let parent = protected.parent().unwrap_or_else(|| unreachable!("parent"));
        std::fs::create_dir_all(parent).unwrap_or_else(|_| unreachable!("mkdir should succeed"));
        write_file(&protected, "kernel");

        let result =
            validate_write_path_in_workspace(protected.to_str().unwrap_or(""), workspace.path());
        assert!(
            result.is_err(),
            "case-variant protected kernel path should be rejected on macOS"
        );
    }
}
