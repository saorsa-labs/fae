//! Scheduler background loop.
//!
//! Spawns a tokio task that periodically checks for due tasks and
//! executes them. Task definitions and run history are persisted to
//! `~/.config/fae/scheduler.json`.

use crate::scheduler::tasks::{
    Schedule, ScheduledTask, TaskKind, TaskResult, TaskRunOutcome, TaskRunRecord,
};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

/// Interval between scheduler ticks (seconds).
const TICK_INTERVAL_SECS: u64 = 60;

/// Number of run-history entries to keep.
const DEFAULT_HISTORY_LIMIT: usize = 400;

/// Callback type for executing a task.
///
/// Takes the full scheduled task and returns a [`TaskResult`].
pub type TaskExecutor = Box<dyn Fn(&ScheduledTask) -> TaskResult + Send + Sync>;

/// Public snapshot used by doctor/GUI tools.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SchedulerSnapshot {
    /// Persisted tasks.
    pub tasks: Vec<ScheduledTask>,
    /// Recent run history.
    #[serde(default)]
    pub history: Vec<TaskRunRecord>,
}

/// Background scheduler that runs periodic tasks.
pub struct Scheduler {
    /// Registered tasks.
    tasks: Vec<ScheduledTask>,
    /// Recent run history.
    history: Vec<TaskRunRecord>,
    /// Path to persisted scheduler state.
    state_path: Option<PathBuf>,
    /// Channel for sending task results to the GUI.
    result_tx: mpsc::UnboundedSender<TaskResult>,
    /// Task executor callback.
    executor: Option<TaskExecutor>,
    /// Max history entries kept in memory and persisted to disk.
    max_history_entries: usize,
}

/// Persisted scheduler state.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct SchedulerState {
    /// Schema version.
    #[serde(default = "default_state_version")]
    version: u8,
    /// Persisted task definitions and runtime state.
    #[serde(default)]
    tasks: Vec<ScheduledTask>,
    /// Persisted run history.
    #[serde(default)]
    history: Vec<TaskRunRecord>,
}

fn default_state_version() -> u8 {
    2
}

impl Scheduler {
    /// Create a new scheduler with the given result channel.
    pub fn new(result_tx: mpsc::UnboundedSender<TaskResult>) -> Self {
        let state_path = Self::default_state_path();
        Self {
            tasks: Vec::new(),
            history: Vec::new(),
            state_path,
            result_tx,
            executor: None,
            max_history_entries: DEFAULT_HISTORY_LIMIT,
        }
    }

    /// Set a custom executor callback for running tasks.
    pub fn with_executor(mut self, executor: TaskExecutor) -> Self {
        self.executor = Some(executor);
        self
    }

    /// Override the in-memory and persisted run-history limit.
    pub fn with_history_limit(mut self, max_entries: usize) -> Self {
        self.max_history_entries = max_entries.max(1);
        self
    }

    /// Register built-in Fae update check task.
    pub fn with_update_checks(&mut self) {
        let mut task = ScheduledTask::new(
            "check_fae_update",
            "Check for Fae updates",
            Schedule::Interval { secs: 6 * 3600 },
        );
        task.kind = TaskKind::Builtin;
        self.add_task_if_missing(task);
    }

    /// Register built-in memory maintenance tasks.
    pub fn with_memory_maintenance(&mut self) {
        let mut migrate_task = ScheduledTask::new(
            "memory_migrate",
            "Check memory schema migrations",
            Schedule::Interval { secs: 3600 },
        );
        migrate_task.kind = TaskKind::Builtin;

        let mut reflect_task = ScheduledTask::new(
            "memory_reflect",
            "Consolidate memory duplicates",
            Schedule::Interval { secs: 6 * 3600 },
        );
        reflect_task.kind = TaskKind::Builtin;

        let mut reindex_task = ScheduledTask::new(
            "memory_reindex",
            "Memory reindex health pass",
            Schedule::Interval { secs: 3 * 3600 },
        );
        reindex_task.kind = TaskKind::Builtin;

        let mut gc_task = ScheduledTask::new(
            "memory_gc",
            "Memory retention cleanup",
            Schedule::Daily { hour: 3, min: 30 },
        );
        gc_task.kind = TaskKind::Builtin;

        self.add_task_if_missing(migrate_task);
        self.add_task_if_missing(reflect_task);
        self.add_task_if_missing(reindex_task);
        self.add_task_if_missing(gc_task);
    }

