//! `fae-engine` — the local inference boundary for the Fae daemon.
//!
//! Two pieces land in chunk 3a, both engine-agnostic and fully tested before the
//! heavy mistral.rs adapter (chunk 3b) is wired:
//!
//! - [`ProviderAdapter`] — the trait every backend (mistral.rs primary,
//!   llama.cpp fallback) implements: stream a chat completion as token / tool-
//!   call events. The daemon holds a `dyn ProviderAdapter` so the backend is
//!   swappable.
//! - [`ModelsLock`] — a **fail-closed** `models.lock` loader: a model is never
//!   loaded unless its file matches the pinned size + SHA-256 in the lock. A
//!   missing file, a size/hash mismatch, or even a placeholder (non-hex) hash
//!   aborts the load.
//!
//! [`MockAdapter`] is a deterministic implementation used by tests and to wire
//! the daemon's conversation path end-to-end before the real engine exists.
#![forbid(unsafe_code)]
#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]
#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used, clippy::panic))]

mod llamacpp_adapter;
mod mistralrs_adapter;
mod mock;
mod models_lock;
mod provider;
mod tts;
#[cfg(target_os = "macos")]
mod voice_tts_adapter;

pub use llamacpp_adapter::{
    kill_all_registered_sidecars, LazyLlamaServerAdapter, LlamaModelSource, LlamaServerAdapter,
    LlamaServerConfig, LlamaServerHandle, RemoteModelArtifact,
};
pub use mistralrs_adapter::LocalMistralrsAdapter;
pub use mock::MockAdapter;
pub use models_lock::{Artifact, LockError, ModelsLock, SUPPORTED_SCHEMA_VERSION};
pub use provider::{
    AdapterInfo, ChatEvent, ChatMessage, ChatRequest, ChatStream, EngineError, LoadedAdapter,
    ProviderAdapter, Role, ToolSpec,
};
pub use tts::{encode_wav_pcm16, MockTtsAdapter, TtsAdapter, TtsAudio};
#[cfg(target_os = "macos")]
pub use voice_tts_adapter::VoiceTtsAdapter;
