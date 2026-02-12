//! Provider adapter trait for LLM backends.
//!
//! Defines the [`ProviderAdapter`] trait that all LLM provider implementations
//! satisfy. Adapters normalize provider-specific APIs into the shared
//! [`LlmEvent`](crate::fae_llm::events::LlmEvent) stream.

use std::pin::Pin;

use async_trait::async_trait;
use futures_util::{Stream, StreamExt};
use serde::{Deserialize, Serialize};

use super::error::FaeLlmError;
use super::events::{AssistantEvent, LlmEvent};
use super::types::{EndpointType, ModelRef, RequestOptions};
use crate::fae_llm::providers::message::Message;

/// Stable alias for provider-facing error type.
pub type LlmError = FaeLlmError;

/// A tool definition provided to the LLM for function calling.
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

/// Provider-neutral context passed to the v1+ streaming contract.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ConversationContext {
    /// Conversation messages in provider-neutral form.
    #[serde(default)]
    pub messages: Vec<Message>,
    /// Tools available to the model.
    #[serde(default)]
    pub tools: Vec<ToolDefinition>,
}

impl ConversationContext {
    /// Create a context from message history.
    pub fn from_messages(messages: Vec<Message>) -> Self {
        Self {
            messages,
            tools: Vec::new(),
        }
    }

    /// Attach tool definitions.
    pub fn with_tools(mut self, tools: Vec<ToolDefinition>) -> Self {
        self.tools = tools;
        self
    }
}

/// A boxed stream of normalized LLM events.
pub type LlmEventStream = Pin<Box<dyn Stream<Item = LlmEvent> + Send>>;

/// Alias for the locked API name.
pub type AssistantEventStream = Pin<Box<dyn Stream<Item = AssistantEvent> + Send>>;

/// Trait for LLM provider adapters.
#[async_trait]
pub trait ProviderAdapter: Send + Sync {
    /// Returns the provider name (e.g. `"openai"`, `"anthropic"`).
    fn name(&self) -> &str;

    /// Returns the endpoint contract for this adapter.
    fn endpoint_type(&self) -> EndpointType {
        EndpointType::OpenAiCompletions
    }

    /// Legacy send contract used by the existing agent loop.
    async fn send(
        &self,
        messages: &[Message],
        options: &RequestOptions,
        tools: &[ToolDefinition],
    ) -> Result<LlmEventStream, FaeLlmError>;

    /// Locked streaming contract.
    ///
    /// Default behavior forwards to [`send`](Self::send), preserving backward
    /// compatibility while exposing the new API.
    async fn stream(
        &self,
        _model: &ModelRef,
        context: &ConversationContext,
        options: &RequestOptions,
    ) -> Result<AssistantEventStream, LlmError> {
        let legacy_stream = self
            .send(&context.messages, options, &context.tools)
            .await?;
        let normalized =
            legacy_stream.flat_map(|event| futures_util::stream::iter(event.to_assistant_events()));
        Ok(Box::pin(normalized))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fae_llm::events::FinishReason;
    use crate::fae_llm::types::ModelRef;
    use futures_util::StreamExt;

    struct NoopProvider;

    #[async_trait]
    impl ProviderAdapter for NoopProvider {
        fn name(&self) -> &str {
            "noop"
        }

        fn endpoint_type(&self) -> EndpointType {
            EndpointType::AnthropicMessages
        }

        async fn send(
            &self,
            _messages: &[Message],
            _options: &RequestOptions,
            _tools: &[ToolDefinition],
        ) -> Result<LlmEventStream, FaeLlmError> {
            let events = vec![LlmEvent::StreamEnd {
                finish_reason: FinishReason::Stop,
            }];
            Ok(Box::pin(futures_util::stream::iter(events)))
        }
    }

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

    #[tokio::test]
    async fn stream_default_forwards_to_send() {
        let provider = NoopProvider;
        let model = ModelRef::new("test");
        let context = ConversationContext::from_messages(vec![Message::user("hello")]);
        let mut stream = provider
            .stream(&model, &context, &RequestOptions::new())
            .await
            .unwrap_or_else(|_| Box::pin(futures_util::stream::empty()));

        let next = stream.next().await;
        assert!(matches!(next, Some(AssistantEvent::Done { .. })));
    }
}
