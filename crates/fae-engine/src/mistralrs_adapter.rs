//! `LocalMistralrsAdapter` — the primary backend, wrapping mistral.rs 0.8.
//!
//! Ported from the S13 eval harness (`bench/mistralrs-eval/`, which proved
//! mistral.rs + candle + Metal builds and that E4B / Qwen3-14B-dense generate +
//! tool-call cleanly on this hardware). The streaming `Response` → [`ChatEvent`]
//! mapping is the same one the harness validated.

use std::sync::Arc;

use async_trait::async_trait;
use mistralrs::{
    IsqType, RequestBuilder, Response, TextMessageRole, TextModelBuilder, Tool, ToolChoice,
};

use crate::provider::{
    AdapterInfo, ChatEvent, ChatRequest, ChatStream, EngineError, ProviderAdapter, Role,
};

/// A loaded mistral.rs text model behind the [`ProviderAdapter`] contract. The
/// model is `Arc`-held so a clone can be moved into each per-turn stream (whose
/// lifetime is independent of `&self`).
pub struct LocalMistralrsAdapter {
    model: Arc<mistralrs::Model>,
    info: AdapterInfo,
}

impl LocalMistralrsAdapter {
    /// Load a text model by HuggingFace id with in-situ Q4K quantisation (the
    /// harness's working path). The caller is responsible for verifying the
    /// model against `models.lock` first (see [`crate::ModelsLock`]); this
    /// constructor performs the actual mistral.rs load.
    pub async fn load_text(model_id: &str) -> Result<LocalMistralrsAdapter, EngineError> {
        let model = TextModelBuilder::new(model_id)
            .with_isq(IsqType::Q4K)
            .with_logging()
            .build()
            .await
            .map_err(|error| EngineError::Load(error.to_string()))?;
        Ok(LocalMistralrsAdapter {
            model: Arc::new(model),
            info: AdapterInfo {
                backend: "mistralrs".to_owned(),
                model_id: model_id.to_owned(),
            },
        })
    }
}

#[async_trait]
impl ProviderAdapter for LocalMistralrsAdapter {
    fn describe(&self) -> AdapterInfo {
        self.info.clone()
    }

    async fn stream_chat(&self, request: ChatRequest) -> Result<ChatStream, EngineError> {
        let builder = build_request(&request)?;
        // Clone the Arc and drive the request *inside* the stream so the stream
        // owns the model — `stream_chat_request` borrows `&self`, so its result
        // cannot outlive `&self` otherwise (the returned `ChatStream` is 'static).
        let model = Arc::clone(&self.model);

        // Re-emit mistral.rs `Response`s as our backend-agnostic events. A single
        // chunk can carry both content and tool calls, so `async_stream` (which
        // lets us `yield` more than once per poll) is the natural fit.
        let mapped = async_stream::stream! {
            let mut inner = match model.stream_chat_request(builder).await {
                Ok(inner) => inner,
                Err(error) => {
                    yield Err(EngineError::Inference(error.to_string()));
                    return;
                }
            };
            while let Some(response) = inner.next().await {
                match response {
                    Response::Chunk(chunk) => {
                        if let Some(choice) = chunk.choices.first() {
                            if let Some(text) = &choice.delta.content {
                                if !text.is_empty() {
                                    yield Ok(ChatEvent::Token(text.clone()));
                                }
                            }
                            if let Some(calls) = &choice.delta.tool_calls {
                                for call in calls {
                                    yield Ok(ChatEvent::ToolCall {
                                        name: call.function.name.clone(),
                                        arguments: call.function.arguments.clone(),
                                    });
                                }
                            }
                        }
                    }
                    Response::Done(_) => {
                        yield Ok(ChatEvent::Done { finish_reason: "stop".to_owned() });
                        break;
                    }
                    Response::InternalError(error) | Response::ValidationError(error) => {
                        yield Err(EngineError::Inference(error.to_string()));
                        break;
                    }
                    Response::ModelError(error, _) => {
                        yield Err(EngineError::Inference(error));
                        break;
                    }
                    _ => {}
                }
            }
        };
        Ok(Box::pin(mapped))
    }
}

fn map_role(role: Role) -> TextMessageRole {
    match role {
        Role::System => TextMessageRole::System,
        Role::User => TextMessageRole::User,
        Role::Assistant => TextMessageRole::Assistant,
        Role::Tool => TextMessageRole::Tool,
    }
}

/// Translate a [`ChatRequest`] into a mistral.rs `RequestBuilder` (system +
/// messages + tools). Pure — no model needed, so it is unit-tested directly.
fn build_request(request: &ChatRequest) -> Result<RequestBuilder, EngineError> {
    let mut builder = RequestBuilder::new();
    if let Some(system) = &request.system {
        builder = builder.add_message(TextMessageRole::System, system);
    }
    for message in &request.messages {
        builder = builder.add_message(map_role(message.role), &message.content);
    }
    if !request.tools.is_empty() {
        let mut tools = Vec::with_capacity(request.tools.len());
        for spec in &request.tools {
            let value = serde_json::json!({
                "type": "function",
                "function": {
                    "name": spec.name,
                    "description": spec.description,
                    "parameters": spec.parameters,
                }
            });
            let tool: Tool = serde_json::from_value(value).map_err(|error| {
                EngineError::Inference(format!("tool spec {}: {error}", spec.name))
            })?;
            tools.push(tool);
        }
        builder = builder.set_tools(tools).set_tool_choice(ToolChoice::Auto);
    }
    Ok(builder)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider::{ChatMessage, ToolSpec};

    fn weather_tool() -> ToolSpec {
        ToolSpec {
            name: "get_weather".to_owned(),
            description: "Get the weather for a city".to_owned(),
            parameters: serde_json::json!({
                "type": "object",
                "properties": { "city": { "type": "string" } },
                "required": ["city"]
            }),
        }
    }

    #[test]
    fn build_request_maps_system_messages_and_tools() {
        // Exercises the pure request translation without loading a model — a
        // malformed tool spec is the only error path and it must not panic.
        let request = ChatRequest {
            system: Some("You are Fae.".to_owned()),
            messages: vec![
                ChatMessage {
                    role: Role::User,
                    content: "weather in Paris?".to_owned(),
                },
                ChatMessage {
                    role: Role::Assistant,
                    content: "checking".to_owned(),
                },
            ],
            tools: vec![weather_tool()],
            max_tokens: 128,
        };
        assert!(build_request(&request).is_ok());
    }

    #[test]
    fn build_request_without_tools_is_ok() {
        let request = ChatRequest {
            system: None,
            messages: vec![ChatMessage {
                role: Role::User,
                content: "hi".to_owned(),
            }],
            tools: Vec::new(),
            max_tokens: 32,
        };
        assert!(build_request(&request).is_ok());
    }
}
