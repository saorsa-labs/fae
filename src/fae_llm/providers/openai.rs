//! OpenAI provider adapter.
//!
//! Supports both the Chat Completions API (`/v1/chat/completions`) and
//! the Responses API (`/v1/responses`). Normalizes provider-specific
//! streaming events to the shared [`LlmEvent`](crate::fae_llm::events::LlmEvent) model.
//!
//! # Supported APIs
//!
//! - **Chat Completions**: The standard `/v1/chat/completions` endpoint with
//!   `stream: true`. Returns `data: {...}` SSE events with delta chunks.
//! - **Responses API**: The newer `/v1/responses` endpoint using typed
//!   `event: ...` SSE events.
//!
//! # Examples
//!
//! ```rust,no_run
//! use fae::fae_llm::providers::openai::{OpenAiConfig, OpenAiAdapter, OpenAiApiMode};
//! use fae::fae_llm::provider::ProviderAdapter;
//! use fae::fae_llm::providers::message::Message;
//! use fae::fae_llm::types::RequestOptions;
//!
//! # async fn example() -> Result<(), fae::fae_llm::error::FaeLlmError> {
//! let config = OpenAiConfig::new("sk-...", "gpt-4o");
//! let adapter = OpenAiAdapter::new(config);
//!
//! let messages = vec![Message::user("Hello")];
//! let options = RequestOptions::new();
//! let stream = adapter.send(&messages, &options, &[]).await?;
//! # Ok(())
//! # }
//! ```

use std::collections::HashMap;
use std::pin::Pin;

use async_trait::async_trait;
use bytes::Bytes;
use futures_util::{Stream, StreamExt};
use serde::{Deserialize, Serialize};

use crate::fae_llm::error::FaeLlmError;
use crate::fae_llm::events::{FinishReason, LlmEvent};
use crate::fae_llm::provider::{LlmEventStream, ProviderAdapter, ToolDefinition};
use crate::fae_llm::providers::message::{Message, MessageContent, Role};
use crate::fae_llm::providers::sse::SseLineParser;
use crate::fae_llm::types::{ModelRef, RequestOptions};

// ── Configuration ─────────────────────────────────────────────

/// Which OpenAI API mode to use.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OpenAiApiMode {
    /// Standard Chat Completions API (`/v1/chat/completions`).
    #[default]
    Completions,
    /// Newer Responses API (`/v1/responses`).
    Responses,
}

/// Configuration for the OpenAI adapter.
#[derive(Debug, Clone)]
pub struct OpenAiConfig {
    /// API key for authentication.
    pub api_key: String,
    /// Base URL (defaults to `https://api.openai.com`).
    pub base_url: String,
    /// Optional organization ID.
    pub org_id: Option<String>,
    /// The model to use.
    pub model: String,
    /// Which API mode to use.
    pub api_mode: OpenAiApiMode,
}

impl OpenAiConfig {
    /// Create a new config with the given API key and model.
    pub fn new(api_key: impl Into<String>, model: impl Into<String>) -> Self {
        Self {
            api_key: api_key.into(),
            base_url: "https://api.openai.com".into(),
            org_id: None,
            model: model.into(),
            api_mode: OpenAiApiMode::default(),
        }
    }

    /// Set a custom base URL.
    pub fn with_base_url(mut self, url: impl Into<String>) -> Self {
        self.base_url = url.into();
        self
    }

    /// Set the organization ID.
    pub fn with_org_id(mut self, org_id: impl Into<String>) -> Self {
        self.org_id = Some(org_id.into());
        self
    }

    /// Set the API mode.
    pub fn with_api_mode(mut self, mode: OpenAiApiMode) -> Self {
        self.api_mode = mode;
        self
    }
}

// ── Request Builders ──────────────────────────────────────────

/// Build the JSON request body for the Chat Completions API.
pub fn build_completions_request(
    model: &str,
    messages: &[Message],
    options: &RequestOptions,
    tools: &[ToolDefinition],
) -> serde_json::Value {
    let mut body = serde_json::json!({
        "model": model,
        "messages": messages_to_openai(messages),
        "stream": options.stream,
    });

    let obj = body.as_object_mut();
    if let Some(obj) = obj {
        if let Some(max_tokens) = options.max_tokens {
            obj.insert("max_tokens".into(), serde_json::json!(max_tokens));
        }
        if let Some(temp) = options.temperature {
            obj.insert("temperature".into(), serde_json::json!(temp));
        }
        if let Some(top_p) = options.top_p {
            obj.insert("top_p".into(), serde_json::json!(top_p));
        }
        if options.stream {
            obj.insert(
                "stream_options".into(),
                serde_json::json!({"include_usage": true}),
            );
        }
        if !tools.is_empty() {
            obj.insert("tools".into(), tools_to_openai(tools));
        }
    }

    body
}

/// Build the JSON request body for the Responses API.
pub fn build_responses_request(
    model: &str,
    messages: &[Message],
    options: &RequestOptions,
    tools: &[ToolDefinition],
) -> serde_json::Value {
    let mut body = serde_json::json!({
        "model": model,
        "input": messages_to_responses_input(messages),
        "stream": options.stream,
    });

    let obj = body.as_object_mut();
    if let Some(obj) = obj {
        if let Some(max_tokens) = options.max_tokens {
            obj.insert("max_output_tokens".into(), serde_json::json!(max_tokens));
        }
        if let Some(temp) = options.temperature {
            obj.insert("temperature".into(), serde_json::json!(temp));
        }
        if let Some(top_p) = options.top_p {
            obj.insert("top_p".into(), serde_json::json!(top_p));
        }
        if !tools.is_empty() {
            let tools_json: Vec<serde_json::Value> = tools
                .iter()
                .map(|t| {
                    serde_json::json!({
                        "type": "function",
                        "name": t.name,
                        "description": t.description,
                        "parameters": t.parameters,
                    })
                })
                .collect();
            obj.insert("tools".into(), serde_json::json!(tools_json));
        }
    }

    body
}

