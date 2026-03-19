# Phase 5.4: Pi RPC Session & Coding Skill

## Overview
PiSession manages a Pi subprocess communicating via JSON-RPC over stdin/stdout.
A new Pi skill tells Fae when and how to delegate tasks to Pi. The agent gets
a `pi_delegate` tool that invokes Pi for coding, file management, and automation.

## Tasks

### Task 1: Create `src/pi/session.rs` — PiSession struct
**Files:** `src/pi/session.rs` (new)

Pi RPC session manager:
```rust
pub struct PiSession {
    process: tokio::process::Child,
    stdin: tokio::process::ChildStdin,
    stdout: BufReader<tokio::process::ChildStdout>,
    request_id: u64,
}
```
- `PiSession::start(pi_path: &Path) -> Result<Self>` spawns `pi --mode rpc --no-session`
- Sets working directory to user's home or configured project dir
- Captures stdin/stdout for JSON communication

### Task 2: Implement RPC protocol — send/receive
**Files:** `src/pi/session.rs`

JSON-RPC over stdin/stdout:
- `send_request(method: &str, params: Value) -> Result<u64>` writes JSON line to stdin
- `read_event() -> Result<PiEvent>` reads one JSON line from stdout
- `PiEvent` enum: `Result { id, content }`, `Progress { text }`, `ToolCall { name, input }`, `Error { message }`
- Handle streaming: Pi sends multiple events per request (progress, tool calls, final result)

### Task 3: Implement `prompt()` — high-level task delegation
**Files:** `src/pi/session.rs`

Send a coding task to Pi and collect results:
- `prompt(task: &str, on_event: impl Fn(PiEvent)) -> Result<String>`
- Sends the task as a prompt request
- Reads events in a loop, calling on_event for each
- Returns final result text
- Timeout handling (configurable, default 5 minutes)

### Task 4: Create `Skills/pi.md` — Pi coding skill
**Files:** `Skills/pi.md` (new)

Behavioral guide for Fae (40-60 lines, goes into system prompt):
- When to delegate to Pi: coding tasks, file editing, config changes, running commands, research with web search
- When NOT to use Pi: simple questions, conversation, things Fae can answer from knowledge
- How to formulate requests: be specific, include file paths if known, describe desired outcome
- Pi can: read/write/edit files, run bash commands, search with grep/find
- Pi uses Fae's local LLM — no cloud API needed for coding
- Progress: Fae narrates Pi's progress to the user via speech
- Error handling: if Pi fails, Fae explains what went wrong

### Task 5: Register Pi skill in `src/skills.rs`
**Files:** `src/skills.rs`

- Add `pub const PI_SKILL: &str = include_str!("../Skills/pi.md");`
- Update `list_skills()` to include `"pi"` in builtins
- Update `load_all_skills()` to include PI_SKILL
- Pi skill only loaded if Pi is installed (check PiManager state)

### Task 6: Create `src/pi/tool.rs` — pi_delegate agent tool
**Files:** `src/pi/tool.rs` (new)

Implement `saorsa_agent::Tool` for Pi delegation:
- Tool name: `pi_delegate`
- Description: "Delegate a coding or file management task to Pi"
- Input: `{ "task": "string describing what to do", "working_dir": "optional path" }`
- Execution: ensure_pi() → start PiSession → prompt(task) → collect result
- Stream Pi's progress events to Fae's RuntimeEvent channel for TTS narration
- Return Pi's final result as tool output

### Task 7: Register pi_delegate tool in agent
**Files:** `src/agent/mod.rs`

- Register `PiDelegateTool` when tool_mode is ReadWrite and Pi is available
- Pass PiManager (Arc) so tool can find/start Pi
- Pi tool gets approval wrapper (user confirms before Pi starts coding)
- Pass runtime_tx for progress narration

### Task 8: Tests
**Files:** `src/pi/session.rs`, `src/pi/tool.rs`, `src/skills.rs`

- PiSession starts subprocess (mock Pi binary for tests)
- JSON-RPC send/receive roundtrip
- prompt() handles timeout
- Pi skill is non-empty and mentions pi_delegate
- pi_delegate tool produces valid output schema
- Skills list includes "pi" when Pi is available

**Acceptance:**
- PiSession communicates with Pi via JSON-RPC
- Pi skill guides Fae on when to delegate
- pi_delegate tool registered in agent
- Voice command → Pi coding task → result narrated back
- `cargo clippy` zero warnings
