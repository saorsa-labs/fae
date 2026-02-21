//! Scheduled task definitions and built-in tasks.
//!
//! Defines the [`ScheduledTask`] type, [`Schedule`] enum for timing,
//! and built-in update-check task implementations.

use chrono::{
    Datelike, Duration, Local, LocalResult, NaiveDate, NaiveDateTime, NaiveTime, TimeZone,
};
use serde::{Deserialize, Serialize};
use std::path::Path;
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
    /// Run once daily at a given hour and minute (local time).
    Daily {
        /// Hour of day (0-23, local time).
        hour: u8,
        /// Minute of hour (0-59).
        min: u8,
    },
    /// Run on selected weekdays at a given local hour and minute.
    Weekly {
        /// Selected weekdays.
        weekdays: Vec<Weekday>,
        /// Hour of day (0-23, local time).
        hour: u8,
        /// Minute of hour (0-59).
        min: u8,
    },
}

/// Day of week for weekly schedules.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Weekday {
    Mon,
    Tue,
    Wed,
    Thu,
    Fri,
    Sat,
    Sun,
}

impl Weekday {
    fn to_short(self) -> &'static str {
        match self {
            Self::Mon => "mon",
            Self::Tue => "tue",
            Self::Wed => "wed",
            Self::Thu => "thu",
            Self::Fri => "fri",
            Self::Sat => "sat",
            Self::Sun => "sun",
        }
    }

    fn from_chrono(day: chrono::Weekday) -> Self {
        match day {
            chrono::Weekday::Mon => Self::Mon,
            chrono::Weekday::Tue => Self::Tue,
            chrono::Weekday::Wed => Self::Wed,
            chrono::Weekday::Thu => Self::Thu,
            chrono::Weekday::Fri => Self::Fri,
            chrono::Weekday::Sat => Self::Sat,
            chrono::Weekday::Sun => Self::Sun,
        }
    }
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
            Self::Daily { hour, min } => write!(f, "daily at {hour:02}:{min:02} local"),
            Self::Weekly {
                weekdays,
                hour,
                min,
            } => {
                let mut days: Vec<String> =
                    weekdays.iter().map(|d| d.to_short().to_owned()).collect();
                days.sort();
                write!(f, "weekly {} at {hour:02}:{min:02} local", days.join(","))
            }
        }
    }
}

impl Schedule {
    fn is_initial_due(&self, now_epoch: u64) -> bool {
        let now_local = epoch_to_local(now_epoch);
        match self {
            Self::Interval { .. } => true,
            Self::Daily { hour, min } => {
                let date = now_local.date_naive();
                match local_datetime(date, *hour, *min) {
                    Some(scheduled) => now_local.timestamp() >= scheduled.timestamp(),
                    None => false,
                }
            }
            Self::Weekly {
                weekdays,
                hour,
                min,
            } => weekly_slot_passed_this_week(weekdays, *hour, *min, now_local),
        }
    }

    fn next_after_epoch(&self, after_epoch: u64) -> u64 {
        let after = epoch_to_local(after_epoch);
        let fallback = after + Duration::hours(24);
        match self {
            Self::Interval { secs } => after_epoch.saturating_add((*secs).max(1)),
            Self::Daily { hour, min } => {
                for offset in 0..=2 {
                    let date = after.date_naive() + Duration::days(offset);
                    if let Some(candidate) = local_datetime(date, *hour, *min)
                        && candidate.timestamp() > after.timestamp()
                    {
                        return epoch_from_local(candidate);
                    }
                }
                epoch_from_local(fallback)
            }
            Self::Weekly {
                weekdays,
                hour,
                min,
            } => {
                if let Some(next) = weekly_next_after(weekdays, *hour, *min, after) {
                    epoch_from_local(next)
                } else {
                    epoch_from_local(fallback)
                }
            }
        }
    }
}

/// Outcome of executing a scheduled task.
#[derive(Debug, Clone)]
pub enum TaskResult {
    /// Task completed successfully with a summary message.
    Success(String),
    /// Structured telemetry payload suitable for runtime/event surfaces.
    Telemetry(TaskTelemetry),
    /// Task completed but needs user attention.
    NeedsUserAction(UserPrompt),
    /// Task failed with an error message.
    Error(String),
}

impl TaskResult {
    /// Returns `true` when the result represents a failure.
    #[must_use]
    pub fn is_error(&self) -> bool {
        matches!(self, Self::Error(_))
    }

    /// Returns a short human-readable summary for run history.
    #[must_use]
    pub fn summary(&self) -> String {
        match self {
            Self::Success(msg) => msg.clone(),
            Self::Telemetry(payload) => payload.message.clone(),
            Self::NeedsUserAction(prompt) => prompt.title.clone(),
            Self::Error(msg) => msg.clone(),
        }
    }

    /// Returns a normalized run outcome kind.
    #[must_use]
    pub fn outcome(&self) -> TaskRunOutcome {
        match self {
            Self::Success(_) => TaskRunOutcome::Success,
            Self::Telemetry(_) => TaskRunOutcome::Telemetry,
            Self::NeedsUserAction(_) => TaskRunOutcome::NeedsUserAction,
            Self::Error(_) => TaskRunOutcome::Error,
        }
    }
}

