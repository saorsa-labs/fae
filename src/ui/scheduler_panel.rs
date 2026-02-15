//! Scheduler management UI panel types and state.
//!
//! Provides types for managing the scheduler UI panel, including editing
//! tasks, form validation, and state management.

use crate::scheduler::tasks::{Schedule, ScheduledTask, TaskKind, Weekday};
use serde::{Deserialize, Serialize};

/// State for the scheduler management panel.
#[derive(Debug, Clone, Default)]
pub struct SchedulerPanelState {
    /// Currently selected task ID for viewing/editing.
    pub selected_task_id: Option<String>,
    /// Task currently being edited (if any).
    pub editing_task: Option<EditingTask>,
    /// Whether execution history view is visible.
    pub showing_history: bool,
    /// Error message to display (if any).
    pub error_message: Option<String>,
}

/// Task being created or edited in the UI.
#[derive(Debug, Clone, PartialEq)]
pub struct EditingTask {
    /// Task ID (None for new tasks, Some for existing).
    pub id: Option<String>,
    /// Task name (user-visible).
    pub name: String,
    /// Schedule configuration (form representation).
    pub schedule: ScheduleForm,
    /// Whether task is enabled.
    pub enabled: bool,
    /// Optional JSON payload (as string for editing).
    pub payload: Option<String>,
}

/// Form representation of schedule (uses Strings for user input).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ScheduleForm {
    /// Interval schedule with seconds as string.
    Interval {
        /// Seconds between runs (as string for editing).
        secs: String,
    },
    /// Daily schedule with hour and minute as strings.
    Daily {
        /// Hour (0-23, as string for editing).
        hour: String,
        /// Minute (0-59, as string for editing).
        min: String,
    },
    /// Weekly schedule with weekdays and time as strings.
    Weekly {
        /// Selected weekdays (as short strings: "mon", "tue", etc.).
        weekdays: Vec<String>,
        /// Hour (0-23, as string for editing).
        hour: String,
        /// Minute (0-59, as string for editing).
        min: String,
    },
}

impl Default for ScheduleForm {
    fn default() -> Self {
        Self::Interval {
            secs: "3600".to_owned(),
        }
    }
}

/// Validation error for editing task forms.
#[derive(Debug, Clone, PartialEq)]
pub enum ValidationError {
    /// Task name is empty or whitespace only.
    NameEmpty,
    /// Interval seconds is not a valid positive integer.
    IntervalSecsInvalid,
    /// Daily hour is not a valid integer 0-23.
    DailyHourInvalid,
    /// Daily minute is not a valid integer 0-59.
    DailyMinuteInvalid,
    /// Weekly hour is not a valid integer 0-23.
    WeeklyHourInvalid,
    /// Weekly minute is not a valid integer 0-59.
    WeeklyMinuteInvalid,
    /// Weekly weekdays list is empty.
    WeeklyWeekdaysEmpty,
    /// Weekly weekdays contains invalid values.
    WeeklyWeekdaysInvalid,
    /// Payload is not valid JSON (when present).
    PayloadInvalidJson,
}

impl std::fmt::Display for ValidationError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NameEmpty => write!(f, "Task name cannot be empty"),
            Self::IntervalSecsInvalid => write!(f, "Interval must be a positive number of seconds"),
            Self::DailyHourInvalid => write!(f, "Hour must be a number between 0 and 23"),
            Self::DailyMinuteInvalid => write!(f, "Minute must be a number between 0 and 59"),
            Self::WeeklyHourInvalid => write!(f, "Hour must be a number between 0 and 23"),
            Self::WeeklyMinuteInvalid => write!(f, "Minute must be a number between 0 and 59"),
            Self::WeeklyWeekdaysEmpty => write!(f, "At least one weekday must be selected"),
            Self::WeeklyWeekdaysInvalid => {
                write!(f, "Invalid weekday (use mon, tue, wed, thu, fri, sat, sun)")
            }
            Self::PayloadInvalidJson => write!(f, "Payload must be valid JSON"),
        }
    }
}

