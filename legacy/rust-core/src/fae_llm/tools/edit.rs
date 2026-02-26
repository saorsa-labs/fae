//! Edit tool — deterministic text edits via find/replace.

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;
use std::fs::OpenOptions;
use std::io::{Read as _, Seek as _, Write as _};
use std::path::PathBuf;

use super::path_validation::{resolve_workspace_root, validate_write_path_in_workspace};
use super::types::{DEFAULT_MAX_BYTES, Tool, ToolResult};

/// Tool that performs deterministic text edits by replacing `old_string`
/// with `new_string` in a file.
///
/// Arguments (JSON):
/// - `path` (string, required) — file path to edit
/// - `old_string` (string, required) — exact text to find (must be unique in file)
/// - `new_string` (string, required) — replacement text
///
/// Only available in `ToolMode::Full`.
pub struct EditTool {
    max_bytes: usize,
    workspace_root: PathBuf,
}

impl EditTool {
    /// Create a new EditTool with the default max file size.
    pub fn new() -> Self {
        Self {
            max_bytes: DEFAULT_MAX_BYTES,
            workspace_root: resolve_workspace_root().unwrap_or_else(|_| PathBuf::from(".")),
        }
    }

    /// Create a new EditTool with a custom max file size.
    pub fn with_max_bytes(max_bytes: usize) -> Self {
        Self {
            max_bytes,
            workspace_root: resolve_workspace_root().unwrap_or_else(|_| PathBuf::from(".")),
        }
    }

    /// Create a new EditTool rooted at a specific workspace path.
    pub fn with_workspace_root(workspace_root: PathBuf) -> Self {
        Self {
            max_bytes: DEFAULT_MAX_BYTES,
            workspace_root,
        }
    }

    /// Create a new EditTool with custom max bytes and workspace root.
    pub fn with_config(max_bytes: usize, workspace_root: PathBuf) -> Self {
        Self {
            max_bytes,
            workspace_root,
        }
    }
}

impl Default for EditTool {
    fn default() -> Self {
        Self::new()
    }
}

impl Tool for EditTool {
    fn name(&self) -> &str {
        "edit"
    }

    fn description(&self) -> &str {
        "Edit a file by replacing an exact string match"
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "File path to edit"
                },
                "old_string": {
                    "type": "string",
                    "description": "Exact text to find (must be unique in the file)"
                },
                "new_string": {
                    "type": "string",
                    "description": "Replacement text"
                }
            },
            "required": ["path", "old_string", "new_string"]
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let path_str = args.get("path").and_then(|v| v.as_str()).ok_or_else(|| {
            FaeLlmError::ToolValidationError("missing required argument: path".into())
        })?;

        let old_string = args
            .get("old_string")
            .and_then(|v| v.as_str())
            .ok_or_else(|| {
                FaeLlmError::ToolValidationError("missing required argument: old_string".into())
            })?;

        let new_string = args
            .get("new_string")
            .and_then(|v| v.as_str())
            .ok_or_else(|| {
                FaeLlmError::ToolValidationError("missing required argument: new_string".into())
            })?;

        let path = validate_write_path_in_workspace(path_str, &self.workspace_root)?;

        let path = match canonicalize_for_mutation(&path, &self.workspace_root) {
            Ok(path) => path,
            Err(message) => return Ok(ToolResult::failure(message)),
        };

        let mut file = match open_existing_rw_nofollow(&path) {
            Ok(file) => file,
            Err(e) => {
                return Ok(ToolResult::failure(format!(
                    "failed to read {}: {e}",
                    path.display()
                )));
            }
        };

        // Read existing file from the opened descriptor so content and writeback
        // apply to the same inode.
        let mut content = String::new();
        if let Err(e) = file.read_to_string(&mut content) {
            return Ok(ToolResult::failure(format!(
                "failed to read {}: {e}",
                path.display()
            )));
        }

        // Check file size
        if content.len() > self.max_bytes {
            return Ok(ToolResult::failure(format!(
                "file exceeds max size ({} bytes > {} bytes)",
                content.len(),
                self.max_bytes
            )));
        }

        // Check that old_string exists and is unique
        let match_count = content.matches(old_string).count();
        if match_count == 0 {
            return Ok(ToolResult::failure(format!(
                "old_string not found in {}",
                path.display()
            )));
        }
        if match_count > 1 {
            return Ok(ToolResult::failure(format!(
                "old_string has {match_count} matches in {} (must be unique)",
                path.display()
            )));
        }

        // Perform replacement
        let new_content = content.replacen(old_string, new_string, 1);

        // Rewrite in place through the same opened descriptor.
        if let Err(e) = file.set_len(0) {
            return Ok(ToolResult::failure(format!(
                "failed to write {}: {e}",
                path.display()
            )));
        }
        if let Err(e) = file.rewind() {
            return Ok(ToolResult::failure(format!(
                "failed to write {}: {e}",
                path.display()
            )));
        }
        if let Err(e) = file.write_all(new_content.as_bytes()) {
            return Ok(ToolResult::failure(format!(
                "failed to write {}: {e}",
                path.display()
            )));
        }
        if let Err(e) = file.sync_all() {
            return Ok(ToolResult::failure(format!(
                "failed to write {}: {e}",
                path.display()
            )));
        }

        Ok(ToolResult::success(format!(
            "edited {}: replaced {} bytes with {} bytes",
            path.display(),
            old_string.len(),
            new_string.len()
        )))
    }

    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        mode == ToolMode::Full
    }
}

