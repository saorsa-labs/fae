//! Create scheduled task tool.
//!
//! Mutation tool that creates or updates a user-defined scheduled task.
//! Supports interval, daily, and weekly schedules.

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;
use crate::scheduler;
use crate::scheduler::tasks::{Schedule, ScheduledTask, Weekday};

use super::types::{Tool, ToolResult};

/// Tool that creates or updates a user-defined scheduled task.
///
/// Parses a schedule from the JSON arguments and persists the task.
/// If a task with the same ID already exists, it is updated (upsert).
///
/// # Arguments (JSON)
///
/// - `name` (string, required) — human-readable task name
/// - `schedule` (object, required) — schedule spec with `type` field:
///   - `{"type": "interval", "secs": 3600}` — run every N seconds
///   - `{"type": "daily", "hour": 9, "min": 0}` — run daily at the given local time
///   - `{"type": "weekly", "weekdays": ["mon","fri"], "hour": 9, "min": 0}` — run on selected weekdays
/// - `id` (string, optional) — task ID; auto-generated from name if omitted
/// - `payload` (any, optional) — opaque data stored with the task
pub struct SchedulerCreateTool;

impl SchedulerCreateTool {
    /// Create a new `SchedulerCreateTool`.
    pub fn new() -> Self {
        Self
    }
}

impl Default for SchedulerCreateTool {
    fn default() -> Self {
        Self::new()
    }
}

impl Tool for SchedulerCreateTool {
    fn name(&self) -> &str {
        "create_scheduled_task"
    }

    fn description(&self) -> &str {
        "Create or update a user-defined scheduled task. Supports interval, daily, and weekly schedules."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Human-readable name for the task"
                },
                "schedule": {
                    "type": "object",
                    "description": "Schedule spec. Must have a 'type' field: 'interval' (with 'secs'), 'daily' (with 'hour','min'), or 'weekly' (with 'weekdays','hour','min')"
                },
                "id": {
                    "type": "string",
                    "description": "Optional task ID. Auto-generated from name if omitted."
                },
                "payload": {
                    "description": "Optional data to store with the task"
                }
            },
            "required": ["name", "schedule"]
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let name = args.get("name").and_then(|v| v.as_str()).ok_or_else(|| {
            FaeLlmError::ToolValidationError("missing required argument: name".into())
        })?;

        if name.trim().is_empty() {
            return Err(FaeLlmError::ToolValidationError(
                "name must not be empty".into(),
            ));
        }

        let schedule_obj = args.get("schedule").ok_or_else(|| {
            FaeLlmError::ToolValidationError("missing required argument: schedule".into())
        })?;

        let schedule = parse_schedule(schedule_obj)?;

        let id = args
            .get("id")
            .and_then(|v| v.as_str())
            .map(String::from)
            .unwrap_or_else(|| slug_from_name(name));

        let payload = args.get("payload").cloned();

        let mut task = ScheduledTask::user_task(&id, name, schedule);
        task.payload = payload;

        scheduler::upsert_persisted_user_task(task)
            .map_err(|e| FaeLlmError::ToolExecutionError(format!("failed to save task: {e}")))?;

        Ok(ToolResult::success(format!(
            "Task '{name}' (id: {id}) created successfully."
        )))
    }

    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        mode == ToolMode::Full
    }
}

/// Parse a `Schedule` from a JSON value.
fn parse_schedule(obj: &serde_json::Value) -> Result<Schedule, FaeLlmError> {
    let schedule_type = obj.get("type").and_then(|v| v.as_str()).ok_or_else(|| {
        FaeLlmError::ToolValidationError(
            "schedule must have a 'type' field: 'interval', 'daily', or 'weekly'".into(),
        )
    })?;

    match schedule_type {
        "interval" => {
            let secs = obj.get("secs").and_then(|v| v.as_u64()).ok_or_else(|| {
                FaeLlmError::ToolValidationError(
                    "interval schedule requires 'secs' (positive integer)".into(),
                )
            })?;
            if secs == 0 {
                return Err(FaeLlmError::ToolValidationError(
                    "interval secs must be greater than 0".into(),
                ));
            }
            Ok(Schedule::Interval { secs })
        }
        "daily" => {
            let hour = parse_hour(obj)?;
            let min = parse_min(obj)?;
            Ok(Schedule::Daily { hour, min })
        }
        "weekly" => {
            let hour = parse_hour(obj)?;
            let min = parse_min(obj)?;
            let weekdays = parse_weekdays(obj)?;
            if weekdays.is_empty() {
                return Err(FaeLlmError::ToolValidationError(
                    "weekly schedule requires at least one weekday".into(),
                ));
            }
            Ok(Schedule::Weekly {
                weekdays,
                hour,
                min,
            })
        }
        other => Err(FaeLlmError::ToolValidationError(format!(
            "unknown schedule type: '{other}'. Must be 'interval', 'daily', or 'weekly'."
        ))),
    }
}

fn parse_hour(obj: &serde_json::Value) -> Result<u8, FaeLlmError> {
    let hour = obj.get("hour").and_then(|v| v.as_u64()).ok_or_else(|| {
        FaeLlmError::ToolValidationError("schedule requires 'hour' (0-23)".into())
    })?;
    if hour > 23 {
        return Err(FaeLlmError::ToolValidationError("hour must be 0-23".into()));
    }
    Ok(hour as u8)
}

fn parse_min(obj: &serde_json::Value) -> Result<u8, FaeLlmError> {
    let min = obj
        .get("min")
        .and_then(|v| v.as_u64())
        .ok_or_else(|| FaeLlmError::ToolValidationError("schedule requires 'min' (0-59)".into()))?;
    if min > 59 {
        return Err(FaeLlmError::ToolValidationError("min must be 0-59".into()));
    }
    Ok(min as u8)
}

