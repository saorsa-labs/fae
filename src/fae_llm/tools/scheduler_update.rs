//! Enable/disable scheduled task tool.
//!
//! Mutation tool that toggles the enabled state of a scheduled task.

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;
use crate::scheduler;

use super::types::{Tool, ToolResult};

/// Tool that enables or disables a scheduled task.
///
/// # Arguments (JSON)
///
/// - `task_id` (string, required) — the task identifier
/// - `enabled` (boolean, required) — `true` to enable, `false` to disable
pub struct SchedulerUpdateTool;

impl SchedulerUpdateTool {
    /// Create a new `SchedulerUpdateTool`.
    pub fn new() -> Self {
        Self
    }
}

impl Default for SchedulerUpdateTool {
    fn default() -> Self {
        Self::new()
    }
}

impl Tool for SchedulerUpdateTool {
    fn name(&self) -> &str {
        "update_scheduled_task"
    }

    fn description(&self) -> &str {
        "Enable or disable a scheduled task by its ID."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "task_id": {
                    "type": "string",
                    "description": "The task identifier"
                },
                "enabled": {
                    "type": "boolean",
                    "description": "true to enable, false to disable"
                }
            },
            "required": ["task_id", "enabled"]
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let task_id = args
            .get("task_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| {
                FaeLlmError::ToolValidationError("missing required argument: task_id".into())
            })?;

        let enabled = args
            .get("enabled")
            .and_then(|v| v.as_bool())
            .ok_or_else(|| {
                FaeLlmError::ToolValidationError(
                    "missing required argument: enabled (boolean)".into(),
                )
            })?;

        let found = scheduler::set_persisted_task_enabled(task_id, enabled)
            .map_err(|e| FaeLlmError::ToolExecutionError(format!("failed to update task: {e}")))?;

        if found {
            let state = if enabled { "enabled" } else { "disabled" };
            Ok(ToolResult::success(format!(
                "Task '{task_id}' is now {state}."
            )))
        } else {
            Ok(ToolResult::failure(format!("Task '{task_id}' not found.")))
        }
    }

    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        mode == ToolMode::Full
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    #[test]
    fn schema_valid() {
        let tool = SchedulerUpdateTool::new();
        let schema = tool.schema();
        assert!(schema.is_object());
        let required = schema.get("required").and_then(|v| v.as_array());
        assert!(required.is_some());
        let required = required.unwrap();
        assert!(required.contains(&serde_json::json!("task_id")));
        assert!(required.contains(&serde_json::json!("enabled")));
    }

    #[test]
    fn not_allowed_in_readonly() {
        let tool = SchedulerUpdateTool::new();
        assert!(!tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn name_and_description() {
        let tool = SchedulerUpdateTool::new();
        assert_eq!(tool.name(), "update_scheduled_task");
        assert!(!tool.description().is_empty());
    }

    #[test]
    fn rejects_missing_task_id() {
        let tool = SchedulerUpdateTool::new();
        let result = tool.execute(serde_json::json!({"enabled": true}));
        assert!(result.is_err());
    }

    #[test]
    fn rejects_missing_enabled() {
        let tool = SchedulerUpdateTool::new();
        let result = tool.execute(serde_json::json!({"task_id": "test"}));
        assert!(result.is_err());
    }
}
