# Phase B.2: Scheduler Conversation Bridge

## Goal
Connect scheduler task execution to the conversation/agent system, allowing scheduled tasks to trigger agent conversations and capture results.

## Context
- Scheduler infrastructure exists: `src/scheduler/` with `ScheduledTask`, `TaskExecutor` callback, persistence
- Phase B.1 complete: LLM tools for scheduler management (create/list/update/delete/trigger tasks)
- Conversation system in `src/pipeline/coordinator.rs`
- Runtime event loop in `src/runtime.rs`
- `ScheduledTask` has `payload: Option<serde_json::Value>` field (currently unused for user tasks)
- User tasks currently return "needs handler" prompt — this phase provides the handler

## Tasks

### Task 1: Define `ConversationTrigger` payload schema
**Files**: `src/scheduler/tasks.rs`, `src/scheduler/mod.rs`

Define the payload schema for scheduler→conversation bridge.
- Create `ConversationTrigger` struct with `prompt: String`, optional `system_addon: Option<String>`, optional `timeout_secs: Option<u64>`
- Implement `Serialize`/`Deserialize` for JSON round-trip
- Add `from_task_payload()` method: `Option<serde_json::Value> → Result<ConversationTrigger>`
- Add `to_json()` helper for creating task payloads
- Tests: serialize/deserialize, round-trip, missing fields, invalid JSON

### Task 2: Create `TaskExecutorBridge` struct
**File**: `src/scheduler/executor_bridge.rs` (new file)

Implement the executor callback that bridges scheduler → conversation.
- `TaskExecutorBridge` struct with `mpsc::Sender<ConversationRequest>`
- Implement `TaskExecutor` signature: `Fn(&ScheduledTask) -> TaskResult`
- Parse `ConversationTrigger` from task payload
- Send conversation request via channel
- Return `TaskResult::Success` if sent, `TaskResult::Error` if channel closed
- Tests: parse valid payload, handle missing payload, channel closed error

### Task 3: Define `ConversationRequest` and response channel
**File**: `src/pipeline/types.rs` (or create if needed)

Define message types for scheduler→pipeline communication.
- `ConversationRequest` struct: `task_id: String`, `prompt: String`, `system_addon: Option<String>`, `response_tx: oneshot::Sender<ConversationResponse>`
- `ConversationResponse` enum: `Success(String)`, `Error(String)`, `Timeout`
- Implement `Debug` for both types
- Tests: create request/response, channel send/receive

### Task 4: Wire executor in `Runtime::new()`
**File**: `src/runtime.rs`

Connect scheduler executor to the runtime pipeline.
- In `Runtime::new()`: create `mpsc::channel()` for conversation requests
- Create `TaskExecutorBridge` with sender half
- Pass executor to `Scheduler::with_executor(bridge.into_executor())`
- Spawn background task to handle conversation requests (receiver loop)
- Tests: verify executor is set, channel wired, background task spawned

### Task 5: Handle `ConversationRequest` in runtime loop
**File**: `src/runtime.rs`, `src/pipeline/coordinator.rs`

Process conversation requests from scheduler.
- In runtime background task: receive `ConversationRequest` from channel
- Create pipeline turn with `TaskConversationSource` attribution
- Execute conversation via `Coordinator::handle_turn()`
- Send response back via `oneshot::Sender`
- Handle timeout (tokio::time::timeout)
- Tests: full request→response cycle, timeout handling, error cases

### Task 6: Add `TaskConversationSource` attribution
**File**: `src/pipeline/types.rs` or equivalent

Mark conversation turns triggered by scheduled tasks.
- Add `TaskConversationSource { task_id: String, task_name: String }` to conversation source enum
- Update conversation history persistence to include source
- Update GUI/TUI to display task-triggered messages differently
- Tests: create turn with task source, persist and reload, verify attribution

### Task 7: Capture and persist task execution results
**File**: `src/scheduler/runner.rs`, `src/runtime.rs`

Persist conversation results back to scheduler history.
- After conversation completes: map `ConversationResponse` to `TaskResult`
- Create `TaskRunRecord` with outcome, summary from response
- Send `TaskResult` via existing `result_tx` channel
- Scheduler records result in history
- Tests: success result captured, error result captured, timeout result captured

### Task 8: Integration tests and documentation
**Files**: `src/scheduler/executor_bridge.rs`, `Prompts/system_prompt.md`

Full workflow validation and user-facing docs.
- Integration test: create task with conversation payload → trigger → verify conversation → check result in history
- Test edge cases: invalid payload, channel closed, conversation error, timeout
- Update system prompt with scheduler conversation examples
- Document payload JSON schema with examples
- Tests: end-to-end workflow, all error paths covered