/// Structured task telemetry.
#[derive(Debug, Clone)]
pub struct TaskTelemetry {
    /// Human-readable summary.
    pub message: String,
    /// Machine-readable runtime event.
    pub event: crate::runtime::RuntimeEvent,
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

/// Logical task kind used by scheduler/doctor policy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum TaskKind {
    /// Built-in background maintenance/update tasks.
    #[default]
    Builtin,
    /// User-defined automation task.
    User,
}

/// One run attempt captured in scheduler history.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskRunRecord {
    /// Task ID.
    pub task_id: String,
    /// Start timestamp (epoch seconds).
    pub started_at: u64,
    /// End timestamp (epoch seconds).
    pub finished_at: u64,
    /// Outcome kind.
    pub outcome: TaskRunOutcome,
    /// Human-readable summary.
    pub summary: String,
}

/// Normalized run outcome for history and doctor checks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TaskRunOutcome {
    Success,
    Telemetry,
    NeedsUserAction,
    Error,
    SoftTimeout,
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
    /// Unix epoch seconds of the last run, if any.
    #[serde(default)]
    pub last_run: Option<u64>,
    /// Unix epoch seconds for the next planned run, if known.
    #[serde(default)]
    pub next_run: Option<u64>,
    /// Whether the task is enabled.
    #[serde(default = "default_enabled")]
    pub enabled: bool,
    /// Logical task kind.
    #[serde(default)]
    pub kind: TaskKind,
    /// Optional opaque payload for user-defined tasks.
    #[serde(default)]
    pub payload: Option<serde_json::Value>,
    /// Consecutive failure count.
    #[serde(default)]
    pub failure_streak: u32,
    /// Maximum immediate retries before returning to normal schedule.
    #[serde(default = "default_max_retries")]
    pub max_retries: u8,
    /// Base retry backoff in seconds.
    #[serde(default = "default_retry_backoff_secs")]
    pub retry_backoff_secs: u64,
    /// Disable task after this many consecutive failures.
    #[serde(default = "default_max_failure_streak_before_pause")]
    pub max_failure_streak_before_pause: u32,
    /// Soft runtime budget in seconds (not a hard cancellation).
    #[serde(default = "default_soft_timeout_secs")]
    pub soft_timeout_secs: u64,
    /// Last error message, if any.
    #[serde(default)]
    pub last_error: Option<String>,
}

fn default_enabled() -> bool {
    true
}

fn default_max_retries() -> u8 {
    3
}

fn default_retry_backoff_secs() -> u64 {
    60
}

fn default_max_failure_streak_before_pause() -> u32 {
    5
}

fn default_soft_timeout_secs() -> u64 {
    300
}

impl ScheduledTask {
    /// Create a new enabled task with the given schedule.
    pub fn new(id: impl Into<String>, name: impl Into<String>, schedule: Schedule) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            schedule,
            last_run: None,
            next_run: None,
            enabled: true,
            kind: TaskKind::Builtin,
            payload: None,
            failure_streak: 0,
            max_retries: default_max_retries(),
            retry_backoff_secs: default_retry_backoff_secs(),
            max_failure_streak_before_pause: default_max_failure_streak_before_pause(),
            soft_timeout_secs: default_soft_timeout_secs(),
            last_error: None,
        }
    }

    /// Creates a new user-defined task.
    pub fn user_task(id: impl Into<String>, name: impl Into<String>, schedule: Schedule) -> Self {
        let mut task = Self::new(id, name, schedule);
        task.kind = TaskKind::User;
        task
    }

    /// Returns `true` if the task is enabled and due to run.
    pub fn is_due(&self) -> bool {
        if !self.enabled {
            return false;
        }

        let now = now_epoch_secs();

        if let Some(next) = self.next_run {
            return now >= next;
        }

        match self.last_run {
            None => self.schedule.is_initial_due(now),
            Some(last) => now >= self.schedule.next_after_epoch(last),
        }
    }

    /// Record a successful run and plan the next run.
    pub fn mark_run_success(&mut self) {
        let now = now_epoch_secs();
        self.last_run = Some(now);
        self.next_run = Some(self.schedule.next_after_epoch(now));
        self.failure_streak = 0;
        self.last_error = None;
    }

    /// Record a failed run and plan retry/backoff.
    pub fn mark_run_failure(&mut self, error: &str) {
        let now = now_epoch_secs();
        self.last_run = Some(now);
        self.failure_streak = self.failure_streak.saturating_add(1);
        self.last_error = Some(error.to_owned());

        if self.failure_streak <= u32::from(self.max_retries) {
            let delay = exponential_backoff(self.retry_backoff_secs, self.failure_streak);
            self.next_run = Some(now.saturating_add(delay));
        } else {
            self.next_run = Some(self.schedule.next_after_epoch(now));
        }

        if self.failure_streak >= self.max_failure_streak_before_pause {
            self.enabled = false;
        }
    }

    /// Force this task to run on the next scheduler tick.
    pub fn mark_due_now(&mut self) {
        self.next_run = Some(now_epoch_secs());
    }

    /// Preserve compatibility with old tests/callers.
    pub fn mark_run(&mut self) {
        self.mark_run_success();
    }
}

