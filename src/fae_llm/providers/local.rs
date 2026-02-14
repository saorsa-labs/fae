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
        tools: &[crate::fae_llm::provider::ToolDefinition],
    ) -> std::result::Result<LlmEventStream, FaeLlmError> {
        // Build request directly via RequestBuilder to support tool messages
        let mut request = mistralrs::RequestBuilder::new();

        tracing::debug!(
            "building mistralrs request with {} messages",
            messages.len()
        );
        for msg in messages {
            tracing::debug!(role = ?msg.role, content_type = ?std::mem::discriminant(&msg.content), "adding message");
            match (&msg.role, &msg.content) {
                // Tool result messages use the dedicated add_tool_message API
                (
                    crate::fae_llm::providers::message::Role::Tool,
                    crate::fae_llm::providers::message::MessageContent::ToolResult {
                        call_id,
                        content,
                    },
                ) => {
                    request = request.add_tool_message(content, call_id);
                }
                // Skip tool-role messages without proper ToolResult content
                (crate::fae_llm::providers::message::Role::Tool, _) => continue,
                // Assistant messages with tool calls
                (crate::fae_llm::providers::message::Role::Assistant, _)
                    if !msg.tool_calls.is_empty() =>
                {
                    let text = match &msg.content {
                        crate::fae_llm::providers::message::MessageContent::Text { text } => {
                            text.clone()
                        }
                        _ => String::new(),
                    };
                    let tool_call_responses: Vec<mistralrs::ToolCallResponse> = msg
                        .tool_calls
                        .iter()
                        .enumerate()
                        .map(|(i, tc)| mistralrs::ToolCallResponse {
                            index: i,
                            id: tc.call_id.clone(),
                            tp: mistralrs::ToolCallType::Function,
                            function: mistralrs::CalledFunction {
                                name: tc.function_name.clone(),
                                arguments: tc.arguments.clone(),
                            },
                        })
                        .collect();
                    request = request.add_message_with_tool_call(
                        mistralrs::TextMessageRole::Assistant,
                        text,
                        tool_call_responses,
                    );
                }
                // Regular text messages (system, user, assistant without tool calls)
                (role, content) => {
                    let mistral_role = match role {
                        crate::fae_llm::providers::message::Role::System => {
                            mistralrs::TextMessageRole::System
                        }
                        crate::fae_llm::providers::message::Role::User => {
                            mistralrs::TextMessageRole::User
                        }
                        crate::fae_llm::providers::message::Role::Assistant => {
                            mistralrs::TextMessageRole::Assistant
                        }
                        crate::fae_llm::providers::message::Role::Tool => continue,
                    };
                    let text = match content {
                        crate::fae_llm::providers::message::MessageContent::Text { text } => {
                            text.clone()
                        }
                        crate::fae_llm::providers::message::MessageContent::ToolResult {
                            content,
                            ..
                        } => content.clone(),
                    };
                    request = request.add_message(mistral_role, &text);
                }
            }
        }

        // Apply sampling parameters
        request = request
            .set_sampler_temperature(self.config.temperature as f64)
            .set_sampler_topp(self.config.top_p as f64)
            .set_sampler_max_len(self.config.max_tokens)
            .enable_thinking(false);

        // Convert fae_llm tool definitions to mistralrs format
        let mistral_tools: Vec<mistralrs::Tool> = tools
            .iter()
            .map(|t| {
                use std::collections::HashMap;
                let params: HashMap<String, serde_json::Value> = t
                    .parameters
                    .as_object()
                    .map(|o| o.iter().map(|(k, v)| (k.clone(), v.clone())).collect())
                    .unwrap_or_default();
                tracing::debug!(
                    tool_name = %t.name,
                    params = ?params,
                    "converting tool to mistralrs format"
                );
                mistralrs::Tool {
                    tp: mistralrs::ToolType::Function,
                    function: mistralrs::Function {
                        description: Some(t.description.clone()),
                        name: t.name.clone(),
                        parameters: Some(params),
                    },
                }
            })
            .collect();

        if !mistral_tools.is_empty() {
            tracing::info!(
                "passing {} tools to mistralrs: {:?}",
                mistral_tools.len(),
                mistral_tools
                    .iter()
                    .map(|t| &t.function.name)
                    .collect::<Vec<_>>()
            );
            // Log full tool definitions for debugging
            for tool in &mistral_tools {
                tracing::debug!(
                    tool_name = %tool.function.name,
                    tool_desc = ?tool.function.description,
                    tool_params = ?tool.function.parameters,
                    "tool definition"
                );
            }
            request = request
                .set_tools(mistral_tools)
                .set_tool_choice(mistralrs::ToolChoice::Auto);
        } else {
            tracing::warn!("no tools being passed to mistralrs!");
        }

        // Start streaming
        let model = Arc::clone(&self.config.model);
        let model_id = self.config.model_id.clone();

        let mut stream = model
            .stream_chat_request(request)
            .await
            .map_err(|e| FaeLlmError::RequestError(format!("mistralrs stream failed: {e}")))?;

        let mut all_events = vec![LlmEvent::StreamStart {
            request_id: uuid::Uuid::new_v4().to_string(),
            model: ModelRef::new(&model_id),
        }];

        // Track whether the model requested tool calls
        let mut has_tool_calls = false;
        let mut last_finish_reason: Option<String> = None;

        // Collect all responses, handling both text and tool call chunks
        while let Some(response) = stream.next().await {
            match response {
                mistralrs::Response::Chunk(chunk) => {
                    if let Some(choice) = chunk.choices.first() {
                        // Handle text content delta
                        if let Some(ref content) = choice.delta.content
                            && !content.is_empty()
                        {
                            all_events.push(LlmEvent::TextDelta {
                                text: content.clone(),
                            });
                        }

                        // Handle tool call deltas
                        if let Some(ref tool_calls) = choice.delta.tool_calls {
                            for tc in tool_calls {
                                has_tool_calls = true;
                                all_events.push(LlmEvent::ToolCallStart {
                                    call_id: tc.id.clone(),
                                    function_name: tc.function.name.clone(),
                                });
                                if !tc.function.arguments.is_empty() {
                                    all_events.push(LlmEvent::ToolCallArgsDelta {
                                        call_id: tc.id.clone(),
                                        args_fragment: tc.function.arguments.clone(),
                                    });
                                }
                                all_events.push(LlmEvent::ToolCallEnd {
                                    call_id: tc.id.clone(),
                                });
                            }
                        }

                        // Track finish reason from the chunk
                        if let Some(ref reason) = choice.finish_reason {
                            last_finish_reason = Some(reason.clone());
                        }
                    }
                }
                mistralrs::Response::Done(completion) => {
                    // Check the completion response for tool calls too (non-streaming path)
                    if let Some(choice) = completion.choices.first() {
                        tracing::debug!(
                            finish_reason = %choice.finish_reason,
                            has_tool_calls = ?choice.message.tool_calls.is_some(),
                            content_len = ?choice.message.content.as_ref().map(|c| c.len()),
                            "mistralrs Done response"
                        );
                        if let Some(ref tool_calls) = choice.message.tool_calls {
                            tracing::info!(
                                num_tool_calls = tool_calls.len(),
                                "model returned tool calls"
                            );
                            for tc in tool_calls {
                                tracing::debug!(
                                    tool_id = %tc.id,
                                    tool_name = %tc.function.name,
                                    tool_args = %tc.function.arguments,
                                    "tool call from model"
                                );
                                has_tool_calls = true;
                                all_events.push(LlmEvent::ToolCallStart {
                                    call_id: tc.id.clone(),
                                    function_name: tc.function.name.clone(),
                                });
                                if !tc.function.arguments.is_empty() {
                                    all_events.push(LlmEvent::ToolCallArgsDelta {
                                        call_id: tc.id.clone(),
                                        args_fragment: tc.function.arguments.clone(),
                                    });
                                }
                                all_events.push(LlmEvent::ToolCallEnd {
                                    call_id: tc.id.clone(),
                                });
                            }
                        }
                        // Also check text content in Done response
                        if let Some(ref content) = choice.message.content
                            && !content.is_empty()
                        {
                            tracing::debug!(
                                content = %content,
                                "Done response content"
                            );
                            all_events.push(LlmEvent::TextDelta {
                                text: content.clone(),
                            });
                        }
                        // Use finish_reason from the completed response
                        if choice.finish_reason == "tool_calls" {
                            has_tool_calls = true;
                        }
                        last_finish_reason = Some(choice.finish_reason.clone());
                    }
                    break;
                }
                mistralrs::Response::ModelError(msg, _) => {
                    all_events.push(LlmEvent::StreamError { error: msg });
                    break;
                }
                mistralrs::Response::InternalError(e) => {
                    all_events.push(LlmEvent::StreamError {
                        error: e.to_string(),
                    });
                    break;
                }
                mistralrs::Response::ValidationError(e) => {
                    all_events.push(LlmEvent::StreamError {
                        error: e.to_string(),
                    });
                    break;
                }
                _ => continue,
            }
        }

        // Determine the correct finish reason
        let finish_reason = if has_tool_calls {
            FinishReason::ToolCalls
        } else {
            match last_finish_reason.as_deref() {
                Some("tool_calls") => FinishReason::ToolCalls,
                Some("length") => FinishReason::Length,
                Some("content_filter") => FinishReason::ContentFilter,
                _ => FinishReason::Stop,
            }
        };

        // Collect text content for debugging
        let text_content: String = all_events
            .iter()
            .filter_map(|e| {
                if let LlmEvent::TextDelta { text } = e {
                    Some(text.as_str())
                } else {
                    None
                }
            })
            .collect();

        tracing::info!(
            "mistralrs response: {} events, finish_reason={}, has_tool_calls={}",
            all_events.len(),
            finish_reason,
            has_tool_calls,
        );
        tracing::debug!(
            response_text = %text_content,
            "full response text from model"
        );

        all_events.push(LlmEvent::StreamEnd { finish_reason });

        Ok(Box::pin(futures_util::stream::iter(all_events)))
    }
}
