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

use axum::extract::State;
use axum::response::Json;
use axum::routing::{get, post};
use axum::Router;
use mistralrs::Model;
use serde::{Deserialize, Serialize};
use std::net::SocketAddr;
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio::task::JoinHandle;
use tracing::info;

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

// ---------------------------------------------------------------------------
// Server configuration
// ---------------------------------------------------------------------------

/// Configuration for the local LLM HTTP server.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct LlmServerConfig {
    /// Whether the server is enabled.
    pub enabled: bool,
    /// Port to bind on. Use `0` for automatic assignment.
    pub port: u16,
    /// Host address to bind on (default: `127.0.0.1`).
    pub host: String,
}

impl Default for LlmServerConfig {
    fn default() -> Self {
        Self {
            enabled: true,
            port: 0,
            host: "127.0.0.1".to_owned(),
        }
    }
}

/// Default model ID exposed by the server.
const MODEL_ID: &str = "fae-qwen3";

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

        let addr = listener
            .local_addr()
            .map_err(|e| crate::error::SpeechError::Llm(format!("failed to get local addr: {e}")))?;

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

/// `POST /v1/chat/completions` — chat completions (placeholder, implemented in Task 3).
async fn handle_chat_completions(
    State(state): State<AppState>,
    Json(_request): Json<ChatCompletionRequest>,
) -> (axum::http::StatusCode, Json<ErrorResponse>) {
    // Reference the model to prove it's wired through state.
    let _model = &state.model;
    (
        axum::http::StatusCode::NOT_IMPLEMENTED,
        Json(ErrorResponse {
            error: ErrorBody {
                message: "chat completions not yet implemented".to_owned(),
                error_type: "not_implemented".to_owned(),
            },
        }),
    )
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
}
