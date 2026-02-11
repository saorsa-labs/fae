//! OpenAI-compatible HTTP server for local LLM inference.
//!
//! Exposes Fae's Qwen 3 (via `mistralrs`) as an OpenAI-compatible endpoint
//! on localhost. This allows Pi and other local tools to use Fae's brain
//! for inference without cloud API keys.
//!
//! ## Endpoints
//!
//! - `GET /v1/models` — list available models
//! - `POST /v1/chat/completions` — chat completions (streaming and non-streaming)

use axum::Router;
use axum::extract::State;
use axum::response::sse::{Event, KeepAlive, Sse};
use axum::response::{IntoResponse, Json};
use axum::routing::{get, post};
use futures_util::stream::Stream;
use mistralrs::{
    CalledFunction, Model, RequestBuilder, Response, TextMessageRole, Tool, ToolCallResponse,
    ToolCallType, ToolChoice,
};
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::net::TcpListener;
use tokio::task::JoinHandle;
use tracing::info;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Request types
// ---------------------------------------------------------------------------

/// OpenAI-compatible chat completion request.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatCompletionRequest {
    /// Model ID to use for completion.
    pub model: String,
    /// Conversation messages.
    pub messages: Vec<ChatMessage>,
    /// Whether to stream the response as SSE events.
    #[serde(default)]
    pub stream: Option<bool>,
    /// Sampling temperature (0.0–2.0).
    #[serde(default)]
    pub temperature: Option<f64>,
    /// Nucleus sampling threshold (0.0–1.0).
    #[serde(default)]
    pub top_p: Option<f64>,
    /// Maximum number of tokens to generate.
    #[serde(default)]
    pub max_tokens: Option<usize>,
    /// Alternative max tokens field used by some OpenAI-compatible clients.
    #[serde(default)]
    pub max_completion_tokens: Option<usize>,
    /// Tool definitions (OpenAI function-calling).
    #[serde(default)]
    pub tools: Option<Vec<Tool>>,
    /// Tool choice policy (OpenAI function-calling).
    ///
    /// This is intentionally parsed as raw JSON for compatibility. Fae currently
    /// only maps `"none"` and `"auto"` into `mistralrs::ToolChoice`.
    #[serde(default)]
    pub tool_choice: Option<serde_json::Value>,
}

/// OpenAI-compatible tool call type.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OpenAiToolCallType {
    Function,
}

/// OpenAI-compatible tool call function payload.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpenAiToolCallFunction {
    pub name: String,
    pub arguments: String,
}

/// OpenAI-compatible tool call.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OpenAiToolCall {
    /// Tool call index (present in streaming deltas).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub index: Option<usize>,
    pub id: String,
    #[serde(rename = "type")]
    pub tp: OpenAiToolCallType,
    pub function: OpenAiToolCallFunction,
}

/// Message content for OpenAI-compatible chat messages.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum ChatMessageContent {
    Text(String),
    Parts(Vec<serde_json::Value>),
}

impl ChatMessageContent {
    fn as_text(&self) -> String {
        match self {
            Self::Text(s) => s.clone(),
            Self::Parts(parts) => {
                let mut out = String::new();
                for part in parts {
                    let Some(tp) = part.get("type").and_then(|v| v.as_str()) else {
                        continue;
                    };
                    if tp != "text" {
                        continue;
                    }
                    let text = part.get("text").and_then(|v| v.as_str()).unwrap_or("");
                    out.push_str(text);
                }
                out
            }
        }
    }
}

/// A single message in a chat conversation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatMessage {
    /// The role of the message author (`system`, `user`, `assistant`).
    pub role: String,
    /// The content of the message.
    ///
    /// For assistant tool-call messages this may be `null`.
    #[serde(default)]
    pub content: Option<ChatMessageContent>,
    /// Tool calls attached to an assistant message.
    #[serde(default)]
    pub tool_calls: Option<Vec<OpenAiToolCall>>,
    /// Tool call ID (for tool result messages).
    #[serde(default)]
    pub tool_call_id: Option<String>,
    /// Optional name (used by some OpenAI-compatible endpoints for tool messages).
    #[serde(default)]
    pub name: Option<String>,
}

