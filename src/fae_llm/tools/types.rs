//! Core tool types for the fae_llm tool system.
//!
//! Defines the [`Tool`] trait that all tools implement and [`ToolResult`]
//! for capturing bounded execution output.

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;

/// Default maximum output size (100 KB).
pub const DEFAULT_MAX_BYTES: usize = 100 * 1024;

/// Result of a tool execution.
///
/// Contains the output content (bounded to `max_bytes`), success/error status,
/// and a flag indicating whether output was truncated.
#[derive(Debug, Clone)]
pub struct ToolResult {
    /// Whether the tool execution succeeded.
    pub success: bool,
    /// Output content (bounded).
    pub content: String,
    /// Error message if the tool execution failed.
    pub error: Option<String>,
    /// Whether the output was truncated to fit within max_bytes.
    pub truncated: bool,
}

impl ToolResult {
    /// Create a successful tool result.
    pub fn success(content: String) -> Self {
        Self {
            success: true,
            content,
            error: None,
            truncated: false,
        }
    }

    /// Create a failed tool result with an error message.
    pub fn failure(error: String) -> Self {
        Self {
            success: false,
            content: String::new(),
            error: Some(error),
            truncated: false,
        }
    }

    /// Create a successful tool result with truncation applied.
    pub fn success_truncated(content: String) -> Self {
        Self {
            success: true,
            content,
            error: None,
            truncated: true,
        }
    }
}

/// Truncate a string to at most `max_bytes`, respecting UTF-8 boundaries.
///
/// Returns `(truncated_string, was_truncated)`.
pub fn truncate_output(s: &str, max_bytes: usize) -> (String, bool) {
    if s.len() <= max_bytes {
        return (s.to_string(), false);
    }

    // Find the last valid UTF-8 char boundary at or before max_bytes
    let mut end = max_bytes;
    while end > 0 && !s.is_char_boundary(end) {
        end -= 1;
    }

    let truncated = &s[..end];
    (
        format!("{truncated}\n\n[output truncated at {max_bytes} bytes]"),
        true,
    )
}

/// Core trait for LLM tools.
///
/// All tools must be `Send + Sync` for use in async contexts.
/// The trait provides metadata (name, description, schema) and
/// an execution method that accepts JSON arguments.
pub trait Tool: Send + Sync {
    /// Returns the tool name (e.g. "read", "bash", "edit", "write").
    fn name(&self) -> &str;

    /// Returns a human-readable description of what the tool does.
    fn description(&self) -> &str;

    /// Returns the JSON Schema for the tool's arguments.
    fn schema(&self) -> serde_json::Value;

    /// Execute the tool with the given JSON arguments.
    ///
    /// # Errors
    ///
    /// Returns `FaeLlmError` for validation/execution failures.
    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError>;

    /// Whether this tool is allowed in the given mode.
    ///
    /// Read-only tools (like `read`) return true for both modes.
    /// Mutation tools (like `bash`, `edit`, `write`) only allow `ToolMode::Full`.
    fn allowed_in_mode(&self, mode: ToolMode) -> bool;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_result_success() {
        let result = ToolResult::success("hello world".to_string());
        assert!(result.success);
        assert_eq!(result.content, "hello world");
        assert!(result.error.is_none());
        assert!(!result.truncated);
    }

    #[test]
    fn tool_result_failure() {
        let result = ToolResult::failure("file not found".to_string());
        assert!(!result.success);
        assert!(result.content.is_empty());
        assert_eq!(result.error, Some("file not found".to_string()));
        assert!(!result.truncated);
    }

    #[test]
    fn tool_result_success_truncated() {
        let result = ToolResult::success_truncated("partial output".to_string());
        assert!(result.success);
        assert_eq!(result.content, "partial output");
        assert!(result.error.is_none());
        assert!(result.truncated);
    }

    #[test]
    fn truncate_output_short_string() {
        let (output, truncated) = truncate_output("hello", 100);
        assert_eq!(output, "hello");
        assert!(!truncated);
    }

    #[test]
    fn truncate_output_exact_boundary() {
        let (output, truncated) = truncate_output("hello", 5);
        assert_eq!(output, "hello");
        assert!(!truncated);
    }

    #[test]
    fn truncate_output_truncates_long_string() {
        let input = "a".repeat(200);
        let (output, truncated) = truncate_output(&input, 100);
        assert!(truncated);
        assert!(output.contains("[output truncated at 100 bytes]"));
        // The actual content before the truncation message should be 100 bytes
        assert!(output.starts_with(&"a".repeat(100)));
    }

    #[test]
    fn truncate_output_respects_utf8_boundary() {
        // 'é' is 2 bytes in UTF-8
        let input = "ééééé"; // 10 bytes total
        let (output, truncated) = truncate_output(input, 5);
        assert!(truncated);
        // Should truncate to 4 bytes (2 chars) since byte 5 is mid-char
        assert!(output.starts_with("éé"));
    }

    #[test]
    fn truncate_output_empty_string() {
        let (output, truncated) = truncate_output("", 100);
        assert_eq!(output, "");
        assert!(!truncated);
    }

    #[test]
    fn truncate_output_zero_max() {
        let (output, truncated) = truncate_output("hello", 0);
        assert!(truncated);
        assert!(output.contains("[output truncated at 0 bytes]"));
    }

    // ── Trait bounds ──────────────────────────────────────────

    /// A dummy tool for testing trait bounds.
    struct DummyTool;

    impl Tool for DummyTool {
        fn name(&self) -> &str {
            "dummy"
        }
        fn description(&self) -> &str {
            "A dummy tool for testing"
        }
        fn schema(&self) -> serde_json::Value {
            serde_json::json!({
                "type": "object",
                "properties": {}
            })
        }
        fn execute(&self, _args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
            Ok(ToolResult::success("dummy output".to_string()))
        }
        fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
            true
        }
    }

    #[test]
    fn tool_trait_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<DummyTool>();
    }

    #[test]
    fn dummy_tool_metadata() {
        let tool = DummyTool;
        assert_eq!(tool.name(), "dummy");
        assert_eq!(tool.description(), "A dummy tool for testing");
        assert!(tool.schema().is_object());
    }

    #[test]
    fn dummy_tool_execute() {
        let tool = DummyTool;
        let result = tool.execute(serde_json::json!({}));
        assert!(result.is_ok());
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("dummy tool should succeed"),
        };
        assert!(result.success);
        assert_eq!(result.content, "dummy output");
    }

    #[test]
    fn dummy_tool_allowed_in_both_modes() {
        let tool = DummyTool;
        assert!(tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }
}
