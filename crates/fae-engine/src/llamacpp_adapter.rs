//! `LlamaServerAdapter` — cross-platform serving backend (gap B1).
//!
//! Talks to a `llama-server` (llama.cpp) sidecar over its OpenAI-compatible
//! HTTP/SSE API and re-emits the stream as backend-agnostic [`ChatEvent`]s, the
//! same contract the mistral.rs adapter satisfies. Chosen after the 2026-06-16
//! validation (docs/architecture/cross-platform-brain-llamacpp-2026-06-16.md §A):
//! llama.cpp serves Gemma 4 text + audio + runtime GGUF-LoRA on Metal/CUDA/Vulkan,
//! which mistral.rs cannot do for Gemma 4.
//!
//! Two construction paths:
//! - [`LlamaServerAdapter::connect`] — attach to an already-running server (the
//!   validation bench, tests, or an externally-managed server).
//! - [`LlamaServerAdapter::spawn`] — launch + supervise a `llama-server` child
//!   ([`LlamaServerHandle`], killed on drop) then attach.
//!
//! Gemma specifics proven in §A and encoded here: the server runs with
//! `--reasoning-format none` (and we request it per-call) so the model's full
//! output — including any `<think>`/`<tool_call>` markup — lands in `content`
//! for Fae to self-parse downstream, rather than being split into
//! `reasoning_content` (which left `content` empty).

use async_trait::async_trait;
use futures_util::StreamExt;

use crate::provider::{
    AdapterInfo, ChatEvent, ChatRequest, ChatStream, EngineError, ProviderAdapter, Role,
};

/// How to launch a `llama-server` sidecar. Paths are caller-resolved (the daemon
/// pins them via `models.lock`); this struct only assembles the command line.
#[derive(Debug, Clone)]
pub struct LlamaServerConfig {
    /// Path to the `llama-server` binary.
    pub binary: String,
    /// Base model GGUF.
    pub model_gguf: String,
    /// Optional personal LoRA adapter GGUF (runtime, unmerged). Loaded inactive
    /// (`--lora-init-without-apply`); per-request scale turns it on.
    pub lora_gguf: Option<String>,
    /// Optional multimodal projector (audio mmproj for Gemma 4 pass-1 ASR).
    pub mmproj: Option<String>,
    /// Loopback port.
    pub port: u16,
    /// Context window.
    pub ctx_size: u32,
    /// GPU layers to offload (`99` = all on Metal/CUDA/Vulkan).
    pub ngl: u32,
}

impl LlamaServerConfig {
    fn args(&self) -> Vec<String> {
        let mut args = vec![
            "-m".to_owned(),
            self.model_gguf.clone(),
            "--host".to_owned(),
            "127.0.0.1".to_owned(),
            "--port".to_owned(),
            self.port.to_string(),
            "-c".to_owned(),
            self.ctx_size.to_string(),
            "-ngl".to_owned(),
            self.ngl.to_string(),
            "-fa".to_owned(),
            "on".to_owned(),
            "--jinja".to_owned(),
            // Keep reasoning inline in `content` so Fae self-parses (§A).
            "--reasoning-format".to_owned(),
            "none".to_owned(),
        ];
        if let Some(lora) = &self.lora_gguf {
            args.push("--lora".to_owned());
            args.push(lora.clone());
            // Loaded but inactive; per-request `lora` scale activates it.
            args.push("--lora-init-without-apply".to_owned());
        }
        if let Some(mmproj) = &self.mmproj {
            args.push("--mmproj".to_owned());
            args.push(mmproj.clone());
        }
        args
    }
}

/// A supervised `llama-server` child. Killed on drop so the sidecar never
/// outlives the daemon during a clean shutdown; combined with the daemon's
/// parent-watch this keeps the app → daemon → llama-server chain tidy. (A hard
/// SIGKILL of the daemon can still orphan it — process-group hardening is a
/// follow-up, tracked with the B-series gaps.)
pub struct LlamaServerHandle {
    child: std::process::Child,
    base_url: String,
}

