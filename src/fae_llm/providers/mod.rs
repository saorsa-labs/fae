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
//! - [`profile`] — Compatibility profiles for OpenAI-compatible providers

pub mod message;
pub mod openai;
pub mod profile;
pub mod sse;