    /// Add (or replace) a task.
    pub fn add_task(&mut self, task: ScheduledTask) {
        if let Some(existing) = self.tasks.iter_mut().find(|t| t.id == task.id) {
            *existing = task;
        } else {
            self.tasks.push(task);
        }
    }

    fn add_task_if_missing(&mut self, task: ScheduledTask) {
        let exists = self.tasks.iter().any(|existing| existing.id == task.id);
        if !exists {
            self.tasks.push(task);
        }
    }

    /// Upsert a user-defined task.
    pub fn upsert_user_task(&mut self, mut task: ScheduledTask) {
        task.kind = TaskKind::User;
        self.add_task(task);
    }

    /// Returns registered tasks.
    pub fn tasks(&self) -> &[ScheduledTask] {
        &self.tasks
    }

    /// Returns scheduler run history.
    pub fn history(&self) -> &[TaskRunRecord] {
        &self.history
    }

    /// Enables or disables a task by ID. Returns `true` when found.
    pub fn set_task_enabled(&mut self, task_id: &str, enabled: bool) -> bool {
        if let Some(task) = self.tasks.iter_mut().find(|t| t.id == task_id) {
            task.enabled = enabled;
            return true;
        }
        false
    }

    /// Marks a task due now. Returns `true` when found.
    pub fn mark_task_due_now(&mut self, task_id: &str) -> bool {
        if let Some(task) = self.tasks.iter_mut().find(|t| t.id == task_id) {
            task.mark_due_now();
            return true;
        }
        false
    }

    /// Load persisted state from disk and merge with registered tasks.
    pub fn load_state(&mut self) {
        let snapshot = match load_snapshot_from_path(self.state_path.clone()) {
            Ok(s) => s,
            Err(e) => {
                warn!("cannot load scheduler state: {e}");
                return;
            }
        };

        for task in snapshot.tasks {
            if let Some(existing) = self.tasks.iter_mut().find(|t| t.id == task.id) {
                *existing = task;
            } else {
                self.tasks.push(task);
            }
        }

        self.history = snapshot.history;
        self.trim_history();

        if let Some(path) = &self.state_path {
            debug!("loaded scheduler state from {}", path.display());
        }
    }

    /// Persist task state and run history.
    fn save_state(&self) {
        let snapshot = SchedulerSnapshot {
            tasks: self.tasks.clone(),
            history: self.history.clone(),
        };

        if let Err(e) = save_snapshot_to_path(self.state_path.clone(), &snapshot) {
            error!("cannot persist scheduler state: {e}");
        }
    }

    /// Start the scheduler background loop.
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
        for task_id in due_ids {
            let task_snapshot = match self.tasks.iter().find(|t| t.id == task_id).cloned() {
                Some(task) => task,
                None => continue,
            };

            let started_at = crate::scheduler::tasks::now_epoch_secs();
            let mut result = self.execute_task(&task_snapshot);
            let finished_at = crate::scheduler::tasks::now_epoch_secs();

            let elapsed_secs = finished_at.saturating_sub(started_at);
            let mut outcome = result.outcome();
            if task_snapshot.soft_timeout_secs > 0 && elapsed_secs > task_snapshot.soft_timeout_secs
            {
                let msg = format!(
                    "task {} exceeded soft timeout ({}s > {}s)",
                    task_snapshot.id, elapsed_secs, task_snapshot.soft_timeout_secs
                );
                result = TaskResult::Error(msg.clone());
                outcome = TaskRunOutcome::SoftTimeout;
            }

            if let Some(task) = self.tasks.iter_mut().find(|t| t.id == task_id) {
                match &result {
                    TaskResult::Error(err) => task.mark_run_failure(err),
                    _ => task.mark_run_success(),
                }
            }

            self.push_history(TaskRunRecord {
                task_id: task_snapshot.id.clone(),
                started_at,
                finished_at,
                outcome,
                summary: result.summary(),
            });

            if self.result_tx.send(result).is_err() {
                debug!("scheduler result channel closed, stopping");
                return;
            }
        }

