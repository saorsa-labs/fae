//! Fetch URL tool — downloads a web page and extracts readable text content.
//!
//! Wraps the [`fae_search`] crate's async `fetch_page_content` API behind the
//! synchronous [`Tool`] trait interface using `tokio::runtime::Handle::current().block_on()`.

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;

use super::types::{DEFAULT_MAX_BYTES, Tool, ToolResult, truncate_output};

/// Tool that fetches a web page and extracts readable text content.
///
/// Downloads the page at the given URL, strips boilerplate (navigation, ads,
/// footers, scripts), and returns the main content as clean text with metadata.
///
/// This is a **read-only** tool — allowed in all tool modes.
///
/// # Arguments (JSON)
///
/// - `url` (string, required) — the URL to fetch
pub struct FetchUrlTool {
    max_bytes: usize,
}

impl FetchUrlTool {
    /// Create a new `FetchUrlTool` with the default max output size.
    pub fn new() -> Self {
        Self {
            max_bytes: DEFAULT_MAX_BYTES,
        }
    }
}

impl Default for FetchUrlTool {
    fn default() -> Self {
        Self::new()
    }
}

impl Tool for FetchUrlTool {
    fn name(&self) -> &str {
        "fetch_url"
    }

    fn description(&self) -> &str {
        "Fetch a web page and extract its readable text content."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "url": {
                    "type": "string",
                    "description": "The URL to fetch and extract content from"
                }
            },
            "required": ["url"]
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let url = args.get("url").and_then(|v| v.as_str()).ok_or_else(|| {
            FaeLlmError::ToolValidationError("missing required argument: url".into())
        })?;

        if url.trim().is_empty() {
            return Err(FaeLlmError::ToolValidationError(
                "url must not be empty".into(),
            ));
        }

        // Basic URL format validation.
        if !url.starts_with("http://") && !url.starts_with("https://") {
            return Err(FaeLlmError::ToolValidationError(
                "url must start with http:// or https://".into(),
            ));
        }

        // Bridge sync Tool::execute to async fae_search::fetch_page_content.
        let handle = tokio::runtime::Handle::current();
        let page = match handle.block_on(fae_search::fetch_page_content(url)) {
            Ok(page) => page,
            Err(e) => {
                return Ok(ToolResult::failure(format!("Failed to fetch {url}: {e}")));
            }
        };

        // Format page content for LLM consumption.
        let mut output = format!("## Page Content: {}\n\n", page.title);
        output.push_str(&format!("URL: {url}\n"));
        output.push_str(&format!("Words: {}\n\n", page.word_count));
        output.push_str(&page.text);

        let (truncated_output, was_truncated) = truncate_output(&output, self.max_bytes);
        if was_truncated {
            Ok(ToolResult::success_truncated(truncated_output))
        } else {
            Ok(ToolResult::success(truncated_output))
        }
    }

    fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
        true // fetch_url is read-only, allowed in all modes
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schema_has_required_url() {
        let tool = FetchUrlTool::new();
        let schema = tool.schema();
        let required = schema.get("required").and_then(|v| v.as_array());
        assert!(required.is_some());
        let required = match required {
            Some(r) => r,
            None => unreachable!("schema should have required"),
        };
        assert!(required.iter().any(|v| v.as_str() == Some("url")));
    }

    #[test]
    fn schema_has_url_property() {
        let tool = FetchUrlTool::new();
        let schema = tool.schema();
        let props = schema.get("properties");
        assert!(props.is_some());
        let props = match props {
            Some(p) => p,
            None => unreachable!("schema should have properties"),
        };
        assert!(props.get("url").is_some());
    }

    #[test]
    fn missing_url_returns_validation_error() {
        let tool = FetchUrlTool::new();
        let result = tool.execute(serde_json::json!({}));
        assert!(result.is_err());
        let err = match result {
            Err(e) => e,
            Ok(_) => unreachable!("should return error for missing url"),
        };
        assert!(err.to_string().contains("url"));
    }

    #[test]
    fn empty_url_returns_validation_error() {
        let tool = FetchUrlTool::new();
        let result = tool.execute(serde_json::json!({"url": "   "}));
        assert!(result.is_err());
        let err = match result {
            Err(e) => e,
            Ok(_) => unreachable!("should return error for empty url"),
        };
        assert!(err.to_string().contains("empty"));
    }

    #[test]
    fn invalid_url_format_returns_validation_error() {
        let tool = FetchUrlTool::new();
        let result = tool.execute(serde_json::json!({"url": "not-a-url"}));
        assert!(result.is_err());
        let err = match result {
            Err(e) => e,
            Ok(_) => unreachable!("should return error for invalid url"),
        };
        assert!(err.to_string().contains("http"));
    }

    #[test]
    fn allowed_in_both_modes() {
        let tool = FetchUrlTool::new();
        assert!(tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn tool_metadata() {
        let tool = FetchUrlTool::new();
        assert_eq!(tool.name(), "fetch_url");
        assert!(!tool.description().is_empty());
    }

    #[test]
    fn default_impl() {
        let tool = FetchUrlTool::default();
        assert_eq!(tool.name(), "fetch_url");
    }

    // Note: execute() with real URLs requires a tokio runtime and network.
    // The stub currently returns an error, which is tested below.

    #[tokio::test]
    async fn execute_handles_stub_error_gracefully() {
        // fetch_page_content is currently a stub that returns an error.
        // The tool should return ToolResult::failure, not panic.
        let tool = FetchUrlTool::new();
        let result = tool.execute(serde_json::json!({"url": "https://example.com"}));
        // Should succeed (Ok) with a failure ToolResult, not Err.
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("stub error should produce ToolResult::failure, not Err"),
        };
        assert!(!result.success);
        assert!(result.error.is_some());
        let error_msg = result.error.as_deref().unwrap_or("");
        assert!(error_msg.contains("not yet implemented"));
    }

    #[tokio::test]
    async fn execute_in_tokio_context_missing_url() {
        let tool = FetchUrlTool::new();
        let result = tool.execute(serde_json::json!({}));
        assert!(result.is_err());
    }
}
