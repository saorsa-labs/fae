//! LLM provider implementations.
//!
//! Each submodule implements the [`ProviderAdapter`](super::provider::ProviderAdapter) trait
//! for a specific LLM backend, normalizing provider-specific streaming
//! formats to the shared [`LlmEvent`](super::events::LlmEvent) model.
//!
//! # Available providers
//!
//! - [`message`] — Shared message types for all providers
//! - `openai` — OpenAI Chat Completions and Responses API (Phase 2.1)

pub mod message;
