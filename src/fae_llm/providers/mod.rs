//! LLM provider implementations.
//!
//! Each submodule implements the [`ProviderAdapter`](super::provider::ProviderAdapter) trait
//! for a specific LLM backend, normalizing provider-specific streaming
//! formats to the shared [`LlmEvent`](super::events::LlmEvent) model.
//!
//! # Available providers
//!
//! - [`message`] — Shared message types for all providers
//! - [`openai`] — OpenAI Chat Completions and Responses API
//! - [`anthropic`] — Anthropic Messages API
//! - [`local`] — Local mistralrs GGUF inference
//! - [`profile`] — Compatibility profiles for OpenAI-compatible providers
//! - [`local_probe`] — Health-check and model discovery for local endpoints

pub mod anthropic;
pub mod local;
pub mod local_probe;
pub mod message;
pub mod openai;
pub mod profile;
pub mod sse;

pub use local::{LocalMistralrsAdapter, LocalMistralrsConfig};

#[cfg(test)]
mod local_probe_tests;
#[cfg(test)]
mod profile_tests;
