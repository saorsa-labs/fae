//! List scheduled tasks tool.
//!
//! Read-only tool that lists all scheduled tasks with their status, schedule,
//! and run history. Supports filtering by kind and enabled state.

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;
use crate::scheduler;
use crate::scheduler::tasks::{Schedule, ScheduledTask, TaskKind};

use super::types::{Tool, ToolResult};

/// Tool that lists scheduled tasks.
///
/// Returns a formatted text listing of all tasks matching the optional filter.
/// This is a **read-only** tool — allowed in all tool modes.
///
/// # Arguments (JSON)
///
/// - `filter` (string, optional) — one of `"all"`, `"enabled"`, `"disabled"`,
///   `"user"`, `"builtin"` (default `"all"`)
pub struct SchedulerListTool;

impl SchedulerListTool {
    /// Create a new `SchedulerListTool`.
    pub fn new() -> Self {
        Self
    }
}

impl Default for SchedulerListTool {
    fn default() -> Self {
        Self::new()
    }
}

impl Tool for SchedulerListTool {
    fn name(&self) -> &str {
        "list_scheduled_tasks"
    }

    fn description(&self) -> &str {
        "List all scheduled tasks with their status, schedule, and last run time. \
         Supports filtering by kind (user/builtin) or enabled state."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "filter": {
                    "type": "string",
                    "description": "Filter tasks: 'all', 'enabled', 'disabled', 'user', or 'builtin' (default: 'all')",
                    "enum": ["all", "enabled", "disabled", "user", "builtin"]
                }
            }
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let filter = args.get("filter").and_then(|v| v.as_str()).unwrap_or("all");

        let snapshot = scheduler::load_persisted_snapshot().map_err(|e| {
            FaeLlmError::ToolExecutionError(format!("failed to load scheduler state: {e}"))
        })?;

        let filtered: Vec<&ScheduledTask> = snapshot
            .tasks
            .iter()
            .filter(|t| match filter {
                "enabled" => t.enabled,
                "disabled" => !t.enabled,
                "user" => t.kind == TaskKind::User,
                "builtin" => t.kind == TaskKind::Builtin,
                _ => true, // "all" or unrecognised
            })
            .collect();

        if filtered.is_empty() {
            return Ok(ToolResult::success(format!(
                "No scheduled tasks found (filter: {filter})."
            )));
        }

        let mut lines = Vec::with_capacity(filtered.len() + 2);
        lines.push(format!("Scheduled tasks ({} total):\n", filtered.len()));

        for task in &filtered {
            let status = if task.enabled { "enabled" } else { "disabled" };
            let kind = match task.kind {
                TaskKind::Builtin => "builtin",
                TaskKind::User => "user",
            };
            let schedule_desc = task.schedule.to_string();
            let last_run = task
                .last_run
                .map_or_else(|| "never".to_owned(), format_time_ago);
            let failure_info = if task.failure_streak > 0 {
                format!(" | failures: {}", task.failure_streak)
            } else {
                String::new()
            };

            lines.push(format!(
                "- [{id}] {name} ({kind})\n  Schedule: {schedule_desc}\n  Status: {status} | Last run: {last_run}{failure_info}",
                id = task.id,
                name = task.name,
            ));
        }

        Ok(ToolResult::success(lines.join("\n")))
    }

    fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
        true // read-only
    }
}

/// Format an epoch timestamp as a human-readable relative time string.
fn format_time_ago(epoch_secs: u64) -> String {
    let now = crate::scheduler::tasks::now_epoch_secs();
    if epoch_secs > now {
        return "in the future".to_owned();
    }
    let diff = now - epoch_secs;

    if diff < 60 {
        "just now".to_owned()
    } else if diff < 3600 {
        format!("{} minutes ago", diff / 60)
    } else if diff < 86400 {
        format!("{} hours ago", diff / 3600)
    } else {
        format!("{} days ago", diff / 86400)
    }
}

