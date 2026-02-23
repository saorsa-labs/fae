//! x0x gossip network tool — interact with the local x0xd daemon via REST API.
//!
//! Provides a single [`X0xTool`] that dispatches to the x0xd daemon running at
//! `http://127.0.0.1:12700`. All network operations go through this tool,
//! including peer discovery, presence, pub/sub messaging, and collaborative
//! task lists.
//!
//! Returns a friendly error when x0xd is not running (connection refused).

use base64::Engine as _;

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;

use super::types::{DEFAULT_MAX_BYTES, Tool, ToolResult, truncate_output};

/// Base URL for the local x0xd REST API.
const X0XD_BASE_URL: &str = "http://127.0.0.1:12700";

/// Default request timeout for x0xd calls.
const REQUEST_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(10);

/// Tool for interacting with the x0x gossip network via the local x0xd daemon.
///
/// Supports actions: `status`, `peers`, `presence`, `publish`, `subscribe`,
/// `find_agent`, `task_lists`, `create_task_list`, `add_task`, `claim_task`,
/// `complete_task`, `list_tasks`.
///
/// This is a **mutation** tool — only allowed in `ToolMode::Full`.
///
/// # Arguments (JSON)
///
/// - `action` (string, required) — the operation to perform
/// - Additional fields depend on the action (see schema)
pub struct X0xTool {
    max_bytes: usize,
}

impl X0xTool {
    /// Create a new `X0xTool` with the default max output size.
    pub fn new() -> Self {
        Self {
            max_bytes: DEFAULT_MAX_BYTES,
        }
    }
}

impl Default for X0xTool {
    fn default() -> Self {
        Self::new()
    }
}

impl Tool for X0xTool {
    fn name(&self) -> &str {
        "x0x"
    }

    fn description(&self) -> &str {
        "Interact with the x0x gossip network: check peers, send messages, \
         discover agents, and manage collaborative task lists via the local x0xd daemon."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "action": {
                    "type": "string",
                    "description": "The operation to perform",
                    "enum": [
                        "status", "peers", "presence", "publish", "subscribe",
                        "find_agent", "task_lists", "create_task_list",
                        "add_task", "claim_task", "complete_task", "list_tasks"
                    ]
                },
                "topic": {
                    "type": "string",
                    "description": "Topic name (for publish, subscribe, create_task_list)"
                },
                "message": {
                    "type": "string",
                    "description": "Message content (for publish)"
                },
                "capability": {
                    "type": "string",
                    "description": "Capability to search for (for find_agent)"
                },
                "list_id": {
                    "type": "string",
                    "description": "Task list ID (for add_task, claim_task, complete_task, list_tasks)"
                },
                "list_name": {
                    "type": "string",
                    "description": "Name for a new task list (for create_task_list)"
                },
                "task_title": {
                    "type": "string",
                    "description": "Task title (for add_task)"
                },
                "task_description": {
                    "type": "string",
                    "description": "Task description (for add_task)"
                },
                "task_id": {
                    "type": "string",
                    "description": "Task ID (for claim_task, complete_task)"
                },
                "status_text": {
                    "type": "string",
                    "description": "Presence status text (for presence)"
                }
            },
            "required": ["action"]
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let action = args.get("action").and_then(|v| v.as_str()).ok_or_else(|| {
            FaeLlmError::ToolValidationError("missing required argument: action".into())
        })?;

        let result = match action {
            "status" => execute_get("/health"),
            "peers" => execute_get("/peers"),
            "presence" => execute_presence(&args),
            "publish" => execute_publish(&args),
            "subscribe" => execute_subscribe(&args),
            "find_agent" => execute_find_agent(&args),
            "task_lists" => execute_get("/task-lists"),
            "create_task_list" => execute_create_task_list(&args),
            "add_task" => execute_add_task(&args),
            "claim_task" => execute_task_action(&args, "claim"),
            "complete_task" => execute_task_action(&args, "complete"),
            "list_tasks" => execute_list_tasks(&args),
            _ => {
                return Err(FaeLlmError::ToolValidationError(format!(
                    "unknown action: {action}"
                )));
            }
        };

        match result {
            Ok(output) => {
                let (truncated_output, was_truncated) = truncate_output(&output, self.max_bytes);
                if was_truncated {
                    Ok(ToolResult::success_truncated(truncated_output))
                } else {
                    Ok(ToolResult::success(truncated_output))
                }
            }
            Err(e) => Ok(ToolResult::failure(e)),
        }
    }

    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        mode == ToolMode::Full
    }
}

// ---------------------------------------------------------------------------
// HTTP helpers
// ---------------------------------------------------------------------------

/// Build a reqwest client with timeout.
fn build_client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .build()
        .map_err(|e| format!("failed to build HTTP client: {e}"))
}

/// Format a connection-refused error into a user-friendly message.
fn format_request_error(e: reqwest::Error) -> String {
    if e.is_connect() {
        "x0xd daemon is not running. Start it with `x0xd` or check if port 12700 is available."
            .to_string()
    } else if e.is_timeout() {
        "x0xd request timed out. The daemon may be overloaded or unreachable.".to_string()
    } else {
        format!("x0xd request failed: {e}")
    }
}

