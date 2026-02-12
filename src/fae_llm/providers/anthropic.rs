//! Anthropic Messages API adapter.
//!
//! Implements the [`ProviderAdapter`] trait for the Anthropic Messages API,
//! supporting streaming with content block deltas, thinking blocks, and
//! tool use.
//!
//! # Anthropic SSE Event Flow
//!
//! ```text
//! message_start → content_block_start → content_block_delta* → content_block_stop
//!              → ... (more content blocks) ...
//!              → message_delta → message_stop
//! ```
//!
//! # Content Block Types
//!
//! - `text` — regular text output
//! - `thinking` — reasoning/thinking output (extended thinking)
//! - `tool_use` — tool call with streamed JSON input

use async_trait::async_trait;
use futures_util::StreamExt;

use crate::fae_llm::error::FaeLlmError;
use crate::fae_llm::events::{FinishReason, LlmEvent};
use crate::fae_llm::observability::spans::*;
use crate::fae_llm::provider::{LlmEventStream, ProviderAdapter, ToolDefinition};
use crate::fae_llm::providers::message::{Message, MessageContent, Role};
use crate::fae_llm::providers::sse::SseLineParser;
use crate::fae_llm::types::{ModelRef, RequestOptions};

// ── Configuration ──────────────────────────────────────────────

/// Configuration for the Anthropic adapter.
#[derive(Debug, Clone)]
pub struct AnthropicConfig {
    /// Anthropic API key.
    pub api_key: String,
    /// Base URL for the API (defaults to `https://api.anthropic.com`).
    pub base_url: String,
    /// Model identifier (e.g. `"claude-sonnet-4-5-20250929"`).
    pub model: String,
    /// API version header value.
    pub api_version: String,
    /// Default max tokens for requests.
    pub max_tokens: usize,
}

impl AnthropicConfig {
    /// Create a new Anthropic config.
    pub fn new(api_key: impl Into<String>, model: impl Into<String>) -> Self {
        Self {
            api_key: api_key.into(),
            base_url: "https://api.anthropic.com".to_string(),
            model: model.into(),
            api_version: "2023-06-01".to_string(),
            max_tokens: 4096,
        }
    }

    /// Set the base URL (useful for testing with mock servers).
    pub fn with_base_url(mut self, base_url: impl Into<String>) -> Self {
        self.base_url = base_url.into();
        self
    }

    /// Set the API version.
    pub fn with_api_version(mut self, version: impl Into<String>) -> Self {
        self.api_version = version.into();
        self
    }

    /// Set the default max tokens.
    pub fn with_max_tokens(mut self, max_tokens: usize) -> Self {
        self.max_tokens = max_tokens;
        self
    }
}

// ── Request Building ───────────────────────────────────────────

/// Build an Anthropic Messages API request body.
///
/// Converts shared message types to Anthropic format, extracting the
/// system message to the top-level `system` field.
pub fn build_messages_request(
    model: &str,
    messages: &[Message],
    options: &RequestOptions,
    tools: &[ToolDefinition],
) -> serde_json::Value {
    let (system_text, anthropic_messages) = convert_messages(messages);
    let max_tokens = options.max_tokens.unwrap_or(4096);

    let mut body = serde_json::json!({
        "model": model,
        "max_tokens": max_tokens,
        "messages": anthropic_messages,
    });

    if let Some(system) = system_text {
        body["system"] = serde_json::Value::String(system);
    }

    if options.stream {
        body["stream"] = serde_json::Value::Bool(true);
    }

    if let Some(temp) = options.temperature {
        body["temperature"] = serde_json::json!(temp);
    }

    if let Some(top_p) = options.top_p {
        body["top_p"] = serde_json::json!(top_p);
    }

    if !tools.is_empty() {
        let tool_defs: Vec<serde_json::Value> = tools
            .iter()
            .map(|t| {
                serde_json::json!({
                    "name": t.name,
                    "description": t.description,
                    "input_schema": t.parameters,
                })
            })
            .collect();
        body["tools"] = serde_json::Value::Array(tool_defs);
    }

    body
}

