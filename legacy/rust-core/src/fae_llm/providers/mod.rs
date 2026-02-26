//! LLM provider implementations.
//!
//! Each submodule implements the [`ProviderAdapter`](super::provider::ProviderAdapter) trait
//! for a specific LLM backend, normalizing provider-specific streaming
//! formats to the shared [`LlmEvent`](super::events::LlmEvent) model.
//!
//! # Available providers
//!
//! - [`message`] — Shared message types for all providers
//! - [`local`] — Local mistralrs GGUF inference (embedded models)

pub mod local;
pub mod message;

pub use local::{LocalMistralrsAdapter, LocalMistralrsConfig};