impl EditingTask {
    /// Create a new empty editing task with default values.
    #[must_use]
    pub fn new() -> Self {
        Self {
            id: None,
            name: String::new(),
            schedule: ScheduleForm::default(),
            enabled: true,
            payload: None,
        }
    }

    /// Create an editing task from an existing scheduled task.
    #[must_use]
    pub fn from_scheduled_task(task: &ScheduledTask) -> Self {
        let schedule = match &task.schedule {
            Schedule::Interval { secs } => ScheduleForm::Interval {
                secs: secs.to_string(),
            },
            Schedule::Daily { hour, min } => ScheduleForm::Daily {
                hour: hour.to_string(),
                min: min.to_string(),
            },
            Schedule::Weekly {
                weekdays,
                hour,
                min,
            } => ScheduleForm::Weekly {
                weekdays: weekdays.iter().map(weekday_to_short).collect(),
                hour: hour.to_string(),
                min: min.to_string(),
            },
        };

        let payload = task
            .payload
            .as_ref()
            .map(|v| serde_json::to_string_pretty(v).unwrap_or_else(|_| v.to_string()));

        Self {
            id: Some(task.id.clone()),
            name: task.name.clone(),
            schedule,
            enabled: task.enabled,
            payload,
        }
    }

    /// Convert editing task to a scheduled task for persistence.
    ///
    /// # Errors
    /// Returns validation error if form values are invalid.
    pub fn to_scheduled_task(&self) -> Result<ScheduledTask, ValidationError> {
        self.validate()?;

        let schedule = match &self.schedule {
            ScheduleForm::Interval { secs } => {
                let secs_val = secs
                    .parse::<u64>()
                    .map_err(|_| ValidationError::IntervalSecsInvalid)?;
                if secs_val == 0 {
                    return Err(ValidationError::IntervalSecsInvalid);
                }
                Schedule::Interval { secs: secs_val }
            }
            ScheduleForm::Daily { hour, min } => {
                let hour_val = hour
                    .parse::<u8>()
                    .map_err(|_| ValidationError::DailyHourInvalid)?;
                let min_val = min
                    .parse::<u8>()
                    .map_err(|_| ValidationError::DailyMinuteInvalid)?;
                if hour_val > 23 {
                    return Err(ValidationError::DailyHourInvalid);
                }
                if min_val > 59 {
                    return Err(ValidationError::DailyMinuteInvalid);
                }
                Schedule::Daily {
                    hour: hour_val,
                    min: min_val,
                }
            }
            ScheduleForm::Weekly {
                weekdays,
                hour,
                min,
            } => {
                if weekdays.is_empty() {
                    return Err(ValidationError::WeeklyWeekdaysEmpty);
                }
                let weekdays_parsed: Result<Vec<Weekday>, _> =
                    weekdays.iter().map(|s| weekday_from_short(s)).collect();
                let weekdays_val =
                    weekdays_parsed.map_err(|_| ValidationError::WeeklyWeekdaysInvalid)?;

                let hour_val = hour
                    .parse::<u8>()
                    .map_err(|_| ValidationError::WeeklyHourInvalid)?;
                let min_val = min
                    .parse::<u8>()
                    .map_err(|_| ValidationError::WeeklyMinuteInvalid)?;
                if hour_val > 23 {
                    return Err(ValidationError::WeeklyHourInvalid);
                }
                if min_val > 59 {
                    return Err(ValidationError::WeeklyMinuteInvalid);
                }
                Schedule::Weekly {
                    weekdays: weekdays_val,
                    hour: hour_val,
                    min: min_val,
                }
            }
        };

        let payload_json = if let Some(ref payload_str) = self.payload {
            let trimmed = payload_str.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(
                    serde_json::from_str(trimmed)
                        .map_err(|_| ValidationError::PayloadInvalidJson)?,
                )
            }
        } else {
            None
        };

        let id = self
            .id
            .clone()
            .unwrap_or_else(|| slug_from_name(&self.name));

