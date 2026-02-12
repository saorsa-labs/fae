//! Write tool — creates or overwrites files with path validation.

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;

use super::path_validation::validate_write_path;
use super::types::{DEFAULT_MAX_BYTES, Tool, ToolResult};

/// Tool that creates or overwrites files.
///
/// Arguments (JSON):
/// - `path` (string, required) — file path to write
/// - `content` (string, required) — content to write
///
/// Only available in `ToolMode::Full`.
pub struct WriteTool {
    max_bytes: usize,
}

impl WriteTool {
    /// Create a new WriteTool with the default max content size.
    pub fn new() -> Self {
        Self {
            max_bytes: DEFAULT_MAX_BYTES,
        }
    }

    /// Create a new WriteTool with a custom max content size.
    pub fn with_max_bytes(max_bytes: usize) -> Self {
        Self { max_bytes }
    }
}

impl Default for WriteTool {
    fn default() -> Self {
        Self::new()
    }
}

impl Tool for WriteTool {
    fn name(&self) -> &str {
        "write"
    }

    fn description(&self) -> &str {
        "Create or overwrite a file with the given content"
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "path": {
                    "type": "string",
                    "description": "File path to write"
                },
                "content": {
                    "type": "string",
                    "description": "Content to write to the file"
                }
            },
            "required": ["path", "content"]
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let path_str = args
            .get("path")
            .and_then(|v| v.as_str())
            .ok_or_else(|| FaeLlmError::ToolError("missing required argument: path".into()))?;

        let content = args
            .get("content")
            .and_then(|v| v.as_str())
            .ok_or_else(|| FaeLlmError::ToolError("missing required argument: content".into()))?;

        let path = validate_write_path(path_str)?;

        // Check content size
        if content.len() > self.max_bytes {
            return Ok(ToolResult::failure(format!(
                "content exceeds max size ({} bytes > {} bytes)",
                content.len(),
                self.max_bytes
            )));
        }

        // Verify parent directory exists
        if let Some(parent) = path.parent()
            && !parent.as_os_str().is_empty()
            && !parent.exists()
        {
            return Ok(ToolResult::failure(format!(
                "parent directory does not exist: {}",
                parent.display()
            )));
        }

        // Write file
        if let Err(e) = std::fs::write(&path, content) {
            return Ok(ToolResult::failure(format!(
                "failed to write {}: {e}",
                path.display()
            )));
        }

        Ok(ToolResult::success(format!(
            "wrote {} bytes to {}",
            content.len(),
            path.display()
        )))
    }

    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        mode == ToolMode::Full
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir() -> tempfile::TempDir {
        match tempfile::tempdir() {
            Ok(d) => d,
            Err(_) => unreachable!("tempdir creation should not fail"),
        }
    }

    #[test]
    fn write_new_file() {
        let dir = temp_dir();
        let path = dir.path().join("new_file.txt");
        let tool = WriteTool::new();
        let result = tool.execute(serde_json::json!({
            "path": path.to_str(),
            "content": "hello world"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("write should succeed"),
        };
        assert!(result.success);
        let content = std::fs::read_to_string(&path).unwrap_or_default();
        assert_eq!(content, "hello world");
    }

    #[test]
    fn write_overwrite_existing() {
        let dir = temp_dir();
        let path = dir.path().join("existing.txt");
        std::fs::write(&path, "old content").unwrap_or_default();

        let tool = WriteTool::new();
        let result = tool.execute(serde_json::json!({
            "path": path.to_str(),
            "content": "new content"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("write should succeed"),
        };
        assert!(result.success);
        let content = std::fs::read_to_string(&path).unwrap_or_default();
        assert_eq!(content, "new content");
    }

    #[test]
    fn write_nonexistent_parent_directory() {
        let dir = temp_dir();
        let path = dir.path().join("nonexistent_dir").join("file.txt");
        let tool = WriteTool::new();
        let result = tool.execute(serde_json::json!({
            "path": path.to_str(),
            "content": "test"
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
                .is_some_and(|e| e.contains("parent directory"))
        );
    }

    #[test]
    fn write_content_exceeds_max_size() {
        let dir = temp_dir();
        let path = dir.path().join("large.txt");
        let tool = WriteTool::with_max_bytes(10);
        let result = tool.execute(serde_json::json!({
            "path": path.to_str(),
            "content": "this content is longer than 10 bytes"
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
    fn write_missing_arguments() {
        let tool = WriteTool::new();
        assert!(tool.execute(serde_json::json!({})).is_err());
        assert!(tool.execute(serde_json::json!({"path": "x"})).is_err());
    }

    #[test]
    fn write_only_allowed_in_full_mode() {
        let tool = WriteTool::new();
        assert!(!tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn write_path_traversal_rejected() {
        let tool = WriteTool::new();
        let result = tool.execute(serde_json::json!({
            "path": "../../../etc/malicious",
            "content": "evil"
        }));
        assert!(result.is_err());
    }

    #[test]
    fn write_system_path_rejected() {
        let tool = WriteTool::new();
        let result = tool.execute(serde_json::json!({
            "path": "/etc/malicious",
            "content": "evil"
        }));
        assert!(result.is_err());
    }

    #[test]
    fn write_empty_content() {
        let dir = temp_dir();
        let path = dir.path().join("empty.txt");
        let tool = WriteTool::new();
        let result = tool.execute(serde_json::json!({
            "path": path.to_str(),
            "content": ""
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("write should succeed"),
        };
        assert!(result.success);
        let content = std::fs::read_to_string(&path).unwrap_or_default();
        assert!(content.is_empty());
    }

    #[test]
    fn write_result_includes_byte_count() {
        let dir = temp_dir();
        let path = dir.path().join("count.txt");
        let tool = WriteTool::new();
        let result = tool.execute(serde_json::json!({
            "path": path.to_str(),
            "content": "12345"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("write should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("5 bytes"));
    }
}