// ---------------------------------------------------------------------------
// Response types (non-streaming)
// ---------------------------------------------------------------------------

/// OpenAI-compatible chat completion response.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatCompletionResponse {
    /// Unique identifier for the completion.
    pub id: String,
    /// Object type (always `"chat.completion"`).
    pub object: String,
    /// Unix timestamp of when the completion was created.
    pub created: u64,
    /// Model used for the completion.
    pub model: String,
    /// List of completion choices.
    pub choices: Vec<Choice>,
    /// Token usage statistics.
    pub usage: Usage,
}

/// A single completion choice.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Choice {
    /// Index of this choice in the list.
    pub index: u32,
    /// The generated message.
    pub message: ChatMessage,
    /// Reason the model stopped generating (`stop`, `length`, etc.).
    pub finish_reason: Option<String>,
}

/// Token usage statistics for a completion.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Usage {
    /// Number of tokens in the prompt.
    pub prompt_tokens: u32,
    /// Number of tokens in the completion.
    pub completion_tokens: u32,
    /// Total tokens (prompt + completion).
    pub total_tokens: u32,
}

// ---------------------------------------------------------------------------
// Streaming response types
// ---------------------------------------------------------------------------

/// OpenAI-compatible streaming chat completion chunk.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatCompletionChunk {
    /// Unique identifier for the completion (same across all chunks).
    pub id: String,
    /// Object type (always `"chat.completion.chunk"`).
    pub object: String,
    /// Unix timestamp of when the completion was created.
    pub created: u64,
    /// Model used for the completion.
    pub model: String,
    /// List of chunk choices (typically one).
    pub choices: Vec<ChunkChoice>,
}

/// A single choice within a streaming chunk.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChunkChoice {
    /// Index of this choice in the list.
    pub index: u32,
    /// The incremental content delta.
    pub delta: Delta,
    /// Reason the model stopped generating (only present in the final chunk).
    pub finish_reason: Option<String>,
}

/// Incremental content delta in a streaming chunk.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Delta {
    /// The role (only present in the first chunk).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    /// The incremental text content.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    /// Tool call deltas (OpenAI function-calling).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tool_calls: Option<Vec<OpenAiToolCall>>,
}

// ---------------------------------------------------------------------------
// Error response
// ---------------------------------------------------------------------------

/// OpenAI-compatible error response.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorResponse {
    /// The error details.
    pub error: ErrorBody,
}

/// Error details within an [`ErrorResponse`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorBody {
    /// Human-readable error message.
    pub message: String,
    /// Error type (e.g. `"server_error"`, `"invalid_request_error"`).
    #[serde(rename = "type")]
    pub error_type: String,
}

// ---------------------------------------------------------------------------
// Model list response
// ---------------------------------------------------------------------------

/// Response from the `GET /v1/models` endpoint.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelListResponse {
    /// Object type (always `"list"`).
    pub object: String,
    /// List of available models.
    pub data: Vec<ModelObject>,
}

/// A single model in the model list.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelObject {
    /// Model identifier.
    pub id: String,
    /// Object type (always `"model"`).
    pub object: String,
    /// Owner of the model.
    pub owned_by: String,
}

use crate::config::LlmServerConfig;

/// Default model ID exposed by the server.
const MODEL_ID: &str = "fae-qwen3";

/// Default temperature when not specified in the request.
const DEFAULT_TEMPERATURE: f64 = 0.7;

/// Default top-p when not specified in the request.
const DEFAULT_TOP_P: f64 = 0.9;

/// Default max tokens when not specified in the request.
const DEFAULT_MAX_TOKENS: usize = 2048;

// ---------------------------------------------------------------------------
// Shared application state
// ---------------------------------------------------------------------------

/// Shared state for axum handlers.
#[derive(Clone)]
struct AppState {
    /// The mistralrs model instance shared with the voice pipeline.
    model: Arc<Model>,
    /// Model ID to report in API responses.
    model_id: String,
}

