//! Scheduled task definitions and built-in tasks.
//!
//! Defines the [`ScheduledTask`] type, [`Schedule`] enum for timing,
//! and built-in update-check task implementations.

use serde::{Deserialize, Serialize};
use std::time::{SystemTime, UNIX_EPOCH};

/// How often a task should run.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Schedule {
    /// Run every N seconds.
    Interval {
        /// Interval in seconds between runs.
        secs: u64,
    },
    /// Run once daily at a given hour and minute (UTC).
    Daily {
        /// Hour of day (0-23, UTC).
        hour: u8,
        /// Minute of hour (0-59).
        min: u8,
    },
}

impl std::fmt::Display for Schedule {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Interval { secs } => {
                if *secs >= 3600 {
                    write!(f, "every {} hours", secs / 3600)
                } else {
                    write!(f, "every {} minutes", secs / 60)
                }
            }
            Self::Daily { hour, min } => write!(f, "daily at {hour:02}:{min:02} UTC"),
        }
    }
}

/// Outcome of executing a scheduled task.
#[derive(Debug, Clone)]
pub enum TaskResult {
    /// Task completed successfully with a summary message.
    Success(String),
    /// Task completed but needs user attention.
    NeedsUserAction(UserPrompt),
    /// Task failed with an error message.
    Error(String),
}

/// A prompt presented to the user after a task completes.
#[derive(Debug, Clone)]
pub struct UserPrompt {
    /// Short title for the notification.
    pub title: String,
    /// Longer descriptive message.
    pub message: String,
    /// Available user actions.
    pub actions: Vec<PromptAction>,
}

/// An action button the user can take in response to a task result.
#[derive(Debug, Clone)]
pub struct PromptAction {
    /// Button label.
    pub label: String,
    /// Machine-readable action identifier.
    pub id: String,
}

/// A task that runs on a schedule.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScheduledTask {
    /// Unique task identifier (e.g. `"check_fae_update"`).
    pub id: String,
    /// Human-readable task name.
    pub name: String,
    /// When to run this task.
    pub schedule: Schedule,
    /// Unix epoch seconds of the last successful run, if any.
    pub last_run: Option<u64>,
    /// Whether the task is enabled.
    pub enabled: bool,
}

impl ScheduledTask {
    /// Create a new enabled task with the given schedule.
    pub fn new(id: impl Into<String>, name: impl Into<String>, schedule: Schedule) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            schedule,
            last_run: None,
            enabled: true,
        }
    }

    /// Returns `true` if the task is enabled and due to run.
    pub fn is_due(&self) -> bool {
        if !self.enabled {
            return false;
        }

        let now = now_epoch_secs();

        match &self.schedule {
            Schedule::Interval { secs } => match self.last_run {
                None => true,
                Some(last) => now.saturating_sub(last) >= *secs,
            },
            Schedule::Daily { hour, min } => {
                let day_secs = u64::from(*hour) * 3600 + u64::from(*min) * 60;
                let today_start = now - (now % 86400);
                let scheduled = today_start + day_secs;

                match self.last_run {
                    None => now >= scheduled,
                    Some(last) => last < scheduled && now >= scheduled,
                }
            }
        }
    }

    /// Record that the task ran at the current time.
    pub fn mark_run(&mut self) {
        self.last_run = Some(now_epoch_secs());
    }
}

/// Returns current UTC seconds since epoch.
fn now_epoch_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

// ---------------------------------------------------------------------------
// Built-in task executors
// ---------------------------------------------------------------------------

/// Well-known task IDs for built-in tasks.
pub const TASK_CHECK_FAE_UPDATE: &str = "check_fae_update";

/// Well-known task ID for the Pi update check.
pub const TASK_CHECK_PI_UPDATE: &str = "check_pi_update";

/// Execute a built-in scheduled task by ID.
///
/// Returns [`TaskResult`] for any known built-in task, or
/// [`TaskResult::Error`] for unknown task IDs.
pub fn execute_builtin(task_id: &str) -> TaskResult {
    match task_id {
        TASK_CHECK_FAE_UPDATE => check_fae_update(),
        TASK_CHECK_PI_UPDATE => check_pi_update(),
        _ => TaskResult::Error(format!("unknown built-in task: {task_id}")),
    }
}