/// Parse a JSON response body, pretty-printing if valid JSON.
fn format_response(status: reqwest::StatusCode, body: String) -> Result<String, String> {
    if status.is_success() {
        // Try to pretty-print JSON, fall back to raw text.
        match serde_json::from_str::<serde_json::Value>(&body) {
            Ok(value) => serde_json::to_string_pretty(&value)
                .map_err(|e| format!("failed to format JSON: {e}")),
            Err(_) => Ok(body),
        }
    } else {
        Err(format!("x0xd returned {status}: {body}"))
    }
}

/// Execute a GET request against x0xd and return the response body.
fn execute_get(path: &str) -> Result<String, String> {
    let client = build_client()?;
    let url = format!("{X0XD_BASE_URL}{path}");

    let handle = tokio::runtime::Handle::current();
    let response = handle
        .block_on(client.get(&url).send())
        .map_err(format_request_error)?;

    let status = response.status();
    let body = handle
        .block_on(response.text())
        .map_err(|e| format!("failed to read response body: {e}"))?;

    format_response(status, body)
}

/// Execute a POST request with a JSON body against x0xd.
fn execute_post(path: &str, body: serde_json::Value) -> Result<String, String> {
    let client = build_client()?;
    let url = format!("{X0XD_BASE_URL}{path}");

    let handle = tokio::runtime::Handle::current();
    let response = handle
        .block_on(client.post(&url).json(&body).send())
        .map_err(format_request_error)?;

    let status = response.status();
    let response_body = handle
        .block_on(response.text())
        .map_err(|e| format!("failed to read response body: {e}"))?;

    format_response(status, response_body)
}

/// Execute a PATCH request with a JSON body against x0xd.
fn execute_patch(path: &str, body: serde_json::Value) -> Result<String, String> {
    let client = build_client()?;
    let url = format!("{X0XD_BASE_URL}{path}");

    let handle = tokio::runtime::Handle::current();
    let response = handle
        .block_on(client.patch(&url).json(&body).send())
        .map_err(format_request_error)?;

    let status = response.status();
    let response_body = handle
        .block_on(response.text())
        .map_err(|e| format!("failed to read response body: {e}"))?;

    format_response(status, response_body)
}

/// Encode bytes as standard base64.
fn base64_encode(data: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(data)
}

// ---------------------------------------------------------------------------
// Action implementations
// ---------------------------------------------------------------------------

fn require_string<'a>(args: &'a serde_json::Value, field: &str) -> Result<&'a str, FaeLlmError> {
    args.get(field)
        .and_then(|v| v.as_str())
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| {
            FaeLlmError::ToolValidationError(format!("missing required argument: {field}"))
        })
}

fn execute_presence(args: &serde_json::Value) -> Result<String, String> {
    if let Some(status_text) = args.get("status_text").and_then(|v| v.as_str()) {
        // Set presence status.
        execute_post("/presence", serde_json::json!({ "status": status_text }))
    } else {
        // Get current presence.
        execute_get("/presence")
    }
}

fn execute_publish(args: &serde_json::Value) -> Result<String, String> {
    let topic = require_string(args, "topic").map_err(|e| e.to_string())?;
    let message = require_string(args, "message").map_err(|e| e.to_string())?;

    // x0xd expects base64-encoded payload.
    let payload = base64_encode(message.as_bytes());
    execute_post(
        "/publish",
        serde_json::json!({
            "topic": topic,
            "payload": payload,
        }),
    )
}

fn execute_subscribe(args: &serde_json::Value) -> Result<String, String> {
    let topic = require_string(args, "topic").map_err(|e| e.to_string())?;

    execute_post("/subscribe", serde_json::json!({ "topic": topic }))
}

fn execute_find_agent(args: &serde_json::Value) -> Result<String, String> {
    let _capability = require_string(args, "capability").map_err(|e| e.to_string())?;

    // x0xd v0.1 does not have a capability-based discovery endpoint.
    // Return presence list as the best available approximation.
    execute_get("/presence")
}

fn execute_create_task_list(args: &serde_json::Value) -> Result<String, String> {
    let list_name = require_string(args, "list_name").map_err(|e| e.to_string())?;
    // Topic defaults to the list name if not provided.
    let topic = args
        .get("topic")
        .and_then(|v| v.as_str())
        .filter(|s| !s.trim().is_empty())
        .unwrap_or(list_name);

    execute_post(
        "/task-lists",
        serde_json::json!({ "name": list_name, "topic": topic }),
    )
}

fn execute_add_task(args: &serde_json::Value) -> Result<String, String> {
    let list_id = require_string(args, "list_id").map_err(|e| e.to_string())?;
    let task_title = require_string(args, "task_title").map_err(|e| e.to_string())?;
    let task_description = args
        .get("task_description")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    execute_post(
        &format!("/task-lists/{list_id}/tasks"),
        serde_json::json!({ "title": task_title, "description": task_description }),
    )
}

