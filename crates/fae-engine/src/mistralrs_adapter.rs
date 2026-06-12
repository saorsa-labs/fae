//! `LocalMistralrsAdapter` — the primary backend, wrapping mistral.rs 0.8.
//!
//! Ported from the S13 eval harness (`bench/mistralrs-eval/`, which proved
//! mistral.rs + candle + Metal builds and that E4B / Qwen3-14B-dense generate +
//! tool-call cleanly on this hardware). The streaming `Response` → [`ChatEvent`]
//! mapping is the same one the harness validated.

use std::sync::Arc;

use async_trait::async_trait;
use mistralrs::{
    AudioInput, IsqType, ModelBuilder, RequestBuilder, Response, TextMessageRole, TextModelBuilder,
    Tool, ToolChoice,
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
        // Prefix cache disabled: with audio-bearing requests (S18) a cache hit
        // across consecutive multimodal prompts corrupts the turn (observed as
        // "heard nothing" / instant empty replies). Correct over fast.
        let model = TextModelBuilder::new(model_id)
            .with_isq(configured_isq())
            .with_prefix_cache_n(None)
            .with_logging()
            .build()
            .await
            .map_err(|error| EngineError::Load(error.to_string()))?;
        Ok(Self::wrap(model, model_id))
    }

    /// Load via the auto-detecting `ModelBuilder`. Required for architectures
    /// registered as conditional-generation classes — Gemma 4 (E2B/E4B) is
    /// `Gemma4ForConditionalGeneration`, which `TextModelBuilder` refuses.
    /// Same Q4K ISQ path; the S13 harness validated Gemma-4 through this
    /// loader ("auto-detect loader — needed for multimodal models").
    pub async fn load_auto(model_id: &str) -> Result<LocalMistralrsAdapter, EngineError> {
        // Prefix cache disabled — same audio-correctness rationale as
        // [`Self::load_text`].
        let model = ModelBuilder::new(model_id)
            .with_isq(configured_isq())
            .with_prefix_cache_n(None)
            .with_logging()
            .build()
            .await
            .map_err(|error| EngineError::Load(error.to_string()))?;
        Ok(Self::wrap(model, model_id))
    }

    /// Try the plain text loader first, then fall back to the auto-detect
    /// loader when the architecture is a conditional-generation class. This is
    /// the daemon's default load path: correct for both dense text models and
    /// Gemma-4-style multimodal registrations, with one download either way.
    pub async fn load(model_id: &str) -> Result<LocalMistralrsAdapter, EngineError> {
        match Self::load_text(model_id).await {
            Ok(adapter) => Ok(adapter),
            Err(EngineError::Load(reason)) if reason.contains("ForConditionalGeneration") => {
                Self::load_auto(model_id).await
            }
            Err(error) => Err(error),
        }
    }

    fn wrap(model: mistralrs::Model, model_id: &str) -> LocalMistralrsAdapter {
        LocalMistralrsAdapter {
            model: Arc::new(model),
            info: AdapterInfo {
                backend: "mistralrs".to_owned(),
                model_id: model_id.to_owned(),
            },
        }
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

/// In-situ quantisation type, `FAE_ISQ` env override. Q4K is the proven
/// default; Q8_0 trades ~2x weight RAM for higher numeric headroom — under
/// test as a cure for the Metal NaN-logits-at-specific-prompt-lengths bug.
fn configured_isq() -> IsqType {
    match std::env::var("FAE_ISQ").as_deref() {
        Ok("Q8_0") | Ok("q8_0") | Ok("Q8") | Ok("q8") => IsqType::Q8_0,
        Ok("Q6K") | Ok("q6k") => IsqType::Q6K,
        Ok("Q5K") | Ok("q5k") => IsqType::Q5K,
        _ => IsqType::Q4K,
    }
}

/// Translate a [`ChatRequest`] into a mistral.rs `RequestBuilder` (system +
/// messages + tools). Pure — no model needed, so it is unit-tested directly.
/// A message carrying audio (S18 push-to-talk) is decoded base64 → WAV bytes →
/// `AudioInput` and attached via `add_audio_message`; audio composes with
/// tools in a single request (validated by the S13 harness).
fn build_request(request: &ChatRequest) -> Result<RequestBuilder, EngineError> {
    // top_k above MAX_DEVICE_TOP_K (128) forces mistral.rs onto the CPU
    // sampling path. The Metal top-k kernel deterministically fails with
    // "invalid Metal top-k softmax normalizer" when a Gemma 4 prompt's total
    // length lands in a narrow window relative to the prefill-chunk boundary
    // (diagnosed 2026-06-12 with replayable payloads; still broken at
    // upstream c22c2e2b). CPU top-k costs ~1ms/token — correct over fast.
    let mut builder = RequestBuilder::new()
        .set_sampler_max_len(request.max_tokens)
        .set_sampler_topk(160);
    if let Some(system) = &request.system {
        builder = builder.add_message(TextMessageRole::System, system);
    }
    for message in &request.messages {
        builder = match message.decode_audio()? {
            Some(bytes) => {
                let clip = AudioInput::from_bytes(&bytes).map_err(|error| {
                    EngineError::Inference(format!("audio decode failed: {error}"))
                })?;
                builder.add_audio_message(map_role(message.role), &message.content, vec![clip])
            }
            None => builder.add_message(map_role(message.role), &message.content),
        };
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
                ChatMessage::text(Role::User, "weather in Paris?"),
                ChatMessage::text(Role::Assistant, "checking"),
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
            messages: vec![ChatMessage::text(Role::User, "hi")],
            tools: Vec::new(),
            max_tokens: 32,
        };
        assert!(build_request(&request).is_ok());
    }

    /// A minimal valid 16 kHz mono 16-bit PCM WAV (the PTT capture format).
    fn tiny_wav() -> Vec<u8> {
        let samples: [i16; 8] = [0, 1000, -1000, 2000, -2000, 1000, -1000, 0];
        let data_len = (samples.len() * 2) as u32;
        let mut wav = Vec::new();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + data_len).to_le_bytes());
        wav.extend_from_slice(b"WAVE");
        wav.extend_from_slice(b"fmt ");
        wav.extend_from_slice(&16u32.to_le_bytes()); // fmt chunk size
        wav.extend_from_slice(&1u16.to_le_bytes()); // PCM
        wav.extend_from_slice(&1u16.to_le_bytes()); // mono
        wav.extend_from_slice(&16_000u32.to_le_bytes()); // sample rate
        wav.extend_from_slice(&32_000u32.to_le_bytes()); // byte rate
        wav.extend_from_slice(&2u16.to_le_bytes()); // block align
        wav.extend_from_slice(&16u16.to_le_bytes()); // bits per sample
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&data_len.to_le_bytes());
        for sample in samples {
            wav.extend_from_slice(&sample.to_le_bytes());
        }
        wav
    }

    fn audio_message(encoded: String) -> ChatMessage {
        ChatMessage {
            role: Role::User,
            content: "what's on my calendar today?".to_owned(),
            audio_wav_base64: Some(encoded),
        }
    }

    #[test]
    fn build_request_attaches_audio_and_composes_with_tools() {
        use base64::Engine as _;
        let encoded = base64::engine::general_purpose::STANDARD.encode(tiny_wav());
        let request = ChatRequest {
            system: Some("You are Fae.".to_owned()),
            messages: vec![audio_message(encoded)],
            tools: vec![weather_tool()],
            max_tokens: 128,
        };
        assert!(build_request(&request).is_ok());
    }

    #[test]
    fn build_request_rejects_malformed_audio() {
        // Malformed base64 fails loud, not silently dropped from the turn.
        let bad_base64 = ChatRequest {
            system: None,
            messages: vec![audio_message("not-base64!!!".to_owned())],
            tools: Vec::new(),
            max_tokens: 32,
        };
        assert!(matches!(
            build_request(&bad_base64),
            Err(EngineError::Inference(_))
        ));
        // Valid base64 that is not decodable audio also fails loud.
        use base64::Engine as _;
        let not_audio = base64::engine::general_purpose::STANDARD.encode(b"plain text bytes");
        let bad_audio = ChatRequest {
            system: None,
            messages: vec![audio_message(not_audio)],
            tools: Vec::new(),
            max_tokens: 32,
        };
        assert!(matches!(
            build_request(&bad_audio),
            Err(EngineError::Inference(_))
        ));
    }
}
