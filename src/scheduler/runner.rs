//! Scheduler background loop.
//!
//! Spawns a tokio task that periodically checks for due tasks and
//! executes them. Task state (last-run timestamps) is persisted to
//! `~/.config/fae/scheduler.json`.

use crate::scheduler::tasks::{Schedule, ScheduledTask, TaskResult};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

/// Interval between scheduler ticks (seconds).
const TICK_INTERVAL_SECS: u64 = 60;

/// Callback type for executing a task.
///
/// Takes the task ID and returns a [`TaskResult`]. Implementations should
/// be lightweight — expensive work happens inside the callback.
pub type TaskExecutor = Box<dyn Fn(&str) -> TaskResult + Send + Sync>;

/// Background scheduler that runs periodic tasks.
pub struct Scheduler {
    /// Registered tasks.
    tasks: Vec<ScheduledTask>,
    /// Path to persisted scheduler state.
    state_path: Option<PathBuf>,
    /// Channel for sending task results to the GUI.
    result_tx: mpsc::UnboundedSender<TaskResult>,
    /// Task executor callback.
    executor: Option<TaskExecutor>,
}

/// Persisted scheduler state (task last-run timestamps).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct SchedulerState {
    /// Map of task ID to last-run epoch seconds.
    tasks: Vec<TaskEntry>,
}

/// A single persisted task entry.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct TaskEntry {
    /// Task identifier.
    id: String,
    /// Unix epoch seconds of last run.
    last_run: Option<u64>,
    /// Whether the task is enabled.
    enabled: bool,
}

impl Scheduler {
    /// Create a new scheduler with the given result channel.
    pub fn new(result_tx: mpsc::UnboundedSender<TaskResult>) -> Self {
        let state_path = Self::default_state_path();
        Self {
            tasks: Vec::new(),
            state_path,
            result_tx,
            executor: None,
        }
    }

    /// Set a custom executor callback for running tasks.
    pub fn with_executor(mut self, executor: TaskExecutor) -> Self {
        self.executor = Some(executor);
        self
    }

    /// Register built-in Fae update check task (every 6 hours + on startup).
    pub fn with_update_checks(&mut self) {
        let fae_task = ScheduledTask::new(
            "check_fae_update",
            "Check for Fae updates",
            Schedule::Interval { secs: 6 * 3600 },
        );

        self.add_task_if_missing(fae_task);
    }

    /// Register built-in memory maintenance tasks.
    ///
    /// These tasks keep memory healthy without user interaction:
    /// - schema migration checks
    /// - reflection / deduplication
    /// - reindex health pass
    /// - retention policy cleanup
    pub fn with_memory_maintenance(&mut self) {
        let migrate_task = ScheduledTask::new(
            "memory_migrate",
            "Check memory schema migrations",
            Schedule::Interval { secs: 3600 },
        );
        let reflect_task = ScheduledTask::new(
            "memory_reflect",
            "Consolidate memory duplicates",
            Schedule::Interval { secs: 6 * 3600 },
        );
        let reindex_task = ScheduledTask::new(
            "memory_reindex",
            "Memory reindex health pass",
            Schedule::Interval { secs: 3 * 3600 },
        );
        let gc_task = ScheduledTask::new(
            "memory_gc",
            "Memory retention cleanup",
            Schedule::Daily { hour: 3, min: 30 },
        );

        self.add_task_if_missing(migrate_task);
        self.add_task_if_missing(reflect_task);
        self.add_task_if_missing(reindex_task);
        self.add_task_if_missing(gc_task);
    }

    /// Add a custom task to the scheduler.
    pub fn add_task(&mut self, task: ScheduledTask) {
        self.tasks.push(task);
    }

    fn add_task_if_missing(&mut self, task: ScheduledTask) {
        let exists = self.tasks.iter().any(|existing| existing.id == task.id);
        if !exists {
            self.tasks.push(task);
        }
    }

    /// Returns a snapshot of the registered tasks.
    pub fn tasks(&self) -> &[ScheduledTask] {
        &self.tasks
    }