// ---------------------------------------------------------------------------
// LlmServer
// ---------------------------------------------------------------------------

/// OpenAI-compatible HTTP server backed by a shared `mistralrs` model.
///
/// The server exposes `GET /v1/models` and `POST /v1/chat/completions`
/// endpoints on localhost. It shares the same `Model` instance used by
/// the voice pipeline, so no extra VRAM/RAM is consumed.
pub struct LlmServer {
    /// The address the server is listening on.
    addr: SocketAddr,
    /// Handle to the background server task.
    handle: JoinHandle<()>,
}

impl LlmServer {
    /// Start the LLM HTTP server.
    ///
    /// Binds to `{config.host}:{config.port}` (use port `0` for auto-assign)
    /// and begins serving in a background tokio task.
    ///
    /// # Errors
    ///
    /// Returns an error if the TCP listener cannot bind.
    pub async fn start(model: Arc<Model>, config: &LlmServerConfig) -> crate::error::Result<Self> {
        let state = AppState {
            model,
            model_id: MODEL_ID.to_owned(),
        };

        let app = Router::new()
            .route("/v1/models", get(handle_models))
            .route("/v1/chat/completions", post(handle_chat_completions))
            .with_state(state);

        let bind_addr = format!("{}:{}", config.host, config.port);
        let listener = TcpListener::bind(&bind_addr)
            .await
            .map_err(|e| crate::error::SpeechError::Llm(format!("LLM server bind failed: {e}")))?;

        let addr = listener.local_addr().map_err(|e| {
            crate::error::SpeechError::Llm(format!("failed to get local addr: {e}"))
        })?;

        info!("LLM server listening on http://{addr}/v1");

        let handle = tokio::spawn(async move {
            if let Err(e) = axum::serve(listener, app).await {
                tracing::error!("LLM server error: {e}");
            }
        });

        Ok(Self { addr, handle })
    }

    /// Returns the address the server is listening on.
    pub fn addr(&self) -> SocketAddr {
        self.addr
    }

    /// Returns the port the server is listening on.
    pub fn port(&self) -> u16 {
        self.addr.port()
    }

    /// Abort the server task.
    pub fn shutdown(&self) {
        self.handle.abort();
    }
}

