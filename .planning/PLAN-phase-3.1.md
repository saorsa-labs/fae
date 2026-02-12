# Phase 3.1: Agent Loop Engine

## Goal
Implement the agentic loop: prompt -> stream -> tool calls -> execute -> continue.
Max turn count, max tool calls per turn guards. Request and tool timeouts.
Abort/cancellation propagation. Tool argument validation against schemas.

## Architecture

```
AgentLoop
  ├── AgentConfig (max_turns, max_tool_calls_per_turn, timeouts)
  ├── Conversation (Vec<Message>, system prompt)
  ├── ProviderAdapter (dyn ProviderAdapter)
  ├── ToolRegistry (registered tools)
  └── CancellationToken (tokio_util::sync::CancellationToken)

Loop:
  1. Send messages to provider (with timeout)
  2. Consume stream, accumulate text + tool calls
  3. If finish_reason == ToolCalls:
     a. Validate tool args against schema
     b. Execute tools (with per-tool timeout)
     c. Append tool results to conversation
     d. Continue loop (check turn/tool limits)
  4. If finish_reason == Stop/Length/Other:
     a. Return final response
  5. If cancelled or limits exceeded:
     a. Return with appropriate status
```

## Tasks

### Task 1: AgentConfig and AgentLoopResult types

**Files:** `src/fae_llm/agent/types.rs`, `src/fae_llm/agent/mod.rs`, `src/fae_llm/mod.rs`

Define the configuration and result types for the agent loop:

- `AgentConfig`: max_turns (u32), max_tool_calls_per_turn (u32), request_timeout_secs (u64), tool_timeout_secs (u64), system_prompt (Option<String>)
- `TurnResult`: struct with text (String), tool_calls (Vec<ExecutedToolCall>), finish_reason (FinishReason), usage (Option<TokenUsage>)
- `ExecutedToolCall`: struct with call_id, function_name, arguments (serde_json::Value), result (ToolResult), duration_ms (u64)
- `AgentLoopResult`: struct with turns (Vec<TurnResult>), final_text (String), total_usage (TokenUsage), stop_reason (StopReason)
- `StopReason` enum: Complete, MaxTurns, MaxToolCalls, Cancelled, Error(String)
- Builder pattern for AgentConfig with sensible defaults
- All types: Debug, Clone, Send, Sync where applicable
- Comprehensive tests for construction, defaults, serde

### Task 2: StreamAccumulator — collect events into structured turn data

**Files:** `src/fae_llm/agent/accumulator.rs`

Build a `StreamAccumulator` that processes LlmEvent streams into structured data:

- Consumes `LlmEvent` one by one
- Accumulates text_delta into full text
- Accumulates tool_call_start/args_delta/end into complete tool calls
- Tracks thinking text separately
- Handles parallel tool calls (multiple call_ids in same stream)
- Returns `AccumulatedTurn`: text, thinking, tool_calls (Vec<AccumulatedToolCall>), finish_reason
- `AccumulatedToolCall`: call_id, function_name, arguments_json (String)
- Handles StreamError events
- Tests: text-only stream, tool-call stream, parallel tools, thinking+text, error handling, empty stream

### Task 3: Tool argument validation against JSON schemas

**Files:** `src/fae_llm/agent/validation.rs`

Implement tool argument validation:

- `validate_tool_args(tool_name: &str, args_json: &str, schema: &serde_json::Value) -> Result<serde_json::Value, FaeLlmError>`
- Parse JSON string to Value (handle parse errors gracefully)
- Validate required fields are present
- Validate field types match schema (string, number, integer, boolean, object, array)
- Return parsed Value on success, descriptive ToolError on failure
- Handle missing "required" array gracefully (treat as no required fields)
- Handle missing "properties" gracefully
- Tests: valid args, missing required field, wrong type, invalid JSON, extra fields OK, nested objects, empty schema

### Task 4: Tool executor with timeout and cancellation

**Files:** `src/fae_llm/agent/executor.rs`

