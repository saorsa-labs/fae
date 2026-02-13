//! Read tool — reads file contents with pagination and bounded output.

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;
use std::path::PathBuf;

use super::path_validation::{resolve_workspace_root, validate_read_path_in_workspace};
use super::types::{DEFAULT_MAX_BYTES, Tool, ToolResult, truncate_output};

/// Tool that reads file contents with optional line-based pagination.
///
/// Arguments (JSON):
/// - `path` (string, required) — file path to read
/// - `offset` (integer, optional) — starting line number (1-based, default 1)
/// - `limit` (integer, optional) — maximum number of lines to return
pub struct ReadTool {
    max_bytes: usize,
    workspace_root: PathBuf,
}

impl ReadTool {
    /// Create a new ReadTool with the default max output size.
    pub fn new() -> Self {
        Self {
            max_bytes: DEFAULT_MAX_BYTES,
            workspace_root: resolve_workspace_root().unwrap_or_else(|_| PathBuf::from(".")),
        }
    }

    /// Create a new ReadTool with a custom max output size.
    pub fn with_max_bytes(max_bytes: usize) -> Self {
        Self {
            max_bytes,
            workspace_root: resolve_workspace_root().unwrap_or_else(|_| PathBuf::from(".")),
        }
    }

    /// Create a new ReadTool rooted at a specific workspace path.
    pub fn with_workspace_root(workspace_root: PathBuf) -> Self {
        Self {
            max_bytes: DEFAULT_MAX_BYTES,
            workspace_root,
        }
    }

    /// Create a new ReadTool with custom max bytes and workspace root.
    pub fn with_config(max_bytes: usize, workspace_root: PathBuf) -> Self {
        Self {
            max_bytes,
            workspace_root,
        }
    }
}

impl Default for ReadTool {
    fn default() -> Self {
        Self::new()
    }
}

impl Tool for ReadTool {
    fn name(&self) -> &str {
        "read"
    }