        if ran_any {
            self.save_state();
        }
    }

    fn push_history(&mut self, run: TaskRunRecord) {
        self.history.push(run);
        self.trim_history();
    }

    fn trim_history(&mut self) {
        if self.history.len() <= self.max_history_entries {
            return;
        }
        let drop_count = self.history.len().saturating_sub(self.max_history_entries);
        self.history.drain(0..drop_count);
    }

    /// Execute a single task.
    fn execute_task(&self, task: &ScheduledTask) -> TaskResult {
        debug!("executing scheduled task: {}", task.id);

        if let Some(executor) = &self.executor {
            return executor(task);
        }

        if task.kind == TaskKind::Builtin {
            return crate::scheduler::tasks::execute_builtin(&task.id);
        }

        TaskResult::NeedsUserAction(crate::scheduler::tasks::UserPrompt {
            title: format!("Task {} is ready", task.name),
            message:
                "This user task needs an execution handler. Open Doctor or assign an executor."
                    .to_owned(),
            actions: vec![crate::scheduler::tasks::PromptAction {
                label: "Open Doctor".to_owned(),
                id: "open_doctor".to_owned(),
            }],
        })
    }

    /// Default path for scheduler state file.
    pub fn default_state_path() -> Option<PathBuf> {
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

fn load_snapshot_from_path(path: Option<PathBuf>) -> crate::Result<SchedulerSnapshot> {
    let Some(path) = path else {
        return Ok(SchedulerSnapshot::default());
    };

    let bytes = match std::fs::read(&path) {
        Ok(contents) => contents,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Ok(SchedulerSnapshot::default());
        }
        Err(e) => {
            return Err(crate::SpeechError::Scheduler(format!(
                "cannot read state: {e}"
            )));
        }
    };

    let state: SchedulerState = serde_json::from_slice(&bytes)
        .map_err(|e| crate::SpeechError::Scheduler(format!("cannot parse state: {e}")))?;

    Ok(SchedulerSnapshot {
        tasks: state.tasks,
        history: state.history,
    })
}

fn save_snapshot_to_path(path: Option<PathBuf>, snapshot: &SchedulerSnapshot) -> crate::Result<()> {
    let Some(path) = path else {
        return Ok(());
    };

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| crate::SpeechError::Scheduler(format!("cannot create state dir: {e}")))?;
    }

    let mut history = snapshot.history.clone();
    if history.len() > DEFAULT_HISTORY_LIMIT {
        let drop_count = history.len().saturating_sub(DEFAULT_HISTORY_LIMIT);
        history.drain(0..drop_count);
    }

    let state = SchedulerState {
        version: default_state_version(),
        tasks: snapshot.tasks.clone(),
        history,
    };

    let json = serde_json::to_string_pretty(&state)
        .map_err(|e| crate::SpeechError::Scheduler(format!("cannot serialize state: {e}")))?;

    std::fs::write(&path, json)
        .map_err(|e| crate::SpeechError::Scheduler(format!("cannot write state: {e}")))?;

    Ok(())
}

/// Load the persisted scheduler snapshot using the default state path.
pub fn load_persisted_snapshot() -> crate::Result<SchedulerSnapshot> {
    load_snapshot_from_path(Scheduler::default_state_path())
}

/// Save the persisted scheduler snapshot using the default state path.
pub fn save_persisted_snapshot(snapshot: &SchedulerSnapshot) -> crate::Result<()> {
    save_snapshot_to_path(Scheduler::default_state_path(), snapshot)
}

