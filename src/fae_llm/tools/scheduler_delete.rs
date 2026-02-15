//! Delete scheduled task tool.
//!
//! Mutation tool that removes a user-defined scheduled task.
//! Builtin tasks cannot be deleted.

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;
use crate::scheduler;
use crate::scheduler::tasks::TaskKind;

use super::types::{Tool, ToolResult};

/// Tool that deletes a user-defined scheduled task.
///
/// Prevents deletion of builtin tasks — only user tasks can be removed.
///
/// # Arguments (JSON)
///
/// - `task_id` (string, required) — the task identifier to delete
pub struct SchedulerDeleteTool;

impl SchedulerDeleteTool {
    /// Create a new `SchedulerDeleteTool`.
    pub fn new() -> Self {
        Self
    }
}

impl Default for SchedulerDeleteTool {
    fn default() -> Self {
        Self::new()
    }
}

impl Tool for SchedulerDeleteTool {
    fn name(&self) -> &str {
        "delete_scheduled_task"
    }

    fn description(&self) -> &str {
        "Delete a user-defined scheduled task by its ID. Builtin tasks cannot be deleted."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "task_id": {
                    "type": "string",
                    "description": "The task identifier to delete"
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

        // Check if the task is builtin before attempting deletion.
        let snapshot = scheduler::load_persisted_snapshot().map_err(|e| {
            FaeLlmError::ToolExecutionError(format!("failed to load scheduler state: {e}"))
        })?;

        if let Some(task) = snapshot.tasks.iter().find(|t| t.id == task_id)
            && task.kind == TaskKind::Builtin
        {
            return Ok(ToolResult::failure(format!(
                "Cannot delete builtin task '{task_id}'. Only user tasks can be deleted."
            )));
        }

        let found = scheduler::remove_persisted_task(task_id)
            .map_err(|e| FaeLlmError::ToolExecutionError(format!("failed to delete task: {e}")))?;

        if found {
            Ok(ToolResult::success(format!(
                "Task '{task_id}' deleted successfully."
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
        let tool = SchedulerDeleteTool::new();
        let schema = tool.schema();
        assert!(schema.is_object());
        let required = schema.get("required").and_then(|v| v.as_array());
        assert!(required.is_some());
        let required = required.unwrap();
        assert!(required.contains(&serde_json::json!("task_id")));
    }

    #[test]
    fn not_allowed_in_readonly() {
        let tool = SchedulerDeleteTool::new();
        assert!(!tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn name_and_description() {
        let tool = SchedulerDeleteTool::new();
        assert_eq!(tool.name(), "delete_scheduled_task");
        assert!(!tool.description().is_empty());
    }

    #[test]
    fn rejects_missing_task_id() {
        let tool = SchedulerDeleteTool::new();
        let result = tool.execute(serde_json::json!({}));
        assert!(result.is_err());
    }
}