/// Format a schedule as a human-readable description.
///
/// Delegates to the `Display` impl on `Schedule`, but exposed as a free
/// function for tests that need to verify formatting without a full task.
pub fn format_schedule(schedule: &Schedule) -> String {
    schedule.to_string()
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use crate::scheduler::tasks::Weekday;

    #[test]
    fn format_schedule_interval_hours() {
        let s = Schedule::Interval { secs: 7200 };
        assert_eq!(format_schedule(&s), "every 2 hours");
    }

    #[test]
    fn format_schedule_interval_minutes() {
        let s = Schedule::Interval { secs: 300 };
        assert_eq!(format_schedule(&s), "every 5 minutes");
    }

    #[test]
    fn format_schedule_daily() {
        let s = Schedule::Daily { hour: 9, min: 0 };
        assert_eq!(format_schedule(&s), "daily at 09:00 local");
    }

    #[test]
    fn format_schedule_weekly() {
        let s = Schedule::Weekly {
            weekdays: vec![Weekday::Mon, Weekday::Fri],
            hour: 14,
            min: 30,
        };
        let desc = format_schedule(&s);
        assert!(desc.contains("weekly"));
        assert!(desc.contains("14:30"));
    }

    #[test]
    fn format_time_ago_just_now() {
        let now = crate::scheduler::tasks::now_epoch_secs();
        assert_eq!(format_time_ago(now), "just now");
    }

    #[test]
    fn format_time_ago_minutes() {
        let now = crate::scheduler::tasks::now_epoch_secs();
        let result = format_time_ago(now.saturating_sub(300));
        assert!(result.contains("5 minutes ago"));
    }

    #[test]
    fn format_time_ago_hours() {
        let now = crate::scheduler::tasks::now_epoch_secs();
        let result = format_time_ago(now.saturating_sub(7200));
        assert!(result.contains("2 hours ago"));
    }

    #[test]
    fn format_time_ago_days() {
        let now = crate::scheduler::tasks::now_epoch_secs();
        let result = format_time_ago(now.saturating_sub(172800));
        assert!(result.contains("2 days ago"));
    }

    #[test]
    fn schema_is_valid_json() {
        let tool = SchedulerListTool::new();
        let schema = tool.schema();
        assert!(schema.is_object());
        assert!(schema.get("properties").is_some());
    }

    #[test]
    fn allowed_in_all_modes() {
        let tool = SchedulerListTool::new();
        assert!(tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn name_and_description() {
        let tool = SchedulerListTool::new();
        assert_eq!(tool.name(), "list_scheduled_tasks");
        assert!(!tool.description().is_empty());
    }

    #[test]
    fn filter_tasks_enabled() {
        let tasks = sample_tasks();
        let filtered: Vec<&ScheduledTask> = tasks.iter().filter(|t| t.enabled).collect();
        assert_eq!(filtered.len(), 2);
    }

    #[test]
    fn filter_tasks_disabled() {
        let tasks = sample_tasks();
        let filtered: Vec<&ScheduledTask> = tasks.iter().filter(|t| !t.enabled).collect();
        assert_eq!(filtered.len(), 1);
    }

    #[test]
    fn filter_tasks_user() {
        let tasks = sample_tasks();
        let filtered: Vec<&ScheduledTask> =
            tasks.iter().filter(|t| t.kind == TaskKind::User).collect();
        assert_eq!(filtered.len(), 2);
    }

    #[test]
    fn filter_tasks_builtin() {
        let tasks = sample_tasks();
        let filtered: Vec<&ScheduledTask> = tasks
            .iter()
            .filter(|t| t.kind == TaskKind::Builtin)
            .collect();
        assert_eq!(filtered.len(), 1);
    }

    fn sample_tasks() -> Vec<ScheduledTask> {
        let mut t1 = ScheduledTask::new(
            "check_update",
            "Check Update",
            Schedule::Interval { secs: 3600 },
        );
        t1.kind = TaskKind::Builtin;

        let t2 = ScheduledTask::user_task(
            "morning-brief",
            "Morning Briefing",
            Schedule::Daily { hour: 9, min: 0 },
        );

        let mut t3 = ScheduledTask::user_task(
            "weekly-report",
            "Weekly Report",
            Schedule::Weekly {
                weekdays: vec![Weekday::Fri],
                hour: 17,
                min: 0,
            },
        );
        t3.enabled = false;

        vec![t1, t2, t3]
    }
}
