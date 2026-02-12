//! Provider adapter trait for LLM backends.
//!
//! Defines the [`ProviderAdapter`] trait that all LLM provider implementations
//! must satisfy. Adapters convert provider-specific APIs into the shared
//! [`LlmEvent`](super::events::LlmEvent) streaming model.
//!
//! # Examples
//!
//! ```rust,no_run
//! use fae::fae_llm::provider::{ProviderAdapter, ToolDefinition};
//! use fae::fae_llm::providers::message::{Message, Role};
//! use fae::fae_llm::types::RequestOptions;
//!
//! async fn example(adapter: &dyn ProviderAdapter) {
//!     let messages = vec![
//!         Message::text(Role::User, "Hello"),
//!     ];
//!     let options = RequestOptions::new();
//!     let stream = adapter.send(&messages, &options, &[]).await;
//! }
//! ```

use std::pin::Pin;

use async_trait::async_trait;
use futures_util::Stream;
use serde::{Deserialize, Serialize};

use super::error::FaeLlmError;
use super::events::LlmEvent;
use super::types::RequestOptions;
use crate::fae_llm::providers::message::Message;

/// A tool definition provided to the LLM for function calling.
///
/// Contains the metadata the model needs to decide when and how to
/// invoke a tool.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolDefinition {
    /// The tool name (e.g. `"read"`, `"bash"`).
    pub name: String,
    /// Human-readable description of the tool's purpose.
    pub description: String,
    /// JSON Schema describing the tool's parameters.
    pub parameters: serde_json::Value,
}

impl ToolDefinition {
    /// Create a new tool definition.
    pub fn new(
        name: impl Into<String>,
        description: impl Into<String>,
        parameters: serde_json::Value,
    ) -> Self {
        Self {
            name: name.into(),
            description: description.into(),
            parameters,
        }
    }
}

/// A boxed stream of LLM events.
pub type LlmEventStream = Pin<Box<dyn Stream<Item = LlmEvent> + Send>>;

/// Trait for LLM provider adapters.
///
/// Each provider (OpenAI, Anthropic, local endpoints) implements this trait
/// to normalize its streaming API into the shared [`LlmEvent`] model.
#[async_trait]
pub trait ProviderAdapter: Send + Sync {
    /// Returns the provider name (e.g. `"openai"`, `"anthropic"`).
    fn name(&self) -> &str;

    /// Send a request to the LLM and return a stream of normalized events.
    ///
    /// # Arguments
    ///
    /// * `messages` - The conversation history
    /// * `options` - Generation parameters (temperature, max_tokens, etc.)
    /// * `tools` - Available tools the model may call
    ///
    /// # Errors
    ///
    /// Returns `FaeLlmError` if the request cannot be initiated (auth, network, etc.).
    /// Stream-level errors are delivered as [`LlmEvent::StreamError`].
    async fn send(
        &self,
        messages: &[Message],
        options: &RequestOptions,
        tools: &[ToolDefinition],
    ) -> Result<LlmEventStream, FaeLlmError>;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_definition_new() {
        let tool = ToolDefinition::new(
            "read",
            "Read a file",
            serde_json::json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string" }
                },
                "required": ["path"]
            }),
        );
        assert_eq!(tool.name, "read");
        assert_eq!(tool.description, "Read a file");
        assert!(tool.parameters.is_object());
    }

    #[test]
    fn tool_definition_serde_round_trip() {
        let original = ToolDefinition::new(
            "bash",
            "Run a shell command",
            serde_json::json!({
                "type": "object",
                "properties": {
                    "command": { "type": "string" }
                }
            }),
        );
        let json = serde_json::to_string(&original).unwrap_or_default();
        let parsed: Result<ToolDefinition, _> = serde_json::from_str(&json);
        assert!(parsed.is_ok());
        match parsed {
            Ok(t) => {
                assert_eq!(t.name, "bash");
                assert_eq!(t.description, "Run a shell command");
            }
            Err(_) => unreachable!("deserialization succeeded"),
        }
    }

    #[test]
    fn tool_definition_clone() {
        let tool = ToolDefinition::new("edit", "Edit a file", serde_json::json!({}));
        let cloned = tool.clone();
        assert_eq!(tool.name, cloned.name);
        assert_eq!(tool.description, cloned.description);
    }

    #[test]
    fn tool_definition_debug() {
        let tool = ToolDefinition::new("write", "Write a file", serde_json::json!({}));
        let debug = format!("{tool:?}");
        assert!(debug.contains("write"));
        assert!(debug.contains("Write a file"));
    }
}