/// Convert shared messages to Anthropic format.
///
/// Returns `(system_text, messages)` where the system text is extracted
/// to the top level and the remaining messages are in Anthropic format.
pub fn convert_messages(messages: &[Message]) -> (Option<String>, Vec<serde_json::Value>) {
    let mut system_text: Option<String> = None;
    let mut result: Vec<serde_json::Value> = Vec::new();

    for msg in messages {
        match msg.role {
            Role::System => {
                if let MessageContent::Text { text } = &msg.content {
                    system_text = Some(text.clone());
                }
            }
            Role::User => {
                if let MessageContent::Text { text } = &msg.content {
                    result.push(serde_json::json!({
                        "role": "user",
                        "content": [{"type": "text", "text": text}],
                    }));
                }
            }
            Role::Assistant => {
                let mut content_blocks: Vec<serde_json::Value> = Vec::new();

                // Add text content if present
                if let MessageContent::Text { text } = &msg.content
                    && !text.is_empty()
                {
                    content_blocks.push(serde_json::json!({"type": "text", "text": text}));
                }

                // Add tool_use blocks for tool calls
                for tc in &msg.tool_calls {
                    let input: serde_json::Value =
                        serde_json::from_str(&tc.arguments).unwrap_or(serde_json::json!({}));
                    content_blocks.push(serde_json::json!({
                        "type": "tool_use",
                        "id": tc.call_id,
                        "name": tc.function_name,
                        "input": input,
                    }));
                }

                if !content_blocks.is_empty() {
                    result.push(serde_json::json!({
                        "role": "assistant",
                        "content": content_blocks,
                    }));
                }
            }
            Role::Tool => {
                // Tool results go as user messages with tool_result content blocks
                if let MessageContent::ToolResult { call_id, content } = &msg.content {
                    result.push(serde_json::json!({
                        "role": "user",
                        "content": [{
                            "type": "tool_result",
                            "tool_use_id": call_id,
                            "content": content,
                        }],
                    }));
                }
            }
        }
    }

    (system_text, result)
}

// ── SSE Event Parsing ──────────────────────────────────────────

/// Tracks the type of currently active content block for proper event mapping.
#[derive(Debug, Clone, PartialEq, Eq)]
enum BlockType {
    Text,
    Thinking,
    ToolUse { call_id: String },
}

/// Tracks active content blocks during Anthropic SSE streaming.
#[derive(Debug, Default)]
pub struct AnthropicBlockTracker {
    /// Currently active block type, indexed by block index.
    active_blocks: Vec<Option<BlockType>>,
}

impl AnthropicBlockTracker {
    /// Create a new block tracker.
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a new content block start.
    fn start_block(&mut self, index: usize, block_type: BlockType) {
        while self.active_blocks.len() <= index {
            self.active_blocks.push(None);
        }
        self.active_blocks[index] = Some(block_type);
    }

    /// Get the type of block at the given index.
    fn block_type(&self, index: usize) -> Option<&BlockType> {
        self.active_blocks.get(index).and_then(|b| b.as_ref())
    }

    /// End the block at the given index, returning its type.
    fn end_block(&mut self, index: usize) -> Option<BlockType> {
        if index < self.active_blocks.len() {
            self.active_blocks[index].take()
        } else {
            None
        }
    }
}

