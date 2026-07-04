//! `OpenRouterAdapter` — optional cloud inference backend via OpenRouter.
//!
//! Posts OpenAI-compatible streaming chat completions to OpenRouter's API and
//! re-emits the stream as backend-agnostic [`ChatEvent`]s, the same contract
//! every [`ProviderAdapter`] satisfies.
//!
//! The SSE wire format is identical to what llama-server emits, so this adapter
//! reuses `events_from_chunk_with_pending_tools` / `finish_pending_tool_calls`
//! from [`crate::llamacpp_adapter`] rather than duplicating the parser.
//!
//! ## Security notes
//!
//! - The API key is held in memory during the adapter's lifetime and is
//!   deliberately excluded from the manual [`Debug`] implementation.
//! - The key must never appear in error messages, log lines, `CloudRequest`
//!   bodies, conductor store entries, or anything that transits the NDJSON
//!   socket. Error formatting in this module does not interpolate `self.api_key`.
//!
//! ## Wiring note
//!
//! This adapter is exported from `fae-engine` but is intentionally unreferenced
//! in `fae-daemon`. It cannot be reached from a live turn until the conductor
//! egress boundary is wired — see ADR-014 (Proposed).

use std::collections::BTreeMap;

use async_trait::async_trait;
use futures_util::StreamExt;

use crate::llamacpp_adapter::{
    events_from_chunk_with_pending_tools, finish_pending_tool_calls, role_str, PendingToolCall,
};
use crate::provider::{
    AdapterInfo, ChatEvent, ChatRequest, ChatStream, EngineError, ProviderAdapter,
};

// ── Construction ─────────────────────────────────────────────────────────────

/// Construction-time configuration for [`OpenRouterAdapter`].
///
/// The `api_key` field is intentionally excluded from any derived or manual
/// `Debug` implementation — do not add `#[derive(Debug)]` to this struct.
pub struct OpenRouterConfig {
    /// OpenRouter base URL, e.g. `"https://openrouter.ai/api"`.
    pub base_url: String,
    /// OpenRouter model identifier, e.g. `"openai/gpt-4.1-mini"`.
    pub model_id: String,
    /// API key — stays in memory only; never logged, never sent over the
    /// daemon's NDJSON socket, and never included in error messages.
    pub api_key: String,
    /// The model's context window, in tokens (Phase G1). OpenRouter serves many
    /// models with different windows, so the caller supplies it; use
    /// [`DEFAULT_OPENROUTER_CONTEXT_WINDOW`] when the specific model's window is
    /// not known.
    pub context_window: usize,
}

/// Conservative default context window for a cloud model reached through
/// OpenRouter when the specific model's window is unknown (Phase G1). Most
/// current chat models comfortably exceed this, so it under-promises headroom.
pub const DEFAULT_OPENROUTER_CONTEXT_WINDOW: usize = 8192;

/// A [`ProviderAdapter`] that streams chat completions from OpenRouter.
///
/// Construction is cheap and involves no network I/O. The first
/// `stream_chat` call sends the initial HTTP request.
pub struct OpenRouterAdapter {
    http: reqwest::Client,
    base_url: String,
    model_id: String,
    /// Never logged; excluded from the manual Debug impl.
    api_key: String,
    info: AdapterInfo,
}

/// Manual `Debug` implementation that redacts the API key.
impl std::fmt::Debug for OpenRouterAdapter {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("OpenRouterAdapter")
            .field("base_url", &self.base_url)
            .field("model_id", &self.model_id)
            .field("api_key", &"[REDACTED]")
            .finish()
    }
}

impl OpenRouterAdapter {
    /// Construct from config. No network I/O; no validation of the key or URL.
    #[must_use]
    pub fn new(config: OpenRouterConfig) -> OpenRouterAdapter {
        OpenRouterAdapter {
            http: reqwest::Client::new(),
            base_url: config.base_url.trim_end_matches('/').to_owned(),
            model_id: config.model_id.clone(),
            api_key: config.api_key,
            info: AdapterInfo {
                backend: "openrouter".to_owned(),
                model_id: config.model_id,
                context_window: config.context_window,
            },
        }
    }
}

// ── Request building ──────────────────────────────────────────────────────────