/// Convert messages to OpenAI Chat Completions format.
fn messages_to_openai(messages: &[Message]) -> Vec<serde_json::Value> {
    messages.iter().map(message_to_openai).collect()
}

/// Convert a single message to OpenAI format.
fn message_to_openai(msg: &Message) -> serde_json::Value {
    let role = match msg.role {
        Role::System => "system",
        Role::User => "user",
        Role::Assistant => "assistant",
        Role::Tool => "tool",
    };

    match &msg.content {
        MessageContent::Text { text } => {
            let mut obj = serde_json::json!({
                "role": role,
                "content": text,
            });

            // Add tool calls for assistant messages
            if !msg.tool_calls.is_empty() {
                let tc_json: Vec<serde_json::Value> = msg
                    .tool_calls
                    .iter()
                    .map(|tc| {
                        serde_json::json!({
                            "id": tc.call_id,
                            "type": "function",
                            "function": {
                                "name": tc.function_name,
                                "arguments": tc.arguments,
                            }
                        })
                    })
                    .collect();
                if let Some(obj) = obj.as_object_mut() {
                    obj.insert("tool_calls".into(), serde_json::json!(tc_json));
                }
            }

            obj
        }
        MessageContent::ToolResult { call_id, content } => {
            serde_json::json!({
                "role": "tool",
                "tool_call_id": call_id,
                "content": content,
            })
        }
    }
}

/// Convert messages to Responses API input format.
fn messages_to_responses_input(messages: &[Message]) -> Vec<serde_json::Value> {
    messages
        .iter()
        .map(|msg| {
            let role = match msg.role {
                Role::System => "developer",
                Role::User => "user",
                Role::Assistant => "assistant",
                Role::Tool => "tool",
            };

            match &msg.content {
                MessageContent::Text { text } => {
                    serde_json::json!({
                        "type": "message",
                        "role": role,
                        "content": [{ "type": "input_text", "text": text }],
                    })
                }
                MessageContent::ToolResult { call_id, content } => {
                    serde_json::json!({
                        "type": "function_call_output",
                        "call_id": call_id,
                        "output": content,
                    })
                }
            }
        })
        .collect()
}

/// Convert tool definitions to OpenAI tools format.
fn tools_to_openai(tools: &[ToolDefinition]) -> serde_json::Value {
    let tools_json: Vec<serde_json::Value> = tools
        .iter()
        .map(|t| {
            serde_json::json!({
                "type": "function",
                "function": {
                    "name": t.name,
                    "description": t.description,
                    "parameters": t.parameters,
                }
            })
        })
        .collect();
    serde_json::json!(tools_json)
}

// ── Response Parsing (Completions) ────────────────────────────

/// Map OpenAI finish reason string to our FinishReason enum.
fn map_finish_reason(reason: &str) -> FinishReason {
    match reason {
        "stop" => FinishReason::Stop,
        "length" => FinishReason::Length,
        "tool_calls" => FinishReason::ToolCalls,
        "content_filter" => FinishReason::ContentFilter,
        _ => FinishReason::Other,
    }
}

/// Tracks in-flight tool calls during streaming.
///
/// OpenAI streams tool calls as incremental chunks with an index.
/// This accumulator tracks which calls have been started and emits
/// appropriate start/delta/end events.
#[derive(Debug, Default)]
pub struct ToolCallAccumulator {
    /// Map from tool call index to (call_id, function_name, accumulated_args).
    active_calls: HashMap<u64, ToolCallState>,
}

/// State of a single in-flight tool call.
#[derive(Debug, Clone)]
struct ToolCallState {
    call_id: String,
    function_name: String,
    started: bool,
}

impl ToolCallAccumulator {
    /// Create a new accumulator.
    pub fn new() -> Self {
        Self::default()
    }

    /// Process a tool call chunk from a streaming response.
    ///
    /// Returns LLM events to emit (ToolCallStart, ToolCallArgsDelta).
    pub fn process_chunk(
        &mut self,
        index: u64,
        id: Option<&str>,
        function_name: Option<&str>,
        args_fragment: Option<&str>,
    ) -> Vec<LlmEvent> {
        let mut events = Vec::new();

        let state = self.active_calls.entry(index).or_insert_with(|| {
            ToolCallState {
                call_id: id.unwrap_or("").to_string(),
                function_name: function_name.unwrap_or("").to_string(),
                started: false,
            }
        });

        // Update call_id and function_name if provided
        if let Some(id_val) = id
            && !id_val.is_empty()
        {
            state.call_id = id_val.to_string();
        }
        if let Some(name) = function_name
            && !name.is_empty()
        {
            state.function_name = name.to_string();
        }

        // Emit ToolCallStart on first encounter
        if !state.started {
            state.started = true;
            events.push(LlmEvent::ToolCallStart {
                call_id: state.call_id.clone(),
                function_name: state.function_name.clone(),
            });
        }

        // Emit args delta if provided
        if let Some(args) = args_fragment
            && !args.is_empty()
        {
            events.push(LlmEvent::ToolCallArgsDelta {
                call_id: state.call_id.clone(),
                args_fragment: args.to_string(),
            });
        }

        events
    }