fn parse_weekdays(obj: &serde_json::Value) -> Result<Vec<Weekday>, FaeLlmError> {
    let arr = obj
        .get("weekdays")
        .and_then(|v| v.as_array())
        .ok_or_else(|| {
            FaeLlmError::ToolValidationError("weekly schedule requires 'weekdays' array".into())
        })?;

    let mut days = Vec::with_capacity(arr.len());
    for item in arr {
        let day_str = item.as_str().ok_or_else(|| {
            FaeLlmError::ToolValidationError("weekday values must be strings".into())
        })?;
        let day = match day_str.to_lowercase().as_str() {
            "mon" | "monday" => Weekday::Mon,
            "tue" | "tuesday" => Weekday::Tue,
            "wed" | "wednesday" => Weekday::Wed,
            "thu" | "thursday" => Weekday::Thu,
            "fri" | "friday" => Weekday::Fri,
            "sat" | "saturday" => Weekday::Sat,
            "sun" | "sunday" => Weekday::Sun,
            other => {
                return Err(FaeLlmError::ToolValidationError(format!(
                    "unknown weekday: '{other}'. Use mon/tue/wed/thu/fri/sat/sun."
                )));
            }
        };
        days.push(day);
    }
    Ok(days)
}

/// Generate a slug-style ID from a task name.
fn slug_from_name(name: &str) -> String {
    name.to_lowercase()
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { '-' })
        .collect::<String>()
        .split('-')
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("-")
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    #[test]
    fn parse_schedule_interval() {
        let obj = serde_json::json!({"type": "interval", "secs": 3600});
        let schedule = parse_schedule(&obj).unwrap();
        assert!(matches!(schedule, Schedule::Interval { secs: 3600 }));
    }

    #[test]
    fn parse_schedule_interval_zero_rejected() {
        let obj = serde_json::json!({"type": "interval", "secs": 0});
        assert!(parse_schedule(&obj).is_err());
    }

    #[test]
    fn parse_schedule_daily() {
        let obj = serde_json::json!({"type": "daily", "hour": 9, "min": 30});
        let schedule = parse_schedule(&obj).unwrap();
        assert!(matches!(schedule, Schedule::Daily { hour: 9, min: 30 }));
    }

    #[test]
    fn parse_schedule_daily_invalid_hour() {
        let obj = serde_json::json!({"type": "daily", "hour": 25, "min": 0});
        assert!(parse_schedule(&obj).is_err());
    }

    #[test]
    fn parse_schedule_daily_invalid_min() {
        let obj = serde_json::json!({"type": "daily", "hour": 9, "min": 60});
        assert!(parse_schedule(&obj).is_err());
    }

    #[test]
    fn parse_schedule_weekly() {
        let obj = serde_json::json!({
            "type": "weekly",
            "weekdays": ["mon", "fri"],
            "hour": 14,
            "min": 0
        });
        let schedule = parse_schedule(&obj).unwrap();
        match schedule {
            Schedule::Weekly {
                weekdays,
                hour,
                min,
            } => {
                assert_eq!(weekdays.len(), 2);
                assert_eq!(hour, 14);
                assert_eq!(min, 0);
            }
            _ => panic!("expected Weekly schedule"),
        }
    }

    #[test]
    fn parse_schedule_weekly_full_names() {
        let obj = serde_json::json!({
            "type": "weekly",
            "weekdays": ["monday", "friday"],
            "hour": 9,
            "min": 0
        });
        let schedule = parse_schedule(&obj).unwrap();
        assert!(matches!(schedule, Schedule::Weekly { .. }));
    }

    #[test]
    fn parse_schedule_weekly_empty_weekdays_rejected() {
        let obj = serde_json::json!({
            "type": "weekly",
            "weekdays": [],
            "hour": 9,
            "min": 0
        });
        assert!(parse_schedule(&obj).is_err());
    }

    #[test]
    fn parse_schedule_unknown_type() {
        let obj = serde_json::json!({"type": "monthly"});
        assert!(parse_schedule(&obj).is_err());
    }

    #[test]
    fn parse_schedule_missing_type() {
        let obj = serde_json::json!({"secs": 60});
        assert!(parse_schedule(&obj).is_err());
    }

    #[test]
    fn slug_from_name_simple() {
        assert_eq!(slug_from_name("Morning Briefing"), "morning-briefing");
    }

    #[test]
    fn slug_from_name_special_chars() {
        assert_eq!(slug_from_name("My Task! (v2)"), "my-task-v2");
    }

    #[test]
    fn slug_from_name_already_slug() {
        assert_eq!(slug_from_name("daily-report"), "daily-report");
    }

    #[test]
    fn schema_valid() {
        let tool = SchedulerCreateTool::new();
        let schema = tool.schema();
        assert!(schema.is_object());
        let required = schema.get("required").and_then(|v| v.as_array());
        assert!(required.is_some());
        let required = required.unwrap();
        assert!(required.contains(&serde_json::json!("name")));
        assert!(required.contains(&serde_json::json!("schedule")));
    }

    #[test]
    fn not_allowed_in_readonly() {
        let tool = SchedulerCreateTool::new();
        assert!(!tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn execute_rejects_empty_name() {
        let tool = SchedulerCreateTool::new();
        let result = tool.execute(serde_json::json!({
            "name": "",
            "schedule": {"type": "interval", "secs": 60}
        }));
        assert!(result.is_err());
    }

    #[test]
    fn execute_rejects_missing_schedule() {
        let tool = SchedulerCreateTool::new();
        let result = tool.execute(serde_json::json!({
            "name": "Test Task"
        }));
        assert!(result.is_err());
    }
}