fn canonicalize_for_mutation(
    path: &std::path::Path,
    workspace_root: &std::path::Path,
) -> Result<PathBuf, String> {
    let root = workspace_root
        .canonicalize()
        .map_err(|e| format!("invalid workspace root: {e}"))?;
    let parent = path
        .parent()
        .ok_or_else(|| "path has no parent directory".to_string())?;
    let canonical_parent = parent
        .canonicalize()
        .map_err(|e| format!("failed to resolve path parent: {e}"))?;
    if !canonical_parent.starts_with(&root) {
        return Err("path parent escapes workspace boundary".to_string());
    }
    let file_name = path
        .file_name()
        .ok_or_else(|| "path has no filename".to_string())?;
    Ok(canonical_parent.join(file_name))
}

fn open_existing_rw_nofollow(path: &std::path::Path) -> std::io::Result<std::fs::File> {
    let mut options = OpenOptions::new();
    options.read(true).write(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW);
    }
    options.open(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn make_test_file(content: &str) -> (tempfile::TempDir, PathBuf) {
        let dir = tempfile::tempdir()
            .unwrap_or_else(|_| unreachable!("tempdir creation should not fail"));
        let path = dir.path().join("test_edit.txt");
        let mut file = std::fs::File::create(&path)
            .unwrap_or_else(|_| unreachable!("file creation should not fail"));
        let _ = file.write_all(content.as_bytes());
        let _ = file.flush();
        (dir, path)
    }

    #[test]
    fn edit_replace_text() {
        let (workspace, file) = make_test_file("hello world");
        let tool = EditTool::with_workspace_root(workspace.path().to_path_buf());
        let result = tool.execute(serde_json::json!({
            "path": file.to_str(),
            "old_string": "world",
            "new_string": "rust"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("edit should succeed"),
        };
        assert!(result.success);
        let content = std::fs::read_to_string(file).unwrap_or_default();
        assert_eq!(content, "hello rust");
    }

    #[test]
    fn edit_multiline_replacement() {
        let (workspace, file) = make_test_file("line 1\nline 2\nline 3\n");
        let tool = EditTool::with_workspace_root(workspace.path().to_path_buf());
        let result = tool.execute(serde_json::json!({
            "path": file.to_str(),
            "old_string": "line 2",
            "new_string": "replaced line"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("edit should succeed"),
        };
        assert!(result.success);
        let content = std::fs::read_to_string(file).unwrap_or_default();
        assert_eq!(content, "line 1\nreplaced line\nline 3\n");
    }

    #[test]
    fn edit_old_string_not_found() {
        let (workspace, file) = make_test_file("hello world");
        let tool = EditTool::with_workspace_root(workspace.path().to_path_buf());
        let result = tool.execute(serde_json::json!({
            "path": file.to_str(),
            "old_string": "nonexistent",
            "new_string": "replacement"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return ToolResult"),
        };
        assert!(!result.success);
        assert!(
            result
                .error
                .as_ref()
                .is_some_and(|e| e.contains("not found"))
        );
    }

    #[test]
    fn edit_multiple_matches_rejected() {
        let (workspace, file) = make_test_file("foo bar foo baz");
        let tool = EditTool::with_workspace_root(workspace.path().to_path_buf());
        let result = tool.execute(serde_json::json!({
            "path": file.to_str(),
            "old_string": "foo",
            "new_string": "qux"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return ToolResult"),
        };
        assert!(!result.success);
        assert!(
            result
                .error
                .as_ref()
                .is_some_and(|e| e.contains("2 matches"))
        );
    }

    #[test]
    fn edit_nonexistent_file() {
        let workspace = tempfile::tempdir()
            .unwrap_or_else(|_| unreachable!("tempdir creation should not fail"));
        let tool = EditTool::with_workspace_root(workspace.path().to_path_buf());
        let missing = workspace.path().join("missing.txt");
        let result = tool.execute(serde_json::json!({
            "path": missing.to_str(),
            "old_string": "x",
            "new_string": "y"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return ToolResult"),
        };
        assert!(!result.success);
    }

    #[test]
    fn edit_file_exceeds_max_size() {
        let large = "x".repeat(200);
        let (workspace, file) = make_test_file(&large);
        let tool = EditTool::with_config(100, workspace.path().to_path_buf());
        let result = tool.execute(serde_json::json!({
            "path": file.to_str(),
            "old_string": "x",
            "new_string": "y"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return ToolResult"),
        };
        assert!(!result.success);
        assert!(
            result
                .error
                .as_ref()
                .is_some_and(|e| e.contains("exceeds max size"))
        );
    }

    #[test]
    fn edit_missing_arguments() {
        let tool = EditTool::new();
        assert!(tool.execute(serde_json::json!({})).is_err());
        assert!(tool.execute(serde_json::json!({"path": "x"})).is_err());
        assert!(
            tool.execute(serde_json::json!({"path": "x", "old_string": "y"}))
                .is_err()
        );
    }

    #[test]
    fn edit_only_allowed_in_full_mode() {
        let tool = EditTool::new();
        assert!(!tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn edit_path_traversal_rejected() {
        let workspace = tempfile::tempdir()
            .unwrap_or_else(|_| unreachable!("tempdir creation should not fail"));
        let tool = EditTool::with_workspace_root(workspace.path().to_path_buf());
        let result = tool.execute(serde_json::json!({
            "path": "../../../etc/passwd",
            "old_string": "x",
            "new_string": "y"
        }));
        assert!(result.is_err());
    }

    #[cfg(unix)]
    #[test]
    fn edit_rejects_symlink_target() {
        let workspace = tempfile::tempdir()
            .unwrap_or_else(|_| unreachable!("tempdir creation should not fail"));
        let real = workspace.path().join("real.txt");
        std::fs::write(&real, "hello world").unwrap_or_default();
        let link = workspace.path().join("link.txt");
        std::os::unix::fs::symlink(&real, &link).unwrap_or_else(|_| unreachable!());

        let tool = EditTool::with_workspace_root(workspace.path().to_path_buf());
        let result = tool.execute(serde_json::json!({
            "path": link.to_str(),
            "old_string": "world",
            "new_string": "rust"
        }));
        assert!(result.is_err(), "symlink edits should be rejected");
    }
}