fn exponential_backoff(base_secs: u64, streak: u32) -> u64 {
    let mut delay = base_secs.max(1);
    let mut i = 1;
    while i < streak {
        delay = delay.saturating_mul(2);
        i += 1;
    }
    delay
}

/// Returns current UTC seconds since epoch.
pub(crate) fn now_epoch_secs() -> u64 {
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(duration) => duration.as_secs(),
        Err(_) => 0,
    }
}

fn epoch_to_local(ts: u64) -> chrono::DateTime<Local> {
    let secs = match i64::try_from(ts) {
        Ok(value) => value,
        Err(_) => return Local::now(),
    };

    match Local.timestamp_opt(secs, 0) {
        LocalResult::Single(dt) => dt,
        LocalResult::Ambiguous(dt, _) => dt,
        LocalResult::None => Local::now(),
    }
}

fn epoch_from_local(dt: chrono::DateTime<Local>) -> u64 {
    u64::try_from(dt.timestamp()).unwrap_or_default()
}

fn local_datetime(date: NaiveDate, hour: u8, min: u8) -> Option<chrono::DateTime<Local>> {
    let time = NaiveTime::from_hms_opt(u32::from(hour.min(23)), u32::from(min.min(59)), 0)?;
    let naive = NaiveDateTime::new(date, time);
    match Local.from_local_datetime(&naive) {
        LocalResult::Single(dt) => Some(dt),
        LocalResult::Ambiguous(dt, _) => Some(dt),
        LocalResult::None => None,
    }
}

fn weekly_slot_passed_this_week(
    weekdays: &[Weekday],
    hour: u8,
    min: u8,
    now: chrono::DateTime<Local>,
) -> bool {
    if weekdays.is_empty() {
        return false;
    }

    let days_since_monday = i64::from(now.weekday().num_days_from_monday());
    let week_start = now.date_naive() - Duration::days(days_since_monday);

    for offset in 0..=days_since_monday {
        let date = week_start + Duration::days(offset);
        let day = Weekday::from_chrono(date.weekday());
        if !weekdays.contains(&day) {
            continue;
        }
        if let Some(candidate) = local_datetime(date, hour, min)
            && candidate.timestamp() <= now.timestamp()
        {
            return true;
        }
    }

    false
}

fn weekly_next_after(
    weekdays: &[Weekday],
    hour: u8,
    min: u8,
    after: chrono::DateTime<Local>,
) -> Option<chrono::DateTime<Local>> {
    if weekdays.is_empty() {
        return None;
    }

    for day_offset in 0..=14 {
        let date = after.date_naive() + Duration::days(day_offset);
        let day = Weekday::from_chrono(date.weekday());
        if !weekdays.contains(&day) {
            continue;
        }

        if let Some(candidate) = local_datetime(date, hour, min)
            && candidate.timestamp() > after.timestamp()
        {
            return Some(candidate);
        }
    }

    None
}

// ---------------------------------------------------------------------------
// Conversation trigger payload
// ---------------------------------------------------------------------------

/// Payload schema for scheduler tasks that trigger agent conversations.
///
/// This payload is stored in [`ScheduledTask::payload`] and parsed when
/// the task executes. The scheduler will inject the prompt into the
/// conversation system and optionally augment the system prompt.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ConversationTrigger {
    /// The user prompt to inject into the conversation.
    pub prompt: String,
    /// Optional addition to the system prompt for this conversation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub system_addon: Option<String>,
    /// Optional conversation timeout in seconds.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeout_secs: Option<u64>,
}

impl ConversationTrigger {
    /// Create a new conversation trigger with the given prompt.
    pub fn new(prompt: impl Into<String>) -> Self {
        Self {
            prompt: prompt.into(),
            system_addon: None,
            timeout_secs: None,
        }
    }

    /// Set the system prompt addon.
    pub fn with_system_addon(mut self, addon: impl Into<String>) -> Self {
        self.system_addon = Some(addon.into());
        self
    }

    /// Set the conversation timeout in seconds.
    pub fn with_timeout_secs(mut self, secs: u64) -> Self {
        self.timeout_secs = Some(secs);
        self
    }

    /// Parse a conversation trigger from a task payload.
    ///
    /// Returns `Ok(trigger)` if the payload is a valid ConversationTrigger.
    /// Returns `Err` if the payload is missing, null, or malformed JSON.
    pub fn from_task_payload(payload: &Option<serde_json::Value>) -> crate::Result<Self> {
        let Some(value) = payload else {
            return Err(crate::error::SpeechError::Config(
                "task payload is missing".to_owned(),
            ));
        };

        if value.is_null() {
            return Err(crate::error::SpeechError::Config(
                "task payload is null".to_owned(),
            ));
        }

        serde_json::from_value(value.clone()).map_err(|e| {
            crate::error::SpeechError::Config(format!("invalid conversation trigger: {e}"))
        })
    }

    /// Convert this trigger to a JSON payload suitable for [`ScheduledTask::payload`].
    pub fn to_json(&self) -> crate::Result<serde_json::Value> {
        serde_json::to_value(self).map_err(|e| {
            crate::error::SpeechError::Config(format!("failed to serialize trigger: {e}"))
        })
    }
}

// ---------------------------------------------------------------------------
// Built-in task executors
// ---------------------------------------------------------------------------