impl LlamaServerHandle {
    /// Spawn the server and block until `/health` is ok (or `timeout`).
    pub async fn spawn(
        config: &LlamaServerConfig,
        timeout: std::time::Duration,
    ) -> Result<LlamaServerHandle, EngineError> {
        let base_url = format!("http://127.0.0.1:{}", config.port);
        let child = std::process::Command::new(&config.binary)
            .args(config.args())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map_err(|error| {
                EngineError::Load(format!("spawn llama-server ({}): {error}", config.binary))
            })?;
        let handle = LlamaServerHandle { child, base_url };
        handle.await_ready(timeout).await?;
        Ok(handle)
    }

    async fn await_ready(&self, timeout: std::time::Duration) -> Result<(), EngineError> {
        let client = reqwest::Client::new();
        let health = format!("{}/health", self.base_url);
        let deadline = std::time::Instant::now() + timeout;
        loop {
            if let Ok(response) = client.get(&health).send().await {
                if response.status().is_success() {
                    return Ok(());
                }
            }
            if std::time::Instant::now() >= deadline {
                return Err(EngineError::Load(format!(
                    "llama-server did not become ready within {timeout:?}"
                )));
            }
            tokio::time::sleep(std::time::Duration::from_millis(250)).await;
        }
    }
}

impl Drop for LlamaServerHandle {
    fn drop(&mut self) {
        // Best-effort: never panic in Drop. Kill then reap so we don't leave a
        // zombie or an orphaned model holding GPU memory.
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// A `llama-server` behind the [`ProviderAdapter`] contract.
pub struct LlamaServerAdapter {
    http: reqwest::Client,
    base_url: String,
    info: AdapterInfo,
    /// Owns the sidecar when we spawned it; `None` when attached to an external
    /// server. Held only to tie the child's lifetime to the adapter.
    _server: Option<LlamaServerHandle>,
}

impl LlamaServerAdapter {
    /// Attach to an already-running server at `base_url` (e.g. `http://127.0.0.1:18082`).
    pub fn connect(base_url: impl Into<String>, model_id: impl Into<String>) -> LlamaServerAdapter {
        LlamaServerAdapter {
            http: reqwest::Client::new(),
            base_url: base_url.into().trim_end_matches('/').to_owned(),
            info: AdapterInfo {
                backend: "llama.cpp".to_owned(),
                model_id: model_id.into(),
            },
            _server: None,
        }
    }

    /// Spawn + supervise a `llama-server` child, then attach to it.
    pub async fn spawn(
        config: LlamaServerConfig,
        model_id: impl Into<String>,
    ) -> Result<LlamaServerAdapter, EngineError> {
        let handle = LlamaServerHandle::spawn(&config, std::time::Duration::from_secs(120)).await?;
        let base_url = handle.base_url.clone();
        Ok(LlamaServerAdapter {
            http: reqwest::Client::new(),
            base_url,
            info: AdapterInfo {
                backend: "llama.cpp".to_owned(),
                model_id: model_id.into(),
            },
            _server: Some(handle),
        })
    }
}

#[async_trait]
impl ProviderAdapter for LlamaServerAdapter {
    fn describe(&self) -> AdapterInfo {
        self.info.clone()
    }

    async fn stream_chat(&self, request: ChatRequest) -> Result<ChatStream, EngineError> {
        let body = build_chat_body(&request, &self.info.model_id)?;
        let url = format!("{}/v1/chat/completions", self.base_url);
        let http = self.http.clone();

        // Drive the HTTP request inside the stream so the returned `ChatStream`
        // is self-contained ('static), matching the mistral.rs adapter shape.
        let mapped = async_stream::stream! {
            let response = match http.post(&url).json(&body).send().await {
                Ok(response) => response,
                Err(error) => {
                    yield Err(EngineError::Inference(format!("llama-server request failed: {error}")));
                    return;
                }
            };
            if !response.status().is_success() {
                let status = response.status();
                let detail = response.text().await.unwrap_or_default();
                yield Err(EngineError::Inference(format!("llama-server {status}: {detail}")));
                return;
            }

            // SSE: events are `data: {json}\n\n`, plus `data: [DONE]`. Buffer
            // across chunk boundaries and emit one ChatEvent per delta.
            let mut byte_stream = response.bytes_stream();
            let mut buffer = String::new();
            let mut saw_done = false;
            while let Some(chunk) = byte_stream.next().await {
                let bytes = match chunk {
                    Ok(bytes) => bytes,
                    Err(error) => {
                        yield Err(EngineError::Inference(format!("llama-server stream error: {error}")));
                        return;
                    }
                };
                buffer.push_str(&String::from_utf8_lossy(&bytes));
                while let Some(newline) = buffer.find('\n') {
                    let line: String = buffer.drain(..=newline).collect();
                    let line = line.trim_end_matches(['\r', '\n']);
                    let Some(data) = line.strip_prefix("data: ") else { continue };
                    if data == "[DONE]" {
                        saw_done = true;
                        continue;
                    }
                    let Ok(value) = serde_json::from_str::<serde_json::Value>(data) else {
                        continue; // keep-alive / non-JSON line
                    };
                    for event in events_from_chunk(&value) {
                        yield Ok(event);
                    }
                }
            }
            let _ = saw_done;
            yield Ok(ChatEvent::Done { finish_reason: "stop".to_owned() });
        };
        Ok(Box::pin(mapped))
    }
}

fn role_str(role: Role) -> &'static str {
    match role {
        Role::System => "system",
        Role::User => "user",
        Role::Assistant => "assistant",
        Role::Tool => "tool",
    }
}

/// Translate a [`ChatRequest`] into an OpenAI `/v1/chat/completions` body. Pure,
/// so it is unit-tested without a server. A message carrying push-to-talk audio
/// (S18) is validated (fail loud on bad base64) and attached as an `input_audio`
/// content part — Gemma 4's audio pass (validation §A).
fn build_chat_body(
    request: &ChatRequest,
    model_id: &str,
) -> Result<serde_json::Value, EngineError> {
    let mut messages = Vec::new();
    if let Some(system) = &request.system {
        messages.push(serde_json::json!({ "role": "system", "content": system }));
    }
    for message in &request.messages {
        let role = role_str(message.role);
        // Validate any attached audio up front — never silently drop a clip.
        match message.decode_audio()? {
            Some(_) => {
                let encoded = message.audio_wav_base64.as_deref().unwrap_or_default();
                messages.push(serde_json::json!({
                    "role": role,
                    "content": [
                        { "type": "input_audio", "input_audio": { "data": encoded, "format": "wav" } },
                        { "type": "text", "text": message.content },
                    ],
                }));
            }
            None => {
                messages.push(serde_json::json!({ "role": role, "content": message.content }));
            }
        }
    }

    let mut body = serde_json::json!({
        "model": model_id,
        "messages": messages,
        "max_tokens": request.max_tokens,
        "stream": true,
        // Keep reasoning inline in `content`; Fae self-parses think/tool markup.
        "reasoning_format": "none",
    });
    if !request.tools.is_empty() {
        let tools: Vec<serde_json::Value> = request
            .tools
            .iter()
            .map(|spec| {
                serde_json::json!({
                    "type": "function",
                    "function": {
                        "name": spec.name,
                        "description": spec.description,
                        "parameters": spec.parameters,
                    }
                })
            })
            .collect();
        body["tools"] = serde_json::Value::Array(tools);
        body["tool_choice"] = serde_json::Value::String("auto".to_owned());
    }
    Ok(body)
}

/// Map one streamed chunk's `choices[0].delta` to zero or more [`ChatEvent`]s.
/// Pure, so the SSE→event mapping is unit-tested without a server.
fn events_from_chunk(value: &serde_json::Value) -> Vec<ChatEvent> {
    let mut events = Vec::new();
    let Some(delta) = value
        .get("choices")
        .and_then(|c| c.get(0))
        .and_then(|c| c.get("delta"))
    else {
        return events;
    };
    if let Some(text) = delta.get("content").and_then(|v| v.as_str()) {
        if !text.is_empty() {
            events.push(ChatEvent::Token(text.to_owned()));
        }
    }
    if let Some(calls) = delta.get("tool_calls").and_then(|v| v.as_array()) {
        for call in calls {
            let function = call.get("function");
            let name = function
                .and_then(|f| f.get("name"))
                .and_then(|v| v.as_str())
                .unwrap_or_default();
            let arguments = function
                .and_then(|f| f.get("arguments"))
                .and_then(|v| v.as_str())
                .unwrap_or_default();
            if !name.is_empty() {
                events.push(ChatEvent::ToolCall {
                    name: name.to_owned(),
                    arguments: arguments.to_owned(),
                });
            }
        }
    }
    events
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
    fn build_body_maps_system_messages_and_tools() {
        let request = ChatRequest {
            system: Some("You are Fae.".to_owned()),
            messages: vec![ChatMessage::text(Role::User, "weather in Paris?")],
            tools: vec![weather_tool()],
            max_tokens: 128,
        };
        let body = build_chat_body(&request, "gemma-4").expect("body");
        assert_eq!(body["model"], "gemma-4");
        assert_eq!(body["stream"], true);
        assert_eq!(body["messages"][0]["role"], "system");
        assert_eq!(body["messages"][1]["role"], "user");
        assert_eq!(body["tools"][0]["function"]["name"], "get_weather");
        assert_eq!(body["tool_choice"], "auto");
    }

    #[test]
    fn build_body_without_tools_omits_tool_fields() {
        let request = ChatRequest {
            system: None,
            messages: vec![ChatMessage::text(Role::User, "hi")],
            tools: Vec::new(),
            max_tokens: 32,
        };
        let body = build_chat_body(&request, "gemma-4").expect("body");
        assert!(body.get("tools").is_none());
        assert_eq!(body["messages"][0]["content"], "hi");
    }

    fn tiny_wav() -> Vec<u8> {
        let samples: [i16; 4] = [0, 1000, -1000, 0];
        let data_len = (samples.len() * 2) as u32;
        let mut wav = Vec::new();
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + data_len).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes());
        wav.extend_from_slice(&16_000u32.to_le_bytes());
        wav.extend_from_slice(&32_000u32.to_le_bytes());
        wav.extend_from_slice(&2u16.to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&data_len.to_le_bytes());
        for sample in samples {
            wav.extend_from_slice(&sample.to_le_bytes());
        }
        wav
    }

    #[test]
    fn build_body_attaches_audio_as_input_audio_part() {
        use base64::Engine as _;
        let encoded = base64::engine::general_purpose::STANDARD.encode(tiny_wav());
        let request = ChatRequest {
            system: None,
            messages: vec![ChatMessage {
                role: Role::User,
                content: "what did I say?".to_owned(),
                audio_wav_base64: Some(encoded),
            }],
            tools: Vec::new(),
            max_tokens: 64,
        };
        let body = build_chat_body(&request, "gemma-4").expect("body");
        let content = &body["messages"][0]["content"];
        assert_eq!(content[0]["type"], "input_audio");
        assert_eq!(content[0]["input_audio"]["format"], "wav");
        assert_eq!(content[1]["type"], "text");
        assert_eq!(content[1]["text"], "what did I say?");
    }

    #[test]
    fn build_body_rejects_malformed_audio() {
        let request = ChatRequest {
            system: None,
            messages: vec![ChatMessage {
                role: Role::User,
                content: "x".to_owned(),
                audio_wav_base64: Some("not-base64!!!".to_owned()),
            }],
            tools: Vec::new(),
            max_tokens: 16,
        };
        assert!(matches!(
            build_chat_body(&request, "gemma-4"),
            Err(EngineError::Inference(_))
        ));
    }

    #[test]
    fn events_from_chunk_extracts_token() {
        let chunk = serde_json::json!({
            "choices": [{ "delta": { "content": "Edinburgh" } }]
        });
        assert_eq!(
            events_from_chunk(&chunk),
            vec![ChatEvent::Token("Edinburgh".to_owned())]
        );
    }

    #[test]
    fn events_from_chunk_extracts_tool_call() {
        let chunk = serde_json::json!({
            "choices": [{ "delta": { "tool_calls": [
                { "function": { "name": "get_weather", "arguments": "{\"city\":\"Paris\"}" } }
            ] } }]
        });
        assert_eq!(
            events_from_chunk(&chunk),
            vec![ChatEvent::ToolCall {
                name: "get_weather".to_owned(),
                arguments: "{\"city\":\"Paris\"}".to_owned(),
            }]
        );
    }

    #[test]
    fn events_from_chunk_empty_delta_yields_nothing() {
        let chunk = serde_json::json!({ "choices": [{ "delta": {} }] });
        assert!(events_from_chunk(&chunk).is_empty());
        let role_only = serde_json::json!({ "choices": [{ "delta": { "role": "assistant" } }] });
        assert!(events_from_chunk(&role_only).is_empty());
    }
}
