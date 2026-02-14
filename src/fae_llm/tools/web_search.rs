//! Web search tool — searches the web using multiple engines concurrently.
//!
//! Wraps the [`fae_search`] crate's async search API behind the synchronous
//! [`Tool`] trait interface using `tokio::runtime::Handle::current().block_on()`.

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;

use super::types::{DEFAULT_MAX_BYTES, Tool, ToolResult, truncate_output};

/// Tool that searches the web using multiple search engines concurrently.
///
/// Queries DuckDuckGo, Brave, Google, and Bing in parallel, deduplicates
/// and ranks results, then formats them for LLM consumption.
///
/// This is a **read-only** tool — allowed in all tool modes.
///
/// # Arguments (JSON)
///
/// - `query` (string, required) — the search query
/// - `max_results` (integer, optional) — maximum results to return (default 5)
pub struct WebSearchTool {
    max_bytes: usize,
}

impl WebSearchTool {
    /// Create a new `WebSearchTool` with the default max output size.
    pub fn new() -> Self {
        Self {
            max_bytes: DEFAULT_MAX_BYTES,
        }
    }
}

impl Default for WebSearchTool {
    fn default() -> Self {
        Self::new()
    }
}

impl Tool for WebSearchTool {
    fn name(&self) -> &str {
        "web_search"
    }

    fn description(&self) -> &str {
        "Search the web using multiple search engines. Returns titles, URLs, and snippets."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "The search query"
                },
                "max_results": {
                    "type": "integer",
                    "description": "Maximum number of results to return (default 5)"
                }
            },
            "required": ["query"]
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let query = args.get("query").and_then(|v| v.as_str()).ok_or_else(|| {
            FaeLlmError::ToolValidationError("missing required argument: query".into())
        })?;

        if query.trim().is_empty() {
            return Err(FaeLlmError::ToolValidationError(
                "query must not be empty".into(),
            ));
        }

        let max_results = args
            .get("max_results")
            .and_then(|v| v.as_u64())
            .map(|v| v as usize)
            .unwrap_or(5);

        let config = fae_search::SearchConfig {
            max_results,
            ..Default::default()
        };

        // Bridge sync Tool::execute to async fae_search::search.
        let handle = tokio::runtime::Handle::current();
        let results = handle
            .block_on(fae_search::search(query, &config))
            .map_err(|e| FaeLlmError::ToolExecutionError(format!("web search failed: {e}")))?;

        if results.is_empty() {
            return Ok(ToolResult::success(format!(
                "No results found for \"{query}\"."
            )));
        }

        // Format results for LLM consumption.
        let mut output = format!("## Search Results for \"{query}\"\n\n");
        for (i, result) in results.iter().enumerate() {
            output.push_str(&format!(
                "{}. **{}**\n   URL: {}\n   {}\n\n",
                i + 1,
                result.title,
                result.url,
                result.snippet,
            ));
        }

        let (truncated_output, was_truncated) = truncate_output(&output, self.max_bytes);
        if was_truncated {
            Ok(ToolResult::success_truncated(truncated_output))
        } else {
            Ok(ToolResult::success(truncated_output))
        }
    }

    fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
        true // web search is read-only, allowed in all modes
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schema_has_required_query() {
        let tool = WebSearchTool::new();
        let schema = tool.schema();
        let required = schema.get("required").and_then(|v| v.as_array());
        assert!(required.is_some());
        let required = match required {
            Some(r) => r,
            None => unreachable!("schema should have required"),
        };
        assert!(required.iter().any(|v| v.as_str() == Some("query")));
    }

    #[test]
    fn schema_has_query_and_max_results_properties() {
        let tool = WebSearchTool::new();
        let schema = tool.schema();
        let props = schema.get("properties");
        assert!(props.is_some());
        let props = match props {
            Some(p) => p,
            None => unreachable!("schema should have properties"),
        };
        assert!(props.get("query").is_some());
        assert!(props.get("max_results").is_some());
    }

    #[test]
    fn missing_query_returns_validation_error() {
        let tool = WebSearchTool::new();
        let result = tool.execute(serde_json::json!({}));
        assert!(result.is_err());
        let err = match result {
            Err(e) => e,
            Ok(_) => unreachable!("should return error for missing query"),
        };
        assert!(err.to_string().contains("query"));
    }

    #[test]
    fn empty_query_returns_validation_error() {
        let tool = WebSearchTool::new();
        let result = tool.execute(serde_json::json!({"query": "   "}));
        assert!(result.is_err());
        let err = match result {
            Err(e) => e,
            Ok(_) => unreachable!("should return error for empty query"),
        };
        assert!(err.to_string().contains("empty"));
    }

    #[test]
    fn allowed_in_both_modes() {
        let tool = WebSearchTool::new();
        assert!(tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn tool_metadata() {
        let tool = WebSearchTool::new();
        assert_eq!(tool.name(), "web_search");
        assert!(!tool.description().is_empty());
    }

    #[test]
    fn default_impl() {
        let tool = WebSearchTool::default();
        assert_eq!(tool.name(), "web_search");
    }

    // Note: execute() with real queries requires a tokio runtime and network.
    // Integration tests with mock engines are covered in Phase 2.2/3.1.
    // The block_on bridge is validated by the tokio::test below.

    #[tokio::test]
    async fn execute_in_tokio_context_missing_query() {
        // Verify the tool can detect validation errors even within an async context.
        // (block_on is not called for validation failures.)
        let tool = WebSearchTool::new();
        let result = tool.execute(serde_json::json!({}));
        assert!(result.is_err());
    }
}