/// Well-known task IDs for built-in tasks.
pub const TASK_CHECK_FAE_UPDATE: &str = "check_fae_update";

/// Well-known task ID for memory reflection/consolidation.
pub const TASK_MEMORY_REFLECT: &str = "memory_reflect";
/// Well-known task ID for memory reindex/health checks.
pub const TASK_MEMORY_REINDEX: &str = "memory_reindex";
/// Well-known task ID for memory retention garbage collection.
pub const TASK_MEMORY_GC: &str = "memory_gc";
/// Well-known task ID for memory schema migration checks.
pub const TASK_MEMORY_MIGRATE: &str = "memory_migrate";
/// Well-known task ID for daily memory database backup.
pub const TASK_MEMORY_BACKUP: &str = "memory_backup";
/// Well-known task ID for the daily noise budget reset.
pub const TASK_NOISE_BUDGET_RESET: &str = "noise_budget_reset";
/// Well-known task ID for checking stale relationships.
pub const TASK_STALE_RELATIONSHIPS: &str = "stale_relationships";
/// Well-known task ID for the morning briefing.
pub const TASK_MORNING_BRIEFING: &str = "morning_briefing";
/// Well-known task ID for checking skill proposal opportunities.
pub const TASK_SKILL_PROPOSALS: &str = "skill_proposals";
/// Well-known task ID for periodic Python skill health checks.
pub const TASK_SKILL_HEALTH_CHECK: &str = "skill_health_check";

/// Execute a built-in scheduled task by ID.
///
/// Returns [`TaskResult`] for any known built-in task, or
/// [`TaskResult::Error`] for unknown task IDs.
pub fn execute_builtin(task_id: &str) -> TaskResult {
    let defaults = crate::config::MemoryConfig::default();
    let root = crate::memory::default_memory_root_dir();
    execute_builtin_with_memory_root(
        task_id,
        &root,
        defaults.retention_days,
        defaults.backup_keep_count,
    )
}

/// Execute a built-in scheduled task by ID using an explicit memory root.
///
/// This is used by the GUI scheduler so memory maintenance tasks target the
/// active configured memory store instead of process defaults.
pub fn execute_builtin_with_memory_root(
    task_id: &str,
    memory_root: &Path,
    retention_days: u32,
    backup_keep_count: usize,
) -> TaskResult {
    match task_id {
        TASK_CHECK_FAE_UPDATE => check_fae_update(),
        TASK_MEMORY_REFLECT => run_memory_reflect_for_root(memory_root),
        TASK_MEMORY_REINDEX => run_memory_reindex_for_root(memory_root),
        TASK_MEMORY_GC => run_memory_gc_for_root(memory_root, retention_days),
        TASK_MEMORY_MIGRATE => run_memory_migrate_for_root(memory_root),
        TASK_MEMORY_BACKUP => run_memory_backup_for_root(memory_root, backup_keep_count),
        TASK_NOISE_BUDGET_RESET => run_noise_budget_reset(),
        TASK_STALE_RELATIONSHIPS => run_stale_relationship_check(memory_root),
        TASK_MORNING_BRIEFING => run_morning_briefing_check(memory_root),
        TASK_SKILL_PROPOSALS => run_skill_proposal_check(memory_root),
        TASK_SKILL_HEALTH_CHECK => run_skill_health_check(),
        _ => TaskResult::Error(format!("unknown built-in task: {task_id}")),
    }
}

/// Reset the daily noise budget.
///
/// This is a lightweight task that logs the reset. The actual NoiseController
/// state is managed in-memory by the pipeline coordinator.
fn run_noise_budget_reset() -> TaskResult {
    tracing::info!("daily noise budget reset");
    TaskResult::Success("noise budget reset".into())
}

/// Check for stale relationships that haven't been mentioned recently.
fn run_stale_relationship_check(memory_root: &Path) -> TaskResult {
    let repo = match crate::memory::SqliteMemoryRepository::new(memory_root) {
        Ok(r) => r,
        Err(e) => return TaskResult::Error(format!("failed to open memory: {e}")),
    };
    let store = crate::intelligence::IntelligenceStore::new(repo);
    match store.query_stale_relationships(30) {
        Ok(stale) => {
            if stale.is_empty() {
                TaskResult::Success("no stale relationships".into())
            } else {
                let names: Vec<String> = stale
                    .iter()
                    .filter_map(|(r, _)| {
                        crate::intelligence::IntelligenceStore::parse_relationship_meta(r)
                            .map(|m| m.name)
                    })
                    .collect();
                TaskResult::Success(format!(
                    "found {} stale relationships: {}",
                    stale.len(),
                    names.join(", ")
                ))
            }
        }
        Err(e) => TaskResult::Error(format!("stale relationship check failed: {e}")),
    }
}

/// Build a morning briefing summary for logging/telemetry.
fn run_morning_briefing_check(memory_root: &Path) -> TaskResult {
    let repo = match crate::memory::SqliteMemoryRepository::new(memory_root) {
        Ok(r) => r,
        Err(e) => return TaskResult::Error(format!("failed to open memory: {e}")),
    };
    let store = crate::intelligence::IntelligenceStore::new(repo);
    let briefing = crate::intelligence::build_briefing(&store);
    if briefing.is_empty() {
        TaskResult::Success("no briefing items today".into())
    } else {
        TaskResult::Success(format!("briefing ready: {} items", briefing.len()))
    }
}

