# Phase 2.1: OpenAI Adapter

## Overview
Implement the ProviderAdapter trait and the OpenAI adapter that supports both the Chat Completions API and the Responses API. Includes SSE streaming parser, request builder, tool call streaming with partial JSON accumulation, and normalization to the shared LlmEvent model.

## Key Files
- `src/fae_llm/provider.rs` (NEW) -- ProviderAdapter trait definition
- `src/fae_llm/providers/mod.rs` (NEW) -- providers module
- `src/fae_llm/providers/openai.rs` (NEW) -- OpenAI adapter
- `src/fae_llm/providers/sse.rs` (NEW) -- SSE line parser
- `src/fae_llm/providers/message.rs` (NEW) -- Message types (role, content)
- `src/fae_llm/mod.rs` -- wire in new modules

## Dependencies needed
- `reqwest` with `stream` feature for async HTTP + SSE streaming
- `tokio-stream` for StreamExt on byte streams
- `pin-project-lite` (transitive, already available)

---

## Task 1: ProviderAdapter trait and message types
**~120 lines | src/fae_llm/provider.rs, src/fae_llm/providers/message.rs**

Define the core async trait that all providers implement:

```rust
#[async_trait]
pub trait ProviderAdapter: Send + Sync {
    fn name(&self) -> &str;
    async fn send(
        &self,
        messages: &[Message],
        options: &RequestOptions,
        tools: &[ToolDefinition],
    ) -> Result<Pin<Box<dyn Stream<Item = LlmEvent> + Send>>>;
}
```

Also define:
- `Message` struct with `role: Role`, `content: MessageContent`
- `Role` enum: System, User, Assistant, Tool
- `MessageContent` enum: Text(String), ToolResult { call_id, content }
- `ToolDefinition` struct: name, description, parameters (JSON schema)
- Wire `pub mod provider;` and `pub mod providers;` into `fae_llm/mod.rs`

All types must derive Debug, Clone, Serialize, Deserialize where appropriate.
Add unit tests for message construction and serialization.

## Task 2: SSE line parser
**~120 lines | src/fae_llm/providers/sse.rs**

Implement a reusable SSE (Server-Sent Events) parser:
- `SseParser` struct that processes a byte stream line by line
- Handles `data:`, `event:`, `id:`, comment lines (`:` prefix), empty lines as event boundaries
- `SseEvent { event_type: Option<String>, data: String, id: Option<String> }`
- `parse_sse_stream(stream: impl Stream<Item = Result<Bytes>>) -> impl Stream<Item = SseEvent>`
- Handle multi-line `data:` fields (concatenate with newlines)
- Handle `[DONE]` sentinel
- Unit tests: single events, multi-line data, comments, empty lines, DONE sentinel

## Task 3: OpenAI Chat Completions request builder
**~150 lines | src/fae_llm/providers/openai.rs**

Implement the request body builder for OpenAI Chat Completions:
- `OpenAiConfig` struct: api_key, base_url, org_id (optional), model
- `build_completions_request(messages, options, tools) -> serde_json::Value`
- Map Message/Role to OpenAI format: `{ "role": "user", "content": "..." }`
- Map ToolDefinition to OpenAI tools format: `{ "type": "function", "function": { ... } }`
- Map RequestOptions: temperature, max_tokens, top_p, stream: true
- Handle tool results as `{ "role": "tool", "tool_call_id": "...", "content": "..." }`
- Unit tests verifying JSON structure matches OpenAI spec

## Task 4: OpenAI SSE response parser (Completions)
**~150 lines | src/fae_llm/providers/openai.rs**

Parse OpenAI Chat Completions streaming responses into LlmEvent:
- `parse_completions_chunk(data: &str) -> Vec<LlmEvent>`
- Parse `choices[0].delta.content` -> TextDelta
- Parse `choices[0].delta.tool_calls[*]` -> ToolCallStart/ToolCallArgsDelta
- Parse `choices[0].finish_reason` -> StreamEnd with mapped FinishReason
- Handle `usage` field in final chunk -> store for ResponseMeta
- Map OpenAI finish reasons: "stop" -> Stop, "length" -> Length, "tool_calls" -> ToolCalls, "content_filter" -> ContentFilter
- Unit tests with realistic OpenAI SSE payloads (text, tool calls, errors)

## Task 5: Tool call streaming accumulator
**~100 lines | src/fae_llm/providers/openai.rs**

Implement streaming tool call accumulation:
- `ToolCallAccumulator` struct tracking in-flight tool calls
- Each tool call has: index, id, function name, accumulated args
- On first chunk with tool_call index -> emit ToolCallStart
- On subsequent chunks -> emit ToolCallArgsDelta
- On finish_reason "tool_calls" or new call -> emit ToolCallEnd for completed calls
- Handle multiple parallel tool calls (different indices)
- Unit tests: single tool call, parallel tool calls, args split across chunks

## Task 6: OpenAI ProviderAdapter implementation
**~120 lines | src/fae_llm/providers/openai.rs**

Wire everything together in the ProviderAdapter impl:
- `OpenAiAdapter` struct holding `OpenAiConfig` and `reqwest::Client`
- `OpenAiAdapter::new(config: OpenAiConfig) -> Self`
- Implement `send()`: build request, POST to /v1/chat/completions, parse SSE stream
- Map SSE events through `parse_completions_chunk` -> flatten into LlmEvent stream
- Emit StreamStart at beginning, StreamError on HTTP errors
- Set Authorization header, optional Organization header
- Handle non-200 responses: parse error body, emit StreamError
- Integration-style test with mock (deferred to Task 8)

## Task 7: OpenAI Responses API support
**~100 lines | src/fae_llm/providers/openai.rs**

Add support for the OpenAI Responses API (newer streaming format):
- `build_responses_request(messages, options, tools) -> serde_json::Value`
- Responses API uses input items format: `{ "type": "message", "role": "user", "content": [...] }`
- `parse_responses_event(event_type: &str, data: &str) -> Vec<LlmEvent>`
- Map response events: `response.output_item.added`, `response.content_part.delta`, `response.function_call_arguments.delta`, `response.completed`
- `OpenAiApiMode` enum: Completions, Responses -- selectable in config
- Unit tests for Responses API event parsing

## Task 8: Integration tests and module wiring
**~120 lines | src/fae_llm/providers/openai.rs, src/fae_llm/mod.rs**

Full integration tests:
- Test complete SSE stream -> LlmEvent sequence for Chat Completions format
- Test complete SSE stream -> LlmEvent sequence for Responses API format
- Test error handling: HTTP 401 -> AuthError, 429 -> RequestError, 500 -> ProviderError
- Test empty response stream
- Test malformed SSE data (graceful degradation, no panics)
- Wire all public types into `mod.rs` re-exports
- Verify `just check` passes with zero warnings
- Update progress.md

---

## Acceptance Criteria
- [ ] `ProviderAdapter` trait defined with async streaming interface
- [ ] SSE parser correctly handles all SSE edge cases
- [ ] OpenAI Chat Completions request builder produces valid JSON
- [ ] Streaming text deltas normalized to LlmEvent::TextDelta
- [ ] Streaming tool calls normalized to ToolCallStart/ArgsDelta/End
- [ ] Tool call accumulator handles parallel tool calls
- [ ] Responses API events parsed and normalized
- [ ] Error responses mapped to appropriate FaeLlmError variants
- [ ] `just check` passes with zero warnings
- [ ] All new code has doc comments
