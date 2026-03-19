# Phase 5.4: Pi RPC Session & Coding Skill

## Overview
`PiSession` spawns Pi in RPC mode (`pi --mode rpc --no-session`), communicates via
JSON-over-stdin/stdout. A new `pi_delegate` agent tool lets Fae delegate coding tasks
to Pi. A skill file (`Skills/pi.md`) tells Fae when to use Pi.

## Pi RPC Protocol
- Process: `pi --mode rpc --no-session --provider <name> --model <id>`
- Requests: JSON lines to stdin, e.g. `{"type":"prompt","message":"..."}`
- Events: JSON lines from stdout (streaming):
  - `agent_start` / `agent_end` — session lifecycle
  - `message_update` — streaming text deltas
  - `tool_execution_start/update/end` — tool invocations
  - `turn_start/end` — reasoning turn boundaries

## Tasks

### Task 1: Define RPC types and PiSession skeleton
**Files**: `src/pi/session.rs`, `src/pi/mod.rs`
- `PiRpcRequest` enum: `Prompt { message }`, `Abort`, `GetState`
- `PiRpcEvent` enum: `AgentStart`, `AgentEnd`, `MessageUpdate { text }`,
  `ToolExecutionStart { name }`, `ToolExecutionEnd { name, success }`,
  `TurnStart`, `TurnEnd`, `Unknown`
- `PiSession` struct: `child: Option<Child>`, `stdin: BufWriter<ChildStdin>`,
  `event_rx: mpsc::Receiver<PiRpcEvent>`
- Add `pub mod session;` to `src/pi/mod.rs`
- Serde derives for all types

### Task 2: Implement PiSession::spawn()
**Files**: `src/pi/session.rs`
- `PiSession::spawn(pi_path, provider, model)` → `Result<Self>`
- Spawns `pi --mode rpc --no-session --provider <p> --model <m>`
- Captures stdin (write) and stdout (read) handles
- Spawns background thread reading stdout lines → mpsc channel as `PiRpcEvent`
- Parse each JSON line into the appropriate event type
- Handle process startup errors

### Task 3: Implement send/receive
**Files**: `src/pi/session.rs`
- `PiSession::send_prompt(message)` → `Result<()>`
- `PiSession::abort()` → `Result<()>`
- `PiSession::next_event()` → `Option<PiRpcEvent>` (non-blocking)
- `PiSession::recv_event()` → `Result<PiRpcEvent>` (blocking)
- Write JSON line to stdin for requests
- Read events from mpsc channel

### Task 4: Implement run_task() high-level orchestrator
**Files**: `src/pi/session.rs`
- `PiSession::run_task(prompt, event_callback)` → `Result<String>`
- Sends prompt, collects events until `agent_end`
- Calls callback for each event (for progress reporting)
- Returns final accumulated text
- Handles abort and errors
- Auto-spawns session if not already running

### Task 5: Create pi_delegate agent tool
**Files**: `src/pi/tool.rs`, `src/pi/mod.rs`
- `PiDelegateTool` implementing `saorsa_agent::Tool`
  - Name: `pi_delegate`
  - Description: "Delegate a coding task to Pi..."
  - Input schema: `{ "task": "string", "working_directory": "string (optional)" }`
- Executes via `PiSession::run_task()`
- Returns result text as tool output
- Add `pub mod tool;` to `src/pi/mod.rs`

### Task 6: Register pi_delegate tool in agent
**Files**: `src/agent/mod.rs`
- Register `PiDelegateTool` when Pi is available
- Pass `PiManager` / `PiSession` state to the tool
- Use `Arc<Mutex<PiSession>>` for shared access
- Only register when `config.tool_mode` includes tools

### Task 7: Create Pi skill file
**Files**: `src/skills/pi.md` (embedded resource)
- Tells Fae when to delegate to Pi
- Patterns: coding tasks, file editing, research, config changes
- Examples of good delegation vs doing it herself

### Task 8: Integration tests
**Files**: `tests/pi_session.rs`
- RPC type serialization round-trips
- Event parsing from JSON lines
- PiSession construction (without actual Pi process)
- Tool schema validation