impl Drop for LlmServer {
    fn drop(&mut self) {
        self.handle.abort();
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Generate a unique completion ID.
fn completion_id() -> String {
    format!("chatcmpl-{}", Uuid::new_v4())
}

/// Get the current Unix timestamp in seconds.
fn unix_timestamp() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Convert our [`ChatMessage`] list into a mistralrs [`RequestBuilder`].
fn build_request(request: &ChatCompletionRequest) -> crate::error::Result<RequestBuilder> {
    let mut rb = RequestBuilder::new();

    for msg in &request.messages {
        let role = match msg.role.as_str() {
            // Some clients may use `developer` role (treated like system).
            "system" | "developer" => TextMessageRole::System,
            "assistant" => TextMessageRole::Assistant,
            "tool" => TextMessageRole::Tool,
            _ => TextMessageRole::User,
        };

        let text = msg
            .content
            .as_ref()
            .map(ChatMessageContent::as_text)
            .unwrap_or_default();

        if role == TextMessageRole::Tool {
            let Some(tool_call_id) = msg.tool_call_id.as_deref() else {
                return Err(crate::error::SpeechError::Server(
                    "tool message missing tool_call_id".to_owned(),
                ));
            };
            rb = rb.add_tool_message(text, tool_call_id);
            continue;
        }

        if role == TextMessageRole::Assistant {
            if let Some(tool_calls) = msg.tool_calls.as_ref() {
                let tool_calls = openai_tool_calls_to_mistral(tool_calls)?;
                rb = rb.add_message_with_tool_call(role.clone(), text, tool_calls);
                continue;
            }

            // Avoid sending empty assistant messages without tool calls; many
            // OpenAI-compatible endpoints reject them.
            if text.trim().is_empty() {
                continue;
            }
        }

        rb = rb.add_message(role, text);
    }

    let max_tokens = request
        .max_tokens
        .or(request.max_completion_tokens)
        .unwrap_or(DEFAULT_MAX_TOKENS);

    rb = rb
        .set_sampler_temperature(request.temperature.unwrap_or(DEFAULT_TEMPERATURE))
        .set_sampler_topp(request.top_p.unwrap_or(DEFAULT_TOP_P))
        .set_sampler_max_len(max_tokens);

    if let Some(tools) = request.tools.clone() {
        rb = rb.set_tools(tools);
    }

    if let Some(choice) = request.tool_choice.as_ref().and_then(map_tool_choice) {
        rb = rb.set_tool_choice(choice);
    }

    Ok(rb)
}

fn map_tool_choice(value: &serde_json::Value) -> Option<ToolChoice> {
    let s = value.as_str()?;
    match s {
        "none" => Some(ToolChoice::None),
        "auto" => Some(ToolChoice::Auto),
        _ => None,
    }
}

fn openai_tool_calls_to_mistral(
    tool_calls: &[OpenAiToolCall],
) -> crate::error::Result<Vec<ToolCallResponse>> {
    let mut out = Vec::with_capacity(tool_calls.len());
    for (i, tool_call) in tool_calls.iter().enumerate() {
        match tool_call.tp {
            OpenAiToolCallType::Function => {
                out.push(ToolCallResponse {
                    index: tool_call.index.unwrap_or(i),
                    id: tool_call.id.clone(),
                    tp: ToolCallType::Function,
                    function: CalledFunction {
                        name: tool_call.function.name.clone(),
                        arguments: tool_call.function.arguments.clone(),
                    },
                });
            }
        }
    }
    Ok(out)
}

fn mistral_tool_calls_to_openai(tool_calls: Vec<ToolCallResponse>) -> Vec<OpenAiToolCall> {
    tool_calls
        .into_iter()
        .map(|tool_call| OpenAiToolCall {
            index: Some(tool_call.index),
            id: tool_call.id,
            tp: OpenAiToolCallType::Function,
            function: OpenAiToolCallFunction {
                name: tool_call.function.name,
                arguments: tool_call.function.arguments,
            },
        })
        .collect()
}

/// Strip `<think>...</think>` blocks from generated text.
fn strip_think_blocks(text: &str) -> String {
    let mut result = String::with_capacity(text.len());
    let mut remaining = text;
    while let Some(start) = remaining.find("<think>") {
        result.push_str(&remaining[..start]);
        if let Some(end) = remaining[start..].find("</think>") {
            remaining = &remaining[start + end + "</think>".len()..];
        } else {
            // Unclosed <think> — discard the rest
            return result;
        }
    }
    result.push_str(remaining);
    result
}

// ---------------------------------------------------------------------------
// Route handlers
// ---------------------------------------------------------------------------

/// `GET /v1/models` — list available models.
async fn handle_models(State(state): State<AppState>) -> Json<ModelListResponse> {
    Json(ModelListResponse {
        object: "list".to_owned(),
        data: vec![ModelObject {
            id: state.model_id,
            object: "model".to_owned(),
            owned_by: "fae-local".to_owned(),
        }],
    })
}

/// `POST /v1/chat/completions` — chat completions (streaming and non-streaming).
async fn handle_chat_completions(
    State(state): State<AppState>,
    Json(request): Json<ChatCompletionRequest>,
) -> axum::response::Response {
    if request.stream == Some(true) {
        handle_streaming(state, request).await.into_response()
    } else {
        handle_non_streaming(state, request).await.into_response()
    }
}

/// Handle a non-streaming chat completion request.
async fn handle_non_streaming(
    state: AppState,
    request: ChatCompletionRequest,
) -> (axum::http::StatusCode, Json<serde_json::Value>) {
    let req = match build_request(&request) {
        Ok(r) => r,
        Err(e) => {
            let err = ErrorResponse {
                error: ErrorBody {
                    message: format!("invalid request: {e}"),
                    error_type: "invalid_request_error".to_owned(),
                },
            };
            let json = serde_json::to_value(err).unwrap_or_default();
            return (axum::http::StatusCode::BAD_REQUEST, Json(json));
        }
    };

    let result = state.model.send_chat_request(req).await;

    let response = match result {
        Ok(resp) => resp,
        Err(e) => {
            let err = ErrorResponse {
                error: ErrorBody {
                    message: format!("inference failed: {e}"),
                    error_type: "server_error".to_owned(),
                },
            };
            let json = serde_json::to_value(err).unwrap_or_default();
            return (axum::http::StatusCode::INTERNAL_SERVER_ERROR, Json(json));
        }
    };

    // Extract content from the mistralrs response.
    let (content, tool_calls, finish_reason) = match response.choices.first() {
        Some(choice) => {
            let content = choice.message.content.as_deref().unwrap_or("");
            let content = strip_think_blocks(content);
            let tool_calls = choice.message.tool_calls.clone().filter(|v| !v.is_empty());
            let tool_calls = tool_calls.map(mistral_tool_calls_to_openai);
            (content, tool_calls, choice.finish_reason.clone())
        }
        None => (String::new(), None, "stop".to_owned()),
    };

    let resp = ChatCompletionResponse {
        id: completion_id(),
        object: "chat.completion".to_owned(),
        created: unix_timestamp(),
        model: state.model_id,
        choices: vec![Choice {
            index: 0,
            message: ChatMessage {
                role: "assistant".to_owned(),
                content: if content.trim().is_empty() {
                    None
                } else {
                    Some(ChatMessageContent::Text(content))
                },
                tool_calls,
                tool_call_id: None,
                name: None,
            },
            finish_reason: Some(finish_reason),
        }],
        usage: Usage {
            prompt_tokens: response.usage.prompt_tokens as u32,
            completion_tokens: response.usage.completion_tokens as u32,
            total_tokens: response.usage.total_tokens as u32,
        },
    };

    let json = serde_json::to_value(resp).unwrap_or_default();
    (axum::http::StatusCode::OK, Json(json))
}

/// Internal message type for the streaming channel.
enum StreamMsg {
    /// A delta chunk from the model (text and/or tool calls).
    Delta {
        content: Option<String>,
        tool_calls: Option<Vec<OpenAiToolCall>>,
    },
    /// Streaming is done (finish_reason).
    Done(String),
    /// An error occurred.
    Error(String),
}

/// Handle a streaming chat completion request via SSE.
///
/// Uses a channel to decouple the `mistralrs` stream lifetime (`Stream<'_>`)
/// from the SSE response lifetime. A background task holds the `Arc<Model>`
/// borrow and forwards tokens through a channel.
async fn handle_streaming(
    state: AppState,
    request: ChatCompletionRequest,
) -> Result<
    Sse<impl Stream<Item = Result<Event, std::convert::Infallible>>>,
    (axum::http::StatusCode, Json<ErrorResponse>),
> {
    let req = match build_request(&request) {
        Ok(r) => r,
        Err(e) => {
            let err = ErrorResponse {
                error: ErrorBody {
                    message: format!("invalid request: {e}"),
                    error_type: "invalid_request_error".to_owned(),
                },
            };
            return Err((axum::http::StatusCode::BAD_REQUEST, Json(err)));
        }
    };

    let model = Arc::clone(&state.model);
    let (tx, mut rx) = tokio::sync::mpsc::channel::<StreamMsg>(64);

    // Spawn a task that holds the Arc<Model> borrow and forwards tokens.
    tokio::spawn(async move {
        let stream = match model.stream_chat_request(req).await {
            Ok(s) => s,
            Err(e) => {
                let _ = tx.send(StreamMsg::Error(format!("stream init: {e}"))).await;
                return;
            }
        };

        let mut streamer = stream;
        let mut in_think_block = false;
        while let Some(response) = streamer.next().await {
            match response {
                Response::Chunk(chunk) => {
                    let Some(choice) = chunk.choices.first() else {
                        continue;
                    };

                    let tool_calls = choice.delta.tool_calls.clone().filter(|v| !v.is_empty());
                    let tool_calls = tool_calls.map(mistral_tool_calls_to_openai);

                    let mut content = choice.delta.content.clone();
                    if let Some(ref c) = content {
                        if c.is_empty() {
                            content = None;
                        } else if c.contains("<think>") {
                            in_think_block = true;
                            content = None;
                        } else if c.contains("</think>") {
                            in_think_block = false;
                            content = None;
                        } else if in_think_block {
                            content = None;
                        }
                    }

                    if content.is_none() && tool_calls.is_none() {
                        continue;
                    }

                    if tx
                        .send(StreamMsg::Delta {
                            content,
                            tool_calls,
                        })
                        .await
                        .is_err()
                    {
                        break;
                    }
                }
                Response::Done(_) => {
                    let _ = tx.send(StreamMsg::Done("stop".to_owned())).await;
                    break;
                }
                Response::ModelError(msg, _) => {
                    let _ = tx.send(StreamMsg::Error(msg)).await;
                    break;
                }
                Response::InternalError(e) => {
                    let _ = tx.send(StreamMsg::Error(e.to_string())).await;
                    break;
                }
                Response::ValidationError(e) => {
                    let _ = tx.send(StreamMsg::Error(e.to_string())).await;
                    break;
                }
                _ => {}
            }
        }
    });

    let id = completion_id();
    let created = unix_timestamp();
    let model_id = state.model_id.clone();

    let sse_stream = async_stream::stream! {
        // First chunk: send role
        let first_chunk = ChatCompletionChunk {
            id: id.clone(),
            object: "chat.completion.chunk".to_owned(),
            created,
            model: model_id.clone(),
            choices: vec![ChunkChoice {
                index: 0,
                delta: Delta {
                    role: Some("assistant".to_owned()),
                    content: None,
                    tool_calls: None,
                },
                finish_reason: None,
            }],
        };
        if let Ok(json) = serde_json::to_string(&first_chunk) {
            yield Ok(Event::default().data(json));
        }

        // Receive tokens from the background task
        while let Some(msg) = rx.recv().await {
            match msg {
                StreamMsg::Delta { content, tool_calls } => {
                    let sse_chunk = ChatCompletionChunk {
                        id: id.clone(),
                        object: "chat.completion.chunk".to_owned(),
                        created,
                        model: model_id.clone(),
                        choices: vec![ChunkChoice {
                            index: 0,
                            delta: Delta {
                                role: None,
                                content,
                                tool_calls,
                            },
                            finish_reason: None,
                        }],
                    };
                    if let Ok(json) = serde_json::to_string(&sse_chunk) {
                        yield Ok(Event::default().data(json));
                    }
                }
                StreamMsg::Done(reason) => {
                    let final_chunk = ChatCompletionChunk {
                        id: id.clone(),
                        object: "chat.completion.chunk".to_owned(),
                        created,
                        model: model_id.clone(),
                        choices: vec![ChunkChoice {
                            index: 0,
                            delta: Delta {
                                role: None,
                                content: None,
                                tool_calls: None,
                            },
                            finish_reason: Some(reason),
                        }],
                    };
                    if let Ok(json) = serde_json::to_string(&final_chunk) {
                        yield Ok(Event::default().data(json));
                    }
                    yield Ok(Event::default().data("[DONE]"));
                    break;
                }
                StreamMsg::Error(msg) => {
                    let err_json = serde_json::json!({
                        "error": {"message": msg, "type": "server_error"}
                    });
                    if let Ok(json) = serde_json::to_string(&err_json) {
                        yield Ok(Event::default().data(json));
                    }
                    break;
                }
            }
        }
    };

    Ok(Sse::new(sse_stream).keep_alive(KeepAlive::default()))
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;

    #[test]
    fn chat_completion_request_round_trip() {
        let req = ChatCompletionRequest {
            model: "fae-qwen3".to_owned(),
            messages: vec![
                ChatMessage {
                    role: "system".to_owned(),
                    content: Some(ChatMessageContent::Text("You are helpful.".to_owned())),
                    tool_calls: None,
                    tool_call_id: None,
                    name: None,
                },
                ChatMessage {
                    role: "user".to_owned(),
                    content: Some(ChatMessageContent::Text("Hello".to_owned())),
                    tool_calls: None,
                    tool_call_id: None,
                    name: None,
                },
            ],
            stream: Some(false),
            temperature: Some(0.7),
            top_p: Some(0.9),
            max_tokens: Some(200),
            max_completion_tokens: None,
            tools: None,
            tool_choice: None,
        };
        let json = serde_json::to_string(&req).unwrap();
        let parsed: ChatCompletionRequest = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.model, "fae-qwen3");
        assert_eq!(parsed.messages.len(), 2);
        assert_eq!(parsed.stream, Some(false));
        assert_eq!(parsed.temperature, Some(0.7));
    }

    #[test]
    fn chat_completion_request_optional_fields_default() {
        let json = r#"{"model":"test","messages":[{"role":"user","content":"hi"}]}"#;
        let req: ChatCompletionRequest = serde_json::from_str(json).unwrap();
        assert_eq!(req.model, "test");
        assert!(req.stream.is_none());
        assert!(req.temperature.is_none());
        assert!(req.top_p.is_none());
        assert!(req.max_tokens.is_none());
    }

    #[test]
    fn chat_completion_response_round_trip() {
        let resp = ChatCompletionResponse {
            id: "chatcmpl-abc123".to_owned(),
            object: "chat.completion".to_owned(),
            created: 1_700_000_000,
            model: "fae-qwen3".to_owned(),
            choices: vec![Choice {
                index: 0,
                message: ChatMessage {
                    role: "assistant".to_owned(),
                    content: Some(ChatMessageContent::Text("Hello!".to_owned())),
                    tool_calls: None,
                    tool_call_id: None,
                    name: None,
                },
                finish_reason: Some("stop".to_owned()),
            }],
            usage: Usage {
                prompt_tokens: 10,
                completion_tokens: 5,
                total_tokens: 15,
            },
        };
        let json = serde_json::to_string(&resp).unwrap();
        let parsed: ChatCompletionResponse = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.id, "chatcmpl-abc123");
        assert_eq!(parsed.choices.len(), 1);
        assert_eq!(
            parsed.choices[0]
                .message
                .content
                .as_ref()
                .map(ChatMessageContent::as_text)
                .as_deref(),
            Some("Hello!")
        );
        assert_eq!(parsed.usage.total_tokens, 15);
    }

