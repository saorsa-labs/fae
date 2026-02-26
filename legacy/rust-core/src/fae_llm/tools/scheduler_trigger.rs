//! Trigger scheduled task tool.
//!
//! Mutation tool that marks a scheduled task for immediate execution
//! on the next scheduler tick.

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;
use crate::scheduler;

use super::types::{Tool, ToolResult};

/// Tool that triggers immediate execution of a scheduled task.
///
/// Marks the task as due now so the scheduler runner will execute it
/// on the next tick.
///
/// # Arguments (JSON)
///
/// - `task_id` (string, required) — the task identifier to trigger
pub struct SchedulerTriggerTool;

impl SchedulerTriggerTool {
    /// Create a new `SchedulerTriggerTool`.
    pub fn new() -> Self {
        Self
    }
}

impl Default for SchedulerTriggerTool {
    fn default() -> Self {
        Self::new()
    }
}

impl Tool for SchedulerTriggerTool {
    fn name(&self) -> &str {
        "trigger_scheduled_task"
    }

    fn description(&self) -> &str {
        "Trigger immediate execution of a scheduled task on the next scheduler tick."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "task_id": {
                    "type": "string",
                    "description": "The task identifier to trigger"
                }
            },
            "required": ["task_id"]
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let task_id = args
            .get("task_id")
            .and_then(|v| v.as_str())
            .ok_or_else(|| {
                FaeLlmError::ToolValidationError("missing required argument: task_id".into())
            })?;

        let found = scheduler::mark_persisted_task_due_now(task_id)
            .map_err(|e| FaeLlmError::ToolExecutionError(format!("failed to trigger task: {e}")))?;

        if found {
            Ok(ToolResult::success(format!(
                "Task '{task_id}' marked for immediate execution."
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
        let tool = SchedulerTriggerTool::new();
        let schema = tool.schema();
        assert!(schema.is_object());
        let required = schema.get("required").and_then(|v| v.as_array());
        assert!(required.is_some());
        let required = required.unwrap();
        assert!(required.contains(&serde_json::json!("task_id")));
    }

    #[test]
    fn not_allowed_in_readonly() {
        let tool = SchedulerTriggerTool::new();
        assert!(!tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn name_and_description() {
        let tool = SchedulerTriggerTool::new();
        assert_eq!(tool.name(), "trigger_scheduled_task");
        assert!(!tool.description().is_empty());
    }

    #[test]
    fn rejects_missing_task_id() {
        let tool = SchedulerTriggerTool::new();
        let result = tool.execute(serde_json::json!({}));
        assert!(result.is_err());
    }
}