    /// Emit ToolCallEnd for all active calls and reset.
    ///
    /// Call this when the stream ends or finish_reason is "tool_calls".
    pub fn finish_all(&mut self) -> Vec<LlmEvent> {
        let mut events = Vec::new();
        // Sort by index for deterministic output
        let mut indices: Vec<u64> = self.active_calls.keys().copied().collect();
        indices.sort();

        for idx in indices {
            if let Some(state) = self.active_calls.get(&idx)
                && state.started
            {
                events.push(LlmEvent::ToolCallEnd {
                    call_id: state.call_id.clone(),
                });
            }
        }
        self.active_calls.clear();
        events
    }

    /// Whether there are any active tool calls.
    pub fn has_active_calls(&self) -> bool {
        !self.active_calls.is_empty()
    }
}

/// Parse a single SSE data payload from the Chat Completions API.
///
/// Returns a list of [`LlmEvent`]s extracted from the chunk.
/// The `accumulator` tracks in-flight tool calls across chunks.
pub fn parse_completions_chunk(
    data: &str,
    accumulator: &mut ToolCallAccumulator,
) -> Vec<LlmEvent> {
    let parsed: serde_json::Value = match serde_json::from_str(data) {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };

    let mut events = Vec::new();

    // Extract choices[0].delta
    if let Some(choices) = parsed.get("choices").and_then(|c| c.as_array()) {
        for choice in choices {
            let delta = match choice.get("delta") {
                Some(d) => d,
                None => continue,
            };

            // Text content
            if let Some(content) = delta.get("content").and_then(|c| c.as_str())
                && !content.is_empty()
            {
                events.push(LlmEvent::TextDelta {
                    text: content.to_string(),
                });
            }

            // Tool calls
            if let Some(tool_calls) = delta.get("tool_calls").and_then(|tc| tc.as_array()) {
                for tc in tool_calls {
                    let index = tc.get("index").and_then(|i| i.as_u64()).unwrap_or(0);
                    let id = tc.get("id").and_then(|i| i.as_str());
                    let function = tc.get("function");
                    let function_name =
                        function.and_then(|f| f.get("name")).and_then(|n| n.as_str());
                    let args = function
                        .and_then(|f| f.get("arguments"))
                        .and_then(|a| a.as_str());

                    let tc_events =
                        accumulator.process_chunk(index, id, function_name, args);
                    events.extend(tc_events);
                }
            }

            // Finish reason
            if let Some(finish_reason) = choice.get("finish_reason").and_then(|f| f.as_str()) {
                // End any active tool calls first
                if finish_reason == "tool_calls" {
                    events.extend(accumulator.finish_all());
                }
                events.push(LlmEvent::StreamEnd {
                    finish_reason: map_finish_reason(finish_reason),
                });
            }
        }
    }

    events
}

// ── Response Parsing (Responses API) ──────────────────────────

/// Parse an SSE event from the Responses API.
///
/// The Responses API uses typed `event:` fields instead of just `data:`.
pub fn parse_responses_event(
    event_type: &str,
    data: &str,
    accumulator: &mut ToolCallAccumulator,
) -> Vec<LlmEvent> {
    let parsed: serde_json::Value = match serde_json::from_str(data) {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };

    let mut events = Vec::new();

    match event_type {
        "response.output_text.delta" => {
            if let Some(delta) = parsed.get("delta").and_then(|d| d.as_str())
                && !delta.is_empty()
            {
                events.push(LlmEvent::TextDelta {
                    text: delta.to_string(),
                });
            }
        }
        "response.function_call_arguments.delta" => {
            if let Some(delta) = parsed.get("delta").and_then(|d| d.as_str()) {
                let call_id = parsed
                    .get("item_id")
                    .and_then(|i| i.as_str())
                    .unwrap_or("unknown");
                let name = parsed
                    .get("name")
                    .and_then(|n| n.as_str());
                let index = parsed.get("output_index").and_then(|i| i.as_u64()).unwrap_or(0);

                let tc_events = accumulator.process_chunk(
                    index,
                    Some(call_id),
                    name,
                    Some(delta),
                );
                events.extend(tc_events);
            }
        }
        "response.function_call_arguments.done" => {
            // Tool call arguments complete for this function
            let call_id = parsed
                .get("item_id")
                .and_then(|i| i.as_str())
                .unwrap_or("unknown");

            events.push(LlmEvent::ToolCallEnd {
                call_id: call_id.to_string(),
            });
        }
        "response.output_item.added" => {
            // Check if this is a function_call item
            if let Some(item) = parsed.get("item")
                && item.get("type").and_then(|t| t.as_str()) == Some("function_call")
            {
                let call_id = item
                    .get("call_id")
                    .or_else(|| item.get("id"))
                    .and_then(|i| i.as_str())
                    .unwrap_or("unknown");
                let name = item
                    .get("name")
                    .and_then(|n| n.as_str())
                    .unwrap_or("unknown");

                events.push(LlmEvent::ToolCallStart {
                    call_id: call_id.to_string(),
                    function_name: name.to_string(),
                });
            }
        }
        "response.completed" => {
            // Finish any active tool calls
            events.extend(accumulator.finish_all());

            let finish = parsed
                .get("response")
                .and_then(|r| r.get("status"))
                .and_then(|s| s.as_str())
                .unwrap_or("completed");

            let reason = match finish {
                "completed" => FinishReason::Stop,
                "incomplete" => FinishReason::Length,
                "cancelled" => FinishReason::Cancelled,
                _ => FinishReason::Other,
            };

            events.push(LlmEvent::StreamEnd {
                finish_reason: reason,
            });
        }
        // Ignore other event types
        _ => {}
    }

    events
}

// ── Adapter Implementation ────────────────────────────────────

/// OpenAI provider adapter.
///
/// Supports both Chat Completions and Responses API modes.
pub struct OpenAiAdapter {
    config: OpenAiConfig,
    client: reqwest::Client,
}

