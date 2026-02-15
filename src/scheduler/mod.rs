//! Background task scheduler.
//!
//! Runs periodic tasks such as checking for Fae and Pi updates.
//! Designed for future extensibility with user-defined scheduled tasks
//! (calendar checks, research, reminders).

pub mod runner;
pub mod tasks;

pub use runner::{
    Scheduler, SchedulerSnapshot, clear_persisted_state, load_persisted_snapshot,
    mark_persisted_task_due_now, remove_persisted_task, save_persisted_snapshot,
    set_persisted_task_enabled, upsert_persisted_user_task,
};
pub use tasks::{
    ConversationTrigger, Schedule, ScheduledTask, TaskResult, TaskRunOutcome, TaskRunRecord,
    Weekday,
};