/// Enable/disable a persisted task by ID.
pub fn set_persisted_task_enabled(task_id: &str, enabled: bool) -> crate::Result<bool> {
    let mut snapshot = load_persisted_snapshot()?;
    let mut found = false;
    for task in &mut snapshot.tasks {
        if task.id == task_id {
            task.enabled = enabled;
            found = true;
            break;
        }
    }

    if found {
        save_persisted_snapshot(&snapshot)?;
    }

    Ok(found)
}

/// Mark a persisted task due now by ID.
pub fn mark_persisted_task_due_now(task_id: &str) -> crate::Result<bool> {
    let mut snapshot = load_persisted_snapshot()?;
    let mut found = false;
    for task in &mut snapshot.tasks {
        if task.id == task_id {
            task.mark_due_now();
            found = true;
            break;
        }
    }

    if found {
        save_persisted_snapshot(&snapshot)?;
    }

    Ok(found)
}

/// Upsert a persisted user task.
pub fn upsert_persisted_user_task(mut task: ScheduledTask) -> crate::Result<()> {
    task.kind = TaskKind::User;
    let mut snapshot = load_persisted_snapshot()?;
    if let Some(existing) = snapshot.tasks.iter_mut().find(|entry| entry.id == task.id) {
        *existing = task;
    } else {
        snapshot.tasks.push(task);
    }
    save_persisted_snapshot(&snapshot)
}

/// Remove a persisted task by ID.
pub fn remove_persisted_task(task_id: &str) -> crate::Result<bool> {
    let mut snapshot = load_persisted_snapshot()?;
    let before = snapshot.tasks.len();
    snapshot.tasks.retain(|task| task.id != task_id);
    let removed = snapshot.tasks.len() != before;
    if removed {
        save_persisted_snapshot(&snapshot)?;
    }
    Ok(removed)
}

