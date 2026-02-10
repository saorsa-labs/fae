# Phase 5.6: Scheduler

## Overview
Background scheduler runs periodic tasks. Built-in tasks check for Fae and Pi
updates daily. Infrastructure designed for future user-defined tasks (calendar
checks, research, reminders). Inspired by OpenClaw's system-level scheduling.

## Dependencies
- Phase 5.5 (UpdateChecker) for update tasks
- Phase 5.3 (PiManager) for Pi update tasks

## Tasks

### Task 1: Create `src/scheduler/mod.rs` — module scaffold
**Files:** `src/scheduler/mod.rs` (new), `src/lib.rs` (edit)

New scheduler module:
- `pub mod runner;`
- `pub mod tasks;`
- Add `pub mod scheduler;` to lib.rs

### Task 2: Create `src/scheduler/tasks.rs` — task definitions
**Files:** `src/scheduler/tasks.rs` (new)

```rust
pub struct ScheduledTask {
    pub id: String,
    pub name: String,
    pub schedule: Schedule,
    pub last_run: Option<DateTime<Utc>>,
    pub enabled: bool,
}

pub enum Schedule {
    Interval(Duration),        // e.g., every 24 hours
    Daily { hour: u8, min: u8 },  // e.g., 9:00 AM
    Weekly { day: Weekday, hour: u8, min: u8 },
}

pub enum TaskResult {
    Success(String),
    NeedsUserAction(UserPrompt),  // e.g., "Update available, install?"
    Error(String),
}

pub struct UserPrompt {
    pub title: String,
    pub message: String,
    pub actions: Vec<PromptAction>,
}
```
- `ScheduledTask::is_due() -> bool` checks if task should run
- `ScheduledTask::mark_run()` updates last_run timestamp

### Task 3: Create `src/scheduler/runner.rs` — scheduler loop
**Files:** `src/scheduler/runner.rs` (new)

Background scheduler:
```rust
pub struct Scheduler {
    tasks: Vec<ScheduledTask>,
    state_path: PathBuf,      // ~/.config/fae/scheduler.json
    result_tx: mpsc::UnboundedSender<TaskResult>,
}
```
- `Scheduler::new(result_tx) -> Self`
- `with_update_checks(&mut self)` adds built-in Fae + Pi update check tasks (daily)
- `run(self) -> JoinHandle` spawns background loop
- Loop: check every 60 seconds, execute any due tasks
- Execute tasks asynchronously (don't block the loop)
- Persist task state (last_run) to scheduler.json

### Task 4: Implement built-in update check tasks
**Files:** `src/scheduler/tasks.rs`

Built-in task implementations:
- `check_fae_update()` — uses UpdateChecker::for_fae(), returns NeedsUserAction if update available
- `check_pi_update()` — uses UpdateChecker::for_pi(), returns NeedsUserAction if update available
- Both respect AutoUpdatePreference (auto-apply if Always, prompt if Ask, log if Never)
- Tasks registered by default via `with_update_checks()`

### Task 5: Task result handling in GUI
**Files:** `src/bin/gui.rs`

Wire scheduler results to the UI:
- `result_rx` channel receives TaskResults
- Success: log silently
- NeedsUserAction: show notification/dialog with action buttons
- Error: log warning, show in settings if persistent
- Update-specific results trigger the update UI (from Phase 5.5)

### Task 6: Scheduler status in GUI settings
**Files:** `src/bin/gui.rs`

Settings section for scheduler:
- "Scheduled Tasks" header
- List tasks: name, schedule, last run, enabled toggle
- Add future placeholder: "More scheduled tasks coming soon"
- Show scheduler state: running/paused

### Task 7: Wire scheduler into GUI startup
**Files:** `src/bin/gui.rs`, `src/startup.rs`

- Create Scheduler on app startup
- Call `with_update_checks()` to add built-in tasks
- Start scheduler background loop
- Pass result_tx to GUI for notification handling
- Graceful shutdown on app exit

### Task 8: Tests
**Files:** `src/scheduler/*.rs`

- Schedule::is_due() returns correct bool for various intervals
- Scheduler executes due tasks
- Task state persisted and reloaded
- Built-in update tasks produce correct results
- Scheduler handles task errors gracefully
- Concurrent task execution doesn't deadlock

**Acceptance:**
- Scheduler runs background tasks on configured intervals
- Built-in update checks run daily
- Results surface in GUI
- Task state persists across app restarts
- `cargo clippy` zero warnings