impl std::fmt::Debug for OpenAiAdapter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OpenAiAdapter")
            .field("model", &self.config.model)
            .field("base_url", &self.config.base_url)
            .field("api_mode", &self.config.api_mode)
            .finish()
    }
}

impl OpenAiAdapter {
    /// Create a new OpenAI adapter with the given configuration.
    pub fn new(config: OpenAiConfig) -> Self {
        let client = reqwest::Client::new();
        Self { config, client }
    }

    /// Build the HTTP request for the configured API mode.
    fn build_request(
        &self,
        messages: &[Message],
        options: &RequestOptions,
        tools: &[ToolDefinition],
    ) -> (String, serde_json::Value) {
        match self.config.api_mode {
            OpenAiApiMode::Completions => {
                let url = format!("{}/v1/chat/completions", self.config.base_url);
                let body =
                    build_completions_request(&self.config.model, messages, options, tools);
                (url, body)
            }
            OpenAiApiMode::Responses => {
                let url = format!("{}/v1/responses", self.config.base_url);
                let body =
                    build_responses_request(&self.config.model, messages, options, tools);
                (url, body)
            }
        }
    }

    /// Map an HTTP error status to the appropriate FaeLlmError.
    fn map_http_error(status: reqwest::StatusCode, body: &str) -> FaeLlmError {
        let message = extract_error_message(body);
        match status.as_u16() {
            401 => FaeLlmError::AuthError(format!("OpenAI authentication failed: {message}")),
            429 => FaeLlmError::RequestError(format!("OpenAI rate limited: {message}")),
            _ => FaeLlmError::ProviderError(format!(
                "OpenAI HTTP {}: {message}",
                status.as_u16()
            )),
        }
    }
}

/// Extract an error message from an OpenAI error response body.
fn extract_error_message(body: &str) -> String {
    serde_json::from_str::<serde_json::Value>(body)
        .ok()
        .and_then(|v| {
            v.get("error")
                .and_then(|e| e.get("message"))
                .and_then(|m| m.as_str())
                .map(String::from)
        })
        .unwrap_or_else(|| body.to_string())
}

#[async_trait]
impl ProviderAdapter for OpenAiAdapter {
    fn name(&self) -> &str {
        "openai"
    }

    async fn send(
        &self,
        messages: &[Message],
        options: &RequestOptions,
        tools: &[ToolDefinition],
    ) -> Result<LlmEventStream, FaeLlmError> {
        let (url, body) = self.build_request(messages, options, tools);
        let model = self.config.model.clone();
        let api_mode = self.config.api_mode;

        let mut request = self
            .client
            .post(&url)
            .header("Authorization", format!("Bearer {}", self.config.api_key))
            .header("Content-Type", "application/json");

        if let Some(org_id) = &self.config.org_id {
            request = request.header("OpenAI-Organization", org_id);
        }

        let response = request.json(&body).send().await.map_err(|e| {
            FaeLlmError::RequestError(format!("OpenAI request failed: {e}"))
        })?;

        let status = response.status();
        if !status.is_success() {
            let body_text = response.text().await.unwrap_or_default();
            return Err(Self::map_http_error(status, &body_text));
        }

        // Create a request ID
        let request_id = response
            .headers()
            .get("x-request-id")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("openai-req")
            .to_string();

        let byte_stream = response.bytes_stream();

        let event_stream = create_event_stream(
            byte_stream,
            request_id,
            model,
            api_mode,
        );

        Ok(Box::pin(event_stream))
    }
}

/// Create an LlmEvent stream from a byte stream.
fn create_event_stream(
    byte_stream: impl Stream<Item = Result<Bytes, reqwest::Error>> + Send + 'static,
    request_id: String,
    model: String,
    api_mode: OpenAiApiMode,
) -> impl Stream<Item = LlmEvent> + Send {
    futures_util::stream::unfold(
        StreamState {
            byte_stream: Box::pin(byte_stream),
            sse_parser: SseLineParser::new(),
            accumulator: ToolCallAccumulator::new(),
            request_id,
            model,
            api_mode,
            started: false,
            event_buffer: Vec::new(),
        },
        |mut state| async move {
            loop {
                // Drain buffered events first
                if let Some(event) = state.event_buffer.pop() {
                    return Some((event, state));
                }

                // Emit StreamStart once
                if !state.started {
                    state.started = true;
                    let start = LlmEvent::StreamStart {
                        request_id: state.request_id.clone(),
                        model: ModelRef::new(&state.model),
                    };
                    return Some((start, state));
                }

                // Read next chunk from byte stream
                match state.byte_stream.next().await {
                    Some(Ok(chunk)) => {
                        let sse_events = state.sse_parser.push(&chunk);
                        for sse_event in sse_events {
                            if sse_event.is_done() {
                                continue;
                            }

                            let llm_events = match state.api_mode {
                                OpenAiApiMode::Completions => {
                                    parse_completions_chunk(
                                        &sse_event.data,
                                        &mut state.accumulator,
                                    )
                                }
                                OpenAiApiMode::Responses => {
                                    let event_type =
                                        sse_event.event_type.as_deref().unwrap_or("");
                                    parse_responses_event(
                                        event_type,
                                        &sse_event.data,
                                        &mut state.accumulator,
                                    )
                                }
                            };

                            // Buffer events in reverse so pop gives correct order
                            for evt in llm_events.into_iter().rev() {
                                state.event_buffer.push(evt);
                            }
                        }
                    }
                    Some(Err(e)) => {
                        let err = LlmEvent::StreamError {
                            error: format!("Stream read error: {e}"),
                        };
                        return Some((err, state));
                    }
                    None => {
                        // Stream ended -- flush any remaining SSE data
                        if let Some(sse_event) = state.sse_parser.flush()
                            && !sse_event.is_done()
                        {
                            let llm_events = match state.api_mode {
                                OpenAiApiMode::Completions => {
                                    parse_completions_chunk(
                                        &sse_event.data,
                                        &mut state.accumulator,
                                    )
                                }
                                OpenAiApiMode::Responses => {
                                    let event_type =
                                        sse_event.event_type.as_deref().unwrap_or("");
                                    parse_responses_event(
                                        event_type,
                                        &sse_event.data,
                                        &mut state.accumulator,
                                    )
                                }
                            };
                            for evt in llm_events.into_iter().rev() {
                                state.event_buffer.push(evt);
                            }
                            continue;
                        }
                        return None;
                    }
                }
            }
        },
    )
}

