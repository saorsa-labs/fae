//! Background task scheduler.
//!
//! Runs periodic tasks such as checking for Fae and Pi updates.
//! Designed for future extensibility with user-defined scheduled tasks
//! (calendar checks, research, reminders).

pub mod runner;
pub mod tasks;

pub use runner::Scheduler;
pub use tasks::{ScheduledTask, TaskResult};