/// Parse a single Anthropic SSE event into LlmEvents.
///
/// # Arguments
/// - `event_type` — the SSE event name (e.g. `"message_start"`, `"content_block_delta"`)
/// - `data` — the JSON data payload
/// - `tracker` — tracks active content block types
pub fn parse_anthropic_event(
    event_type: &str,
    data: &str,
    tracker: &mut AnthropicBlockTracker,
) -> Vec<LlmEvent> {
    let json: serde_json::Value = match serde_json::from_str(data) {
        Ok(v) => v,
        Err(_) => return Vec::new(),
    };

    match event_type {
        "message_start" => {
            let model_id = json
                .pointer("/message/model")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown");
            tracing::debug!(model = model_id, "Stream started");
            let msg_id = json
                .pointer("/message/id")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown");
            vec![LlmEvent::StreamStart {
                request_id: msg_id.to_string(),
                model: ModelRef::new(model_id),
            }]
        }

        "content_block_start" => {
            let index = json.get("index").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
            let block = &json["content_block"];
            let block_type = block.get("type").and_then(|v| v.as_str()).unwrap_or("text");

            match block_type {
                "thinking" => {
                    tracker.start_block(index, BlockType::Thinking);
                    vec![LlmEvent::ThinkingStart]
                }
                "tool_use" => {
                    let call_id = block
                        .get("id")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    let name = block
                        .get("name")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    tracker.start_block(
                        index,
                        BlockType::ToolUse {
                            call_id: call_id.clone(),
                        },
                    );
                    vec![LlmEvent::ToolCallStart {
                        call_id,
                        function_name: name,
                    }]
                }
                _ => {
                    // text or unknown — just register as text block
                    tracker.start_block(index, BlockType::Text);
                    Vec::new()
                }
            }
        }

        "content_block_delta" => {
            let index = json.get("index").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
            let delta = &json["delta"];
            let delta_type = delta.get("type").and_then(|v| v.as_str()).unwrap_or("");

            match delta_type {
                "text_delta" => {
                    let text = delta
                        .get("text")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    if text.is_empty() {
                        Vec::new()
                    } else {
                        vec![LlmEvent::TextDelta { text }]
                    }
                }
                "thinking_delta" => {
                    let text = delta
                        .get("thinking")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    if text.is_empty() {
                        Vec::new()
                    } else {
                        vec![LlmEvent::ThinkingDelta { text }]
                    }
                }
                "input_json_delta" => {
                    let partial = delta
                        .get("partial_json")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    if partial.is_empty() {
                        return Vec::new();
                    }
                    // Look up the call_id from the tracker
                    let call_id = match tracker.block_type(index) {
                        Some(BlockType::ToolUse { call_id }) => call_id.clone(),
                        _ => String::new(),
                    };
                    vec![LlmEvent::ToolCallArgsDelta {
                        call_id,
                        args_fragment: partial,
                    }]
                }
                _ => Vec::new(),
            }
        }

        "content_block_stop" => {
            let index = json.get("index").and_then(|v| v.as_u64()).unwrap_or(0) as usize;
            match tracker.end_block(index) {
                Some(BlockType::Thinking) => vec![LlmEvent::ThinkingEnd],
                Some(BlockType::ToolUse { call_id }) => {
                    vec![LlmEvent::ToolCallEnd { call_id }]
                }
                _ => Vec::new(), // Text block stop produces no event
            }
        }

        "message_delta" => {
            let stop_reason = json
                .pointer("/delta/stop_reason")
                .and_then(|v| v.as_str())
                .unwrap_or("end_turn");
            vec![LlmEvent::StreamEnd {
                finish_reason: map_stop_reason(stop_reason),
            }]
        }

        // message_stop, ping, error — ignored or handled elsewhere
        "error" => {
            let message = json
                .pointer("/error/message")
                .and_then(|v| v.as_str())
                .unwrap_or("unknown error")
                .to_string();
            vec![LlmEvent::StreamError { error: message }]
        }

        _ => Vec::new(),
    }
}

// ── Finish Reason Mapping ──────────────────────────────────────

/// Map Anthropic stop reasons to our normalized [`FinishReason`].
pub fn map_stop_reason(reason: &str) -> FinishReason {
    match reason {
        "end_turn" => FinishReason::Stop,
        "max_tokens" => FinishReason::Length,
        "tool_use" => FinishReason::ToolCalls,
        "stop_sequence" => FinishReason::Stop,
        _ => FinishReason::Other,
    }
}

// ── Error Mapping ──────────────────────────────────────────────

/// Map HTTP error responses to typed errors.
pub fn map_http_error(status: reqwest::StatusCode, body: &str) -> FaeLlmError {
    let detail = extract_error_message(body);

    match status.as_u16() {
        401 | 403 => FaeLlmError::AuthError(detail),
        429 => FaeLlmError::RequestError(format!("rate limit exceeded: {detail}")),
        400 => FaeLlmError::RequestError(detail),
        529 => FaeLlmError::ProviderError(format!("API overloaded: {detail}")),
        s if s >= 500 => FaeLlmError::ProviderError(detail),
        _ => FaeLlmError::RequestError(format!("HTTP {status}: {detail}")),
    }
}

/// Extract a human-readable error message from an Anthropic error response.
fn extract_error_message(body: &str) -> String {
    serde_json::from_str::<serde_json::Value>(body)
        .ok()
        .and_then(|v| {
            v.pointer("/error/message")
                .and_then(|m| m.as_str())
                .map(String::from)
        })
        .unwrap_or_else(|| {
            if body.is_empty() {
                "no response body".to_string()
            } else {
                body.chars().take(500).collect()
            }
        })
}