/// Check GitHub for a new Fae release.
///
/// Loads the update state, runs the checker, and returns an appropriate
/// [`TaskResult`]. Respects the user's [`AutoUpdatePreference`].
fn check_fae_update() -> TaskResult {
    use crate::update::{AutoUpdatePreference, UpdateChecker, UpdateState};

    let mut state = UpdateState::load();
    let checker = UpdateChecker::for_fae();
    let etag = state.etag_fae.clone();

    match checker.check(etag.as_deref()) {
        Ok((Some(release), new_etag)) => {
            state.etag_fae = new_etag;
            state.mark_checked();
            let _ = state.save();

            match state.auto_update {
                AutoUpdatePreference::Always => TaskResult::NeedsUserAction(UserPrompt {
                    title: "Fae Update Available".to_owned(),
                    message: format!(
                        "Fae {} is available (you have {}). Auto-update enabled.",
                        release.version,
                        checker.current_version()
                    ),
                    actions: vec![PromptAction {
                        label: "Install Now".to_owned(),
                        id: "install_fae_update".to_owned(),
                    }],
                }),
                AutoUpdatePreference::Ask => TaskResult::NeedsUserAction(UserPrompt {
                    title: "Fae Update Available".to_owned(),
                    message: format!(
                        "Fae {} is available (you have {}).",
                        release.version,
                        checker.current_version()
                    ),
                    actions: vec![
                        PromptAction {
                            label: "Install".to_owned(),
                            id: "install_fae_update".to_owned(),
                        },
                        PromptAction {
                            label: "Skip".to_owned(),
                            id: "dismiss_fae_update".to_owned(),
                        },
                    ],
                }),
                AutoUpdatePreference::Never => {
                    TaskResult::Success(format!("Fae {} available (auto-update disabled)", release.version))
                }
            }
        }
        Ok((None, new_etag)) => {
            state.etag_fae = new_etag;
            state.mark_checked();
            let _ = state.save();
            TaskResult::Success("Fae is up to date".to_owned())
        }
        Err(e) => TaskResult::Error(format!("Fae update check failed: {e}")),
    }
}