/// Internal state for the event stream.
struct StreamState {
    byte_stream: Pin<Box<dyn Stream<Item = Result<Bytes, reqwest::Error>> + Send>>,
    sse_parser: SseLineParser,
    accumulator: ToolCallAccumulator,
    request_id: String,
    model: String,
    api_mode: OpenAiApiMode,
    started: bool,
    event_buffer: Vec<LlmEvent>,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fae_llm::providers::message::AssistantToolCall;

    // ── OpenAiConfig ──────────────────────────────────────────

    #[test]
    fn config_new() {
        let config = OpenAiConfig::new("sk-test", "gpt-4o");
        assert_eq!(config.api_key, "sk-test");
        assert_eq!(config.model, "gpt-4o");
        assert_eq!(config.base_url, "https://api.openai.com");
        assert!(config.org_id.is_none());
        assert_eq!(config.api_mode, OpenAiApiMode::Completions);
    }

    #[test]
    fn config_with_base_url() {
        let config = OpenAiConfig::new("key", "model")
            .with_base_url("https://custom.api.com");
        assert_eq!(config.base_url, "https://custom.api.com");
    }

    #[test]
    fn config_with_org_id() {
        let config = OpenAiConfig::new("key", "model")
            .with_org_id("org-123");
        assert_eq!(config.org_id.as_deref(), Some("org-123"));
    }

    #[test]
    fn config_with_api_mode() {
        let config = OpenAiConfig::new("key", "model")
            .with_api_mode(OpenAiApiMode::Responses);
        assert_eq!(config.api_mode, OpenAiApiMode::Responses);
    }

    // ── Request Builders ──────────────────────────────────────

    #[test]
    fn completions_request_basic() {
        let messages = vec![Message::user("Hello")];
        let options = RequestOptions::new().with_stream(true);
        let body = build_completions_request("gpt-4o", &messages, &options, &[]);

        assert_eq!(body["model"], "gpt-4o");
        assert_eq!(body["stream"], true);
        assert!(body["messages"].is_array());

        let msgs = body["messages"].as_array();
        assert!(msgs.is_some_and(|m| m.len() == 1));
    }

    #[test]
    fn completions_request_with_options() {
        let options = RequestOptions::new()
            .with_max_tokens(4096)
            .with_temperature(0.3)
            .with_top_p(0.95);
        let body = build_completions_request("gpt-4o", &[], &options, &[]);

        assert_eq!(body["max_tokens"], 4096);
        assert_eq!(body["temperature"], 0.3);
        assert_eq!(body["top_p"], 0.95);
    }

    #[test]
    fn completions_request_with_tools() {
        let tools = vec![ToolDefinition::new(
            "read",
            "Read a file",
            serde_json::json!({
                "type": "object",
                "properties": { "path": { "type": "string" } }
            }),
        )];
        let options = RequestOptions::new();
        let body = build_completions_request("gpt-4o", &[], &options, &tools);

        assert!(body["tools"].is_array());
        let tools_arr = body["tools"].as_array();
        assert!(tools_arr.is_some_and(|t| t.len() == 1));
        assert_eq!(tools_arr.and_then(|t| t[0].get("type")).and_then(|t| t.as_str()), Some("function"));
    }

    #[test]
    fn completions_request_stream_options() {
        let options = RequestOptions::new().with_stream(true);
        let body = build_completions_request("gpt-4o", &[], &options, &[]);
        assert_eq!(body["stream_options"]["include_usage"], true);
    }

    #[test]
    fn completions_request_messages_format() {
        let messages = vec![
            Message::system("You are helpful."),
            Message::user("Hello"),
            Message::assistant("Hi there!"),
            Message::tool_result("call_1", "file contents"),
        ];
        let options = RequestOptions::new();
        let body = build_completions_request("gpt-4o", &messages, &options, &[]);

        let msgs = body["messages"].as_array();
        assert!(msgs.is_some_and(|m| m.len() == 4));
        if let Some(msgs) = msgs {
            assert_eq!(msgs[0]["role"], "system");
            assert_eq!(msgs[1]["role"], "user");
            assert_eq!(msgs[2]["role"], "assistant");
            assert_eq!(msgs[3]["role"], "tool");
            assert_eq!(msgs[3]["tool_call_id"], "call_1");
        }
    }

    #[test]
    fn completions_request_assistant_with_tool_calls() {
        let tool_calls = vec![AssistantToolCall {
            call_id: "call_abc".into(),
            function_name: "bash".into(),
            arguments: r#"{"command":"ls"}"#.into(),
        }];
        let messages = vec![Message::assistant_with_tool_calls(
            Some("Let me check.".into()),
            tool_calls,
        )];
        let options = RequestOptions::new();
        let body = build_completions_request("gpt-4o", &messages, &options, &[]);

        let msg = &body["messages"][0];
        assert_eq!(msg["role"], "assistant");
        assert!(msg["tool_calls"].is_array());
        let tcs = msg["tool_calls"].as_array();
        assert!(tcs.is_some_and(|t| t.len() == 1));
        if let Some(tcs) = tcs {
            assert_eq!(tcs[0]["id"], "call_abc");
            assert_eq!(tcs[0]["function"]["name"], "bash");
        }
    }