        Ok(ScheduledTask {
            id,
            name: self.name.clone(),
            schedule,
            last_run: None,
            next_run: None,
            enabled: self.enabled,
            kind: TaskKind::User,
            payload: payload_json,
            failure_streak: 0,
            max_retries: 3,
            retry_backoff_secs: 60,
            max_failure_streak_before_pause: 5,
            soft_timeout_secs: 300,
            last_error: None,
        })
    }

    /// Validate the editing task form.
    ///
    /// # Errors
    /// Returns the first validation error found.
    pub fn validate(&self) -> Result<(), ValidationError> {
        if self.name.trim().is_empty() {
            return Err(ValidationError::NameEmpty);
        }

        match &self.schedule {
            ScheduleForm::Interval { secs } => {
                let secs_val = secs
                    .parse::<u64>()
                    .map_err(|_| ValidationError::IntervalSecsInvalid)?;
                if secs_val == 0 {
                    return Err(ValidationError::IntervalSecsInvalid);
                }
            }
            ScheduleForm::Daily { hour, min } => {
                let hour_val = hour
                    .parse::<u8>()
                    .map_err(|_| ValidationError::DailyHourInvalid)?;
                let min_val = min
                    .parse::<u8>()
                    .map_err(|_| ValidationError::DailyMinuteInvalid)?;
                if hour_val > 23 {
                    return Err(ValidationError::DailyHourInvalid);
                }
                if min_val > 59 {
                    return Err(ValidationError::DailyMinuteInvalid);
                }
            }
            ScheduleForm::Weekly {
                weekdays,
                hour,
                min,
            } => {
                if weekdays.is_empty() {
                    return Err(ValidationError::WeeklyWeekdaysEmpty);
                }
                for wd in weekdays {
                    weekday_from_short(wd).map_err(|_| ValidationError::WeeklyWeekdaysInvalid)?;
                }
                let hour_val = hour
                    .parse::<u8>()
                    .map_err(|_| ValidationError::WeeklyHourInvalid)?;
                let min_val = min
                    .parse::<u8>()
                    .map_err(|_| ValidationError::WeeklyMinuteInvalid)?;
                if hour_val > 23 {
                    return Err(ValidationError::WeeklyHourInvalid);
                }
                if min_val > 59 {
                    return Err(ValidationError::WeeklyMinuteInvalid);
                }
            }
        }

        if let Some(ref payload_str) = self.payload {
            let trimmed = payload_str.trim();
            if !trimmed.is_empty() {
                serde_json::from_str::<serde_json::Value>(trimmed)
                    .map_err(|_| ValidationError::PayloadInvalidJson)?;
            }
        }

        Ok(())
    }
}

impl Default for EditingTask {
    fn default() -> Self {
        Self::new()
    }
}

/// Convert weekday enum to short string representation.
fn weekday_to_short(wd: &Weekday) -> String {
    match wd {
        Weekday::Mon => "mon",
        Weekday::Tue => "tue",
        Weekday::Wed => "wed",
        Weekday::Thu => "thu",
        Weekday::Fri => "fri",
        Weekday::Sat => "sat",
        Weekday::Sun => "sun",
    }
    .to_owned()
}

/// Convert short string to weekday enum.
///
/// # Errors
/// Returns error if string is not a valid weekday.
fn weekday_from_short(s: &str) -> Result<Weekday, ()> {
    match s.to_lowercase().as_str() {
        "mon" | "monday" => Ok(Weekday::Mon),
        "tue" | "tuesday" => Ok(Weekday::Tue),
        "wed" | "wednesday" => Ok(Weekday::Wed),
        "thu" | "thursday" => Ok(Weekday::Thu),
        "fri" | "friday" => Ok(Weekday::Fri),
        "sat" | "saturday" => Ok(Weekday::Sat),
        "sun" | "sunday" => Ok(Weekday::Sun),
        _ => Err(()),
    }
}

/// Generate a slug ID from a task name.
fn slug_from_name(name: &str) -> String {
    name.to_lowercase()
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { '_' })
        .collect::<String>()
        .trim_matches('_')
        .to_owned()
}

