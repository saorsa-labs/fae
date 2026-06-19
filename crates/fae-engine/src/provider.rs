//! The backend-agnostic inference contract.

use async_trait::async_trait;
use futures_util::stream::BoxStream;

use crate::models_lock::LockError;

/// Chat role. Mirrors the subset the daemon needs; the adapter maps these onto
/// the engine's own chat template.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    System,
    User,
    Assistant,
    Tool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatMessage {
    pub role: Role,
    pub content: String,
    /// Optional audio clip (base64-encoded WAV) attached to this message —
    /// the S18 push-to-talk path sends the user's speech directly to an
    /// audio-capable model (Gemma 4). `None` for ordinary text turns.
    pub audio_wav_base64: Option<String>,
}

impl ChatMessage {
    /// A plain text message (the common case).
    #[must_use]
    pub fn text(role: Role, content: impl Into<String>) -> ChatMessage {
        ChatMessage {
            role,
            content: content.into(),
            audio_wav_base64: None,
        }
    }

    /// Decode the attached audio clip, if any. Malformed base64 fails loud —
    /// a clip the engine cannot decode must never be silently dropped from
    /// the turn.
    pub fn decode_audio(&self) -> Result<Option<Vec<u8>>, EngineError> {
        use base64::Engine as _;
        match &self.audio_wav_base64 {
            None => Ok(None),
            Some(encoded) => base64::engine::general_purpose::STANDARD
                .decode(encoded)
                .map(Some)
                .map_err(|error| EngineError::Inference(format!("invalid audio base64: {error}"))),
        }
    }
}

/// A tool the model may call. `parameters` is a JSON Schema object.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ToolSpec {
    pub name: String,
    pub description: String,
    pub parameters: serde_json::Value,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatRequest {
    pub system: Option<String>,
    pub messages: Vec<ChatMessage>,
    pub tools: Vec<ToolSpec>,
    pub max_tokens: usize,
}

impl ChatRequest {
    /// The most recent user message, if any — convenience for adapters/tests.
    #[must_use]
    pub fn last_user(&self) -> Option<&str> {
        self.messages
            .iter()
            .rev()
            .find(|message| message.role == Role::User)
            .map(|message| message.content.as_str())
    }
}

/// One streamed step of a completion. The daemon forwards these as protocol
/// events; a turn is a sequence of `Token`/`ToolCall` ending in `Done`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChatEvent {
    Token(String),
    ToolCall { name: String, arguments: String },
    Done { finish_reason: String },
}

#[derive(Debug, thiserror::Error)]
pub enum EngineError {
    #[error("no model is loaded")]
    NotLoaded,
    #[error("model load failed: {0}")]
    Load(String),
    #[error("inference failed: {0}")]
    Inference(String),
    #[error(transparent)]
    Lock(#[from] LockError),
    /// A personal-adapter path was rejected before it reached `llama-server`:
    /// missing/unreadable file, or outside the confined personal-adapters
    /// directory. This is a remotely-reachable command (`engine.reload` over
    /// NDJSON), so an arbitrary absolute path must never be handed to the sidecar.
    #[error("adapter path rejected: {0}")]
    AdapterPath(String),
}

/// The personal LoRA adapter currently loaded into the serving sidecar — its
/// confined path, content hash, and live scale. Surfaced by `runtime.status`
/// so a deploy/rollback is auditable (which adapter, on or off). `None` when no
/// adapter is loaded (base model).
#[derive(Debug, Clone, PartialEq)]
pub struct LoadedAdapter {
    /// Absolute path of the loaded adapter GGUF (already confinement-checked).
    pub path: String,
    /// SHA-256 of the loaded GGUF — the local trust record for a runtime-built
    /// adapter that cannot be pinned in `models.lock` (it does not exist at
    /// build time).
    pub sha256: String,
    /// Live per-request scale: `0.0` = base (rolled back), `1.0` = personalized.
    pub scale: f32,
}

/// A stream of completion events. `'static` so it can be moved into a per-turn
/// task and forwarded over the transport.
pub type ChatStream = BoxStream<'static, Result<ChatEvent, EngineError>>;

/// What every backend implements. `Send + Sync` so a single adapter can be
/// shared (`Arc<dyn ProviderAdapter>`) across connection tasks.
#[async_trait]
pub trait ProviderAdapter: Send + Sync {
    /// Backend + model identity, for `runtime.status` and audit.
    fn describe(&self) -> AdapterInfo;

    /// Stream a chat completion. Errors before the first token surface here;
    /// errors mid-stream arrive as `Err` items in the stream.
    async fn stream_chat(&self, request: ChatRequest) -> Result<ChatStream, EngineError>;

    /// Set the active personal-LoRA scale: `0.0` = base model, `1.0` =
    /// personalized (gap B3). This is the validated instant-rollback / A-B
    /// toggle. Backends without a runtime adapter (mistral.rs, mock) ignore it
    /// via this default no-op; the llama.cpp lane applies it per request.
    fn set_adapter_scale(&self, _scale: f32) -> Result<(), EngineError> {
        Ok(())
    }

    /// Restart serving with a freshly-trained personal adapter (gap B3b deploy
    /// primitive). `personal_adapter` is a path to the new adapter, or `None` to
    /// reload base-only. Only a backend that manages its own serving process
    /// (the llama.cpp sidecar) supports this; others reject it via this default.
    async fn reload_adapter(&self, _personal_adapter: Option<String>) -> Result<(), EngineError> {
        Err(EngineError::Inference(
            "adapter reload is not supported by this backend".to_owned(),
        ))
    }

    /// The personal adapter currently loaded into the serving sidecar, if any
    /// (gap P3/C3). Backends without a runtime adapter return `None` via this
    /// default; the llama.cpp lane reports the confined path, content hash, and
    /// live scale so `runtime.status` can audit a deploy/rollback.
    fn loaded_adapter(&self) -> Option<LoadedAdapter> {
        None
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdapterInfo {
    pub backend: String,
    pub model_id: String,
}