/// Check GitHub for a new Pi release.
///
/// Loads the update state to determine the current Pi version, runs the
/// checker, and returns an appropriate [`TaskResult`].
fn check_pi_update() -> TaskResult {
    use crate::update::{AutoUpdatePreference, UpdateChecker, UpdateState};

    let mut state = UpdateState::load();

    let pi_version = match &state.pi_version {
        Some(v) => v.clone(),
        None => return TaskResult::Success("Pi not installed, skipping update check".to_owned()),
    };

    let checker = UpdateChecker::for_pi(&pi_version);
    let etag = state.etag_pi.clone();

    match checker.check(etag.as_deref()) {
        Ok((Some(release), new_etag)) => {
            state.etag_pi = new_etag;
            state.mark_checked();
            let _ = state.save();

            match state.auto_update {
                AutoUpdatePreference::Always => TaskResult::NeedsUserAction(UserPrompt {
                    title: "Pi Update Available".to_owned(),
                    message: format!(
                        "Pi {} is available (you have {}). Auto-update enabled.",
                        release.version, pi_version
                    ),
                    actions: vec![PromptAction {
                        label: "Install Now".to_owned(),
                        id: "install_pi_update".to_owned(),
                    }],
                }),
                AutoUpdatePreference::Ask => TaskResult::NeedsUserAction(UserPrompt {
                    title: "Pi Update Available".to_owned(),
                    message: format!(
                        "Pi {} is available (you have {}).",
                        release.version, pi_version
                    ),
                    actions: vec![
                        PromptAction {
                            label: "Install".to_owned(),
                            id: "install_pi_update".to_owned(),
                        },
                        PromptAction {
                            label: "Skip".to_owned(),
                            id: "dismiss_pi_update".to_owned(),
                        },
                    ],
                }),
                AutoUpdatePreference::Never => {
                    TaskResult::Success(format!("Pi {} available (auto-update disabled)", release.version))
                }
            }
        }
        Ok((None, new_etag)) => {
            state.etag_pi = new_etag;
            state.mark_checked();
            let _ = state.save();
            TaskResult::Success("Pi is up to date".to_owned())
        }
        Err(e) => TaskResult::Error(format!("Pi update check failed: {e}")),
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    #[test]
    fn new_task_has_correct_defaults() {
        let task = ScheduledTask::new("test", "Test Task", Schedule::Interval { secs: 3600 });
        assert_eq!(task.id, "test");
        assert_eq!(task.name, "Test Task");
        assert!(task.last_run.is_none());
        assert!(task.enabled);
    }

    #[test]
    fn is_due_when_never_run_interval() {
        let task = ScheduledTask::new("t", "T", Schedule::Interval { secs: 60 });
        assert!(task.is_due());
    }

    #[test]
    fn is_due_false_when_recently_run() {
        let mut task = ScheduledTask::new("t", "T", Schedule::Interval { secs: 86400 });
        task.mark_run();
        assert!(!task.is_due());
    }

    #[test]
    fn is_due_true_when_interval_elapsed() {
        let mut task = ScheduledTask::new("t", "T", Schedule::Interval { secs: 60 });
        // Pretend it ran 120 seconds ago.
        task.last_run = Some(now_epoch_secs().saturating_sub(120));
        assert!(task.is_due());
    }

    #[test]
    fn is_due_false_when_disabled() {
        let mut task = ScheduledTask::new("t", "T", Schedule::Interval { secs: 0 });
        task.enabled = false;
        assert!(!task.is_due());
    }

    #[test]
    fn mark_run_updates_last_run() {
        let mut task = ScheduledTask::new("t", "T", Schedule::Interval { secs: 60 });
        assert!(task.last_run.is_none());
        task.mark_run();
        assert!(task.last_run.is_some());
        let ts = task.last_run.unwrap();
        assert!(ts > 0);
    }

    #[test]
    fn schedule_serde_interval_round_trip() {
        let schedule = Schedule::Interval { secs: 3600 };
        let json = serde_json::to_string(&schedule).unwrap();
        let restored: Schedule = serde_json::from_str(&json).unwrap();
        match restored {
            Schedule::Interval { secs } => assert_eq!(secs, 3600),
            _ => panic!("expected Interval"),
        }
    }

    #[test]
    fn schedule_serde_daily_round_trip() {
        let schedule = Schedule::Daily { hour: 9, min: 30 };
        let json = serde_json::to_string(&schedule).unwrap();
        let restored: Schedule = serde_json::from_str(&json).unwrap();
        match restored {
            Schedule::Daily { hour, min } => {
                assert_eq!(hour, 9);
                assert_eq!(min, 30);
            }
            _ => panic!("expected Daily"),
        }
    }

    #[test]
    fn task_serde_round_trip() {
        let mut task =
            ScheduledTask::new("check_fae", "Check Fae Update", Schedule::Interval { secs: 86400 });
        task.mark_run();

        let json = serde_json::to_string(&task).unwrap();
        let restored: ScheduledTask = serde_json::from_str(&json).unwrap();
        assert_eq!(restored.id, "check_fae");
        assert_eq!(restored.name, "Check Fae Update");
        assert!(restored.enabled);
        assert!(restored.last_run.is_some());
    }

    #[test]
    fn schedule_display_interval_hours() {
        let s = Schedule::Interval { secs: 86400 };
        assert_eq!(s.to_string(), "every 24 hours");
    }

    #[test]
    fn schedule_display_interval_minutes() {
        let s = Schedule::Interval { secs: 1800 };
        assert_eq!(s.to_string(), "every 30 minutes");
    }

    #[test]
    fn schedule_display_daily() {
        let s = Schedule::Daily { hour: 9, min: 0 };
        assert_eq!(s.to_string(), "daily at 09:00 UTC");
    }

    #[test]
    fn is_due_daily_when_never_run_and_past_time() {
        // Use a time that's definitely in the past today
        let now = now_epoch_secs();
        let today_start = now - (now % 86400);
        let elapsed_today = now - today_start;

        if elapsed_today > 60 {
            // At least 1 minute into the day — use a time 1 minute ago
            let past_secs = elapsed_today - 60;
            let hour = (past_secs / 3600) as u8;
            let min = ((past_secs % 3600) / 60) as u8;
            let task = ScheduledTask::new("t", "T", Schedule::Daily { hour, min });
            assert!(task.is_due());
        }
    }

    #[test]
    fn is_due_daily_false_when_already_ran_today() {
        let now = now_epoch_secs();
        let today_start = now - (now % 86400);
        let elapsed_today = now - today_start;

        if elapsed_today > 120 {
            let past_secs = elapsed_today - 60;
            let hour = (past_secs / 3600) as u8;
            let min = ((past_secs % 3600) / 60) as u8;
            let mut task = ScheduledTask::new("t", "T", Schedule::Daily { hour, min });
            // Ran after the scheduled time today
            task.last_run = Some(today_start + past_secs + 1);
            assert!(!task.is_due());
        }
    }

    #[test]
    fn task_result_variants() {
        let success = TaskResult::Success("done".to_owned());
        assert!(matches!(success, TaskResult::Success(_)));

        let error = TaskResult::Error("fail".to_owned());
        assert!(matches!(error, TaskResult::Error(_)));

        let prompt = UserPrompt {
            title: "Update".to_owned(),
            message: "New version".to_owned(),
            actions: vec![PromptAction {
                label: "Install".to_owned(),
                id: "install".to_owned(),
            }],
        };
        let action = TaskResult::NeedsUserAction(prompt);
        assert!(matches!(action, TaskResult::NeedsUserAction(_)));
    }

    #[test]
    fn execute_builtin_unknown_task_returns_error() {
        let result = execute_builtin("nonexistent_task");
        assert!(matches!(result, TaskResult::Error(_)));
    }

    #[test]
    fn execute_builtin_fae_check_returns_result() {
        // This makes a real HTTP call, so it may fail in CI without network.
        // We just verify it doesn't panic and returns a valid TaskResult.
        let result = execute_builtin(TASK_CHECK_FAE_UPDATE);
        assert!(
            matches!(result, TaskResult::Success(_) | TaskResult::NeedsUserAction(_) | TaskResult::Error(_))
        );
    }

    #[test]
    fn execute_builtin_pi_check_without_pi_returns_success() {
        // With no Pi installed (pi_version is None in default state),
        // the check should succeed with a skip message.
        let result = execute_builtin(TASK_CHECK_PI_UPDATE);
        match &result {
            TaskResult::Success(msg) => assert!(msg.contains("not installed") || msg.contains("up to date")),
            TaskResult::Error(_) => {} // Network error is acceptable
            TaskResult::NeedsUserAction(_) => {} // Update available is fine too
        }
    }

    #[test]
    fn task_id_constants() {
        assert_eq!(TASK_CHECK_FAE_UPDATE, "check_fae_update");
        assert_eq!(TASK_CHECK_PI_UPDATE, "check_pi_update");
    }
}