/// Task list view component — displays all scheduled tasks.
#[derive(Debug, Clone, Default)]
pub struct TaskListView {
    /// Tasks to display.
    pub tasks: Vec<ScheduledTask>,
    /// Currently selected task ID.
    pub selected_id: Option<String>,
}

impl TaskListView {
    /// Create a new task list view.
    #[must_use]
    pub fn new(tasks: Vec<ScheduledTask>) -> Self {
        Self {
            tasks,
            selected_id: None,
        }
    }

    /// Set the selected task ID.
    pub fn set_selected(&mut self, task_id: Option<String>) {
        self.selected_id = task_id;
    }

    /// Get the currently selected task.
    #[must_use]
    pub fn selected_task(&self) -> Option<&ScheduledTask> {
        let id = self.selected_id.as_ref()?;
        self.tasks.iter().find(|t| &t.id == id)
    }

    /// Format a task for display in the list.
    #[must_use]
    pub fn format_task(&self, task: &ScheduledTask) -> String {
        let status = if task.enabled { "●" } else { "○" };
        let schedule = format_schedule(&task.schedule);
        let last_run = task
            .last_run
            .map(format_timestamp)
            .unwrap_or_else(|| "Never".to_owned());

        format!(
            "{} {} | {} | Last: {}",
            status, task.name, schedule, last_run
        )
    }
}

/// Format a schedule for human-readable display.
#[must_use]
pub fn format_schedule(schedule: &Schedule) -> String {
    match schedule {
        Schedule::Interval { secs } => {
            if secs % 86400 == 0 {
                format!("Every {} day(s)", secs / 86400)
            } else if secs % 3600 == 0 {
                format!("Every {} hour(s)", secs / 3600)
            } else if secs % 60 == 0 {
                format!("Every {} minute(s)", secs / 60)
            } else {
                format!("Every {} second(s)", secs)
            }
        }
        Schedule::Daily { hour, min } => {
            format!("Daily at {:02}:{:02}", hour, min)
        }
        Schedule::Weekly {
            weekdays,
            hour,
            min,
        } => {
            let days: Vec<String> = weekdays.iter().map(weekday_to_short).collect();
            format!("Weekly on {} at {:02}:{:02}", days.join(", "), hour, min)
        }
    }
}

