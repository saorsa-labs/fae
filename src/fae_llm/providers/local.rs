//! Local mistralrs provider adapter.
//!
//! Provides a fae_llm ProviderAdapter implementation for local GGUF model inference
//! via mistralrs. This enables the Agent backend to use local Qwen3 models.

use async_trait::async_trait;
use std::sync::Arc;

use crate::fae_llm::LlmEventStream;
use crate::fae_llm::error::FaeLlmError;
use crate::fae_llm::events::{FinishReason, LlmEvent};
use crate::fae_llm::provider::ProviderAdapter;
use crate::fae_llm::providers::message::Message;
use crate::fae_llm::types::{EndpointType, ModelRef, RequestOptions};

/// Configuration for the local mistralrs provider.
#[derive(Clone)]
pub struct LocalMistralrsConfig {
    /// The mistralrs Model instance.
    pub model: Arc<mistralrs::Model>,
    /// Model ID (e.g., "qwen3-4b").
    pub model_id: String,
    /// Maximum tokens to generate.
    pub max_tokens: usize,
    /// Sampling temperature.
    pub temperature: f32,
    /// Nucleus sampling threshold.
    pub top_p: f32,
}

impl LocalMistralrsConfig {
    /// Create a new config.
    pub fn new(model: Arc<mistralrs::Model>, model_id: impl Into<String>) -> Self {
        Self {
            model,
            model_id: model_id.into(),
            max_tokens: 2048,
            temperature: 0.7,
            top_p: 0.9,
        }
    }

    /// Set max tokens.
    pub fn with_max_tokens(mut self, max: usize) -> Self {
        self.max_tokens = max;
        self
    }

    /// Set temperature.
    pub fn with_temperature(mut self, temp: f32) -> Self {
        self.temperature = temp;
        self
    }

    /// Set top_p.
    pub fn with_top_p(mut self, top_p: f32) -> Self {
        self.top_p = top_p;
        self
    }
}

/// Local mistralrs provider adapter.
///
/// Wraps a mistralrs Model and implements the ProviderAdapter trait
/// so it can be used by the fae_llm agent loop.
pub struct LocalMistralrsAdapter {
    config: LocalMistralrsConfig,
}

impl LocalMistralrsAdapter {
    /// Create a new adapter.
    pub fn new(config: LocalMistralrsConfig) -> Self {
        Self { config }
    }
}

impl std::fmt::Debug for LocalMistralrsAdapter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("LocalMistralrsAdapter")
            .field("model_id", &self.config.model_id)
            .finish()
    }
}

#[async_trait]
impl ProviderAdapter for LocalMistralrsAdapter {
    fn name(&self) -> &str {
        "mistralrs"
    }

    fn endpoint_type(&self) -> EndpointType {
        EndpointType::Local
    }

    async fn send(
        &self,
        messages: &[Message],
        _options: &RequestOptions,
        _tools: &[crate::fae_llm::provider::ToolDefinition],
    ) -> std::result::Result<LlmEventStream, FaeLlmError> {
        // Convert fae_llm messages to mistralrs format
        let mut mistral_messages = mistralrs::TextMessages::new().enable_thinking(false);

        for msg in messages {
            let role = match msg.role {
                crate::fae_llm::providers::message::Role::System => {
                    mistralrs::TextMessageRole::System
                }
                crate::fae_llm::providers::message::Role::User => mistralrs::TextMessageRole::User,
                crate::fae_llm::providers::message::Role::Assistant => {
                    mistralrs::TextMessageRole::Assistant
                }
                crate::fae_llm::providers::message::Role::Tool => continue,
            };

            let content = match &msg.content {
                crate::fae_llm::providers::message::MessageContent::Text { text } => text.clone(),
                crate::fae_llm::providers::message::MessageContent::ToolResult { .. } => continue,
            };
            mistral_messages = mistral_messages.add_message(role, &content);
        }

        // Build request
        let request = mistralrs::RequestBuilder::from(mistral_messages)
            .set_sampler_temperature(self.config.temperature as f64)
            .set_sampler_topp(self.config.top_p as f64)
            .set_sampler_max_len(self.config.max_tokens);

        // Start streaming - get the stream synchronously first
        let model = Arc::clone(&self.config.model);
        let model_id = self.config.model_id.clone();

        let mut stream = model
            .stream_chat_request(request)
            .await
            .map_err(|e| FaeLlmError::RequestError(format!("mistralrs stream failed: {e}")))?;

        // Create a simple in-memory stream using futures_util
        let mut all_events = vec![LlmEvent::StreamStart {
            request_id: uuid::Uuid::new_v4().to_string(),
            model: ModelRef::new(&model_id),
        }];

        // Collect all responses
        while let Some(response) = stream.next().await {
            let event = match response {
                mistralrs::Response::Chunk(chunk) => {
                    if let Some(choice) = chunk.choices.first() {
                        if let Some(ref content) = choice.delta.content {
                            LlmEvent::TextDelta {
                                text: content.clone(),
                            }
                        } else {
                            continue;
                        }
                    } else {
                        continue;
                    }
                }
                mistralrs::Response::Done(_) => LlmEvent::StreamEnd {
                    finish_reason: FinishReason::Stop,
                },
                mistralrs::Response::ModelError(msg, _) => LlmEvent::StreamError { error: msg },
                _ => continue,
            };
            all_events.push(event);
        }

        // Return as stream
        Ok(Box::pin(futures_util::stream::iter(all_events)))
    }
}
