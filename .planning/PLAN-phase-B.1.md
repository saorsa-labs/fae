# Phase B.1: Scheduler LLM Tools

## Goal
Give the LLM agent the ability to manage scheduled tasks through tool calls. Users can ask Fae to create reminders, recurring tasks, and automations via natural language.

## Context
- Scheduler infrastructure already exists: `src/scheduler/` with `ScheduledTask`, `Schedule`, persistence, runner loop
- Tool system in `src/fae_llm/tools/` with `Tool` trait, `ToolRegistry`, `ToolResult`
- Tools registered in `src/agent/mod.rs::build_registry()`
- Scheduler persistence API: `load_persisted_snapshot()`, `upsert_persisted_user_task()`, `set_persisted_task_enabled()`, `mark_persisted_task_due_now()`, `remove_persisted_task()`

## Tasks

### Task 1: Create `SchedulerListTool`
**File**: `src/fae_llm/tools/scheduler_list.rs`

Implement `Tool` trait for listing scheduled tasks.
- Schema: optional `filter` param (`all`, `enabled`, `disabled`, `user`, `builtin`)
- Execute: call `load_persisted_snapshot()`, format tasks as readable text
- Display: task id, name, schedule description, enabled status, last run, next run
- `allowed_in_mode`: true for all modes (read-only operation)
- Tests: list with various filters, empty list, formatting

### Task 2: Create `SchedulerCreateTool`
**File**: `src/fae_llm/tools/scheduler_create.rs`

Implement `Tool` trait for creating/updating user tasks.
- Schema: `name` (required), `schedule` object (required: `type` + params), optional `id`, `payload`
- Schedule parsing: `{"type": "interval", "secs": 3600}`, `{"type": "daily", "hour": 9, "min": 0}`, `{"type": "weekly", "weekdays": ["mon","wed","fri"], "hour": 9, "min": 0}`
- Execute: build `ScheduledTask` with `TaskKind::User`, call `upsert_persisted_user_task()`
- Generate ID if not provided (slug from name)
- `allowed_in_mode`: Full/FullNoApproval only (creates persistent state)
- Tests: create with each schedule type, update existing, invalid schedule, missing fields

### Task 3: Create `SchedulerUpdateTool`
**File**: `src/fae_llm/tools/scheduler_update.rs`

Implement `Tool` trait for enabling/disabling tasks.
- Schema: `task_id` (required), `enabled` (required, boolean)
- Execute: call `set_persisted_task_enabled()`
- Return confirmation with task name and new state
- `allowed_in_mode`: Full/FullNoApproval only
- Tests: enable, disable, task not found

### Task 4: Create `SchedulerDeleteTool`
**File**: `src/fae_llm/tools/scheduler_delete.rs`

Implement `Tool` trait for deleting tasks.
- Schema: `task_id` (required)
- Execute: call `remove_persisted_task()`
- Prevent deletion of builtin tasks (load snapshot, check kind first)
- Return confirmation or error
- `allowed_in_mode`: Full/FullNoApproval only
- Tests: delete user task, reject builtin deletion, task not found

### Task 5: Create `SchedulerTriggerTool`
**File**: `src/fae_llm/tools/scheduler_trigger.rs`

Implement `Tool` trait for triggering immediate task execution.
- Schema: `task_id` (required)
- Execute: call `mark_persisted_task_due_now()`
- Return confirmation
- `allowed_in_mode`: Full/FullNoApproval only
- Tests: trigger existing task, task not found

### Task 6: Register scheduler tools in `build_registry()`
**File**: `src/agent/mod.rs`, `src/fae_llm/tools/mod.rs`

- Add `pub mod scheduler_list;` etc. to tools/mod.rs
- Re-export tool structs
- In `build_registry()`: register `SchedulerListTool` in ReadOnly+ modes, other scheduler tools in Full/FullNoApproval modes
- Tests: verify tools appear in registry schemas

### Task 7: Update system prompt with scheduler tool guidance
**File**: `Prompts/system_prompt.md` (or equivalent)

- Add section describing scheduler capabilities
- Document schedule JSON format with examples
- Explain task lifecycle: create → enable → trigger → delete
- Note: builtin tasks cannot be deleted, only enabled/disabled

### Task 8: Integration tests
**File**: `src/fae_llm/tools/scheduler_list.rs` (and others, inline tests)

- Full workflow: create task → list (verify present) → trigger → disable → re-enable → delete → list (verify absent)
- Edge cases: duplicate create (upsert), invalid schedule values, empty task list
- Verify ToolResult formatting is LLM-friendly
- Verify schema correctness for all tools