/// Format a timestamp for human-readable display.
#[must_use]
pub fn format_timestamp(timestamp: u64) -> String {
    use std::time::{SystemTime, UNIX_EPOCH};

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let elapsed = now.saturating_sub(timestamp);

    if elapsed < 60 {
        "Just now".to_owned()
    } else if elapsed < 3600 {
        format!("{} minute(s) ago", elapsed / 60)
    } else if elapsed < 86400 {
        format!("{} hour(s) ago", elapsed / 3600)
    } else if elapsed < 604800 {
        format!("{} day(s) ago", elapsed / 86400)
    } else {
        // For older timestamps, show date
        use chrono::{DateTime, Utc};
        let dt: DateTime<Utc> = DateTime::from_timestamp(timestamp as i64, 0)
            .unwrap_or_else(|| DateTime::from_timestamp(0, 0).unwrap_or_default());
        dt.format("%Y-%m-%d %H:%M").to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    #[test]
    fn test_new_editing_task_has_defaults() {
        let task = EditingTask::new();
        assert_eq!(task.id, None);
        assert_eq!(task.name, "");
        assert!(task.enabled);
        assert_eq!(task.payload, None);
        assert!(matches!(task.schedule, ScheduleForm::Interval { .. }));
    }

    #[test]
    fn test_from_scheduled_task_interval() {
        let scheduled = ScheduledTask {
            id: "test_task".to_owned(),
            name: "Test Task".to_owned(),
            schedule: Schedule::Interval { secs: 3600 },
            last_run: None,
            next_run: None,
            enabled: true,
            kind: TaskKind::User,
            payload: None,
            failure_streak: 0,
            max_retries: 3,
            retry_backoff_secs: 60,
            max_failure_streak_before_pause: 5,
            soft_timeout_secs: 300,
            last_error: None,
        };

        let editing = EditingTask::from_scheduled_task(&scheduled);
        assert_eq!(editing.id, Some("test_task".to_owned()));
        assert_eq!(editing.name, "Test Task");
        assert!(editing.enabled);
        assert!(matches!(
            editing.schedule,
            ScheduleForm::Interval { ref secs } if secs == "3600"
        ));
    }

    #[test]
    fn test_from_scheduled_task_daily() {
        let scheduled = ScheduledTask {
            id: "daily_task".to_owned(),
            name: "Daily Task".to_owned(),
            schedule: Schedule::Daily { hour: 9, min: 30 },
            last_run: None,
            next_run: None,
            enabled: true,
            kind: TaskKind::User,
            payload: None,
            failure_streak: 0,
            max_retries: 3,
            retry_backoff_secs: 60,
            max_failure_streak_before_pause: 5,
            soft_timeout_secs: 300,
            last_error: None,
        };

        let editing = EditingTask::from_scheduled_task(&scheduled);
        assert!(matches!(
            editing.schedule,
            ScheduleForm::Daily { ref hour, ref min } if hour == "9" && min == "30"
        ));
    }

    #[test]
    fn test_from_scheduled_task_weekly() {
        let scheduled = ScheduledTask {
            id: "weekly_task".to_owned(),
            name: "Weekly Task".to_owned(),
            schedule: Schedule::Weekly {
                weekdays: vec![Weekday::Mon, Weekday::Wed, Weekday::Fri],
                hour: 14,
                min: 0,
            },
            last_run: None,
            next_run: None,
            enabled: true,
            kind: TaskKind::User,
            payload: None,
            failure_streak: 0,
            max_retries: 3,
            retry_backoff_secs: 60,
            max_failure_streak_before_pause: 5,
            soft_timeout_secs: 300,
            last_error: None,
        };

        let editing = EditingTask::from_scheduled_task(&scheduled);
        if let ScheduleForm::Weekly {
            weekdays,
            hour,
            min,
        } = editing.schedule
        {
            assert_eq!(weekdays, vec!["mon", "wed", "fri"]);
            assert_eq!(hour, "14");
            assert_eq!(min, "0");
        } else {
            panic!("Expected Weekly schedule");
        }
    }

    #[test]
    fn test_to_scheduled_task_interval_valid() {
        let editing = EditingTask {
            id: Some("test".to_owned()),
            name: "Test Task".to_owned(),
            schedule: ScheduleForm::Interval {
                secs: "7200".to_owned(),
            },
            enabled: true,
            payload: None,
        };

        let result = editing.to_scheduled_task();
        assert!(result.is_ok());
        let task = result.unwrap();
        assert_eq!(task.id, "test");
        assert_eq!(task.name, "Test Task");
        assert!(matches!(task.schedule, Schedule::Interval { secs: 7200 }));
    }

    #[test]
    fn test_to_scheduled_task_generates_id_if_none() {
        let editing = EditingTask {
            id: None,
            name: "My Cool Task!".to_owned(),
            schedule: ScheduleForm::Interval {
                secs: "60".to_owned(),
            },
            enabled: true,
            payload: None,
        };

        let result = editing.to_scheduled_task();
        assert!(result.is_ok());
        let task = result.unwrap();
        assert_eq!(task.id, "my_cool_task");
    }

    #[test]
    fn test_validate_empty_name_fails() {
        let editing = EditingTask {
            id: None,
            name: "   ".to_owned(),
            schedule: ScheduleForm::Interval {
                secs: "60".to_owned(),
            },
            enabled: true,
            payload: None,
        };

        let result = editing.validate();
        assert_eq!(result, Err(ValidationError::NameEmpty));
    }

    #[test]
    fn test_validate_interval_zero_fails() {
        let editing = EditingTask {
            id: None,
            name: "Task".to_owned(),
            schedule: ScheduleForm::Interval {
                secs: "0".to_owned(),
            },
            enabled: true,
            payload: None,
        };

        let result = editing.validate();
        assert_eq!(result, Err(ValidationError::IntervalSecsInvalid));
    }

    #[test]
    fn test_validate_interval_non_numeric_fails() {
        let editing = EditingTask {
            id: None,
            name: "Task".to_owned(),
            schedule: ScheduleForm::Interval {
                secs: "abc".to_owned(),
            },
            enabled: true,
            payload: None,
        };

        let result = editing.validate();
        assert_eq!(result, Err(ValidationError::IntervalSecsInvalid));
    }

    #[test]
    fn test_validate_daily_hour_out_of_range_fails() {
        let editing = EditingTask {
            id: None,
            name: "Task".to_owned(),
            schedule: ScheduleForm::Daily {
                hour: "24".to_owned(),
                min: "0".to_owned(),
            },
            enabled: true,
            payload: None,
        };

        let result = editing.validate();
        assert_eq!(result, Err(ValidationError::DailyHourInvalid));
    }

    #[test]
    fn test_validate_daily_minute_out_of_range_fails() {
        let editing = EditingTask {
            id: None,
            name: "Task".to_owned(),
            schedule: ScheduleForm::Daily {
                hour: "12".to_owned(),
                min: "60".to_owned(),
            },
            enabled: true,
            payload: None,
        };

        let result = editing.validate();
        assert_eq!(result, Err(ValidationError::DailyMinuteInvalid));
    }

    #[test]
    fn test_validate_weekly_empty_weekdays_fails() {
        let editing = EditingTask {
            id: None,
            name: "Task".to_owned(),
            schedule: ScheduleForm::Weekly {
                weekdays: vec![],
                hour: "9".to_owned(),
                min: "0".to_owned(),
            },
            enabled: true,
            payload: None,
        };

        let result = editing.validate();
        assert_eq!(result, Err(ValidationError::WeeklyWeekdaysEmpty));
    }

    #[test]
    fn test_validate_weekly_invalid_weekday_fails() {
        let editing = EditingTask {
            id: None,
            name: "Task".to_owned(),
            schedule: ScheduleForm::Weekly {
                weekdays: vec!["mon".to_owned(), "invalid".to_owned()],
                hour: "9".to_owned(),
                min: "0".to_owned(),
            },
            enabled: true,
            payload: None,
        };

        let result = editing.validate();
        assert_eq!(result, Err(ValidationError::WeeklyWeekdaysInvalid));
    }

    #[test]
    fn test_validate_invalid_json_payload_fails() {
        let editing = EditingTask {
            id: None,
            name: "Task".to_owned(),
            schedule: ScheduleForm::Interval {
                secs: "60".to_owned(),
            },
            enabled: true,
            payload: Some("{not valid json}".to_owned()),
        };

        let result = editing.validate();
        assert_eq!(result, Err(ValidationError::PayloadInvalidJson));
    }

    #[test]
    fn test_validate_empty_payload_is_valid() {
        let editing = EditingTask {
            id: None,
            name: "Task".to_owned(),
            schedule: ScheduleForm::Interval {
                secs: "60".to_owned(),
            },
            enabled: true,
            payload: Some("   ".to_owned()),
        };

        let result = editing.validate();
        assert!(result.is_ok());
    }

    #[test]
    fn test_validate_valid_json_payload_succeeds() {
        let editing = EditingTask {
            id: None,
            name: "Task".to_owned(),
            schedule: ScheduleForm::Interval {
                secs: "60".to_owned(),
            },
            enabled: true,
            payload: Some(r#"{"prompt": "test"}"#.to_owned()),
        };

        let result = editing.validate();
        assert!(result.is_ok());
    }

    #[test]
    fn test_round_trip_interval() {
        let original = ScheduledTask {
            id: "test".to_owned(),
            name: "Test".to_owned(),
            schedule: Schedule::Interval { secs: 3600 },
            last_run: None,
            next_run: None,
            enabled: true,
            kind: TaskKind::User,
            payload: None,
            failure_streak: 0,
            max_retries: 3,
            retry_backoff_secs: 60,
            max_failure_streak_before_pause: 5,
            soft_timeout_secs: 300,
            last_error: None,
        };

        let editing = EditingTask::from_scheduled_task(&original);
        let converted = editing.to_scheduled_task().unwrap();

        assert_eq!(converted.id, original.id);
        assert_eq!(converted.name, original.name);
        assert!(matches!(
            converted.schedule,
            Schedule::Interval { secs: 3600 }
        ));
        assert_eq!(converted.enabled, original.enabled);
    }

    #[test]
    fn test_weekday_conversions() {
        assert_eq!(weekday_to_short(&Weekday::Mon), "mon");
        assert_eq!(weekday_from_short("mon"), Ok(Weekday::Mon));
        assert_eq!(weekday_from_short("Monday"), Ok(Weekday::Mon));
        assert_eq!(weekday_from_short("MONDAY"), Ok(Weekday::Mon));
        assert!(weekday_from_short("invalid").is_err());
    }

    #[test]
    fn test_slug_from_name() {
        assert_eq!(slug_from_name("My Cool Task"), "my_cool_task");
        assert_eq!(slug_from_name("Test@123!"), "test_123");
        assert_eq!(slug_from_name("___test___"), "test");
    }

    // Task 3: Task List View Tests

    #[test]
    fn test_task_list_view_new() {
        let tasks = vec![ScheduledTask {
            id: "test".to_owned(),
            name: "Test Task".to_owned(),
            schedule: Schedule::Interval { secs: 3600 },
            last_run: None,
            next_run: None,
            enabled: true,
            kind: TaskKind::User,
            payload: None,
            failure_streak: 0,
            max_retries: 3,
            retry_backoff_secs: 60,
            max_failure_streak_before_pause: 5,
            soft_timeout_secs: 300,
            last_error: None,
        }];

        let view = TaskListView::new(tasks.clone());
        assert_eq!(view.tasks.len(), 1);
        assert_eq!(view.selected_id, None);
        assert_eq!(view.tasks[0].id, "test");
    }

    #[test]
    fn test_task_list_view_set_selected() {
        let tasks = vec![ScheduledTask {
            id: "test".to_owned(),
            name: "Test Task".to_owned(),
            schedule: Schedule::Interval { secs: 3600 },
            last_run: None,
            next_run: None,
            enabled: true,
            kind: TaskKind::User,
            payload: None,
            failure_streak: 0,
            max_retries: 3,
            retry_backoff_secs: 60,
            max_failure_streak_before_pause: 5,
            soft_timeout_secs: 300,
            last_error: None,
        }];

        let mut view = TaskListView::new(tasks);
        view.set_selected(Some("test".to_owned()));
        assert_eq!(view.selected_id, Some("test".to_owned()));
    }

    #[test]
    fn test_task_list_view_selected_task() {
        let tasks = vec![ScheduledTask {
            id: "test".to_owned(),
            name: "Test Task".to_owned(),
            schedule: Schedule::Interval { secs: 3600 },
            last_run: None,
            next_run: None,
            enabled: true,
            kind: TaskKind::User,
            payload: None,
            failure_streak: 0,
            max_retries: 3,
            retry_backoff_secs: 60,
            max_failure_streak_before_pause: 5,
            soft_timeout_secs: 300,
            last_error: None,
        }];

        let mut view = TaskListView::new(tasks);
        view.set_selected(Some("test".to_owned()));

        let selected = view.selected_task();
        assert!(selected.is_some());
        let task = selected.unwrap();
        assert_eq!(task.id, "test");
        assert_eq!(task.name, "Test Task");
    }

    #[test]
    fn test_task_list_view_selected_task_none_when_no_selection() {
        let tasks = vec![ScheduledTask {
            id: "test".to_owned(),
            name: "Test Task".to_owned(),
            schedule: Schedule::Interval { secs: 3600 },
            last_run: None,
            next_run: None,
            enabled: true,
            kind: TaskKind::User,
            payload: None,
            failure_streak: 0,
            max_retries: 3,
            retry_backoff_secs: 60,
            max_failure_streak_before_pause: 5,
            soft_timeout_secs: 300,
            last_error: None,
        }];

        let view = TaskListView::new(tasks);
        assert!(view.selected_task().is_none());
    }

    #[test]
    fn test_format_task_enabled() {
        let task = ScheduledTask {
            id: "test".to_owned(),
            name: "Test Task".to_owned(),
            schedule: Schedule::Interval { secs: 3600 },
            last_run: None,
            next_run: None,
            enabled: true,
            kind: TaskKind::User,
            payload: None,
            failure_streak: 0,
            max_retries: 3,
            retry_backoff_secs: 60,
            max_failure_streak_before_pause: 5,
            soft_timeout_secs: 300,
            last_error: None,
        };

        let view = TaskListView::new(vec![task.clone()]);
        let formatted = view.format_task(&task);
        assert!(formatted.contains("●"));
        assert!(formatted.contains("Test Task"));
        assert!(formatted.contains("Every 1 hour(s)"));
        assert!(formatted.contains("Never"));
    }

    #[test]
    fn test_format_task_disabled() {
        let task = ScheduledTask {
            id: "test".to_owned(),
            name: "Test Task".to_owned(),
            schedule: Schedule::Interval { secs: 3600 },
            last_run: None,
            next_run: None,
            enabled: false,
            kind: TaskKind::User,
            payload: None,
            failure_streak: 0,
            max_retries: 3,
            retry_backoff_secs: 60,
            max_failure_streak_before_pause: 5,
            soft_timeout_secs: 300,
            last_error: None,
        };

        let view = TaskListView::new(vec![task.clone()]);
        let formatted = view.format_task(&task);
        assert!(formatted.contains("○"));
        assert!(formatted.contains("Test Task"));
    }

    #[test]
    fn test_format_schedule_interval_seconds() {
        let schedule = Schedule::Interval { secs: 45 };
        assert_eq!(format_schedule(&schedule), "Every 45 second(s)");
    }

    #[test]
    fn test_format_schedule_interval_minutes() {
        let schedule = Schedule::Interval { secs: 300 };
        assert_eq!(format_schedule(&schedule), "Every 5 minute(s)");
    }

    #[test]
    fn test_format_schedule_interval_hours() {
        let schedule = Schedule::Interval { secs: 7200 };
        assert_eq!(format_schedule(&schedule), "Every 2 hour(s)");
    }

    #[test]
    fn test_format_schedule_interval_days() {
        let schedule = Schedule::Interval { secs: 172800 };
        assert_eq!(format_schedule(&schedule), "Every 2 day(s)");
    }

    #[test]
    fn test_format_schedule_daily() {
        let schedule = Schedule::Daily { hour: 9, min: 30 };
        assert_eq!(format_schedule(&schedule), "Daily at 09:30");
    }

    #[test]
    fn test_format_schedule_weekly() {
        let schedule = Schedule::Weekly {
            weekdays: vec![Weekday::Mon, Weekday::Wed, Weekday::Fri],
            hour: 14,
            min: 0,
        };
        assert_eq!(
            format_schedule(&schedule),
            "Weekly on mon, wed, fri at 14:00"
        );
    }

    #[test]
    fn test_format_timestamp_just_now() {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let timestamp = now - 30; // 30 seconds ago
        assert_eq!(format_timestamp(timestamp), "Just now");
    }

    #[test]
    fn test_format_timestamp_minutes_ago() {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let timestamp = now - 300; // 5 minutes ago
        assert_eq!(format_timestamp(timestamp), "5 minute(s) ago");
    }

    #[test]
    fn test_format_timestamp_hours_ago() {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let timestamp = now - 7200; // 2 hours ago
        assert_eq!(format_timestamp(timestamp), "2 hour(s) ago");
    }

    #[test]
    fn test_format_timestamp_days_ago() {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        let timestamp = now - 172800; // 2 days ago
        assert_eq!(format_timestamp(timestamp), "2 day(s) ago");
    }

    #[test]
    fn test_format_timestamp_old_date() {
        let timestamp = 1609459200u64; // 2021-01-01 00:00:00 UTC
        let formatted = format_timestamp(timestamp);
        assert!(formatted.contains("2021-01-01"));
    }
}