    fn description(&self) -> &str {
        "Read file contents with optional line offset and limit"
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "File path to read"
                },
                "offset": {
                    "type": "integer",
                    "description": "Starting line number (1-based, default 1)"
                },
                "limit": {
                    "type": "integer",
                    "description": "Maximum number of lines to return"
                }
            },
            "required": ["path"]
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let path_str = args.get("path").and_then(|v| v.as_str()).ok_or_else(|| {
            FaeLlmError::ToolValidationError("missing required argument: path".into())
        })?;

        let path = validate_read_path_in_workspace(path_str, &self.workspace_root)?;

        let offset = args
            .get("offset")
            .and_then(|v| v.as_u64())
            .map(|v| v.max(1) as usize)
            .unwrap_or(1);

        let limit = args
            .get("limit")
            .and_then(|v| v.as_u64())
            .map(|v| v as usize);

        // Read file
        let content = match std::fs::read_to_string(&path) {
            Ok(c) => c,
            Err(e) => {
                return Ok(ToolResult::failure(format!(
                    "failed to read {}: {e}",
                    path.display()
                )));
            }
        };

        // Apply line-based pagination
        let lines: Vec<&str> = content.lines().collect();
        let start = offset.saturating_sub(1); // Convert 1-based to 0-based
        let end = match limit {
            Some(lim) => (start + lim).min(lines.len()),
            None => lines.len(),
        };

        if start >= lines.len() {
            return Ok(ToolResult::success(String::new()));
        }

        let output = lines[start..end].join("\n");

        // Apply truncation
        let (truncated_output, was_truncated) = truncate_output(&output, self.max_bytes);
        if was_truncated {
            Ok(ToolResult::success_truncated(truncated_output))
        } else {
            Ok(ToolResult::success(truncated_output))
        }
    }

    fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
        true // read is allowed in both modes
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn make_workspace_file(content: &str) -> (tempfile::TempDir, PathBuf) {
        use std::io::Write;
        let workspace = tempfile::tempdir()
            .unwrap_or_else(|_| unreachable!("tempdir creation should not fail"));
        let file_path = workspace.path().join("test.txt");
        let mut file = std::fs::File::create(&file_path)
            .unwrap_or_else(|_| unreachable!("file creation should not fail"));
        let _ = file.write_all(content.as_bytes());
        (workspace, file_path)
    }

    #[test]
    fn read_entire_file() {
        let (workspace, file) = make_workspace_file("line 1\nline 2\nline 3");
        let tool = ReadTool::with_workspace_root(workspace.path().to_path_buf());
        let result = tool.execute(serde_json::json!({"path": file.to_str()}));
        assert!(result.is_ok());
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("read should succeed"),
        };
        assert!(result.success);
        assert_eq!(result.content, "line 1\nline 2\nline 3");
        assert!(!result.truncated);
    }

    #[test]
    fn read_with_offset() {
        let (workspace, file) = make_workspace_file("line 1\nline 2\nline 3\nline 4");
        let tool = ReadTool::with_workspace_root(workspace.path().to_path_buf());
        let result = tool.execute(serde_json::json!({"path": file.to_str(), "offset": 2}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("read should succeed"),
        };
        assert!(result.success);
        assert_eq!(result.content, "line 2\nline 3\nline 4");
    }

    #[test]
    fn read_with_offset_and_limit() {
        let (workspace, file) = make_workspace_file("line 1\nline 2\nline 3\nline 4\nline 5");
        let tool = ReadTool::with_workspace_root(workspace.path().to_path_buf());
        let result =
            tool.execute(serde_json::json!({"path": file.to_str(), "offset": 2, "limit": 2}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("read should succeed"),
        };
        assert!(result.success);
        assert_eq!(result.content, "line 2\nline 3");
    }

    #[test]
    fn read_offset_beyond_end() {
        let (workspace, file) = make_workspace_file("line 1\nline 2");
        let tool = ReadTool::with_workspace_root(workspace.path().to_path_buf());
        let result = tool.execute(serde_json::json!({"path": file.to_str(), "offset": 100}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("read should succeed"),
        };
        assert!(result.success);
        assert!(result.content.is_empty());
    }

    #[test]
    fn read_nonexistent_file() {
        let workspace = tempfile::tempdir()
            .unwrap_or_else(|_| unreachable!("tempdir creation should not fail"));
        let tool = ReadTool::with_workspace_root(workspace.path().to_path_buf());
        let missing = workspace.path().join("nonexistent.txt");
        let result = tool.execute(serde_json::json!({"path": missing.to_str()}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("read should return ToolResult, not Err"),
        };
        assert!(!result.success);
        assert!(result.error.is_some());
    }

    #[test]
    fn read_missing_path_argument() {
        let tool = ReadTool::new();
        let result = tool.execute(serde_json::json!({}));
        assert!(result.is_err());
    }

    #[test]
    fn read_truncates_large_output() {
        let large_content = "x".repeat(200);
        let (workspace, file) = make_workspace_file(&large_content);
        let tool = ReadTool::with_config(50, workspace.path().to_path_buf());
        let result = tool.execute(serde_json::json!({"path": file.to_str()}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("read should succeed"),
        };
        assert!(result.success);
        assert!(result.truncated);
        assert!(result.content.contains("[output truncated"));
    }

    #[test]
    fn read_path_traversal_rejected() {
        let tool = ReadTool::new();
        let result = tool.execute(serde_json::json!({"path": "../../../etc/passwd"}));
        assert!(result.is_err());
    }

    #[test]
    fn read_allowed_in_both_modes() {
        let tool = ReadTool::new();
        assert!(tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn read_schema_has_required_path() {
        let tool = ReadTool::new();
        let schema = tool.schema();
        let required = schema.get("required").and_then(|v| v.as_array());
        assert!(required.is_some());
        let required = match required {
            Some(r) => r,
            None => unreachable!("schema should have required"),
        };
        assert!(required.iter().any(|v| v.as_str() == Some("path")));
    }
}
