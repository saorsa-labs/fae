//! Scheduler background loop.
//!
//! Spawns a tokio task that periodically checks for due tasks and
//! executes them. Task definitions and run history are persisted to
//! `~/.config/fae/scheduler.json`.

use crate::scheduler::tasks::{
    Schedule, ScheduledTask, TaskKind, TaskResult, TaskRunOutcome, TaskRunRecord,
};
use crate::scheduler::{
    authority::{LeaderLease, LeadershipDecision, RunKeyLedger, now_epoch_millis},
    tasks,
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
    /// Optional leader lease controller for single-writer scheduling.
    leader_lease: Option<LeaderLease>,
    /// Optional run-key dedupe ledger shared across scheduler instances.
    run_key_ledger: Option<RunKeyLedger>,
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
            leader_lease: None,
            run_key_ledger: None,
        }
    }

    /// Enable single-leader scheduling via a lease controller.
    pub fn with_leader_lease(mut self, lease: LeaderLease) -> Self {
        self.leader_lease = Some(lease);
        self
    }

    /// Enable cross-instance run-key dedupe.
    pub fn with_run_key_ledger(mut self, ledger: RunKeyLedger) -> Self {
        self.run_key_ledger = Some(ledger);
        self
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

        let mut backup_task = ScheduledTask::new(
            "memory_backup",
            "Daily memory database backup",
            Schedule::Daily { hour: 2, min: 0 },
        );
        backup_task.kind = TaskKind::Builtin;

        self.add_task_if_missing(migrate_task);
        self.add_task_if_missing(reflect_task);
        self.add_task_if_missing(reindex_task);
        self.add_task_if_missing(gc_task);
        self.add_task_if_missing(backup_task);
    }

    /// Register built-in intelligence maintenance tasks.
    ///
    /// Includes: noise budget reset, stale relationship check, morning briefing,
    /// and skill proposal detection.
    pub fn with_intelligence_maintenance(&mut self) {
        use crate::scheduler::tasks::{
            TASK_MORNING_BRIEFING, TASK_NOISE_BUDGET_RESET, TASK_SKILL_PROPOSALS,
            TASK_STALE_RELATIONSHIPS,
        };

        let mut noise_reset = ScheduledTask::new(
            TASK_NOISE_BUDGET_RESET,
            "Reset daily noise budget",
            Schedule::Daily { hour: 0, min: 0 },
        );
        noise_reset.kind = TaskKind::Builtin;

        let mut stale_rel = ScheduledTask::new(
            TASK_STALE_RELATIONSHIPS,
            "Check stale relationships",
            Schedule::Interval {
                secs: 7 * 24 * 3600,
            },
        );
        stale_rel.kind = TaskKind::Builtin;

        let mut morning = ScheduledTask::new(
            TASK_MORNING_BRIEFING,
            "Prepare morning briefing",
            Schedule::Daily { hour: 8, min: 0 },
        );
        morning.kind = TaskKind::Builtin;

        let mut skills = ScheduledTask::new(
            TASK_SKILL_PROPOSALS,
            "Check skill opportunities",
            Schedule::Daily { hour: 11, min: 0 },
        );
        skills.kind = TaskKind::Builtin;

        self.add_task_if_missing(noise_reset);
        self.add_task_if_missing(stale_rel);
        self.add_task_if_missing(morning);
        self.add_task_if_missing(skills);
    }

    /// Register periodic health checks for Python skills (every 5 minutes).
    pub fn with_skill_health_checks(&mut self) {
        use crate::scheduler::tasks::TASK_SKILL_HEALTH_CHECK;

        let mut task = ScheduledTask::new(
            TASK_SKILL_HEALTH_CHECK,
            "Python Skill Health Checks",
            Schedule::Interval { secs: 300 },
        );
        task.kind = TaskKind::Builtin;
        self.add_task_if_missing(task);
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
                if !self.should_execute_tick() {
                    continue;
                }
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

            let started_at = tasks::now_epoch_secs();
            let planned_at = task_snapshot.next_run.unwrap_or_else(|| {
                if TICK_INTERVAL_SECS == 0 {
                    started_at
                } else {
                    started_at.saturating_sub(started_at % TICK_INTERVAL_SECS)
                }
            });

            let run_key = build_run_key(&task_snapshot.id, planned_at);
            if self.should_skip_duplicate_run(&run_key, &task_snapshot.id, started_at) {
                continue;
            }

            let mut result = self.execute_task(&task_snapshot);
            let finished_at = tasks::now_epoch_secs();

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

    fn should_execute_tick(&self) -> bool {
        let Some(lease) = self.leader_lease.as_ref() else {
            return true;
        };

        match lease.try_acquire_or_renew_at(now_epoch_millis()) {
            Ok(LeadershipDecision::Leader { takeover }) => {
                if takeover {
                    info!("scheduler leadership acquired via takeover");
                }
                true
            }
            Ok(LeadershipDecision::Follower {
                leader_instance_id,
                lease_expires_at,
            }) => {
                debug!(
                    "scheduler tick skipped; leader is '{}' until {}",
                    leader_instance_id, lease_expires_at
                );
                false
            }
            Err(e) => {
                warn!("scheduler lease check failed, skipping tick: {e}");
                false
            }
        }
    }

    fn should_skip_duplicate_run(&mut self, run_key: &str, task_id: &str, started_at: u64) -> bool {
        let Some(ledger) = self.run_key_ledger.as_mut() else {
            return false;
        };

        match ledger.record_once(run_key) {
            Ok(true) => false,
            Ok(false) => {
                debug!("suppressing duplicate scheduler run key '{run_key}'");
                if let Some(task) = self.tasks.iter_mut().find(|t| t.id == task_id) {
                    task.mark_run_success();
                }
                self.push_history(TaskRunRecord {
                    task_id: task_id.to_owned(),
                    started_at,
                    finished_at: started_at,
                    outcome: TaskRunOutcome::Success,
                    summary: format!("duplicate run suppressed ({run_key})"),
                });
                true
            }
            Err(e) => {
                warn!("run-key dedupe failed for task '{task_id}', continuing: {e}");
                false
            }
        }
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

pub(crate) fn build_run_key(task_id: &str, planned_at: u64) -> String {
    format!("{task_id}:{planned_at}")
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
    use crate::scheduler::authority::{LeaderLease, LeaderLeaseConfig, RunKeyLedger};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

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

    #[test]
    fn duplicate_run_key_is_suppressed_before_execution() {
        let (tx, mut rx) = mpsc::unbounded_channel();
        let ledger_path = std::env::temp_dir().join("fae-scheduler-v2-dedupe.jsonl");
        let mut ledger = RunKeyLedger::new(ledger_path.clone());
        let dedupe_key = build_run_key("dup-task", 1);
        assert!(ledger.record_once(&dedupe_key).expect("seed dedupe key"));

        let mut scheduler = Scheduler::new(tx).with_run_key_ledger(ledger);
        scheduler.state_path = None;
        let calls = Arc::new(AtomicUsize::new(0));
        let call_counter = Arc::clone(&calls);
        scheduler.executor = Some(Box::new(move |_| {
            call_counter.fetch_add(1, Ordering::SeqCst);
            TaskResult::Success("ran".to_owned())
        }));

        let mut task = ScheduledTask::new("dup-task", "Dup Task", Schedule::Interval { secs: 60 });
        task.next_run = Some(1);
        scheduler.add_task(task);

        scheduler.tick();

        assert_eq!(calls.load(Ordering::SeqCst), 0);
        assert_eq!(scheduler.history().len(), 1);
        assert!(
            scheduler.history()[0]
                .summary
                .contains("duplicate run suppressed"),
            "summary was: {}",
            scheduler.history()[0].summary
        );
        assert!(
            rx.try_recv().is_err(),
            "suppressed run should not emit result"
        );
        let _ = std::fs::remove_file(ledger_path);
    }

    #[test]
    fn follower_scheduler_skips_tick_when_leader_is_active() {
        let dir = std::env::temp_dir().join("fae-scheduler-v2-leader");
        let _ = std::fs::create_dir_all(&dir);
        let lease_path = dir.join("scheduler.leader.lock");
        let cfg = LeaderLeaseConfig::default();

        let leader = LeaderLease::new("leader-a", 1001, lease_path.clone(), cfg);
        let now = now_epoch_millis();
        let _ = leader
            .try_acquire_or_renew_at(now)
            .expect("acquire leader lease");

        let follower = LeaderLease::new("leader-b", 1002, lease_path, cfg);
        let (tx, _rx) = mpsc::unbounded_channel();
        let scheduler = Scheduler::new(tx).with_leader_lease(follower);

        assert!(
            !scheduler.should_execute_tick(),
            "follower should skip tick while another leader lease is active"
        );

        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn shared_ledger_prevents_duplicate_execution_across_schedulers() {
        let temp = tempfile::tempdir().expect("tempdir");
        let ledger_path = temp.path().join("scheduler.run_keys.jsonl");
        let task_id = "shared-dedupe-task";
        let planned_at = 12_345_u64;

        let mut ledger_a = RunKeyLedger::new(ledger_path.clone());
        let mut ledger_b = RunKeyLedger::new(ledger_path.clone());

        assert!(ledger_a.record_once("warmup-a").expect("warmup a"));
        assert!(ledger_b.record_once("warmup-b").expect("warmup b"));

        let (tx_a, mut rx_a) = mpsc::unbounded_channel();
        let (tx_b, mut rx_b) = mpsc::unbounded_channel();
        let calls = Arc::new(AtomicUsize::new(0));

        let calls_a = Arc::clone(&calls);
        let mut scheduler_a = Scheduler::new(tx_a).with_run_key_ledger(ledger_a);
        scheduler_a.state_path = None;
        scheduler_a.executor = Some(Box::new(move |_| {
            calls_a.fetch_add(1, Ordering::SeqCst);
            TaskResult::Success("ran-a".to_owned())
        }));
        let mut task_a =
            ScheduledTask::new(task_id, "Shared Task A", Schedule::Interval { secs: 60 });
        task_a.next_run = Some(planned_at);
        scheduler_a.add_task(task_a);

        let calls_b = Arc::clone(&calls);
        let mut scheduler_b = Scheduler::new(tx_b).with_run_key_ledger(ledger_b);
        scheduler_b.state_path = None;
        scheduler_b.executor = Some(Box::new(move |_| {
            calls_b.fetch_add(1, Ordering::SeqCst);
            TaskResult::Success("ran-b".to_owned())
        }));
        let mut task_b =
            ScheduledTask::new(task_id, "Shared Task B", Schedule::Interval { secs: 60 });
        task_b.next_run = Some(planned_at);
        scheduler_b.add_task(task_b);

        scheduler_a.tick();
        scheduler_b.tick();

        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "shared run key should execute once across schedulers"
        );

        let emitted = usize::from(rx_a.try_recv().is_ok()) + usize::from(rx_b.try_recv().is_ok());
        assert_eq!(
            emitted, 1,
            "exactly one scheduler should emit an execution result"
        );
    }
}