// ── Adapter ────────────────────────────────────────────────────

/// Anthropic Messages API provider adapter.
///
/// Implements [`ProviderAdapter`] for the Anthropic Messages API with
/// streaming support via SSE content block deltas.
pub struct AnthropicAdapter {
    config: AnthropicConfig,
    client: reqwest::Client,
}

impl AnthropicAdapter {
    /// Create a new Anthropic adapter.
    pub fn new(config: AnthropicConfig) -> Self {
        let client = reqwest::Client::new();
        Self { config, client }
    }

    /// Returns a reference to the adapter configuration.
    pub fn config(&self) -> &AnthropicConfig {
        &self.config
    }
}

#[async_trait]
impl ProviderAdapter for AnthropicAdapter {
    fn name(&self) -> &str {
        "anthropic"
    }

    async fn send(
        &self,
        messages: &[Message],
        options: &RequestOptions,
        tools: &[ToolDefinition],
    ) -> Result<LlmEventStream, FaeLlmError> {
        let span = tracing::info_span!(
            SPAN_PROVIDER_REQUEST,
            { FIELD_PROVIDER } = "anthropic",
            { FIELD_MODEL } = %self.config.model,
            { FIELD_ENDPOINT_TYPE } = "messages",
        );
        let _enter = span.enter();

        tracing::debug!("Building Anthropic request");

        let streaming_options = if options.stream {
            options.clone()
        } else {
            let mut opts = options.clone();
            opts.stream = true;
            opts
        };

        let body = build_messages_request(&self.config.model, messages, &streaming_options, tools);

        tracing::debug!("Sending request to Anthropic");

        let url = format!("{}/v1/messages", self.config.base_url);
        let response = self
            .client
            .post(&url)
            .header("x-api-key", &self.config.api_key)
            .header("anthropic-version", &self.config.api_version)
            .header("content-type", "application/json")
            .header("accept", "text/event-stream")
            .json(&body)
            .send()
            .await
            .map_err(|e| {
                tracing::error!(error = %e, "Anthropic request failed");
                FaeLlmError::RequestError(format!("connection error: {e}"))
            })?;

        if !response.status().is_success() {
            let status = response.status();
            let body = response
                .text()
                .await
                .unwrap_or_else(|_| "failed to read body".into());
            tracing::error!(status = %status, body = %body, "Anthropic request returned error");
            return Err(map_http_error(status, &body));
        }

        tracing::info!("Anthropic stream starting");

        let byte_stream = response.bytes_stream();

        let event_stream = futures_util::stream::unfold(
            (
                byte_stream,
                SseLineParser::new(),
                AnthropicBlockTracker::new(),
                Vec::<LlmEvent>::new(),
            ),
            |(mut byte_stream, mut sse_parser, mut tracker, mut buffer)| async move {
                loop {
                    // Drain buffered events first
                    if let Some(event) = buffer.pop() {
                        return Some((event, (byte_stream, sse_parser, tracker, buffer)));
                    }

                    // Get next chunk
                    match byte_stream.next().await {
                        Some(Ok(chunk)) => {
                            let sse_events = sse_parser.push(&chunk);
                            for sse in sse_events {
                                if sse.is_done() {
                                    continue;
                                }
                                let event_type = sse.event_type.as_deref().unwrap_or("");
                                let events =
                                    parse_anthropic_event(event_type, &sse.data, &mut tracker);
                                // Reverse so we can pop from the end in order
                                for e in events.into_iter().rev() {
                                    buffer.push(e);
                                }
                            }
                            // Try to drain again at top of loop
                        }
                        Some(Err(e)) => {
                            tracing::error!(error = %e, "Anthropic stream error");
                            return Some((
                                LlmEvent::StreamError {
                                    error: format!("stream read error: {e}"),
                                },
                                (byte_stream, sse_parser, tracker, buffer),
                            ));
                        }
                        None => {
                            // Stream ended — drain any remaining buffered events
                            if let Some(event) = buffer.pop() {
                                return Some((event, (byte_stream, sse_parser, tracker, buffer)));
                            }
                            return None;
                        }
                    }
                }
            },
        );

        Ok(Box::pin(event_stream))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── AnthropicConfig ────────────────────────────────────────

    #[test]
    fn config_new() {
        let config = AnthropicConfig::new("sk-test", "claude-sonnet-4-5-20250929");
        assert_eq!(config.api_key, "sk-test");
        assert_eq!(config.model, "claude-sonnet-4-5-20250929");
        assert_eq!(config.api_version, "2023-06-01");
        assert_eq!(config.max_tokens, 4096);
    }

    #[test]
    fn config_builder() {
        let config = AnthropicConfig::new("key", "model")
            .with_api_version("2024-01-01")
            .with_max_tokens(8192);
        assert_eq!(config.api_version, "2024-01-01");
        assert_eq!(config.max_tokens, 8192);
    }

    // ── Request Building ───────────────────────────────────────

    #[test]
    fn build_request_basic() {
        let messages = vec![Message::user("Hello")];
        let opts = RequestOptions::new().with_stream(true);
        let body = build_messages_request("claude-sonnet-4-5", &messages, &opts, &[]);

        assert_eq!(body["model"], "claude-sonnet-4-5");
        assert!(body["stream"].as_bool().unwrap_or(false));
        assert!(body["messages"].is_array());
        assert_eq!(body["messages"].as_array().map(|a| a.len()), Some(1));
    }

    #[test]
    fn build_request_extracts_system() {
        let messages = vec![Message::system("You are helpful."), Message::user("Hi")];
        let opts = RequestOptions::new();
        let body = build_messages_request("model", &messages, &opts, &[]);

        assert_eq!(body["system"], "You are helpful.");
        // Only user message in messages array
        assert_eq!(body["messages"].as_array().map(|a| a.len()), Some(1));
        assert_eq!(body["messages"][0]["role"], "user");
    }

    #[test]
    fn build_request_with_tools() {
        let tools = vec![ToolDefinition::new(
            "read",
            "Read a file",
            serde_json::json!({"type": "object", "properties": {"path": {"type": "string"}}}),
        )];
        let opts = RequestOptions::new();
        let body = build_messages_request("model", &[Message::user("Hi")], &opts, &tools);

        assert!(body["tools"].is_array());
        assert_eq!(body["tools"].as_array().map(|a| a.len()), Some(1));
        assert_eq!(body["tools"][0]["name"], "read");
        assert!(body["tools"][0].get("input_schema").is_some());
    }

    #[test]
    fn build_request_with_temperature() {
        let opts = RequestOptions::new().with_temperature(0.5).with_top_p(0.9);
        let body = build_messages_request("model", &[Message::user("Hi")], &opts, &[]);

        assert_eq!(body["temperature"], 0.5);
        assert_eq!(body["top_p"], 0.9);
    }

    // ── Message Conversion ─────────────────────────────────────

    #[test]
    fn convert_user_message() {
        let msgs = vec![Message::user("Hello")];
        let (sys, converted) = convert_messages(&msgs);
        assert!(sys.is_none());
        assert_eq!(converted.len(), 1);
        assert_eq!(converted[0]["role"], "user");
        assert_eq!(converted[0]["content"][0]["type"], "text");
        assert_eq!(converted[0]["content"][0]["text"], "Hello");
    }

    #[test]
    fn convert_assistant_with_tool_calls() {
        use crate::fae_llm::providers::message::AssistantToolCall;
        let msgs = vec![Message::assistant_with_tool_calls(
            Some("I'll read the file.".into()),
            vec![AssistantToolCall {
                call_id: "call_1".into(),
                function_name: "read".into(),
                arguments: r#"{"path":"main.rs"}"#.into(),
            }],
        )];
        let (_, converted) = convert_messages(&msgs);
        assert_eq!(converted.len(), 1);
        assert_eq!(converted[0]["role"], "assistant");

        let content = converted[0]["content"].as_array();
        assert!(content.is_some());
        let content = content.unwrap_or(&Vec::new()).clone();
        assert_eq!(content.len(), 2); // text + tool_use
        assert_eq!(content[0]["type"], "text");
        assert_eq!(content[1]["type"], "tool_use");
        assert_eq!(content[1]["id"], "call_1");
        assert_eq!(content[1]["name"], "read");
    }

    #[test]
    fn convert_tool_result() {
        let msgs = vec![Message::tool_result("call_1", "file contents here")];
        let (_, converted) = convert_messages(&msgs);
        assert_eq!(converted.len(), 1);
        assert_eq!(converted[0]["role"], "user");
        assert_eq!(converted[0]["content"][0]["type"], "tool_result");
        assert_eq!(converted[0]["content"][0]["tool_use_id"], "call_1");
        assert_eq!(converted[0]["content"][0]["content"], "file contents here");
    }

    #[test]
    fn convert_system_extracted() {
        let msgs = vec![
            Message::system("Be concise."),
            Message::user("Hello"),
            Message::assistant("Hi!"),
        ];
        let (sys, converted) = convert_messages(&msgs);
        assert_eq!(sys, Some("Be concise.".to_string()));
        assert_eq!(converted.len(), 2); // user + assistant, no system
    }

    // ── SSE Event Parsing ──────────────────────────────────────

    #[test]
    fn parse_message_start() {
        let mut tracker = AnthropicBlockTracker::new();
        let data = r#"{"type":"message_start","message":{"id":"msg_01","model":"claude-sonnet-4-5","role":"assistant"}}"#;
        let events = parse_anthropic_event("message_start", data, &mut tracker);
        assert_eq!(events.len(), 1);
        assert!(
            matches!(&events[0], LlmEvent::StreamStart { request_id, model }
                if request_id == "msg_01" && model.model_id == "claude-sonnet-4-5"
            )
        );
    }

    #[test]
    fn parse_text_block_delta() {
        let mut tracker = AnthropicBlockTracker::new();
        // Start a text block
        let start_data =
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#;
        let _ = parse_anthropic_event("content_block_start", start_data, &mut tracker);

        // Delta
        let delta_data = r#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello "}}"#;
        let events = parse_anthropic_event("content_block_delta", delta_data, &mut tracker);
        assert_eq!(events.len(), 1);
        assert!(matches!(&events[0], LlmEvent::TextDelta { text } if text == "Hello "));
    }

    #[test]
    fn parse_thinking_block() {
        let mut tracker = AnthropicBlockTracker::new();

        // Start thinking
        let start_data =
            r#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}"#;
        let events = parse_anthropic_event("content_block_start", start_data, &mut tracker);
        assert_eq!(events.len(), 1);
        assert!(matches!(events[0], LlmEvent::ThinkingStart));

        // Thinking delta
        let delta_data = r#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me think..."}}"#;
        let events = parse_anthropic_event("content_block_delta", delta_data, &mut tracker);
        assert_eq!(events.len(), 1);
        assert!(
            matches!(&events[0], LlmEvent::ThinkingDelta { text } if text == "Let me think...")
        );

        // Stop thinking
        let stop_data = r#"{"type":"content_block_stop","index":0}"#;
        let events = parse_anthropic_event("content_block_stop", stop_data, &mut tracker);
        assert_eq!(events.len(), 1);
        assert!(matches!(events[0], LlmEvent::ThinkingEnd));
    }

    #[test]
    fn parse_tool_use_block() {
        let mut tracker = AnthropicBlockTracker::new();

        // Start tool_use
        let start_data = r#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_01","name":"read"}}"#;
        let events = parse_anthropic_event("content_block_start", start_data, &mut tracker);
        assert_eq!(events.len(), 1);
        assert!(
            matches!(&events[0], LlmEvent::ToolCallStart { call_id, function_name }
                if call_id == "toolu_01" && function_name == "read"
            )
        );

        // Input JSON delta
        let delta_data = r#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\""}}"#;
        let events = parse_anthropic_event("content_block_delta", delta_data, &mut tracker);
        assert_eq!(events.len(), 1);
        assert!(
            matches!(&events[0], LlmEvent::ToolCallArgsDelta { call_id, args_fragment }
                if call_id == "toolu_01" && args_fragment == "{\"path\":\""
            )
        );

        // Stop tool_use
        let stop_data = r#"{"type":"content_block_stop","index":0}"#;
        let events = parse_anthropic_event("content_block_stop", stop_data, &mut tracker);
        assert_eq!(events.len(), 1);
        assert!(matches!(&events[0], LlmEvent::ToolCallEnd { call_id } if call_id == "toolu_01"));
    }

    #[test]
    fn parse_message_delta_stop_reason() {
        let mut tracker = AnthropicBlockTracker::new();

        let data = r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":100}}"#;
        let events = parse_anthropic_event("message_delta", data, &mut tracker);
        assert_eq!(events.len(), 1);
        assert!(matches!(
            events[0],
            LlmEvent::StreamEnd {
                finish_reason: FinishReason::Stop
            }
        ));
    }

    #[test]
    fn parse_message_delta_tool_use_stop() {
        let mut tracker = AnthropicBlockTracker::new();
        let data = r#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":50}}"#;
        let events = parse_anthropic_event("message_delta", data, &mut tracker);
        assert_eq!(events.len(), 1);
        assert!(matches!(
            events[0],
            LlmEvent::StreamEnd {
                finish_reason: FinishReason::ToolCalls
            }
        ));
    }

    #[test]
    fn parse_error_event() {
        let mut tracker = AnthropicBlockTracker::new();
        let data =
            r#"{"type":"error","error":{"type":"overloaded_error","message":"API is overloaded"}}"#;
        let events = parse_anthropic_event("error", data, &mut tracker);
        assert_eq!(events.len(), 1);
        assert!(matches!(&events[0], LlmEvent::StreamError { error }
            if error == "API is overloaded"
        ));
    }

    #[test]
    fn parse_unknown_event_type() {
        let mut tracker = AnthropicBlockTracker::new();
        let events = parse_anthropic_event("ping", "{}", &mut tracker);
        assert!(events.is_empty());
    }

    #[test]
    fn parse_invalid_json() {
        let mut tracker = AnthropicBlockTracker::new();
        let events = parse_anthropic_event("message_start", "not json", &mut tracker);
        assert!(events.is_empty());
    }

    // ── Multi-block Stream ─────────────────────────────────────

    #[test]
    fn multi_block_thinking_then_text() {
        let mut tracker = AnthropicBlockTracker::new();

        let sse_sequence = [
            (
                "message_start",
                r#"{"type":"message_start","message":{"id":"msg_01","model":"claude-opus-4","role":"assistant"}}"#,
            ),
            (
                "content_block_start",
                r#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}"#,
            ),
            (
                "content_block_delta",
                r#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Analyzing..."}}"#,
            ),
            (
                "content_block_stop",
                r#"{"type":"content_block_stop","index":0}"#,
            ),
            (
                "content_block_start",
                r#"{"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}"#,
            ),
            (
                "content_block_delta",
                r#"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"The answer is 42."}}"#,
            ),
            (
                "content_block_stop",
                r#"{"type":"content_block_stop","index":1}"#,
            ),
            (
                "message_delta",
                r#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":50}}"#,
            ),
        ];

        let mut all_events = Vec::new();
        for (event_type, data) in &sse_sequence {
            all_events.extend(parse_anthropic_event(event_type, data, &mut tracker));
        }

        // Verify stream structure
        assert!(matches!(all_events[0], LlmEvent::StreamStart { .. }));
        assert!(matches!(all_events[1], LlmEvent::ThinkingStart));
        assert!(
            matches!(&all_events[2], LlmEvent::ThinkingDelta { text } if text == "Analyzing...")
        );
        assert!(matches!(all_events[3], LlmEvent::ThinkingEnd));
        assert!(
            matches!(&all_events[4], LlmEvent::TextDelta { text } if text == "The answer is 42.")
        );
        assert!(matches!(
            all_events[5],
            LlmEvent::StreamEnd {
                finish_reason: FinishReason::Stop
            }
        ));
    }

    // ── Stop Reason Mapping ────────────────────────────────────

    #[test]
    fn stop_reason_end_turn() {
        assert_eq!(map_stop_reason("end_turn"), FinishReason::Stop);
    }

    #[test]
    fn stop_reason_max_tokens() {
        assert_eq!(map_stop_reason("max_tokens"), FinishReason::Length);
    }

    #[test]
    fn stop_reason_tool_use() {
        assert_eq!(map_stop_reason("tool_use"), FinishReason::ToolCalls);
    }

    #[test]
    fn stop_reason_stop_sequence() {
        assert_eq!(map_stop_reason("stop_sequence"), FinishReason::Stop);
    }

    #[test]
    fn stop_reason_unknown() {
        assert_eq!(map_stop_reason("something_else"), FinishReason::Other);
    }

    // ── Error Mapping ──────────────────────────────────────────

    #[test]
    fn http_error_401() {
        let err = map_http_error(
            reqwest::StatusCode::UNAUTHORIZED,
            r#"{"type":"error","error":{"type":"authentication_error","message":"Invalid API key"}}"#,
        );
        assert_eq!(err.code(), "AUTH_FAILED");
    }

    #[test]
    fn http_error_403() {
        let err = map_http_error(
            reqwest::StatusCode::FORBIDDEN,
            r#"{"type":"error","error":{"type":"permission_error","message":"Not allowed"}}"#,
        );
        assert_eq!(err.code(), "AUTH_FAILED");
    }

    #[test]
    fn http_error_429() {
        let err = map_http_error(
            reqwest::StatusCode::TOO_MANY_REQUESTS,
            r#"{"type":"error","error":{"type":"rate_limit_error","message":"Too many requests"}}"#,
        );
        assert_eq!(err.code(), "REQUEST_FAILED");
    }

    #[test]
    fn http_error_400() {
        let err = map_http_error(
            reqwest::StatusCode::BAD_REQUEST,
            r#"{"type":"error","error":{"type":"invalid_request_error","message":"Bad request"}}"#,
        );
        assert_eq!(err.code(), "REQUEST_FAILED");
    }

    #[test]
    fn http_error_500() {
        let err = map_http_error(
            reqwest::StatusCode::INTERNAL_SERVER_ERROR,
            r#"{"type":"error","error":{"type":"api_error","message":"Internal error"}}"#,
        );
        assert_eq!(err.code(), "PROVIDER_ERROR");
    }

    #[test]
    fn http_error_529_overloaded() {
        let status =
            reqwest::StatusCode::from_u16(529).unwrap_or(reqwest::StatusCode::SERVICE_UNAVAILABLE);
        let err = map_http_error(
            status,
            r#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#,
        );
        assert_eq!(err.code(), "PROVIDER_ERROR");
    }

    #[test]
    fn http_error_empty_body() {
        let err = map_http_error(reqwest::StatusCode::INTERNAL_SERVER_ERROR, "");
        assert_eq!(err.code(), "PROVIDER_ERROR");
        assert!(err.message().contains("no response body"));
    }

    // ── Adapter ────────────────────────────────────────────────

    #[test]
    fn adapter_name() {
        let config = AnthropicConfig::new("key", "model");
        let adapter = AnthropicAdapter::new(config);
        assert_eq!(adapter.name(), "anthropic");
    }

    #[test]
    fn adapter_config_accessible() {
        let config = AnthropicConfig::new("sk-test", "claude-opus-4");
        let adapter = AnthropicAdapter::new(config);
        assert_eq!(adapter.config().model, "claude-opus-4");
    }

    // ── Block Tracker ──────────────────────────────────────────

    #[test]
    fn block_tracker_start_and_end() {
        let mut tracker = AnthropicBlockTracker::new();
        tracker.start_block(0, BlockType::Thinking);
        tracker.start_block(1, BlockType::Text);
        tracker.start_block(
            2,
            BlockType::ToolUse {
                call_id: "tc_1".into(),
            },
        );

        assert_eq!(tracker.block_type(0), Some(&BlockType::Thinking));
        assert_eq!(tracker.block_type(1), Some(&BlockType::Text));

        let ended = tracker.end_block(0);
        assert_eq!(ended, Some(BlockType::Thinking));
        assert!(tracker.block_type(0).is_none());
    }

    #[test]
    fn block_tracker_end_nonexistent() {
        let mut tracker = AnthropicBlockTracker::new();
        assert!(tracker.end_block(99).is_none());
    }

    // ── Send + Sync ────────────────────────────────────────────

    #[test]
    fn types_are_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<AnthropicConfig>();
        assert_send_sync::<AnthropicAdapter>();
        assert_send_sync::<AnthropicBlockTracker>();
    }

    // ── Extract Error Message ──────────────────────────────────

    #[test]
    fn extract_error_from_json() {
        let body = r#"{"type":"error","error":{"type":"auth_error","message":"Invalid API key"}}"#;
        assert_eq!(extract_error_message(body), "Invalid API key");
    }

    #[test]
    fn extract_error_from_non_json() {
        assert_eq!(
            extract_error_message("Service Unavailable"),
            "Service Unavailable"
        );
    }

    #[test]
    fn extract_error_from_empty() {
        assert_eq!(extract_error_message(""), "no response body");
    }
}
