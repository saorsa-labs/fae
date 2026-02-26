//! Integration tests for scheduler UI components.
//!
//! Tests the full workflow of scheduler panel types, view formatting,
//! and round-trip conversions between UI and scheduler types.

use fae::scheduler::tasks::{Schedule, ScheduledTask, TaskKind, TaskRunOutcome, TaskRunRecord};
use fae::ui::scheduler_panel::{
    EditingTask, ExecutionHistoryView, SchedulerPanelState, TaskEditForm, TaskListView,
    ValidationError, format_duration, format_outcome, format_schedule, format_timestamp,
};

/// Test full workflow: create EditingTask → validate → convert to ScheduledTask → format for display.
#[test]
fn test_full_task_creation_workflow() {
    // User creates a new task via UI
    let mut form = TaskEditForm::new();
    form.set_name("Daily Standup".to_owned());
    form.set_schedule_daily("9".to_owned(), "30".to_owned());
    form.set_enabled(true);

    // Validate form
    assert!(form.validate());

    // Save to ScheduledTask
    let task = form.save().unwrap();
    assert_eq!(task.name, "Daily Standup");
    assert!(task.enabled);
    assert!(matches!(
        task.schedule,
        Schedule::Daily { hour: 9, min: 30 }
    ));

    // Display in task list
    let view = TaskListView::new(vec![task.clone()]);
    let formatted = view.format_task(&task);
    assert!(formatted.contains("Daily Standup"));
    assert!(formatted.contains("Daily at 09:30"));
    assert!(formatted.contains("Never")); // No last run yet
}