/// Delete persisted scheduler state (tasks + history).
pub fn clear_persisted_state() -> crate::Result<()> {
    if let Some(path) = Scheduler::default_state_path() {
        match std::fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(crate::SpeechError::Scheduler(format!(
                "cannot delete scheduler state: {e}"
            ))),
        }
    } else {
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    fn make_scheduler() -> (Scheduler, mpsc::UnboundedReceiver<TaskResult>) {
        let (tx, rx) = mpsc::unbounded_channel();
        let mut scheduler = Scheduler::new(tx);
        scheduler.state_path = None;
        (scheduler, rx)
    }

    #[test]
    fn new_scheduler_has_no_tasks() {
        let (scheduler, _rx) = make_scheduler();
        assert!(scheduler.tasks().is_empty());
    }

    #[test]
    fn builtins_are_idempotent() {
        let (mut scheduler, _rx) = make_scheduler();
        scheduler.with_update_checks();
        scheduler.with_update_checks();
        scheduler.with_memory_maintenance();
        scheduler.with_memory_maintenance();

        let ids: Vec<&str> = scheduler.tasks().iter().map(|t| t.id.as_str()).collect();
        assert_eq!(
            ids.iter().filter(|id| **id == "check_fae_update").count(),
            1
        );
        assert_eq!(ids.iter().filter(|id| **id == "memory_migrate").count(), 1);
        assert_eq!(ids.iter().filter(|id| **id == "memory_reflect").count(), 1);
        assert_eq!(ids.iter().filter(|id| **id == "memory_reindex").count(), 1);
        assert_eq!(ids.iter().filter(|id| **id == "memory_gc").count(), 1);
    }

    #[test]
    fn tick_executes_due_tasks_and_records_history() {
        let (mut scheduler, mut rx) = make_scheduler();
        scheduler.executor = Some(Box::new(|task| {
            TaskResult::Success(format!("ran {}", task.id))
        }));
        scheduler.add_task(ScheduledTask::new(
            "due",
            "Due Task",
            Schedule::Interval { secs: 0 },
        ));

        scheduler.tick();

        let result = rx.try_recv().expect("result available");
        assert!(matches!(result, TaskResult::Success(_)));
        assert_eq!(scheduler.history().len(), 1);
        assert_eq!(scheduler.history()[0].task_id, "due");
        assert_eq!(scheduler.history()[0].outcome, TaskRunOutcome::Success);
    }

    #[test]
    fn tick_marks_failure_and_backoff() {
        let (mut scheduler, mut rx) = make_scheduler();
        scheduler.executor = Some(Box::new(|_| TaskResult::Error("boom".to_owned())));

        let mut task = ScheduledTask::new("err", "Error Task", Schedule::Interval { secs: 0 });
        task.retry_backoff_secs = 1;
        scheduler.add_task(task);

        scheduler.tick();

        let result = rx.try_recv().expect("result available");
        assert!(matches!(result, TaskResult::Error(_)));

        let task = scheduler
            .tasks()
            .iter()
            .find(|t| t.id == "err")
            .expect("task exists");
        assert_eq!(task.failure_streak, 1);
        assert!(task.last_error.is_some());
        assert!(task.next_run.is_some());
    }

    #[test]
    fn run_history_is_bounded() {
        let (mut scheduler, mut rx) = make_scheduler();
        scheduler.max_history_entries = 2;
        scheduler.executor = Some(Box::new(|task| TaskResult::Success(task.id.clone())));

        scheduler.add_task(ScheduledTask::new("a", "A", Schedule::Interval { secs: 0 }));
        scheduler.add_task(ScheduledTask::new("b", "B", Schedule::Interval { secs: 0 }));
        scheduler.add_task(ScheduledTask::new("c", "C", Schedule::Interval { secs: 0 }));

        scheduler.tick();

        let _ = rx.try_recv();
        let _ = rx.try_recv();
        let _ = rx.try_recv();

        assert_eq!(scheduler.history().len(), 2);
    }

    #[test]
    fn persisted_snapshot_round_trip() {
        let dir = std::env::temp_dir().join("fae-scheduler-v2-roundtrip");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("scheduler.json");

        let snapshot = SchedulerSnapshot {
            tasks: vec![ScheduledTask::new(
                "task-1",
                "Task 1",
                Schedule::Interval { secs: 60 },
            )],
            history: vec![TaskRunRecord {
                task_id: "task-1".to_owned(),
                started_at: 1,
                finished_at: 2,
                outcome: TaskRunOutcome::Success,
                summary: "ok".to_owned(),
            }],
        };

        save_snapshot_to_path(Some(path.clone()), &snapshot).expect("save");
        let restored = load_snapshot_from_path(Some(path.clone())).expect("load");

        assert_eq!(restored.tasks.len(), 1);
        assert_eq!(restored.history.len(), 1);
        assert_eq!(restored.history[0].summary, "ok");

        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn set_and_due_now_mutators_work() {
        let dir = std::env::temp_dir().join("fae-scheduler-v2-mutators");
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("scheduler.json");

        let mut task = ScheduledTask::new("task-1", "Task 1", Schedule::Interval { secs: 60 });
        task.enabled = false;
        let snapshot = SchedulerSnapshot {
            tasks: vec![task],
            history: Vec::new(),
        };
        save_snapshot_to_path(Some(path.clone()), &snapshot).expect("save");

        let changed = {
            let mut loaded = load_snapshot_from_path(Some(path.clone())).expect("load");
            let mut found = false;
            for task in &mut loaded.tasks {
                if task.id == "task-1" {
                    task.enabled = true;
                    task.mark_due_now();
                    found = true;
                }
            }
            save_snapshot_to_path(Some(path.clone()), &loaded).expect("save");
            found
        };

        assert!(changed);
        let restored = load_snapshot_from_path(Some(path.clone())).expect("load");
        let task = restored
            .tasks
            .iter()
            .find(|t| t.id == "task-1")
            .expect("task");
        assert!(task.enabled);
        assert!(task.next_run.is_some());

        let _ = std::fs::remove_dir_all(&dir);
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

        let result = tokio::time::timeout(std::time::Duration::from_secs(5), rx.recv()).await;
        assert!(result.is_ok());
        assert!(matches!(result.unwrap().unwrap(), TaskResult::Success(_)));

        handle.abort();
    }
}
