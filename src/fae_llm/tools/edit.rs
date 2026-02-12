//! Edit tool — deterministic text edits via find/replace.

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;

use super::path_validation::validate_write_path;
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
}

impl EditTool {
    /// Create a new EditTool with the default max file size.
    pub fn new() -> Self {
        Self {
            max_bytes: DEFAULT_MAX_BYTES,
        }
    }

    /// Create a new EditTool with a custom max file size.
    pub fn with_max_bytes(max_bytes: usize) -> Self {
        Self { max_bytes }
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
        let path_str = args
            .get("path")
            .and_then(|v| v.as_str())
            .ok_or_else(|| FaeLlmError::ToolError("missing required argument: path".into()))?;

        let old_string = args
            .get("old_string")
            .and_then(|v| v.as_str())
            .ok_or_else(|| {
                FaeLlmError::ToolError("missing required argument: old_string".into())
            })?;

        let new_string = args
            .get("new_string")
            .and_then(|v| v.as_str())
            .ok_or_else(|| {
                FaeLlmError::ToolError("missing required argument: new_string".into())
            })?;

        let path = validate_write_path(path_str)?;

        // Read existing file
        let content = match std::fs::read_to_string(&path) {
            Ok(c) => c,
            Err(e) => {
                return Ok(ToolResult::failure(format!(
                    "failed to read {}: {e}",
                    path.display()
                )));
            }
        };

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

        // Write back
        if let Err(e) = std::fs::write(&path, &new_content) {
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn make_test_file(content: &str) -> tempfile::NamedTempFile {
        let mut file = match tempfile::NamedTempFile::new() {
            Ok(f) => f,
            Err(_) => unreachable!("tempfile creation should not fail"),
        };
        let _ = file.write_all(content.as_bytes());
        let _ = file.flush();
        file
    }

    #[test]
    fn edit_replace_text() {
        let file = make_test_file("hello world");
        let tool = EditTool::new();
        let result = tool.execute(serde_json::json!({
            "path": file.path().to_str(),
            "old_string": "world",
            "new_string": "rust"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("edit should succeed"),
        };
        assert!(result.success);
        let content = std::fs::read_to_string(file.path()).unwrap_or_default();
        assert_eq!(content, "hello rust");
    }

    #[test]
    fn edit_multiline_replacement() {
        let file = make_test_file("line 1\nline 2\nline 3\n");
        let tool = EditTool::new();
        let result = tool.execute(serde_json::json!({
            "path": file.path().to_str(),
            "old_string": "line 2",
            "new_string": "replaced line"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("edit should succeed"),
        };
        assert!(result.success);
        let content = std::fs::read_to_string(file.path()).unwrap_or_default();
        assert_eq!(content, "line 1\nreplaced line\nline 3\n");
    }

    #[test]
    fn edit_old_string_not_found() {
        let file = make_test_file("hello world");
        let tool = EditTool::new();
        let result = tool.execute(serde_json::json!({
            "path": file.path().to_str(),
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
        let file = make_test_file("foo bar foo baz");
        let tool = EditTool::new();
        let result = tool.execute(serde_json::json!({
            "path": file.path().to_str(),
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
        let tool = EditTool::new();
        let result = tool.execute(serde_json::json!({
            "path": "/tmp/nonexistent_fae_edit_test.txt",
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
        let file = make_test_file(&large);
        let tool = EditTool::with_max_bytes(100);
        let result = tool.execute(serde_json::json!({
            "path": file.path().to_str(),
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
        let tool = EditTool::new();
        let result = tool.execute(serde_json::json!({
            "path": "../../../etc/passwd",
            "old_string": "x",
            "new_string": "y"
        }));
        assert!(result.is_err());
    }
}