/// Test full workflow: load ScheduledTask → convert to EditingTask → modify → save back.
#[test]
fn test_full_task_editing_workflow() {
    // Existing task from scheduler
    let original = ScheduledTask {
        id: "weekly_report".to_owned(),
        name: "Weekly Report".to_owned(),
        schedule: Schedule::Weekly {
            weekdays: vec![
                fae::scheduler::tasks::Weekday::Mon,
                fae::scheduler::tasks::Weekday::Fri,
            ],
            hour: 17,
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

    // User opens edit form
    let mut form = TaskEditForm::from_task(&original);
    assert_eq!(form.editing_task.name, "Weekly Report");

    // User modifies schedule (change to daily)
    form.set_schedule_daily("17".to_owned(), "0".to_owned());

    // Validate and save
    assert!(form.validate());
    let updated = form.save().unwrap();
    assert!(matches!(
        updated.schedule,
        Schedule::Daily { hour: 17, min: 0 }
    ));
    assert_eq!(updated.id, "weekly_report");
    assert_eq!(updated.name, "Weekly Report");
}

/// Test execution history display workflow.
#[test]
fn test_execution_history_workflow() {
    // Scheduler has run records
    let records = vec![
        TaskRunRecord {
            task_id: "task1".to_owned(),
            started_at: 1000,
            finished_at: 1015,
            outcome: TaskRunOutcome::Success,
            summary: "Task completed successfully".to_owned(),
        },
        TaskRunRecord {
            task_id: "task1".to_owned(),
            started_at: 2000,
            finished_at: 2005,
            outcome: TaskRunOutcome::Error,
            summary: "Task failed with error".to_owned(),
        },
        TaskRunRecord {
            task_id: "task2".to_owned(),
            started_at: 3000,
            finished_at: 3120,
            outcome: TaskRunOutcome::Success,
            summary: "Different task completed".to_owned(),
        },
    ];

    // View all records
    let view = ExecutionHistoryView::new(records.clone());
    let all = view.filtered_records();
    assert_eq!(all.len(), 3);

    // Filter to specific task
    let task1_view = ExecutionHistoryView::for_task(records, "task1".to_owned());
    let task1_records = task1_view.filtered_records();
    assert_eq!(task1_records.len(), 2);
    assert!(task1_records.iter().all(|r| r.task_id == "task1"));

    // Format records for display
    let formatted = task1_view.format_record(task1_records[0]);
    assert!(formatted.contains("✓")); // Success symbol
    assert!(formatted.contains("task1"));
    assert!(formatted.contains("15s")); // Duration
}

/// Test validation error handling workflow.
#[test]
fn test_validation_error_workflow() {
    // User creates form with invalid data
    let mut form = TaskEditForm::new();
    form.set_name("".to_owned()); // Invalid: empty name
    form.set_schedule_interval("0".to_owned()); // Invalid: zero interval

    // Validation fails
    assert!(!form.validate());
    assert_eq!(form.validation_errors.len(), 1);
    assert_eq!(form.validation_errors[0], ValidationError::NameEmpty);

    // Attempting to save also fails
    let result = form.save();
    assert!(result.is_err());
    assert_eq!(result.unwrap_err(), ValidationError::NameEmpty);

    // User fixes the name
    form.set_name("Valid Task".to_owned());

    // Validation still fails (zero interval)
    assert!(!form.validate());
    assert_eq!(
        form.validation_errors[0],
        ValidationError::IntervalSecsInvalid
    );

    // User fixes the interval
    form.set_schedule_interval("3600".to_owned());

    // Now validation succeeds
    assert!(form.validate());
    assert!(form.validation_errors.is_empty());

    // Save succeeds
    let task = form.save().unwrap();
    assert_eq!(task.name, "Valid Task");
}

/// Test SchedulerPanelState workflow.
#[test]
fn test_scheduler_panel_state_workflow() {
    let mut state = SchedulerPanelState::default();

    // Initially no selection
    assert_eq!(state.selected_task_id, None);
    assert_eq!(state.editing_task, None);
    assert!(!state.showing_history);

    // User selects a task
    state.selected_task_id = Some("task1".to_owned());
    assert_eq!(state.selected_task_id, Some("task1".to_owned()));

    // User opens edit form
    state.editing_task = Some(EditingTask::new());
    assert!(state.editing_task.is_some());

    // User toggles history view
    state.showing_history = true;
    assert!(state.showing_history);

    // User closes everything
    state.selected_task_id = None;
    state.editing_task = None;
    state.showing_history = false;
    assert_eq!(state.selected_task_id, None);
    assert_eq!(state.editing_task, None);
    assert!(!state.showing_history);
}

/// Test schedule formatting for all schedule types.
#[test]
fn test_schedule_formatting_comprehensive() {
    // Interval schedules
    assert_eq!(
        format_schedule(&Schedule::Interval { secs: 1 }),
        "Every 1 second(s)"
    );
    assert_eq!(
        format_schedule(&Schedule::Interval { secs: 60 }),
        "Every 1 minute(s)"
    );
    assert_eq!(
        format_schedule(&Schedule::Interval { secs: 3600 }),
        "Every 1 hour(s)"
    );
    assert_eq!(
        format_schedule(&Schedule::Interval { secs: 86400 }),
        "Every 1 day(s)"
    );

    // Daily schedule
    assert_eq!(
        format_schedule(&Schedule::Daily { hour: 0, min: 0 }),
        "Daily at 00:00"
    );
    assert_eq!(
        format_schedule(&Schedule::Daily { hour: 23, min: 59 }),
        "Daily at 23:59"
    );

    // Weekly schedule
    assert_eq!(
        format_schedule(&Schedule::Weekly {
            weekdays: vec![fae::scheduler::tasks::Weekday::Sun],
            hour: 8,
            min: 0
        }),
        "Weekly on sun at 08:00"
    );
}

/// Test outcome formatting for all outcome types.
#[test]
fn test_outcome_formatting_comprehensive() {
    assert_eq!(format_outcome(&TaskRunOutcome::Success), "✓");
    assert_eq!(format_outcome(&TaskRunOutcome::Telemetry), "ⓘ");
    assert_eq!(format_outcome(&TaskRunOutcome::NeedsUserAction), "⚠");
    assert_eq!(format_outcome(&TaskRunOutcome::Error), "✗");
    assert_eq!(format_outcome(&TaskRunOutcome::SoftTimeout), "⏱");
}

/// Test duration formatting for various durations.
#[test]
fn test_duration_formatting_comprehensive() {
    assert_eq!(format_duration(0), "< 1s");
    assert_eq!(format_duration(1), "1s");
    assert_eq!(format_duration(59), "59s");
    assert_eq!(format_duration(60), "1m 0s");
    assert_eq!(format_duration(61), "1m 1s");
    assert_eq!(format_duration(3599), "59m 59s");
    assert_eq!(format_duration(3600), "1h 0m");
    assert_eq!(format_duration(3661), "1h 1m");
    assert_eq!(format_duration(7200), "2h 0m");
}

/// Test round-trip conversion: ScheduledTask → EditingTask → ScheduledTask.
#[test]
fn test_round_trip_conversion_preserves_data() {
    let original = ScheduledTask {
        id: "test_task".to_owned(),
        name: "Test Task".to_owned(),
        schedule: Schedule::Interval { secs: 7200 },
        last_run: Some(1000),
        next_run: Some(2000),
        enabled: false,
        kind: TaskKind::User,
        payload: Some(serde_json::json!({"key": "value"})),
        failure_streak: 2,
        max_retries: 5,
        retry_backoff_secs: 120,
        max_failure_streak_before_pause: 10,
        soft_timeout_secs: 600,
        last_error: Some("Previous error".to_owned()),
    };

    // Convert to editing form
    let editing = EditingTask::from_scheduled_task(&original);
    assert_eq!(editing.id, Some("test_task".to_owned()));
    assert_eq!(editing.name, "Test Task");
    assert!(!editing.enabled);
    assert!(editing.payload.is_some());

    // Convert back
    let converted = editing.to_scheduled_task().unwrap();
    assert_eq!(converted.id, original.id);
    assert_eq!(converted.name, original.name);
    assert_eq!(converted.enabled, original.enabled);
    assert!(matches!(
        converted.schedule,
        Schedule::Interval { secs: 7200 }
    ));

    // Note: last_run, next_run, failure_streak, etc. are reset on conversion
    // This is expected behavior as these are runtime state
    assert_eq!(converted.last_run, None);
    assert_eq!(converted.failure_streak, 0);
}

/// Test timestamp formatting at various time distances.
#[test]
fn test_timestamp_formatting_relative() {
    use std::time::{SystemTime, UNIX_EPOCH};

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    // Just now
    assert_eq!(format_timestamp(now - 30), "Just now");

    // Minutes ago
    assert_eq!(format_timestamp(now - 120), "2 minute(s) ago");

    // Hours ago
    assert_eq!(format_timestamp(now - 7200), "2 hour(s) ago");

    // Days ago
    assert_eq!(format_timestamp(now - 172800), "2 day(s) ago");

    // Old date (more than a week ago)
    let old = format_timestamp(1609459200); // 2021-01-01
    assert!(old.contains("2021-01-01"));
}