/// Claim or complete a task via PATCH /task-lists/{id}/tasks/{tid}.
fn execute_task_action(args: &serde_json::Value, action: &str) -> Result<String, String> {
    let list_id = require_string(args, "list_id").map_err(|e| e.to_string())?;
    let task_id = require_string(args, "task_id").map_err(|e| e.to_string())?;

    execute_patch(
        &format!("/task-lists/{list_id}/tasks/{task_id}"),
        serde_json::json!({ "action": action }),
    )
}

fn execute_list_tasks(args: &serde_json::Value) -> Result<String, String> {
    let list_id = require_string(args, "list_id").map_err(|e| e.to_string())?;

    execute_get(&format!("/task-lists/{list_id}/tasks"))
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schema_has_required_action() {
        let tool = X0xTool::new();
        let schema = tool.schema();
        let required = schema.get("required").and_then(|v| v.as_array());
        assert!(required.is_some());
        let required = match required {
            Some(r) => r,
            None => unreachable!("schema should have required"),
        };
        assert!(required.iter().any(|v| v.as_str() == Some("action")));
    }

    #[test]
    fn schema_has_action_enum() {
        let tool = X0xTool::new();
        let schema = tool.schema();
        let action_prop = schema
            .get("properties")
            .and_then(|p| p.get("action"))
            .and_then(|a| a.get("enum"))
            .and_then(|e| e.as_array());
        assert!(action_prop.is_some());
        let actions = match action_prop {
            Some(a) => a,
            None => unreachable!("schema should have action enum"),
        };
        assert!(actions.len() >= 12);
    }

    #[test]
    fn missing_action_returns_validation_error() {
        let tool = X0xTool::new();
        let result = tool.execute(serde_json::json!({}));
        assert!(result.is_err());
        let err = match result {
            Err(e) => e,
            Ok(_) => unreachable!("should return error for missing action"),
        };
        assert!(err.to_string().contains("action"));
    }

    #[test]
    fn unknown_action_returns_validation_error() {
        let tool = X0xTool::new();
        let result = tool.execute(serde_json::json!({"action": "destroy_everything"}));
        assert!(result.is_err());
        let err = match result {
            Err(e) => e,
            Ok(_) => unreachable!("should return error for unknown action"),
        };
        assert!(err.to_string().contains("unknown action"));
    }

    #[test]
    fn publish_requires_topic_and_message() {
        let tool = X0xTool::new();
        // publish without topic should fail gracefully (returns failure ToolResult).
        let result = tool.execute(serde_json::json!({"action": "publish"}));
        assert!(result.is_ok());
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("publish validation should return ToolResult"),
        };
        assert!(!result.success);
        assert!(result.error.as_deref().unwrap_or("").contains("topic"));
    }

    #[test]
    fn add_task_requires_list_id_and_title() {
        let tool = X0xTool::new();
        let result = tool.execute(serde_json::json!({"action": "add_task"}));
        assert!(result.is_ok());
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("add_task validation should return ToolResult"),
        };
        assert!(!result.success);
        assert!(result.error.as_deref().unwrap_or("").contains("list_id"));
    }

    #[test]
    fn only_allowed_in_full_mode() {
        let tool = X0xTool::new();
        assert!(!tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn tool_metadata() {
        let tool = X0xTool::new();
        assert_eq!(tool.name(), "x0x");
        assert!(!tool.description().is_empty());
    }

    #[test]
    fn default_impl() {
        let tool = X0xTool::default();
        assert_eq!(tool.name(), "x0x");
    }

    #[test]
    fn base64_encode_works() {
        assert_eq!(base64_encode(b"Hello world"), "SGVsbG8gd29ybGQ=");
    }

    /// Network-dependent tests require a tokio runtime context for the
    /// `Handle::current().block_on()` bridge inside execute(). We spawn a
    /// blocking task within the runtime so the inner block_on succeeds.
    #[tokio::test]
    async fn status_returns_failure_when_daemon_not_running() {
        let result = tokio::task::spawn_blocking(|| {
            let tool = X0xTool::new();
            tool.execute(serde_json::json!({"action": "status"}))
        })
        .await;
        let result = match result {
            Ok(Ok(r)) => r,
            _ => unreachable!("status should return ToolResult even on connection error"),
        };
        assert!(!result.success);
        // Should mention x0xd not running.
        assert!(result.error.as_deref().unwrap_or("").contains("x0xd"));
    }

    #[tokio::test]
    async fn peers_returns_failure_when_daemon_not_running() {
        let result = tokio::task::spawn_blocking(|| {
            let tool = X0xTool::new();
            tool.execute(serde_json::json!({"action": "peers"}))
        })
        .await;
        let result = match result {
            Ok(Ok(r)) => r,
            _ => unreachable!("peers should return ToolResult"),
        };
        assert!(!result.success);
    }
}
