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
use mistralrs::{Model, RequestBuilder, Response, TextMessageRole, TextMessages};
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
}

/// A single message in a chat conversation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatMessage {
    /// The role of the message author (`system`, `user`, `assistant`).
    pub role: String,
    /// The content of the message.
    pub content: String,
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
fn build_request(
    messages: &[ChatMessage],
    temperature: Option<f64>,
    top_p: Option<f64>,
    max_tokens: Option<usize>,
) -> RequestBuilder {
    let mut text_messages = TextMessages::new().enable_thinking(false);
    for msg in messages {
        let role = match msg.role.as_str() {
            "system" => TextMessageRole::System,
            "assistant" => TextMessageRole::Assistant,
            _ => TextMessageRole::User,
        };
        text_messages = text_messages.add_message(role, &msg.content);
    }

    RequestBuilder::from(text_messages)
        .set_sampler_temperature(temperature.unwrap_or(DEFAULT_TEMPERATURE))
        .set_sampler_topp(top_p.unwrap_or(DEFAULT_TOP_P))
        .set_sampler_max_len(max_tokens.unwrap_or(DEFAULT_MAX_TOKENS))
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
    let req = build_request(
        &request.messages,
        request.temperature,
        request.top_p,
        request.max_tokens,
    );

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
    let content = response
        .choices
        .first()
        .and_then(|c| c.message.content.as_deref())
        .unwrap_or("");

    let content = strip_think_blocks(content);
    let finish_reason = response
        .choices
        .first()
        .map(|c| c.finish_reason.clone())
        .unwrap_or_else(|| "stop".to_owned());

    let resp = ChatCompletionResponse {
        id: completion_id(),
        object: "chat.completion".to_owned(),
        created: unix_timestamp(),
        model: state.model_id,
        choices: vec![Choice {
            index: 0,
            message: ChatMessage {
                role: "assistant".to_owned(),
                content,
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
    /// A token chunk from the model.
    Token(String),
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
    let req = build_request(
        &request.messages,
        request.temperature,
        request.top_p,
        request.max_tokens,
    );

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
                    if let Some(choice) = chunk.choices.first()
                        && let Some(ref content) = choice.delta.content
                    {
                        if content.is_empty() {
                            continue;
                        }
                        if content.contains("<think>") {
                            in_think_block = true;
                            continue;
                        }
                        if content.contains("</think>") {
                            in_think_block = false;
                            continue;
                        }
                        if in_think_block {
                            continue;
                        }
                        if tx.send(StreamMsg::Token(content.clone())).await.is_err() {
                            break;
                        }
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
                StreamMsg::Token(content) => {
                    let sse_chunk = ChatCompletionChunk {
                        id: id.clone(),
                        object: "chat.completion.chunk".to_owned(),
                        created,
                        model: model_id.clone(),
                        choices: vec![ChunkChoice {
                            index: 0,
                            delta: Delta {
                                role: None,
                                content: Some(content),
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
                    content: "You are helpful.".to_owned(),
                },
                ChatMessage {
                    role: "user".to_owned(),
                    content: "Hello".to_owned(),
                },
            ],
            stream: Some(false),
            temperature: Some(0.7),
            top_p: Some(0.9),
            max_tokens: Some(200),
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
                    content: "Hello!".to_owned(),
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
        assert_eq!(parsed.choices[0].message.content, "Hello!");
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
                content: "You are helpful.".to_owned(),
            },
            ChatMessage {
                role: "user".to_owned(),
                content: "Hello".to_owned(),
            },
            ChatMessage {
                role: "assistant".to_owned(),
                content: "Hi there!".to_owned(),
            },
        ];
        // Just verify it doesn't panic — the RequestBuilder is opaque.
        let _req = build_request(&messages, Some(0.5), Some(0.8), Some(100));
    }
}