    /// Load persisted state from disk and merge with registered tasks.
    pub fn load_state(&mut self) {
        let path = match &self.state_path {
            Some(p) => p.clone(),
            None => return,
        };

        let bytes = match std::fs::read(&path) {
            Ok(b) => b,
            Err(_) => return,
        };

        let state: SchedulerState = match serde_json::from_slice(&bytes) {
            Ok(s) => s,
            Err(e) => {
                warn!("cannot parse scheduler state: {e}");
                return;
            }
        };

        // Merge persisted state into registered tasks.
        for entry in &state.tasks {
            if let Some(task) = self.tasks.iter_mut().find(|t| t.id == entry.id) {
                task.last_run = entry.last_run;
                task.enabled = entry.enabled;
            }
        }

        debug!("loaded scheduler state from {}", path.display());
    }

    /// Persist task state to disk.
    fn save_state(&self) {
        let path = match &self.state_path {
            Some(p) => p,
            None => return,
        };

        let entries: Vec<TaskEntry> = self
            .tasks
            .iter()
            .map(|t| TaskEntry {
                id: t.id.clone(),
                last_run: t.last_run,
                enabled: t.enabled,
            })
            .collect();

        let state = SchedulerState { tasks: entries };

        if let Some(parent) = path.parent()
            && let Err(e) = std::fs::create_dir_all(parent)
        {
            error!("cannot create scheduler state dir: {e}");
            return;
        }

        match serde_json::to_string_pretty(&state) {
            Ok(json) => {
                if let Err(e) = std::fs::write(path, json) {
                    error!("cannot write scheduler state: {e}");
                }
            }
            Err(e) => {
                error!("cannot serialize scheduler state: {e}");
            }
        }
    }

    /// Start the scheduler background loop.
    ///
    /// Returns a [`tokio::task::JoinHandle`] for the spawned task.
    /// The loop runs until the result channel is closed.
    pub fn run(mut self) -> tokio::task::JoinHandle<()> {
        self.load_state();

        tokio::spawn(async move {
            info!("scheduler started with {} tasks", self.tasks.len());
            let mut interval =
                tokio::time::interval(std::time::Duration::from_secs(TICK_INTERVAL_SECS));

            loop {
                interval.tick().await;
                self.tick();
            }
        })
    }

    /// Execute one scheduler tick — check and run due tasks.
    fn tick(&mut self) {
        let due_ids: Vec<String> = self
            .tasks
            .iter()
            .filter(|t| t.is_due())
            .map(|t| t.id.clone())
            .collect();

        let ran_any = !due_ids.is_empty();
        for id in due_ids {
            let result = self.execute_task(&id);

            // Mark the task as run regardless of result.
            if let Some(task) = self.tasks.iter_mut().find(|t| t.id == id) {
                task.mark_run();
            }

            // Send result to GUI.
            if self.result_tx.send(result).is_err() {
                debug!("scheduler result channel closed, stopping");
                return;
            }
        }

        // Persist state after running tasks.
        if ran_any {
            self.save_state();
        }
    }

    /// Execute a single task by ID.
    fn execute_task(&self, task_id: &str) -> TaskResult {
        debug!("executing scheduled task: {task_id}");

        if let Some(executor) = &self.executor {
            return executor(task_id);
        }

        // Default: try built-in tasks.
        crate::scheduler::tasks::execute_builtin(task_id)
    }