    #[test]
    fn chat_completion_chunk_round_trip() {
        let chunk = ChatCompletionChunk {
            id: "chatcmpl-abc123".to_owned(),
            object: "chat.completion.chunk".to_owned(),
            created: 1_700_000_000,
            model: "fae-qwen3".to_owned(),
            choices: vec![ChunkChoice {
                index: 0,
                delta: Delta {
                    role: None,
                    content: Some("Hello".to_owned()),
                    tool_calls: None,
                },
                finish_reason: None,
            }],
        };
        let json = serde_json::to_string(&chunk).unwrap();
        let parsed: ChatCompletionChunk = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.id, "chatcmpl-abc123");
        assert_eq!(parsed.choices[0].delta.content.as_deref(), Some("Hello"));
        assert!(parsed.choices[0].delta.role.is_none());
    }

    #[test]
    fn delta_skips_none_fields() {
        let delta = Delta {
            role: None,
            content: Some("token".to_owned()),
            tool_calls: None,
        };
        let json = serde_json::to_string(&delta).unwrap();
        assert!(!json.contains("role"));
        assert!(json.contains("token"));
    }

    #[test]
    fn error_response_round_trip() {
        let err = ErrorResponse {
            error: ErrorBody {
                message: "something went wrong".to_owned(),
                error_type: "server_error".to_owned(),
            },
        };
        let json = serde_json::to_string(&err).unwrap();
        let parsed: ErrorResponse = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.error.message, "something went wrong");
        assert_eq!(parsed.error.error_type, "server_error");
    }

    #[test]
    fn model_list_response_round_trip() {
        let resp = ModelListResponse {
            object: "list".to_owned(),
            data: vec![ModelObject {
                id: "fae-qwen3".to_owned(),
                object: "model".to_owned(),
                owned_by: "fae-local".to_owned(),
            }],
        };
        let json = serde_json::to_string(&resp).unwrap();
        let parsed: ModelListResponse = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.object, "list");
        assert_eq!(parsed.data.len(), 1);
        assert_eq!(parsed.data[0].id, "fae-qwen3");
        assert_eq!(parsed.data[0].owned_by, "fae-local");
    }

    #[test]
    fn llm_server_config_defaults() {
        let config = LlmServerConfig::default();
        assert!(config.enabled);
        assert_eq!(config.port, 0);
        assert_eq!(config.host, "127.0.0.1");
    }

    #[test]
    fn llm_server_config_serde_round_trip() {
        let config = LlmServerConfig {
            enabled: false,
            port: 8080,
            host: "0.0.0.0".to_owned(),
        };
        let json = serde_json::to_string(&config).unwrap();
        let parsed: LlmServerConfig = serde_json::from_str(&json).unwrap();
        assert!(!parsed.enabled);
        assert_eq!(parsed.port, 8080);
        assert_eq!(parsed.host, "0.0.0.0");
    }

    #[test]
    fn model_id_constant_is_fae_qwen3() {
        assert_eq!(MODEL_ID, "fae-qwen3");
    }

    #[test]
    fn usage_round_trip() {
        let usage = Usage {
            prompt_tokens: 42,
            completion_tokens: 10,
            total_tokens: 52,
        };
        let json = serde_json::to_string(&usage).unwrap();
        let parsed: Usage = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.prompt_tokens, 42);
        assert_eq!(parsed.completion_tokens, 10);
        assert_eq!(parsed.total_tokens, 52);
    }

    #[test]
    fn strip_think_blocks_removes_thinking() {
        assert_eq!(
            strip_think_blocks("Hello <think>reasoning here</think>World"),
            "Hello World"
        );
    }

    #[test]
    fn strip_think_blocks_no_blocks() {
        assert_eq!(strip_think_blocks("Hello World"), "Hello World");
    }

    #[test]
    fn strip_think_blocks_unclosed() {
        assert_eq!(strip_think_blocks("Hello <think>never ends"), "Hello ");
    }

    #[test]
    fn strip_think_blocks_multiple() {
        assert_eq!(
            strip_think_blocks("A<think>1</think>B<think>2</think>C"),
            "ABC"
        );
    }

    #[test]
    fn completion_id_has_prefix() {
        let id = completion_id();
        assert!(id.starts_with("chatcmpl-"));
        assert!(id.len() > "chatcmpl-".len());
    }

    #[test]
    fn build_request_maps_roles() {
        let messages = vec![
            ChatMessage {
                role: "system".to_owned(),
                content: Some(ChatMessageContent::Text("You are helpful.".to_owned())),
                tool_calls: None,
                tool_call_id: None,
                name: None,
            },
            ChatMessage {
                role: "user".to_owned(),
                content: Some(ChatMessageContent::Text("Hello".to_owned())),
                tool_calls: None,
                tool_call_id: None,
                name: None,
            },
            ChatMessage {
                role: "assistant".to_owned(),
                content: Some(ChatMessageContent::Text("Hi there!".to_owned())),
                tool_calls: None,
                tool_call_id: None,
                name: None,
            },
        ];
        // Just verify it doesn't panic — the RequestBuilder is opaque.
        let req = ChatCompletionRequest {
            model: "fae-qwen3".to_owned(),
            messages,
            stream: Some(false),
            temperature: Some(0.5),
            top_p: Some(0.8),
            max_tokens: Some(100),
            max_completion_tokens: None,
            tools: None,
            tool_choice: None,
        };
        let _req = build_request(&req).unwrap();
    }
}