    #[test]
    fn responses_request_basic() {
        let messages = vec![Message::user("Hello")];
        let options = RequestOptions::new().with_max_tokens(1024);
        let body = build_responses_request("gpt-4o", &messages, &options, &[]);

        assert_eq!(body["model"], "gpt-4o");
        assert_eq!(body["max_output_tokens"], 1024);
        assert!(body["input"].is_array());
    }

    #[test]
    fn responses_request_system_is_developer() {
        let messages = vec![Message::system("You are helpful.")];
        let options = RequestOptions::new();
        let body = build_responses_request("gpt-4o", &messages, &options, &[]);

        let input = body["input"].as_array();
        assert!(input.is_some_and(|i| !i.is_empty()));
        if let Some(input) = input {
            assert_eq!(input[0]["role"], "developer");
        }
    }

    // ── Finish Reason Mapping ─────────────────────────────────

    #[test]
    fn finish_reason_mapping() {
        assert_eq!(map_finish_reason("stop"), FinishReason::Stop);
        assert_eq!(map_finish_reason("length"), FinishReason::Length);
        assert_eq!(map_finish_reason("tool_calls"), FinishReason::ToolCalls);
        assert_eq!(
            map_finish_reason("content_filter"),
            FinishReason::ContentFilter
        );
        assert_eq!(map_finish_reason("unknown"), FinishReason::Other);
    }

    // ── Tool Call Accumulator ─────────────────────────────────

