//! Local mistralrs provider adapter.
//!
//! Provides a fae_llm ProviderAdapter implementation for local GGUF model inference
//! via mistralrs. This enables the Agent backend to use local Qwen3 models.
//!
//! **Streaming**: Events are yielded in real-time as tokens arrive from
//! mistralrs, enabling TTS to begin speaking the first sentence while the
//! model is still generating. This is critical for perceived latency.

use async_trait::async_trait;
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio_stream::wrappers::ReceiverStream;

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
///
/// Events are streamed in real-time via a tokio channel so downstream
/// consumers (TTS, UI) receive tokens as they are generated rather than
/// waiting for the entire response to complete.
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
        options: &RequestOptions,
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

        // Apply per-request sampling, falling back to provider defaults.
        let temperature = options
            .temperature
            .unwrap_or(self.config.temperature as f64);
        let top_p = options.top_p.unwrap_or(self.config.top_p as f64);
        let max_tokens = options
            .max_tokens
            .map(|v| v as usize)
            .unwrap_or(self.config.max_tokens);

        request = request
            .set_sampler_temperature(temperature)
            .set_sampler_topp(top_p)
            .set_sampler_max_len(max_tokens)
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

        // Create a channel-backed stream so events are yielded in real-time
        // as tokens arrive from mistralrs, rather than collecting everything
        // into a Vec first (which would block TTS until generation completes).
        let model = Arc::clone(&self.config.model);
        let model_id = self.config.model_id.clone();
        let (tx, rx) = mpsc::channel::<LlmEvent>(64);

        // Spawn a background task that starts the mistralrs stream and
        // forwards events through the channel. Both the model reference
        // and the stream live inside this task to satisfy lifetime bounds.
        tokio::spawn(async move {
            // Start the mistralrs stream inside the spawned task so the
            // model Arc and the stream it borrows share the same lifetime.
            let mut mistral_stream = match model.stream_chat_request(request).await {
                Ok(s) => s,
                Err(e) => {
                    let _ = tx
                        .send(LlmEvent::StreamError {
                            error: format!("mistralrs stream failed: {e}"),
                        })
                        .await;
                    return;
                }
            };

            // Emit StreamStart so consumers know generation has begun.
            let request_id = uuid::Uuid::new_v4().to_string();
            if tx
                .send(LlmEvent::StreamStart {
                    request_id,
                    model: ModelRef::new(&model_id),
                })
                .await
                .is_err()
            {
                return;
            }

            let mut has_tool_calls = false;
            let mut last_finish_reason: Option<String> = None;
            let mut event_count: usize = 1; // StreamStart already sent

            while let Some(response) = mistral_stream.next().await {
                match response {
                    mistralrs::Response::Chunk(chunk) => {
                        if let Some(choice) = chunk.choices.first() {
                            // Forward text content delta immediately
                            if let Some(ref content) = choice.delta.content
                                && !content.is_empty()
                            {
                                event_count += 1;
                                if tx
                                    .send(LlmEvent::TextDelta {
                                        text: content.clone(),
                                    })
                                    .await
                                    .is_err()
                                {
                                    tracing::debug!("stream consumer dropped, stopping");
                                    return;
                                }
                            }

                            // Forward tool call deltas immediately
                            if let Some(ref tool_calls) = choice.delta.tool_calls {
                                for tc in tool_calls {
                                    has_tool_calls = true;
                                    let events = [
                                        LlmEvent::ToolCallStart {
                                            call_id: tc.id.clone(),
                                            function_name: tc.function.name.clone(),
                                        },
                                        LlmEvent::ToolCallArgsDelta {
                                            call_id: tc.id.clone(),
                                            args_fragment: tc.function.arguments.clone(),
                                        },
                                        LlmEvent::ToolCallEnd {
                                            call_id: tc.id.clone(),
                                        },
                                    ];
                                    for event in events {
                                        // Skip empty arg deltas
                                        if matches!(&event, LlmEvent::ToolCallArgsDelta { args_fragment, .. } if args_fragment.is_empty())
                                        {
                                            continue;
                                        }
                                        event_count += 1;
                                        if tx.send(event).await.is_err() {
                                            return;
                                        }
                                    }
                                }
                            }

                            if let Some(ref reason) = choice.finish_reason {
                                last_finish_reason = Some(reason.clone());
                            }
                        }
                    }
                    mistralrs::Response::Done(completion) => {
                        if let Some(choice) = completion.choices.first() {
                            tracing::debug!(
                                finish_reason = %choice.finish_reason,
                                has_tool_calls = ?choice.message.tool_calls.is_some(),
                                content_len = ?choice.message.content.as_ref().map(|c| c.len()),
                                "mistralrs Done response"
                            );
                            // Handle tool calls from Done response (non-streaming path)
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
                                    let events = [
                                        LlmEvent::ToolCallStart {
                                            call_id: tc.id.clone(),
                                            function_name: tc.function.name.clone(),
                                        },
                                        LlmEvent::ToolCallArgsDelta {
                                            call_id: tc.id.clone(),
                                            args_fragment: tc.function.arguments.clone(),
                                        },
                                        LlmEvent::ToolCallEnd {
                                            call_id: tc.id.clone(),
                                        },
                                    ];
                                    for event in events {
                                        if matches!(&event, LlmEvent::ToolCallArgsDelta { args_fragment, .. } if args_fragment.is_empty())
                                        {
                                            continue;
                                        }
                                        event_count += 1;
                                        if tx.send(event).await.is_err() {
                                            return;
                                        }
                                    }
                                }
                            }
                            // Handle text content from Done response
                            if let Some(ref content) = choice.message.content
                                && !content.is_empty()
                            {
                                tracing::debug!(
                                    content = %content,
                                    "Done response content"
                                );
                                event_count += 1;
                                let _ = tx
                                    .send(LlmEvent::TextDelta {
                                        text: content.clone(),
                                    })
                                    .await;
                            }
                            if choice.finish_reason == "tool_calls" {
                                has_tool_calls = true;
                            }
                            last_finish_reason = Some(choice.finish_reason.clone());
                        }
                        break;
                    }
                    mistralrs::Response::ModelError(msg, _) => {
                        event_count += 1;
                        let _ = tx.send(LlmEvent::StreamError { error: msg }).await;
                        break;
                    }
                    mistralrs::Response::InternalError(e) => {
                        event_count += 1;
                        let _ = tx
                            .send(LlmEvent::StreamError {
                                error: e.to_string(),
                            })
                            .await;
                        break;
                    }
                    mistralrs::Response::ValidationError(e) => {
                        event_count += 1;
                        let _ = tx
                            .send(LlmEvent::StreamError {
                                error: e.to_string(),
                            })
                            .await;
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

            tracing::info!(
                "mistralrs response complete: {} events, finish_reason={}, has_tool_calls={}",
                event_count,
                finish_reason,
                has_tool_calls,
            );

            let _ = tx.send(LlmEvent::StreamEnd { finish_reason }).await;
        });

        // Return a real streaming adapter backed by the channel receiver.
        // Each event is yielded as soon as the background task produces it.
        Ok(Box::pin(ReceiverStream::new(rx)))
    }
}