    /// Default path for scheduler state file.
    fn default_state_path() -> Option<PathBuf> {
        #[cfg(target_os = "windows")]
        {
            std::env::var_os("LOCALAPPDATA")
                .map(|d| PathBuf::from(d).join("fae").join("scheduler.json"))
        }
        #[cfg(not(target_os = "windows"))]
        {
            std::env::var_os("HOME").map(|h| {
                PathBuf::from(h)
                    .join(".config")
                    .join("fae")
                    .join("scheduler.json")
            })
        }
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use crate::scheduler::tasks::Schedule;

    fn make_scheduler() -> (Scheduler, mpsc::UnboundedReceiver<TaskResult>) {
        let (tx, rx) = mpsc::unbounded_channel();
        let mut scheduler = Scheduler::new(tx);
        // Disable disk persistence in tests.
        scheduler.state_path = None;
        (scheduler, rx)
    }

    #[test]
    fn new_scheduler_has_no_tasks() {
        let (scheduler, _rx) = make_scheduler();
        assert!(scheduler.tasks().is_empty());
    }

    #[test]
    fn with_update_checks_adds_fae_task() {
        let (mut scheduler, _rx) = make_scheduler();
        scheduler.with_update_checks();
        assert_eq!(scheduler.tasks().len(), 1);
        assert_eq!(scheduler.tasks()[0].id, "check_fae_update");
    }

    #[test]
    fn with_memory_maintenance_adds_four_tasks() {
        let (mut scheduler, _rx) = make_scheduler();
        scheduler.with_memory_maintenance();

        let ids: Vec<&str> = scheduler.tasks().iter().map(|t| t.id.as_str()).collect();
        assert!(ids.contains(&"memory_migrate"));
        assert!(ids.contains(&"memory_reflect"));
        assert!(ids.contains(&"memory_reindex"));
        assert!(ids.contains(&"memory_gc"));
        assert_eq!(scheduler.tasks().len(), 4);
    }

    #[test]
    fn with_memory_maintenance_is_idempotent() {
        let (mut scheduler, _rx) = make_scheduler();
        scheduler.with_memory_maintenance();
        scheduler.with_memory_maintenance();

        let ids: Vec<&str> = scheduler.tasks().iter().map(|t| t.id.as_str()).collect();
        let migrate_count = ids.iter().filter(|id| **id == "memory_migrate").count();
        let reflect_count = ids.iter().filter(|id| **id == "memory_reflect").count();
        let reindex_count = ids.iter().filter(|id| **id == "memory_reindex").count();
        let gc_count = ids.iter().filter(|id| **id == "memory_gc").count();
        assert_eq!(migrate_count, 1);
        assert_eq!(reflect_count, 1);
        assert_eq!(reindex_count, 1);
        assert_eq!(gc_count, 1);
        assert_eq!(scheduler.tasks().len(), 4);
    }

    #[test]
    fn add_task_registers_custom_task() {
        let (mut scheduler, _rx) = make_scheduler();
        let task = ScheduledTask::new("custom", "Custom Task", Schedule::Interval { secs: 300 });
        scheduler.add_task(task);
        assert_eq!(scheduler.tasks().len(), 1);
        assert_eq!(scheduler.tasks()[0].id, "custom");
    }

    #[test]
    fn tick_executes_due_tasks() {
        let (mut scheduler, mut rx) = make_scheduler();
        // Use a custom executor so the test doesn't depend on network.
        scheduler.executor = Some(Box::new(|_| TaskResult::Success("ran".to_owned())));
        // Add a task that's immediately due (never run, interval 0).
        let task = ScheduledTask::new("due", "Due Task", Schedule::Interval { secs: 0 });
        scheduler.add_task(task);

        scheduler.tick();

        // Should have sent a result.
        let result = rx.try_recv().unwrap();
        assert!(matches!(result, TaskResult::Success(_)));

        // Task should now have a last_run set.
        assert!(scheduler.tasks()[0].last_run.is_some());
    }

    #[test]
    fn tick_skips_not_due_tasks() {
        let (mut scheduler, mut rx) = make_scheduler();
        let mut task = ScheduledTask::new("not_due", "Not Due", Schedule::Interval { secs: 86400 });
        task.mark_run(); // Just ran, not due for 24h.
        scheduler.add_task(task);

        scheduler.tick();

        // No result should have been sent.
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn tick_with_custom_executor() {
        let (mut scheduler, mut rx) = make_scheduler();
        scheduler.executor = Some(Box::new(|id| {
            TaskResult::Success(format!("custom executed: {id}"))
        }));

        let task = ScheduledTask::new("exec", "Exec Task", Schedule::Interval { secs: 0 });
        scheduler.add_task(task);

        scheduler.tick();

        let result = rx.try_recv().unwrap();
        match result {
            TaskResult::Success(msg) => assert!(msg.contains("custom executed")),
            _ => panic!("expected Success"),
        }
    }

    #[test]
    fn state_persistence_round_trip() {
        let dir = std::env::temp_dir().join("fae-scheduler-test");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("scheduler-test.json");

        let (tx, _rx) = mpsc::unbounded_channel();
        let mut scheduler = Scheduler::new(tx);
        scheduler.state_path = Some(path.clone());

        let mut task =
            ScheduledTask::new("persist", "Persist Test", Schedule::Interval { secs: 3600 });
        task.mark_run();
        let saved_last_run = task.last_run;
        scheduler.add_task(task);

        // Save state.
        scheduler.save_state();

        // Create a new scheduler, add the same task (without last_run),
        // then load state.
        let (tx2, _rx2) = mpsc::unbounded_channel();
        let mut scheduler2 = Scheduler::new(tx2);
        scheduler2.state_path = Some(path.clone());
        scheduler2.add_task(ScheduledTask::new(
            "persist",
            "Persist Test",
            Schedule::Interval { secs: 3600 },
        ));

        scheduler2.load_state();
        assert_eq!(scheduler2.tasks()[0].last_run, saved_last_run);

        // Cleanup.
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_dir(&dir);
    }

    #[test]
    fn default_state_path_is_some() {
        let path = Scheduler::default_state_path();
        assert!(path.is_some());
        let path_str = path.unwrap().to_string_lossy().to_string();
        assert!(path_str.contains("scheduler.json"));
    }

    #[test]
    fn scheduler_state_serde_round_trip() {
        let state = SchedulerState {
            tasks: vec![
                TaskEntry {
                    id: "task1".to_owned(),
                    last_run: Some(1000),
                    enabled: true,
                },
                TaskEntry {
                    id: "task2".to_owned(),
                    last_run: None,
                    enabled: false,
                },
            ],
        };

        let json = serde_json::to_string(&state).unwrap();
        let restored: SchedulerState = serde_json::from_str(&json).unwrap();
        assert_eq!(restored.tasks.len(), 2);
        assert_eq!(restored.tasks[0].id, "task1");
        assert_eq!(restored.tasks[0].last_run, Some(1000));
        assert!(restored.tasks[0].enabled);
        assert_eq!(restored.tasks[1].id, "task2");
        assert!(restored.tasks[1].last_run.is_none());
        assert!(!restored.tasks[1].enabled);
    }

    #[test]
    fn load_state_handles_missing_file() {
        let (tx, _rx) = mpsc::unbounded_channel();
        let mut scheduler = Scheduler::new(tx);
        scheduler.state_path = Some(PathBuf::from("/tmp/nonexistent-scheduler-state.json"));
        // Should not panic or error.
        scheduler.load_state();
    }

    #[test]
    fn load_state_handles_invalid_json() {
        let dir = std::env::temp_dir().join("fae-scheduler-test-invalid");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("invalid.json");
        std::fs::write(&path, "not valid json").unwrap();

        let (tx, _rx) = mpsc::unbounded_channel();
        let mut scheduler = Scheduler::new(tx);
        scheduler.state_path = Some(path.clone());
        // Should not panic, just warn.
        scheduler.load_state();

        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_dir(&dir);
    }

    #[test]
    fn tick_marks_run_even_on_error() {
        let (mut scheduler, mut rx) = make_scheduler();
        scheduler.executor = Some(Box::new(|_| TaskResult::Error("boom".to_owned())));

        let task = ScheduledTask::new("err", "Error Task", Schedule::Interval { secs: 0 });
        scheduler.add_task(task);

        scheduler.tick();

        // Should have sent the error result.
        let result = rx.try_recv().unwrap();
        assert!(matches!(result, TaskResult::Error(_)));

        // Task should still have been marked as run.
        assert!(scheduler.tasks()[0].last_run.is_some());
    }

    #[test]
    fn tick_executes_multiple_due_tasks() {
        let (mut scheduler, mut rx) = make_scheduler();
        scheduler.executor = Some(Box::new(|id| TaskResult::Success(id.to_owned())));

        scheduler.add_task(ScheduledTask::new("a", "A", Schedule::Interval { secs: 0 }));
        scheduler.add_task(ScheduledTask::new("b", "B", Schedule::Interval { secs: 0 }));
        scheduler.add_task(ScheduledTask::new("c", "C", Schedule::Interval { secs: 0 }));

        scheduler.tick();

        // All three tasks should have produced results.
        let r1 = rx.try_recv().unwrap();
        let r2 = rx.try_recv().unwrap();
        let r3 = rx.try_recv().unwrap();
        assert!(matches!(r1, TaskResult::Success(_)));
        assert!(matches!(r2, TaskResult::Success(_)));
        assert!(matches!(r3, TaskResult::Success(_)));

        // All should be marked as run.
        assert!(scheduler.tasks().iter().all(|t| t.last_run.is_some()));
    }

    #[test]
    fn tick_second_time_skips_recently_run() {
        let (mut scheduler, mut rx) = make_scheduler();
        scheduler.executor = Some(Box::new(|_| TaskResult::Success("ok".to_owned())));

        scheduler.add_task(ScheduledTask::new(
            "once",
            "Once",
            Schedule::Interval { secs: 3600 },
        ));

        // First tick: executes.
        scheduler.tick();
        let _ = rx.try_recv().unwrap();

        // Second tick: should not execute again (3600s interval).
        scheduler.tick();
        assert!(rx.try_recv().is_err());
    }

    #[test]
    fn with_executor_overrides_builtin() {
        let (mut scheduler, mut rx) = make_scheduler();
        scheduler.with_update_checks();
        // Override with custom executor.
        scheduler =
            scheduler.with_executor(Box::new(|id| TaskResult::Success(format!("custom: {id}"))));

        // Force all tasks to be due.
        for task in &mut scheduler.tasks {
            task.last_run = None;
            task.schedule = Schedule::Interval { secs: 0 };
        }

        scheduler.tick();

        let r1 = rx.try_recv().unwrap();
        match r1 {
            TaskResult::Success(msg) => assert!(msg.starts_with("custom: ")),
            _ => panic!("expected Success from custom executor"),
        }
    }

    #[tokio::test]
    async fn run_starts_and_ticks() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let mut scheduler = Scheduler::new(tx);
        scheduler.state_path = None;
        scheduler.executor = Some(Box::new(|_| TaskResult::Success("ran".to_owned())));
        scheduler.add_task(ScheduledTask::new(
            "async_test",
            "Async",
            Schedule::Interval { secs: 0 },
        ));

        let handle = scheduler.run();

        // Wait for the first tick result (should come within ~1 second).
        let result = tokio::time::timeout(std::time::Duration::from_secs(5), rx.recv()).await;

        assert!(result.is_ok());
        let task_result = result.unwrap().unwrap();
        assert!(matches!(task_result, TaskResult::Success(_)));

        handle.abort();
    }

    #[test]
    fn save_state_creates_directory() {
        let dir = std::env::temp_dir()
            .join("fae-scheduler-test-mkdir")
            .join("nested");
        let path = dir.join("scheduler.json");

        // Ensure the directory doesn't exist.
        let _ = std::fs::remove_dir_all(dir.parent().unwrap());

        let (tx, _rx) = mpsc::unbounded_channel();
        let mut scheduler = Scheduler::new(tx);
        scheduler.state_path = Some(path.clone());
        scheduler.add_task(ScheduledTask::new(
            "t",
            "T",
            Schedule::Interval { secs: 60 },
        ));

        scheduler.save_state();

        assert!(path.exists());

        // Cleanup.
        let _ = std::fs::remove_dir_all(dir.parent().unwrap());
    }

    #[test]
    fn needs_user_action_result_sent_to_channel() {
        use crate::scheduler::tasks::{PromptAction, UserPrompt};

        let (mut scheduler, mut rx) = make_scheduler();
        scheduler.executor = Some(Box::new(|_| {
            TaskResult::NeedsUserAction(UserPrompt {
                title: "Update".to_owned(),
                message: "New version".to_owned(),
                actions: vec![PromptAction {
                    label: "Install".to_owned(),
                    id: "install".to_owned(),
                }],
            })
        }));

        scheduler.add_task(ScheduledTask::new(
            "update",
            "Update",
            Schedule::Interval { secs: 0 },
        ));
        scheduler.tick();

        let result = rx.try_recv().unwrap();
        assert!(matches!(result, TaskResult::NeedsUserAction(_)));
    }

    #[test]
    fn telemetry_result_sent_to_channel() {
        use crate::runtime::RuntimeEvent;
        use crate::scheduler::tasks::TaskTelemetry;

        let (mut scheduler, mut rx) = make_scheduler();
        scheduler.executor = Some(Box::new(|_| {
            TaskResult::Telemetry(TaskTelemetry {
                message: "memory maintenance".to_owned(),
                event: RuntimeEvent::MemoryWrite {
                    op: "reindex".to_owned(),
                    target_id: None,
                },
            })
        }));

        scheduler.add_task(ScheduledTask::new(
            "memory_reindex",
            "Memory reindex",
            Schedule::Interval { secs: 0 },
        ));
        scheduler.tick();

        let result = rx.try_recv().unwrap();
        match result {
            TaskResult::Telemetry(payload) => {
                assert_eq!(payload.message, "memory maintenance");
                assert!(matches!(
                    payload.event,
                    RuntimeEvent::MemoryWrite { op, target_id }
                    if op == "reindex" && target_id.is_none()
                ));
            }
            other => panic!("expected telemetry result, got: {other:?}"),
        }
    }
}