    #[test]
    fn accumulator_single_tool_call() {
        let mut acc = ToolCallAccumulator::new();

        // First chunk: id + function name
        let events = acc.process_chunk(0, Some("call_1"), Some("read"), None);
        assert_eq!(events.len(), 1);
        assert!(matches!(&events[0], LlmEvent::ToolCallStart { call_id, function_name }
            if call_id == "call_1" && function_name == "read"));

        // Second chunk: args
        let events = acc.process_chunk(0, None, None, Some(r#"{"path":"#));
        assert_eq!(events.len(), 1);
        assert!(matches!(&events[0], LlmEvent::ToolCallArgsDelta { call_id, args_fragment }
            if call_id == "call_1" && args_fragment == r#"{"path":"#));

        // Third chunk: more args
        let events = acc.process_chunk(0, None, None, Some(r#""main.rs"}"#));
        assert_eq!(events.len(), 1);

        // Finish
        let events = acc.finish_all();
        assert_eq!(events.len(), 1);
        assert!(matches!(&events[0], LlmEvent::ToolCallEnd { call_id } if call_id == "call_1"));

        assert!(!acc.has_active_calls());
    }

    #[test]
    fn accumulator_parallel_tool_calls() {
        let mut acc = ToolCallAccumulator::new();

        // Start two tool calls
        let events1 = acc.process_chunk(0, Some("call_1"), Some("read"), None);
        assert_eq!(events1.len(), 1);

        let events2 = acc.process_chunk(1, Some("call_2"), Some("write"), None);
        assert_eq!(events2.len(), 1);

        // Args for both
        let _ = acc.process_chunk(0, None, None, Some(r#"{"a":1}"#));
        let _ = acc.process_chunk(1, None, None, Some(r#"{"b":2}"#));

        assert!(acc.has_active_calls());

        // Finish all
        let events = acc.finish_all();
        assert_eq!(events.len(), 2);
        assert!(matches!(&events[0], LlmEvent::ToolCallEnd { call_id } if call_id == "call_1"));
        assert!(matches!(&events[1], LlmEvent::ToolCallEnd { call_id } if call_id == "call_2"));
    }

    #[test]
    fn accumulator_empty_finish() {
        let mut acc = ToolCallAccumulator::new();
        let events = acc.finish_all();
        assert!(events.is_empty());
    }

    #[test]
    fn accumulator_empty_args_no_delta() {
        let mut acc = ToolCallAccumulator::new();
        let events = acc.process_chunk(0, Some("call_1"), Some("read"), Some(""));
        // Should emit ToolCallStart but no ToolCallArgsDelta for empty args
        assert_eq!(events.len(), 1);
        assert!(matches!(&events[0], LlmEvent::ToolCallStart { .. }));
    }

    // ── parse_completions_chunk ───────────────────────────────

    #[test]
    fn parse_text_delta() {
        let data = r#"{"choices":[{"delta":{"content":"Hello"},"index":0}]}"#;
        let mut acc = ToolCallAccumulator::new();
        let events = parse_completions_chunk(data, &mut acc);
        assert_eq!(events.len(), 1);
        assert!(matches!(&events[0], LlmEvent::TextDelta { text } if text == "Hello"));
    }

    #[test]
    fn parse_empty_content_skipped() {
        let data = r#"{"choices":[{"delta":{"content":""},"index":0}]}"#;
        let mut acc = ToolCallAccumulator::new();
        let events = parse_completions_chunk(data, &mut acc);
        assert!(events.is_empty());
    }

    #[test]
    fn parse_finish_reason_stop() {
        let data = r#"{"choices":[{"delta":{},"finish_reason":"stop","index":0}]}"#;
        let mut acc = ToolCallAccumulator::new();
        let events = parse_completions_chunk(data, &mut acc);
        assert_eq!(events.len(), 1);
        assert!(matches!(
            &events[0],
            LlmEvent::StreamEnd { finish_reason: FinishReason::Stop }
        ));
    }

    #[test]
    fn parse_finish_reason_tool_calls() {
        let data = r#"{"choices":[{"delta":{},"finish_reason":"tool_calls","index":0}]}"#;
        let mut acc = ToolCallAccumulator::new();
        // First start a tool call
        acc.process_chunk(0, Some("call_1"), Some("read"), None);

        let events = parse_completions_chunk(data, &mut acc);
        // Should have ToolCallEnd + StreamEnd
        assert_eq!(events.len(), 2);
        assert!(matches!(&events[0], LlmEvent::ToolCallEnd { .. }));
        assert!(matches!(
            &events[1],
            LlmEvent::StreamEnd { finish_reason: FinishReason::ToolCalls }
        ));
    }

    #[test]
    fn parse_tool_call_start() {
        let data = r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc","function":{"name":"bash","arguments":""}}]},"index":0}]}"#;
        let mut acc = ToolCallAccumulator::new();
        let events = parse_completions_chunk(data, &mut acc);
        assert_eq!(events.len(), 1);
        assert!(matches!(&events[0], LlmEvent::ToolCallStart { call_id, function_name }
            if call_id == "call_abc" && function_name == "bash"));
    }

    #[test]
    fn parse_tool_call_args_delta() {
        // First start the call
        let start_data = r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc","function":{"name":"bash","arguments":""}}]},"index":0}]}"#;
        let mut acc = ToolCallAccumulator::new();
        let _ = parse_completions_chunk(start_data, &mut acc);

        // Then stream args
        let args_data = r#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"cmd\":"}}]},"index":0}]}"#;
        let events = parse_completions_chunk(args_data, &mut acc);
        assert_eq!(events.len(), 1);
        assert!(matches!(&events[0], LlmEvent::ToolCallArgsDelta { call_id, args_fragment }
            if call_id == "call_abc" && args_fragment == r#"{"cmd":"#));
    }

    #[test]
    fn parse_invalid_json_returns_empty() {
        let mut acc = ToolCallAccumulator::new();
        let events = parse_completions_chunk("not json", &mut acc);
        assert!(events.is_empty());
    }

    #[test]
    fn parse_empty_choices() {
        let data = r#"{"choices":[]}"#;
        let mut acc = ToolCallAccumulator::new();
        let events = parse_completions_chunk(data, &mut acc);
        assert!(events.is_empty());
    }

    // ── parse_responses_event ─────────────────────────────────

    #[test]
    fn responses_text_delta() {
        let data = r#"{"delta":"Hello"}"#;
        let mut acc = ToolCallAccumulator::new();
        let events = parse_responses_event("response.output_text.delta", data, &mut acc);
        assert_eq!(events.len(), 1);
        assert!(matches!(&events[0], LlmEvent::TextDelta { text } if text == "Hello"));
    }

    #[test]
    fn responses_completed() {
        let data = r#"{"response":{"status":"completed"}}"#;
        let mut acc = ToolCallAccumulator::new();
        let events = parse_responses_event("response.completed", data, &mut acc);
        assert_eq!(events.len(), 1);
        assert!(matches!(
            &events[0],
            LlmEvent::StreamEnd { finish_reason: FinishReason::Stop }
        ));
    }

    #[test]
    fn responses_function_call_added() {
        let data = r#"{"item":{"type":"function_call","call_id":"fc_1","name":"read"}}"#;
        let mut acc = ToolCallAccumulator::new();
        let events = parse_responses_event("response.output_item.added", data, &mut acc);
        assert_eq!(events.len(), 1);
        assert!(matches!(&events[0], LlmEvent::ToolCallStart { call_id, function_name }
            if call_id == "fc_1" && function_name == "read"));
    }

    #[test]
    fn responses_function_args_delta() {
        let data = r#"{"item_id":"fc_1","delta":"{\"path\":","output_index":0}"#;
        let mut acc = ToolCallAccumulator::new();
        let events = parse_responses_event(
            "response.function_call_arguments.delta",
            data,
            &mut acc,
        );
        // Should emit ToolCallStart (first encounter via accumulator) + ToolCallArgsDelta
        assert_eq!(events.len(), 2);
    }

    #[test]
    fn responses_function_args_done() {
        let data = r#"{"item_id":"fc_1"}"#;
        let mut acc = ToolCallAccumulator::new();
        let events = parse_responses_event(
            "response.function_call_arguments.done",
            data,
            &mut acc,
        );
        assert_eq!(events.len(), 1);
        assert!(matches!(&events[0], LlmEvent::ToolCallEnd { call_id } if call_id == "fc_1"));
    }

    #[test]
    fn responses_unknown_event_ignored() {
        let data = r#"{"foo":"bar"}"#;
        let mut acc = ToolCallAccumulator::new();
        let events = parse_responses_event("response.unknown_event", data, &mut acc);
        assert!(events.is_empty());
    }

    #[test]
    fn responses_invalid_json_returns_empty() {
        let mut acc = ToolCallAccumulator::new();
        let events = parse_responses_event("response.output_text.delta", "not json", &mut acc);
        assert!(events.is_empty());
    }

    // ── Error Extraction ──────────────────────────────────────

    #[test]
    fn extract_error_from_json() {
        let body = r#"{"error":{"message":"Invalid API key","type":"authentication_error"}}"#;
        let msg = extract_error_message(body);
        assert_eq!(msg, "Invalid API key");
    }

    #[test]
    fn extract_error_fallback_to_body() {
        let body = "Something went wrong";
        let msg = extract_error_message(body);
        assert_eq!(msg, "Something went wrong");
    }

    // ── OpenAiAdapter ─────────────────────────────────────────

    #[test]
    fn adapter_name() {
        let config = OpenAiConfig::new("key", "model");
        let adapter = OpenAiAdapter::new(config);
        assert_eq!(adapter.name(), "openai");
    }

    #[test]
    fn adapter_debug() {
        let config = OpenAiConfig::new("sk-secret", "gpt-4o");
        let adapter = OpenAiAdapter::new(config);
        let debug = format!("{adapter:?}");
        assert!(debug.contains("gpt-4o"));
        // API key should NOT be in debug output
        assert!(!debug.contains("sk-secret"));
    }

    #[test]
    fn adapter_build_request_completions() {
        let config = OpenAiConfig::new("key", "gpt-4o");
        let adapter = OpenAiAdapter::new(config);
        let (url, body) = adapter.build_request(&[], &RequestOptions::new(), &[]);
        assert!(url.ends_with("/v1/chat/completions"));
        assert_eq!(body["model"], "gpt-4o");
    }

    #[test]
    fn adapter_build_request_responses() {
        let config = OpenAiConfig::new("key", "gpt-4o")
            .with_api_mode(OpenAiApiMode::Responses);
        let adapter = OpenAiAdapter::new(config);
        let (url, body) = adapter.build_request(&[], &RequestOptions::new(), &[]);
        assert!(url.ends_with("/v1/responses"));
        assert_eq!(body["model"], "gpt-4o");
    }

    // ── Full SSE Stream Simulation ────────────────────────────

    #[test]
    fn full_completions_stream_text_only() {
        let sse_data = concat!(
            "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\"},\"index\":0}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"},\"index\":0}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\" world\"},\"index\":0}]}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\",\"index\":0}]}\n\n",
            "data: [DONE]\n\n",
        );

        let sse_events = super::super::sse::parse_sse_text(sse_data);
        let mut acc = ToolCallAccumulator::new();
        let mut all_events = Vec::new();

        for sse in &sse_events {
            if sse.is_done() {
                continue;
            }
            let events = parse_completions_chunk(&sse.data, &mut acc);
            all_events.extend(events);
        }

        // Collect text
        let text: String = all_events
            .iter()
            .filter_map(|e| match e {
                LlmEvent::TextDelta { text } => Some(text.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(text, "Hello world");

        // Verify finish
        let last = all_events.last();
        assert!(last.is_some_and(|e| matches!(e, LlmEvent::StreamEnd { finish_reason: FinishReason::Stop })));
    }

    #[test]
    fn full_completions_stream_with_tool_call() {
        let sse_data = concat!(
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"\"}}]},\"index\":0}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"path\\\"\"}}]},\"index\":0}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\":\\\"main.rs\\\"}\"}}]},\"index\":0}]}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\",\"index\":0}]}\n\n",
            "data: [DONE]\n\n",
        );

        let sse_events = super::super::sse::parse_sse_text(sse_data);
        let mut acc = ToolCallAccumulator::new();
        let mut all_events = Vec::new();

        for sse in &sse_events {
            if sse.is_done() {
                continue;
            }
            let events = parse_completions_chunk(&sse.data, &mut acc);
            all_events.extend(events);
        }

        // Should have: ToolCallStart, ArgsDelta, ArgsDelta, ToolCallEnd, StreamEnd
        assert!(all_events.iter().any(|e| matches!(e, LlmEvent::ToolCallStart { function_name, .. } if function_name == "read")));
        assert!(all_events.iter().any(|e| matches!(e, LlmEvent::ToolCallEnd { .. })));
        assert!(all_events.last().is_some_and(|e| matches!(e, LlmEvent::StreamEnd { finish_reason: FinishReason::ToolCalls })));

        // Collect args
        let args: String = all_events
            .iter()
            .filter_map(|e| match e {
                LlmEvent::ToolCallArgsDelta { args_fragment, .. } => Some(args_fragment.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(args, r#"{"path":"main.rs"}"#);
    }

    #[test]
    fn http_error_401_maps_to_auth_error() {
        let err = OpenAiAdapter::map_http_error(
            reqwest::StatusCode::UNAUTHORIZED,
            r#"{"error":{"message":"Invalid API key"}}"#,
        );
        assert!(matches!(err, FaeLlmError::AuthError(_)));
        assert!(err.message().contains("Invalid API key"));
    }

    #[test]
    fn http_error_429_maps_to_request_error() {
        let err = OpenAiAdapter::map_http_error(
            reqwest::StatusCode::TOO_MANY_REQUESTS,
            r#"{"error":{"message":"Rate limit exceeded"}}"#,
        );
        assert!(matches!(err, FaeLlmError::RequestError(_)));
    }

    #[test]
    fn http_error_500_maps_to_provider_error() {
        let err = OpenAiAdapter::map_http_error(
            reqwest::StatusCode::INTERNAL_SERVER_ERROR,
            "Internal Server Error",
        );
        assert!(matches!(err, FaeLlmError::ProviderError(_)));
    }

    // ── OpenAiApiMode ─────────────────────────────────────────

    #[test]
    fn api_mode_default_is_completions() {
        assert_eq!(OpenAiApiMode::default(), OpenAiApiMode::Completions);
    }

    #[test]
    fn api_mode_serde_round_trip() {
        for mode in &[OpenAiApiMode::Completions, OpenAiApiMode::Responses] {
            let json = serde_json::to_string(mode).unwrap_or_default();
            let parsed: Result<OpenAiApiMode, _> = serde_json::from_str(&json);
            assert!(parsed.is_ok());
            match parsed {
                Ok(m) => assert_eq!(m, *mode),
                Err(_) => unreachable!("deserialization succeeded"),
            }
        }
    }
}
