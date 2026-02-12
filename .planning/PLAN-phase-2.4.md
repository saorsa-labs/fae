# Phase 2.4: Anthropic Adapter

## Goal
Implement a native Anthropic Messages API adapter that maps thinking/tool_use blocks to the shared LlmEvent model with streaming support via content block deltas.

## Files
- `src/fae_llm/providers/anthropic.rs` — Anthropic adapter implementation
- `src/fae_llm/providers/mod.rs` — Wire in anthropic module
- `src/fae_llm/mod.rs` — Re-export Anthropic types, add integration tests

## Tasks

### Task 1: AnthropicConfig and request builder
Create `src/fae_llm/providers/anthropic.rs` with:
- `AnthropicConfig` struct: `api_key`, `model`, `api_version` (default "2023-06-01"), `max_tokens` (default 4096)
- `AnthropicConfig::new(api_key, model)` constructor
- Builder methods: `with_api_version()`, `with_max_tokens()`
- `build_messages_request()` — converts `&[Message]` + `RequestOptions` + `&[ToolDefinition]` to Anthropic JSON
  - System message extracted to top-level `system` field
  - User/assistant messages as content blocks
  - Tool definitions mapped to Anthropic `tools` format
  - Tool results mapped to `tool_result` content blocks
- Unit tests for request JSON structure

### Task 2: Message format conversion
Add to `anthropic.rs`:
- `convert_messages()` — transform shared Message types to Anthropic format
  - System messages → extracted to separate field
  - User text → `{"role": "user", "content": [{"type": "text", "text": "..."}]}`
  - Assistant text → `{"role": "assistant", "content": [{"type": "text", "text": "..."}]}`
  - Assistant tool calls → `{"type": "tool_use", "id": "...", "name": "...", "input": {...}}`
  - Tool results → `{"role": "user", "content": [{"type": "tool_result", "tool_use_id": "...", "content": "..."}]}`
- Unit tests for all message conversions

### Task 3: SSE stream event parsing
Add to `anthropic.rs`:
- `parse_anthropic_event()` — parse a single SSE event into LlmEvents
  - `message_start` → StreamStart
  - `content_block_start` with `type: "text"` → (buffer index)
  - `content_block_start` with `type: "thinking"` → ThinkingStart
  - `content_block_start` with `type: "tool_use"` → ToolCallStart
  - `content_block_delta` with `type: "text_delta"` → TextDelta
  - `content_block_delta` with `type: "thinking_delta"` → ThinkingDelta
  - `content_block_delta` with `type: "input_json_delta"` → ToolCallArgsDelta
  - `content_block_stop` → (ThinkingEnd or ToolCallEnd depending on active block)
  - `message_delta` with `stop_reason` → StreamEnd
  - `message_stop` → (ignored, StreamEnd already sent)
- `AnthropicBlockTracker` to track active content block types
- Unit tests for each event type

### Task 4: Finish reason and error mapping
Add to `anthropic.rs`:
- `map_stop_reason()` — convert Anthropic stop reasons to FinishReason
  - `"end_turn"` → Stop
  - `"max_tokens"` → Length
  - `"tool_use"` → ToolCalls
  - `"stop_sequence"` → Stop
  - other → Other
- `map_http_error()` — convert HTTP status codes to FaeLlmError
  - 401/403 → AuthError
  - 429 → RequestError (rate limit)
  - 500+ → ProviderError
  - 400 → RequestError (with body detail)
  - 529 → ProviderError (overloaded)
- Unit tests for all mappings

### Task 5: AnthropicAdapter implementing ProviderAdapter
Add to `anthropic.rs`:
- `AnthropicAdapter` struct wrapping config + reqwest::Client
- `impl ProviderAdapter for AnthropicAdapter`
  - `name()` → "anthropic"
  - `send()` → builds request, sends to `https://api.anthropic.com/v1/messages`, streams SSE response
- Request headers: `x-api-key`, `anthropic-version`, `content-type`, `accept: text/event-stream`
- Stream processing using SseLineParser → parse_anthropic_event → LlmEvent stream
- Error handling for non-2xx responses
- Unit tests for adapter construction and name

### Task 6: Streaming integration
Add to `anthropic.rs`:
- `create_anthropic_stream()` — wraps SSE parsing into `LlmEventStream`
- Full stream lifecycle: message_start → content blocks → message_delta → message_stop
- Handle interleaved thinking + text blocks
- Handle tool_use blocks with partial JSON input streaming
- Handle multiple content blocks in a single message
- Unit tests for multi-block stream parsing

### Task 7: Wire into module tree
- Add `pub mod anthropic;` to `providers/mod.rs`
- Update providers/mod.rs doc comment
- Add re-exports to `fae_llm/mod.rs`: `AnthropicAdapter`, `AnthropicConfig`
- Ensure `cargo check` and `cargo clippy` pass

### Task 8: Integration tests
Add integration tests to `fae_llm/mod.rs`:
- `anthropic_text_stream()` — parse SSE text response
- `anthropic_thinking_stream()` — parse thinking + text response
- `anthropic_tool_call_stream()` — parse tool_use response
- `anthropic_multi_block_stream()` — interleaved content blocks
- `anthropic_stop_reasons()` — all stop reason mappings
- `anthropic_error_mapping()` — HTTP error classification
- `anthropic_request_format()` — verify request JSON structure
- `anthropic_message_conversion()` — tool results and system messages