Implement tool execution with timeouts and cancellation:

- `ToolExecutor` struct wrapping ToolRegistry + tool_timeout
- `execute_tool(name, args_json, cancel_token) -> Result<ExecutedToolCall, FaeLlmError>`
  - Look up tool in registry
  - Validate args against schema (from Task 3)
  - Execute with tokio::time::timeout
  - Wrap result in ExecutedToolCall with duration_ms
  - Respect cancellation token
- `execute_tools(calls: Vec<AccumulatedToolCall>, cancel_token) -> Vec<Result<ExecutedToolCall, FaeLlmError>>`
  - Execute tool calls sequentially (not parallel in v1 for safety)
  - Stop on cancellation
  - Track per-tool timing
- Tests: successful execution, tool not found, validation failure, timeout, cancellation

### Task 5: AgentLoop core implementation

**Files:** `src/fae_llm/agent/loop_engine.rs`

Implement the main agent loop:

- `AgentLoop` struct: config, provider, tool_registry, cancel_token
- `AgentLoop::new(config, provider, tool_registry) -> Self`
- `AgentLoop::run(user_message: &str) -> Result<AgentLoopResult, FaeLlmError>`
  - Build initial messages (system prompt + user message)
  - Loop: send to provider -> accumulate -> check finish reason
  - If ToolCalls: validate & execute tools, append results, continue
  - If Stop/Length: break with final text
  - Check max_turns guard each iteration
  - Check max_tool_calls_per_turn guard
  - Apply request_timeout to provider.send()
  - Propagate cancellation
  - Accumulate TokenUsage across turns
- `AgentLoop::cancel()` — trigger cancellation
- Build ToolDefinition list from registry for provider
- Tests: mock provider with predetermined responses, multi-turn tool loop, max turns enforcement, cancellation

### Task 6: AgentLoop with conversation continuation

**Files:** `src/fae_llm/agent/loop_engine.rs` (extend)

Extend AgentLoop to support continuing with existing conversation:

- `AgentLoop::run_with_messages(messages: Vec<Message>) -> Result<AgentLoopResult, FaeLlmError>`
  - Same loop but with pre-existing conversation
- `AgentLoop::run_continuation(previous: &AgentLoopResult, user_message: &str) -> Result<AgentLoopResult, FaeLlmError>`
  - Reconstruct messages from previous result + new user message
- Helper: `build_messages_from_result(result: &AgentLoopResult) -> Vec<Message>`
  - Convert turns into proper Message sequence
- Tests: continuation from previous result, multi-turn conversation, tool results preserved in continuation

### Task 7: Module wiring and public API exports

**Files:** `src/fae_llm/agent/mod.rs`, `src/fae_llm/mod.rs`

Wire up the agent module and export public API:

- `src/fae_llm/agent/mod.rs` — declare submodules, re-export key types
- Update `src/fae_llm/mod.rs` — add `pub mod agent;` and key re-exports
- Ensure all public types have doc comments
- Ensure all public APIs have doc examples where practical
- Tests: verify all public types are accessible from `fae::fae_llm::agent::*`

### Task 8: Integration tests — full agent loop scenarios

**Files:** `src/fae_llm/agent/mod.rs` (integration tests section)

Comprehensive integration tests:

- Text-only response (no tools): prompt -> text -> done
- Single tool call: prompt -> tool call -> tool result -> text -> done
- Multi-turn tool loop: prompt -> tool1 -> result1 -> tool2 -> result2 -> text -> done
- Max turns reached: loop exceeds max_turns, returns MaxTurns
- Max tool calls per turn: too many tools in one response
- Request timeout: provider takes too long
- Tool timeout: tool execution takes too long
- Cancellation mid-stream: cancel while streaming
- Cancellation mid-tool: cancel while executing tool
- Invalid tool args: model sends bad JSON, graceful error in result
- Unknown tool name: model calls nonexistent tool
- Empty response from provider
- All agent types are Send + Sync