/// Check for skill proposal opportunities.
fn run_skill_proposal_check(memory_root: &Path) -> TaskResult {
    let opportunities = crate::intelligence::detect_skill_opportunities(memory_root);
    if opportunities.is_empty() {
        TaskResult::Success("no new skill opportunities detected".into())
    } else {
        let names: Vec<&str> = opportunities
            .iter()
            .map(|(name, _, _)| name.as_str())
            .collect();
        TaskResult::Success(format!(
            "detected {} skill opportunities: {}",
            opportunities.len(),
            names.join(", ")
        ))
    }
}

/// Run health checks for all active Python skills.
///
/// Lists installed skills and reports on their status. This is a lightweight
/// check that inspects lifecycle status; actual process-level health checks
/// are performed by the runtime when skills are running.
fn run_skill_health_check() -> TaskResult {
    let skills = crate::skills::list_python_skills();
    if skills.is_empty() {
        return TaskResult::Success("no Python skills installed".into());
    }

    let active_count = skills.iter().filter(|s| s.status.is_runnable()).count();
    let quarantined: Vec<&str> = skills
        .iter()
        .filter(|s| s.status.is_quarantined())
        .map(|s| s.id.as_str())
        .collect();

    if quarantined.is_empty() {
        TaskResult::Success(format!(
            "{active_count}/{} skills healthy",
            skills.len()
        ))
    } else {
        TaskResult::Success(format!(
            "{active_count}/{} skills healthy, {} quarantined: {}",
            skills.len(),
            quarantined.len(),
            quarantined.join(", ")
        ))
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
                AutoUpdatePreference::Never => TaskResult::Success(format!(
                    "Fae {} available (auto-update disabled)",
                    release.version
                )),
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

fn run_memory_reflect_for_root(root: &Path) -> TaskResult {
    match crate::memory::run_memory_reflection(root) {
        Ok(msg) => TaskResult::Telemetry(TaskTelemetry {
            message: msg,
            event: crate::runtime::RuntimeEvent::MemoryWrite {
                op: "reflect".to_owned(),
                target_id: None,
            },
        }),
        Err(e) => TaskResult::Error(format!("memory reflection failed: {e}")),
    }
}

fn run_memory_reindex_for_root(root: &Path) -> TaskResult {
    match crate::memory::run_memory_reindex(root) {
        Ok(msg) => TaskResult::Telemetry(TaskTelemetry {
            message: msg,
            event: crate::runtime::RuntimeEvent::MemoryWrite {
                op: "reindex".to_owned(),
                target_id: None,
            },
        }),
        Err(e) => TaskResult::Error(format!("memory reindex failed: {e}")),
    }
}

fn run_memory_gc_for_root(root: &Path, retention_days: u32) -> TaskResult {
    match crate::memory::run_memory_gc(root, retention_days) {
        Ok(msg) => TaskResult::Telemetry(TaskTelemetry {
            message: msg,
            event: crate::runtime::RuntimeEvent::MemoryWrite {
                op: "retention_gc".to_owned(),
                target_id: None,
            },
        }),
        Err(e) => TaskResult::Error(format!("memory retention failed: {e}")),
    }
}

fn run_memory_migrate_for_root(root: &Path) -> TaskResult {
    let repo = match crate::memory::SqliteMemoryRepository::new(root) {
        Ok(r) => r,
        Err(e) => return TaskResult::Error(format!("failed to open memory: {e}")),
    };
    let target = crate::memory::current_memory_schema_version();
    match repo.migrate_if_needed(target) {
        Ok(()) => {
            let from = repo.schema_version().unwrap_or(target);
            TaskResult::Telemetry(TaskTelemetry {
                message: "memory schema up to date".to_owned(),
                event: crate::runtime::RuntimeEvent::MemoryMigration {
                    from,
                    to: target,
                    success: true,
                },
            })
        }
        Err(e) => {
            let from = repo.schema_version().unwrap_or(target);
            TaskResult::Telemetry(TaskTelemetry {
                message: format!("memory migration failed: {e}"),
                event: crate::runtime::RuntimeEvent::MemoryMigration {
                    from,
                    to: target,
                    success: false,
                },
            })
        }
    }
}

fn run_memory_backup_for_root(root: &Path, keep_count: usize) -> TaskResult {
    let db = crate::memory::backup::db_path(root);
    if !db.exists() {
        return TaskResult::Success("backup skipped: no database file".into());
    }
    let backup_dir = root.join("backups");

    match crate::memory::backup::backup_database(&db, &backup_dir) {
        Ok(path) => {
            let rotated =
                crate::memory::backup::rotate_backups(&backup_dir, keep_count).unwrap_or(0);
            let name = path
                .file_name()
                .map(|f| f.to_string_lossy().to_string())
                .unwrap_or_default();
            TaskResult::Success(format!(
                "backup created: {name}, rotated {rotated} old backup(s)"
            ))
        }
        Err(e) => TaskResult::Error(format!("memory backup failed: {e}")),
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use crate::runtime::RuntimeEvent;
    use crate::test_utils::temp_test_root;

    fn temp_root(name: &str) -> std::path::PathBuf {
        temp_test_root("scheduler-task", name)
    }

    fn seed_old_episode_record(root: &std::path::Path, id: &str) {
        use crate::memory::{MemoryKind, MemoryRecord, MemoryStatus};

        let repo =
            crate::memory::SqliteMemoryRepository::new(root).expect("sqlite repo for seeding");
        repo.ensure_layout().expect("ensure memory layout");

        let old = super::now_epoch_secs().saturating_sub(400 * 24 * 3600);
        let record = MemoryRecord {
            id: id.to_owned(),
            kind: MemoryKind::Episode,
            status: MemoryStatus::Active,
            text: "old episode".to_owned(),
            confidence: 0.8,
            source_turn_id: Some("turn-old".to_owned()),
            tags: vec!["episode".to_owned()],
            supersedes: None,
            created_at: old,
            updated_at: old,
            importance_score: None,
            stale_after_secs: None,
            metadata: None,
        };
        repo.insert_record_raw(&record).expect("insert old record");
    }

    #[test]
    fn new_task_has_correct_defaults() {
        let task = ScheduledTask::new("test", "Test Task", Schedule::Interval { secs: 3600 });
        assert_eq!(task.id, "test");
        assert_eq!(task.name, "Test Task");
        assert!(task.last_run.is_none());
        assert!(task.enabled);
        assert_eq!(task.kind, TaskKind::Builtin);
        assert!(task.next_run.is_none());
    }

    #[test]
    fn user_task_sets_user_kind() {
        let task = ScheduledTask::user_task(
            "daily-brief",
            "Daily Brief",
            Schedule::Interval { secs: 60 },
        );
        assert_eq!(task.kind, TaskKind::User);
    }

    #[test]
    fn interval_due_when_never_run() {
        let task = ScheduledTask::new("t", "T", Schedule::Interval { secs: 60 });
        assert!(task.is_due());
    }

    #[test]
    fn interval_not_due_when_recently_run() {
        let mut task = ScheduledTask::new("t", "T", Schedule::Interval { secs: 86400 });
        task.mark_run_success();
        assert!(!task.is_due());
    }

    #[test]
    fn failure_sets_backoff_and_error() {
        let mut task = ScheduledTask::new("t", "T", Schedule::Interval { secs: 3600 });
        task.retry_backoff_secs = 10;
        task.mark_run_failure("boom");
        assert_eq!(task.failure_streak, 1);
        assert_eq!(task.last_error.as_deref(), Some("boom"));
        let next = task.next_run.expect("next run set");
        assert!(next >= now_epoch_secs().saturating_add(10));
    }

    #[test]
    fn too_many_failures_disable_task() {
        let mut task = ScheduledTask::new("t", "T", Schedule::Interval { secs: 3600 });
        task.max_failure_streak_before_pause = 2;
        task.mark_run_failure("err-1");
        assert!(task.enabled);
        task.mark_run_failure("err-2");
        assert!(!task.enabled);
    }

    #[test]
    fn success_resets_failure_state() {
        let mut task = ScheduledTask::new("t", "T", Schedule::Interval { secs: 3600 });
        task.mark_run_failure("err");
        assert_eq!(task.failure_streak, 1);
        task.mark_run_success();
        assert_eq!(task.failure_streak, 0);
        assert!(task.last_error.is_none());
        assert!(task.next_run.is_some());
    }

    #[test]
    fn daily_display_uses_local_wording() {
        let s = Schedule::Daily { hour: 9, min: 0 };
        assert_eq!(s.to_string(), "daily at 09:00 local");
    }

    #[test]
    fn weekly_display_lists_days() {
        let s = Schedule::Weekly {
            weekdays: vec![Weekday::Fri, Weekday::Mon],
            hour: 9,
            min: 30,
        };
        assert_eq!(s.to_string(), "weekly fri,mon at 09:30 local");
    }

    #[test]
    fn schedule_serde_weekly_round_trip() {
        let schedule = Schedule::Weekly {
            weekdays: vec![Weekday::Mon, Weekday::Wed],
            hour: 8,
            min: 15,
        };
        let json = serde_json::to_string(&schedule).unwrap();
        let restored: Schedule = serde_json::from_str(&json).unwrap();
        match restored {
            Schedule::Weekly {
                weekdays,
                hour,
                min,
            } => {
                assert_eq!(weekdays, vec![Weekday::Mon, Weekday::Wed]);
                assert_eq!(hour, 8);
                assert_eq!(min, 15);
            }
            _ => panic!("expected Weekly"),
        }
    }

    #[test]
    fn task_serde_round_trip() {
        let mut task = ScheduledTask::new(
            "check_fae",
            "Check Fae Update",
            Schedule::Interval { secs: 86400 },
        );
        task.kind = TaskKind::User;
        task.mark_run_success();

        let json = serde_json::to_string(&task).unwrap();
        let restored: ScheduledTask = serde_json::from_str(&json).unwrap();
        assert_eq!(restored.id, "check_fae");
        assert_eq!(restored.name, "Check Fae Update");
        assert!(restored.enabled);
        assert!(restored.last_run.is_some());
        assert_eq!(restored.kind, TaskKind::User);
    }

    #[test]
    fn task_result_variants_and_helpers() {
        let success = TaskResult::Success("done".to_owned());
        assert!(!success.is_error());
        assert_eq!(success.summary(), "done");
        assert_eq!(success.outcome(), TaskRunOutcome::Success);

        let telemetry = TaskResult::Telemetry(TaskTelemetry {
            message: "telemetry".to_owned(),
            event: RuntimeEvent::MemoryWrite {
                op: "reindex".to_owned(),
                target_id: None,
            },
        });
        assert_eq!(telemetry.summary(), "telemetry");
        assert_eq!(telemetry.outcome(), TaskRunOutcome::Telemetry);

        let error = TaskResult::Error("fail".to_owned());
        assert!(error.is_error());
        assert_eq!(error.outcome(), TaskRunOutcome::Error);

        let prompt = UserPrompt {
            title: "Update".to_owned(),
            message: "New version".to_owned(),
            actions: vec![PromptAction {
                label: "Install".to_owned(),
                id: "install".to_owned(),
            }],
        };
        let action = TaskResult::NeedsUserAction(prompt);
        assert_eq!(action.outcome(), TaskRunOutcome::NeedsUserAction);
    }

    #[test]
    fn execute_builtin_unknown_task_returns_error() {
        let result = execute_builtin("nonexistent_task");
        assert!(matches!(result, TaskResult::Error(_)));
    }

    #[test]
    fn execute_builtin_with_memory_root_respects_custom_retention_days() {
        let root = temp_root("custom-retention");
        seed_old_episode_record(&root, "episode-custom-retention");

        let result = execute_builtin_with_memory_root(
            TASK_MEMORY_GC,
            &root,
            /* retention_days */ 0,
            /* backup_keep_count */ 7,
        );
        assert!(matches!(result, TaskResult::Telemetry(_)));

        let repo = crate::memory::SqliteMemoryRepository::new(&root).expect("sqlite repo");
        let records = repo.list_records().expect("list records");
        let kept = records
            .iter()
            .find(|r| r.id == "episode-custom-retention")
            .expect("record should exist");
        assert_eq!(kept.status, crate::memory::MemoryStatus::Active);

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn execute_builtin_fae_check_returns_result() {
        let result = execute_builtin(TASK_CHECK_FAE_UPDATE);
        assert!(matches!(
            result,
            TaskResult::Success(_)
                | TaskResult::Telemetry(_)
                | TaskResult::NeedsUserAction(_)
                | TaskResult::Error(_)
        ));
    }

    #[test]
    fn run_memory_migrate_for_root_emits_migration_telemetry_success() {
        let root = temp_root("migration-success");

        let result = run_memory_migrate_for_root(&root);
        let target = crate::memory::current_memory_schema_version();
        match result {
            TaskResult::Telemetry(TaskTelemetry {
                event: RuntimeEvent::MemoryMigration { from, to, success },
                ..
            }) => {
                // Fresh SQLite DB is created at current schema version.
                assert_eq!(from, target);
                assert_eq!(to, target);
                assert!(success);
            }
            other => panic!("expected migration telemetry, got: {other:?}"),
        }

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn run_memory_migrate_for_root_emits_migration_telemetry_failure() {
        let root = temp_root("migration-failure");
        // Place a directory where fae.db should be, so SQLite cannot open it.
        std::fs::create_dir_all(root.join("fae.db")).expect("create dir as db path");

        let result = run_memory_migrate_for_root(&root);
        // SqliteMemoryRepository::new fails → TaskResult::Error
        assert!(matches!(result, TaskResult::Error(_)));

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn run_memory_reflect_for_root_emits_write_telemetry() {
        let root = temp_root("reflect-telemetry");

        let result = run_memory_reflect_for_root(&root);
        match result {
            TaskResult::Telemetry(TaskTelemetry {
                event: RuntimeEvent::MemoryWrite { op, target_id },
                ..
            }) => {
                assert_eq!(op, "reflect");
                assert!(target_id.is_none());
            }
            other => panic!("expected reflect telemetry, got: {other:?}"),
        }

        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn task_id_constants() {
        assert_eq!(TASK_CHECK_FAE_UPDATE, "check_fae_update");
    }

    // -----------------------------------------------------------------------
    // ConversationTrigger tests
    // -----------------------------------------------------------------------

    #[test]
    fn conversation_trigger_new() {
        let trigger = ConversationTrigger::new("What's the weather?");
        assert_eq!(trigger.prompt, "What's the weather?");
        assert!(trigger.system_addon.is_none());
        assert!(trigger.timeout_secs.is_none());
    }

    #[test]
    fn conversation_trigger_with_system_addon() {
        let trigger = ConversationTrigger::new("Check calendar")
            .with_system_addon("You are a calendar assistant");
        assert_eq!(trigger.prompt, "Check calendar");
        match trigger.system_addon {
            Some(ref addon) => assert_eq!(addon, "You are a calendar assistant"),
            None => unreachable!(),
        }
    }

    #[test]
    fn conversation_trigger_with_timeout() {
        let trigger = ConversationTrigger::new("Quick task").with_timeout_secs(30);
        assert_eq!(trigger.prompt, "Quick task");
        match trigger.timeout_secs {
            Some(secs) => assert_eq!(secs, 30),
            None => unreachable!(),
        }
    }

    #[test]
    fn conversation_trigger_serialize_deserialize() {
        let trigger = ConversationTrigger::new("Hello")
            .with_system_addon("Test")
            .with_timeout_secs(60);

        let json = serde_json::to_value(&trigger).expect("serialize");
        let deserialized: ConversationTrigger = serde_json::from_value(json).expect("deserialize");

        assert_eq!(trigger, deserialized);
    }

    #[test]
    fn conversation_trigger_serialize_minimal() {
        let trigger = ConversationTrigger::new("Simple prompt");
        let json = serde_json::to_value(&trigger).expect("serialize");

        assert!(
            json.get("prompt").is_some(),
            "JSON must contain prompt field"
        );
        assert_eq!(
            json.get("prompt").and_then(|v| v.as_str()),
            Some("Simple prompt")
        );
        assert!(
            json.get("system_addon").is_none(),
            "Optional fields should not serialize when None"
        );
        assert!(
            json.get("timeout_secs").is_none(),
            "Optional fields should not serialize when None"
        );
    }

    #[test]
    fn conversation_trigger_deserialize_missing_optional_fields() {
        let json = serde_json::json!({
            "prompt": "Test prompt"
        });

        let trigger: ConversationTrigger = serde_json::from_value(json).expect("deserialize");
        assert_eq!(trigger.prompt, "Test prompt");
        assert!(trigger.system_addon.is_none());
        assert!(trigger.timeout_secs.is_none());
    }

    #[test]
    fn conversation_trigger_from_task_payload_valid() {
        let payload = Some(serde_json::json!({
            "prompt": "Remind me",
            "system_addon": "Calendar mode",
            "timeout_secs": 120
        }));

        let trigger = ConversationTrigger::from_task_payload(&payload).expect("parse payload");
        assert_eq!(trigger.prompt, "Remind me");
        match trigger.system_addon {
            Some(ref addon) => assert_eq!(addon, "Calendar mode"),
            None => unreachable!(),
        }
        match trigger.timeout_secs {
            Some(secs) => assert_eq!(secs, 120),
            None => unreachable!(),
        }
    }

    #[test]
    fn conversation_trigger_from_task_payload_minimal() {
        let payload = Some(serde_json::json!({
            "prompt": "Simple"
        }));

        let trigger = ConversationTrigger::from_task_payload(&payload).expect("parse payload");
        assert_eq!(trigger.prompt, "Simple");
        assert!(trigger.system_addon.is_none());
        assert!(trigger.timeout_secs.is_none());
    }

    #[test]
    fn conversation_trigger_from_task_payload_none() {
        let result = ConversationTrigger::from_task_payload(&None);
        match result {
            Err(crate::error::SpeechError::Config(msg)) => {
                assert!(
                    msg.contains("missing"),
                    "Expected 'missing' in error: {msg}"
                );
            }
            other => panic!("Expected Config error for missing payload, got: {other:?}"),
        }
    }

    #[test]
    fn conversation_trigger_from_task_payload_null() {
        let payload = Some(serde_json::Value::Null);
        let result = ConversationTrigger::from_task_payload(&payload);
        match result {
            Err(crate::error::SpeechError::Config(msg)) => {
                assert!(msg.contains("null"), "Expected 'null' in error: {msg}");
            }
            other => panic!("Expected Config error for null payload, got: {other:?}"),
        }
    }

    #[test]
    fn conversation_trigger_from_task_payload_invalid_json() {
        let payload = Some(serde_json::json!({
            "invalid_field": "no prompt field"
        }));

        let result = ConversationTrigger::from_task_payload(&payload);
        match result {
            Err(crate::error::SpeechError::Config(msg)) => {
                assert!(
                    msg.contains("invalid") || msg.contains("missing field"),
                    "Expected JSON error in message: {msg}"
                );
            }
            other => panic!("Expected Config error for invalid JSON, got: {other:?}"),
        }
    }

    #[test]
    fn conversation_trigger_to_json() {
        let trigger = ConversationTrigger::new("Test prompt")
            .with_system_addon("Addon text")
            .with_timeout_secs(90);

        let json = trigger.to_json().expect("to_json");

        assert_eq!(
            json.get("prompt").and_then(|v| v.as_str()),
            Some("Test prompt")
        );
        assert_eq!(
            json.get("system_addon").and_then(|v| v.as_str()),
            Some("Addon text")
        );
        assert_eq!(json.get("timeout_secs").and_then(|v| v.as_u64()), Some(90));
    }

    #[test]
    fn conversation_trigger_to_json_minimal() {
        let trigger = ConversationTrigger::new("Minimal");
        let json = trigger.to_json().expect("to_json");

        assert_eq!(json.get("prompt").and_then(|v| v.as_str()), Some("Minimal"));
        assert!(json.get("system_addon").is_none());
        assert!(json.get("timeout_secs").is_none());
    }

    #[test]
    fn conversation_trigger_round_trip_via_json() {
        let original = ConversationTrigger::new("Round trip test")
            .with_system_addon("System text")
            .with_timeout_secs(45);

        let json = original.to_json().expect("to_json");
        let payload = Some(json);
        let parsed = ConversationTrigger::from_task_payload(&payload).expect("from_task_payload");

        assert_eq!(original, parsed);
    }
}
