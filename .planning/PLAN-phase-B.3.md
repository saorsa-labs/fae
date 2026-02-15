# Phase B.3: Scheduler Management UI

## Goal
Add native GUI controls for managing scheduled tasks, viewing execution history, and monitoring task status. Users can create, edit, and delete tasks through the menu bar panel without using voice commands.

## Context
- Phase B.1 complete: LLM tools for scheduler management (list/create/update/delete/trigger)
- Phase B.2 complete: Scheduler conversation bridge (ConversationTrigger, TaskExecutorBridge)
- GUI menu bar exists: `src/bin/gui.rs` with Settings, Soul, Skills, Memories, Ingestion items
- Scheduler persistence API: `load_persisted_snapshot()`, `upsert_persisted_user_task()`, etc.
- Task execution records stored in scheduler state
- Documentation issue: CLAUDE.md states GC is "daily at 03:30 UTC" but should be local time

## Tasks

### Task 1: Add "Scheduled Tasks" menu item
**Files**: `src/bin/gui.rs`

Add menu item to open scheduler management panel.
- Define `FAE_MENU_OPEN_SCHEDULER` constant (value: "fae-menu-scheduler")
- Create `MenuItem::with_id()` for "Scheduled Tasks..." in app submenu
- Add menu item between "Memories..." and "Ingestion..." for consistency
- Wire menu event handler in `app()` function to set `show_scheduler_panel` signal
- Tests: verify menu item appears, event triggers signal

### Task 2: Create scheduler panel types and state
**File**: `src/ui/scheduler_panel.rs` (new file)

Define types and state for scheduler UI panel.
- `SchedulerPanelState` struct with fields: `selected_task_id: Option<String>`, `editing_task: Option<EditingTask>`, `showing_history: bool`, `error_message: Option<String>`
- `EditingTask` struct: `id: Option<String>`, `name: String`, `schedule: ScheduleForm`, `enabled: bool`, `payload: Option<String>`
- `ScheduleForm` enum: `Interval { secs: String }`, `Daily { hour: String, min: String }`, `Weekly { weekdays: Vec<String>, hour: String, min: String }`
- Helper methods: `EditingTask::new()`, `from_scheduled_task()`, `to_scheduled_task()`, `validate()`
- Tests: create editing task, round-trip conversion, validation errors

### Task 3: Create task list view component
**File**: `src/ui/scheduler_panel.rs`

Render task list with name, schedule, last run, and enabled toggle.
- `TaskListView` component with props: `tasks: Vec<ScheduledTask>`, `selected_id: Option<String>`, `on_select: EventHandler<String>`, `on_toggle_enabled: EventHandler<(String, bool)>`, `on_trigger: EventHandler<String>`
- Display columns: checkbox (enabled), name, schedule description, last run timestamp, next run timestamp, trigger button
- Format schedule: "Every 1 hour" / "Daily at 09:00" / "Weekly Mon,Wed,Fri at 09:00"
- Format timestamps: relative time ("2 minutes ago") with hover tooltip (absolute time)
- Highlight selected task with background color
- Gray out disabled tasks
- Tests: render empty list, render tasks, format schedule strings, format timestamps

### Task 4: Create task edit form component
**File**: `src/ui/scheduler_panel.rs`

Render add/edit form for user tasks.
- `TaskEditForm` component with props: `editing: Option<EditingTask>`, `on_save: EventHandler<EditingTask>`, `on_cancel: EventHandler<()>`
- Form fields: text input (name), radio buttons (schedule type), conditional inputs (interval secs / daily hour/min / weekly weekdays+hour/min), checkbox (enabled), textarea (payload JSON, optional)
- Real-time validation: name not empty, schedule params valid numbers, weekdays valid, payload valid JSON or empty
- Display validation errors inline below fields
- "Save" button disabled if validation fails
- "Cancel" button to close form
- Tests: render empty form, render with existing task, validation errors, save/cancel events

### Task 5: Create execution history viewer component
**File**: `src/ui/scheduler_panel.rs`

Render task execution history with logs.
- `ExecutionHistoryView` component with props: `task_id: String`, `task_name: String`, `history: Vec<TaskRunRecord>`, `on_close: EventHandler<()>`
- Display table: timestamp, outcome (Success/Error/Timeout), summary
- Color-code outcomes: green (success), red (error), yellow (timeout)
- Show most recent runs first (reverse chronological)
- Empty state: "No execution history" if no records
- Close button to return to task list
- Tests: render history, empty state, outcome colors, close event

### Task 6: Wire scheduler panel into GUI
**File**: `src/bin/gui.rs`

Integrate scheduler panel into main app window.
- Add `show_scheduler_panel: Signal<bool>` to app state
- Import `SchedulerPanelState`, `TaskListView`, `TaskEditForm`, `ExecutionHistoryView`
- Render scheduler panel when `show_scheduler_panel` is true (modal overlay or side panel)
- Load tasks on panel open: call `load_persisted_snapshot()`
- Handle events: select task, toggle enabled (call `set_persisted_task_enabled()`), trigger (call `mark_persisted_task_due_now()`), save edited task (call `upsert_persisted_user_task()`), delete task (call `remove_persisted_task()`)
- Show confirmation dialog for delete operations
- Refresh task list after mutations
- Tests: panel open/close, task operations trigger persistence calls, error handling

### Task 7: Fix CLAUDE.md scheduler timing documentation
**File**: `CLAUDE.md`

Correct the GC timing documentation to reflect local time instead of UTC.
- Line 44: Change "Memory GC: daily at 03:30 UTC" to "Memory GC: daily at 03:30 local time"
- Verify other scheduler timing docs use "local time" consistently
- Check if scheduler implementation actually uses local time (confirm with src/scheduler/tasks.rs)
- Tests: none (documentation fix)

### Task 8: Integration tests and documentation
**Files**: `src/ui/scheduler_panel.rs`, `Prompts/system_prompt.md`

Full UI workflow validation and user-facing docs.
- Integration test: open panel → create task → verify persisted → edit task → trigger → view history → delete → verify removed
- Test edge cases: invalid form input, delete builtin task (should fail), concurrent modifications
- Update system prompt: mention "Scheduled Tasks" menu item for GUI users
- Document GUI workflow as alternative to voice commands
- Tests: end-to-end panel workflow, error cases, UI state consistency