/// Translate a [`ChatRequest`] into an OpenAI-compatible streaming request body
/// for OpenRouter's `/v1/chat/completions` endpoint.
///
/// Audio clips are rejected: cloud models targeted through OpenRouter are
/// text-only in v1. The local two-pass STT path (S18) transcribes audio to text
/// before the turn reaches the conductor, so in practice audio-bearing messages
/// should never reach this adapter.
fn build_openrouter_body(
    request: &ChatRequest,
    model_id: &str,
) -> Result<serde_json::Value, EngineError> {
    let mut messages = Vec::new();
    if let Some(system) = &request.system {
        messages.push(serde_json::json!({ "role": "system", "content": system }));
    }
    for message in &request.messages {
        let role = role_str(message.role);
        if message.audio_wav_base64.is_some() {
            return Err(EngineError::Inference(
                "OpenRouterAdapter: audio-bearing messages are not supported in v1 \
                 (STT should transcribe before the turn reaches the cloud lane)"
                    .to_owned(),
            ));
        }
        messages.push(serde_json::json!({ "role": role, "content": message.content }));
    }

    let mut body = serde_json::json!({
        "model": model_id,
        "messages": messages,
        "max_tokens": request.max_tokens,
        "stream": true,
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

// ── ProviderAdapter impl ──────────────────────────────────────────────────────

#[async_trait]
impl ProviderAdapter for OpenRouterAdapter {
    fn describe(&self) -> AdapterInfo {
        self.info.clone()
    }

    /// Stream a chat completion through OpenRouter.
    ///
    /// Pre-flight HTTP errors (4xx / 5xx) are returned as `Err` before the
    /// stream is created. Mid-stream errors (network interruption, missing
    /// `[DONE]`) are yielded as `Err` items on the stream.
    ///
    /// The `Authorization` header carrying the API key is set on the outgoing
    /// request; its value never appears in any returned error.
    async fn stream_chat(&self, request: ChatRequest) -> Result<ChatStream, EngineError> {
        let body = build_openrouter_body(&request, &self.model_id)?;
        let url = format!("{}/v1/chat/completions", self.base_url);

        let response = self
            .http
            .post(&url)
            .header(
                reqwest::header::AUTHORIZATION,
                format!("Bearer {}", self.api_key),
            )
            // OpenRouter-recommended attribution headers (optional but recommended).
            .header("HTTP-Referer", "https://github.com/saorsa-labs/fae")
            .header("X-Title", "Fae")
            .json(&body)
            .send()
            .await
            .map_err(|error| {
                EngineError::Inference(format!("OpenRouter request failed: {error}"))
            })?;

        let status = response.status();

        // 401 / 403 → typed auth failure. The response body may contain the
        // OpenRouter error detail; include it but never include the key itself.
        if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
            let detail = response.text().await.unwrap_or_default();
            return Err(EngineError::Inference(format!(
                "OpenRouter auth failed ({status}): {detail}"
            )));
        }

        // 429 → rate-limited. Caller should back off and retry or fall back to
        // the local model; the conductor's BudgetGovernor tracks this.
        if status == reqwest::StatusCode::TOO_MANY_REQUESTS {
            let detail = response.text().await.unwrap_or_default();
            return Err(EngineError::Inference(format!(
                "OpenRouter rate limited (429): {detail}"
            )));
        }

        // Any other non-2xx → retryable-or-fatal depending on caller.
        if !status.is_success() {
            let detail = response.text().await.unwrap_or_default();
            return Err(EngineError::Inference(format!(
                "OpenRouter {status}: {detail}"
            )));
        }

        // ── SSE stream ──────────────────────────────────────────────────────
        // Events are `data: {json}\n\n`, terminated by `data: [DONE]`.
        // The response is now owned ('static) and moved into the stream closure.
        //
        // Usage fields in the final chunk (prompt_tokens / completion_tokens)
        // are silently ignored — ChatEvent has no usage variant, and this
        // mirrors the LlamaServerAdapter's handling.
        let mapped = async_stream::stream! {
            let mut byte_stream = response.bytes_stream();
            let mut buffer = String::new();
            let mut saw_done = false;
            let mut pending_tool_calls: BTreeMap<usize, PendingToolCall> = BTreeMap::new();

            while let Some(chunk) = byte_stream.next().await {
                let bytes = match chunk {
                    Ok(bytes) => bytes,
                    Err(error) => {
                        yield Err(EngineError::Inference(format!(
                            "OpenRouter stream error: {error}"
                        )));
                        return;
                    }
                };
                buffer.push_str(&String::from_utf8_lossy(&bytes));

                while let Some(newline) = buffer.find('\n') {
                    let line: String = buffer.drain(..=newline).collect();
                    let line = line.trim_end_matches(['\r', '\n']);
                    let Some(data) = line.strip_prefix("data: ") else {
                        continue;
                    };
                    if data == "[DONE]" {
                        saw_done = true;
                        continue;
                    }
                    let Ok(value) = serde_json::from_str::<serde_json::Value>(data) else {
                        continue; // keep-alive / non-JSON line
                    };
                    for event in
                        events_from_chunk_with_pending_tools(&value, &mut pending_tool_calls)
                    {
                        yield Ok(event);
                    }
                }
            }

            // A stream that ends without `data: [DONE]` is a truncated turn
            // (mid-turn network cut / server crash). Fail loud so the caller
            // does not speak a partial reply or capture it to memory.
            if !saw_done {
                yield Err(EngineError::Inference(
                    "OpenRouter stream ended without [DONE]".to_owned(),
                ));
                return;
            }

            for call in finish_pending_tool_calls(&mut pending_tool_calls) {
                yield Ok(call);
            }
            yield Ok(ChatEvent::Done {
                finish_reason: "stop".to_owned(),
            });
        };

        Ok(Box::pin(mapped))
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider::{ChatMessage, Role};
    use futures_util::StreamExt;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    // ── Test helpers ──────────────────────────────────────────────────────────

    fn make_adapter(base_url: impl Into<String>) -> OpenRouterAdapter {
        OpenRouterAdapter::new(OpenRouterConfig {
            base_url: base_url.into(),
            model_id: "test/model-x".to_owned(),
            api_key: "sk-test-key".to_owned(),
            context_window: DEFAULT_OPENROUTER_CONTEXT_WINDOW,
        })
    }

    fn simple_request() -> ChatRequest {
        ChatRequest {
            system: None,
            messages: vec![ChatMessage::text(Role::User, "ping")],
            tools: vec![],
            max_tokens: 64,
        }
    }

    /// Spawn a one-shot HTTP mock server. Accepts one TCP connection, reads up
    /// to 16 KB of the incoming request (sufficient for test payloads), sends
    /// `tx` the raw request text, writes `response_bytes`, then closes.
    /// Returns (base_url, request_receiver).
    async fn serve_once(
        response_bytes: Vec<u8>,
    ) -> (String, tokio::sync::oneshot::Receiver<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        let (tx, rx) = tokio::sync::oneshot::channel::<String>();
        tokio::spawn(async move {
            let (mut conn, _) = listener.accept().await.unwrap();
            let mut buf = vec![0u8; 16 * 1024];
            let n = conn.read(&mut buf).await.unwrap_or(0);
            let req = String::from_utf8_lossy(&buf[..n]).into_owned();
            let _ = tx.send(req);
            let _ = conn.write_all(&response_bytes).await;
            // conn drops → TCP FIN → reqwest sees EOF on the response body
        });
        (format!("http://127.0.0.1:{}", addr.port()), rx)
    }

    // ── (a) Happy path: two deltas + usage chunk ──────────────────────────────

    #[tokio::test]
    async fn happy_path_two_deltas_and_done() {
        // The final chunk has a `usage` field — it should be silently ignored
        // (no ChatEvent::Usage variant exists, matching LlamaServerAdapter).
        let sse = concat!(
            "HTTP/1.1 200 OK\r\n",
            "Content-Type: text/event-stream\r\n",
            "\r\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"},\"finish_reason\":null}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\" world\"},\"finish_reason\":null}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"\"},\"finish_reason\":\"stop\"}],",
            "\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}\n\n",
            "data: [DONE]\n\n",
        );
        let (base_url, _req_rx) = serve_once(sse.as_bytes().to_vec()).await;
        let adapter = make_adapter(base_url);

        let stream = adapter.stream_chat(simple_request()).await.unwrap();
        let events: Vec<_> = stream.collect().await;

        // Expect: Token("hello"), Token(" world"), Done{finish_reason: "stop"}.
        // The usage chunk produces an empty delta (skipped) + no tool calls.
        assert_eq!(events.len(), 3, "unexpected event count: {events:?}");
        assert_eq!(
            events[0].as_ref().unwrap(),
            &ChatEvent::Token("hello".to_owned())
        );
        assert_eq!(
            events[1].as_ref().unwrap(),
            &ChatEvent::Token(" world".to_owned())
        );
        assert!(
            matches!(
                events[2].as_ref().unwrap(),
                ChatEvent::Done { finish_reason } if finish_reason == "stop"
            ),
            "expected Done{{finish_reason:stop}}, got {:?}",
            events[2]
        );
    }

    // ── (b) Authorization header + model id present in request ────────────────

    #[tokio::test]
    async fn auth_header_and_model_id_in_request() {
        let sse = concat!(
            "HTTP/1.1 200 OK\r\n",
            "Content-Type: text/event-stream\r\n",
            "\r\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"},\"finish_reason\":null}]}\n\n",
            "data: [DONE]\n\n",
        );
        let (base_url, req_rx) = serve_once(sse.as_bytes().to_vec()).await;
        let adapter = make_adapter(base_url);

        // Consume the stream so the full request is sent and the server reads it.
        let stream = adapter.stream_chat(simple_request()).await.unwrap();
        let _: Vec<_> = stream.collect().await;

        // The server sends the captured request over the channel after reading it,
        // which happens before writing the response — so req_rx resolves immediately.
        let req = req_rx.await.unwrap();

        // Authorization header must be present with the exact key value.
        assert!(
            req.contains("Authorization: Bearer sk-test-key")
                || req
                    .to_ascii_lowercase()
                    .contains("authorization: bearer sk-test-key"),
            "Authorization header missing or wrong; request headers:\n{req}"
        );

        // Model id must appear in the JSON request body.
        assert!(
            req.contains("test/model-x"),
            "model id missing from request body; request:\n{req}"
        );
    }

    // ── (c) HTTP 401 → typed auth error ──────────────────────────────────────

    #[tokio::test]
    async fn http_401_yields_auth_error() {
        let response = b"HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n";
        let (base_url, _req_rx) = serve_once(response.to_vec()).await;
        let adapter = make_adapter(base_url);

        // `ChatStream` (boxed trait object) doesn't implement Debug, so
        // `unwrap_err()` won't compile. Use `match` to extract the error.
        let msg = match adapter.stream_chat(simple_request()).await {
            Err(e) => e.to_string(),
            Ok(_) => panic!("expected Err for 401, got Ok"),
        };
        assert!(
            msg.contains("401"),
            "expected '401' in error message, got: {msg}"
        );
        // Key must not appear in the error message.
        assert!(
            !msg.contains("sk-test-key"),
            "API key leaked into error: {msg}"
        );
    }

    // ── (d) HTTP 429 → rate-limit error ──────────────────────────────────────

    #[tokio::test]
    async fn http_429_yields_rate_limit_error() {
        let response = b"HTTP/1.1 429 Too Many Requests\r\nContent-Length: 0\r\n\r\n";
        let (base_url, _req_rx) = serve_once(response.to_vec()).await;
        let adapter = make_adapter(base_url);

        let msg = match adapter.stream_chat(simple_request()).await {
            Err(e) => e.to_string(),
            Ok(_) => panic!("expected Err for 429, got Ok"),
        };
        assert!(
            msg.contains("429") || msg.contains("rate limit"),
            "expected rate-limit signal in error, got: {msg}"
        );
        assert!(
            !msg.contains("sk-test-key"),
            "API key leaked into error: {msg}"
        );
    }

    // ── (e) Mid-stream cut → stream yields Err ────────────────────────────────

    #[tokio::test]
    async fn mid_stream_cut_yields_err_on_stream() {
        // Partial SSE: one delta delivered, connection closed without [DONE].
        let sse = concat!(
            "HTTP/1.1 200 OK\r\n",
            "Content-Type: text/event-stream\r\n",
            "\r\n",
            "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"},\"finish_reason\":null}]}\n\n",
            // No `data: [DONE]` — server closes the connection here.
        );
        let (base_url, _req_rx) = serve_once(sse.as_bytes().to_vec()).await;
        let adapter = make_adapter(base_url);

        let stream = adapter.stream_chat(simple_request()).await.unwrap();
        let events: Vec<_> = stream.collect().await;

        // Must have received the partial token before the error.
        assert!(
            !events.is_empty(),
            "expected at least one event before the cut"
        );
        // The final item on the stream must be an Err.
        let last = events.last().unwrap();
        assert!(
            last.is_err(),
            "expected Err as last stream item on mid-stream cut, got: {last:?}"
        );
    }

    // ── Extra: audio-bearing messages are rejected before network I/O ─────────

    #[tokio::test]
    async fn audio_message_rejected_before_send() {
        // Use a port that nothing is listening on — if we reach the network the
        // test will fail with a connection error rather than the expected error.
        let adapter = make_adapter("http://127.0.0.1:1");
        let request = ChatRequest {
            system: None,
            messages: vec![ChatMessage {
                role: Role::User,
                content: "hello".to_owned(),
                audio_wav_base64: Some("dGVzdA==".to_owned()),
            }],
            tools: vec![],
            max_tokens: 64,
        };
        let msg = match adapter.stream_chat(request).await {
            Err(e) => e.to_string(),
            Ok(_) => panic!("expected Err for audio-bearing message, got Ok"),
        };
        assert!(
            msg.contains("audio"),
            "expected 'audio' in error, got: {msg}"
        );
    }
}
