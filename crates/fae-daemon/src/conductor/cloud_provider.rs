//! Provider-backed [`CloudProvider`]: drives a real `fae_engine`
//! [`ProviderAdapter`] (e.g. `OpenRouterAdapter`) to completion behind the
//! conductor's egress gates (PII membrane → pricing → budget → approval →
//! request construction). ADR-014 decision 2: a `ProviderBackedCloudProvider`
//! replaces `MockCloudProvider` in the conductor's production wiring once the
//! `RemoteAllowed` lane is enabled.
//!
//! The [`CloudProvider`] trait is **sync** and is invoked from inside the tokio
//! runtime (`route_turn` is async → `run_cloud_direct`/`run_cloud_chain` →
//! `execute_cloud_role_call` → `CloudProvider::call`). We bridge to the
//! adapter's async streaming API with `block_in_place` + `Handle::block_on`
//! (justified inline in [`ProviderBackedCloudProvider::call`]). This keeps the
//! bridge contained to this one type — the sync trait surface the rest of the
//! conductor + its tests depend on is left untouched.

use std::sync::Arc;

use fae_engine::{ChatEvent, ChatMessage, ChatRequest, ProviderAdapter, Role};
use futures_util::StreamExt;
use serde_json::Value;

use crate::conductor::executor::{
    CloudCallError, CloudCallResult, CloudCallSuccess, CloudProvider, CloudRequest,
};
use crate::conductor::prompts::{THINKER_SYSTEM, VERIFIER_SYSTEM, WORKER_SYSTEM};
use crate::conductor::recipe::ConductorRole;

/// Wraps an `Arc<dyn ProviderAdapter>` (the OpenRouter adapter in production)
/// as the conductor's `CloudProvider`. Holds no key material — the adapter owns
/// its credential and excludes it from `Debug`, errors, and logs.
pub struct ProviderBackedCloudProvider {
    adapter: Arc<dyn ProviderAdapter>,
}

impl ProviderBackedCloudProvider {
    pub fn new(adapter: Arc<dyn ProviderAdapter>) -> Self {
        Self { adapter }
    }

    /// Map a conductor [`CloudRequest`] to an engine [`ChatRequest`]. The
    /// role-conditioned system prompt (chain topology) mirrors the local
    /// `run_chain` path so a cloud Thinker/Worker/Verifier behaves like its
    /// local counterpart; a direct call (`role: None`) carries no system prompt.
    fn chat_request(request: &CloudRequest) -> ChatRequest {
        let system = request.role.map(|role| role_system_prompt(role).to_owned());
        ChatRequest {
            system,
            messages: vec![ChatMessage::text(Role::User, request.prompt.clone())],
            tools: Vec::new(),
            max_tokens: usize::try_from(request.max_output_tokens).unwrap_or(usize::MAX),
        }
    }
}

impl CloudProvider for ProviderBackedCloudProvider {
    fn call(&self, request: CloudRequest) -> CloudCallResult {
        let chat = Self::chat_request(&request);
        let adapter = Arc::clone(&self.adapter);
        // Sync→async bridge. `call` is sync (the trait is), but it runs inside a
        // tokio worker driving `route_turn`. `block_in_place` releases this
        // worker so sibling turns keep progressing while we drive the remote
        // stream to completion; `Handle::block_on` then polls the adapter's
        // async SSE stream on this thread. Requires the multi-thread runtime
        // (`#[tokio::main]`), which the daemon uses; unit tests that exercise
        // this path must use `flavor = "multi_thread"`.
        let collected = tokio::task::block_in_place(|| {
            tokio::runtime::Handle::current().block_on(drive_stream(adapter, chat))
        });
        match collected {
            Ok(text) => Ok(CloudCallSuccess {
                response: serde_json::json!({
                    "text": text,
                    "tool_calls": Vec::<Value>::new(),
                    "finish_reason": "stop",
                }),
                // Usage tokens are dropped upstream by design (the adapter
                // redacts them), so there is no measured cost. The executor
                // falls back to the pricing-table estimate as the recorded
                // (conservative) cost basis — see `execute_cloud_role_call`.
                actual_cost: None,
            }),
            Err(code) => Err(CloudCallError {
                code,
                billed_cost: None,
            }),
        }
    }
}

/// Drive one chat completion to its terminal `Done` event, accumulating the
/// streamed tokens. A stream that ends without a `Done` marker is a mid-stream
/// cut and fails loud (never a silent partial answer). Error strings are the
/// adapter's typed `EngineError` display, which is key-free by construction.
async fn drive_stream(
    adapter: Arc<dyn ProviderAdapter>,
    request: ChatRequest,
) -> Result<String, String> {
    let mut stream = adapter
        .stream_chat(request)
        .await
        .map_err(|error| format!("stream-start:{error}"))?;
    let mut text = String::new();
    while let Some(item) = stream.next().await {
        match item {
            Ok(ChatEvent::Token(token)) => text.push_str(&token),
            // v1 cloud path is text-only reasoning; tool calls over the remote
            // lane are a follow-up (ADR-014). Downstream reads only `text`.
            Ok(ChatEvent::ToolCall { .. }) => {}
            Ok(ChatEvent::Done { .. }) => return Ok(text),
            Err(error) => return Err(format!("stream:{error}")),
        }
    }
    Err("stream-incomplete".to_string())
}

fn role_system_prompt(role: ConductorRole) -> &'static str {
    match role {
        ConductorRole::Thinker => THINKER_SYSTEM,
        ConductorRole::Worker => WORKER_SYSTEM,
        ConductorRole::Verifier => VERIFIER_SYSTEM,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use fae_engine::{AdapterInfo, ChatStream, EngineError, MockAdapter};
    use futures_util::stream;
    use std::sync::atomic::{AtomicUsize, Ordering};

    fn request(role: Option<ConductorRole>, prompt: &str) -> CloudRequest {
        CloudRequest {
            worker_id: "cloud:openrouter/openai/gpt-4.1-mini".to_string(),
            role,
            prompt: prompt.to_string(),
            max_output_tokens: 64,
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn drives_mock_adapter_stream_to_completion() {
        let provider = ProviderBackedCloudProvider::new(Arc::new(MockAdapter::new("mock")));
        let success = provider
            .call(request(None, "hello"))
            .expect("mock adapter completes");
        assert_eq!(
            success.response.get("text").and_then(Value::as_str),
            Some("echo: hello")
        );
        assert_eq!(
            success
                .response
                .get("finish_reason")
                .and_then(Value::as_str),
            Some("stop")
        );
        // Usage/cost is dropped by design → executor uses the pricing estimate.
        assert!(success.actual_cost.is_none());
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn role_maps_to_system_prompt() {
        // The role-conditioned system prompt must be present on the mapped
        // request (chain-topology parity with the local `run_chain` path).
        let req = request(Some(ConductorRole::Verifier), "answer");
        let chat = ProviderBackedCloudProvider::chat_request(&req);
        assert_eq!(chat.system.as_deref(), Some(VERIFIER_SYSTEM));
        assert_eq!(chat.max_tokens, 64);
        // A direct call carries no system prompt.
        let direct = ProviderBackedCloudProvider::chat_request(&request(None, "answer"));
        assert!(direct.system.is_none());
    }

    /// A stream that ends without a `Done` marker (mid-stream cut) fails loud.
    struct CutAdapter;

    #[async_trait]
    impl ProviderAdapter for CutAdapter {
        fn describe(&self) -> AdapterInfo {
            AdapterInfo {
                backend: "cut".to_owned(),
                model_id: "cut".to_owned(),
            }
        }
        async fn stream_chat(&self, _request: ChatRequest) -> Result<ChatStream, EngineError> {
            let events = vec![Ok(ChatEvent::Token("partial".to_owned()))];
            Ok(Box::pin(stream::iter(events)))
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn mid_stream_cut_fails_loud() {
        let provider = ProviderBackedCloudProvider::new(Arc::new(CutAdapter));
        let error = provider.call(request(None, "x")).expect_err("cut fails");
        assert_eq!(error.code, "stream-incomplete");
        assert!(error.billed_cost.is_none());
    }

    /// A stream-start error surfaces its typed code with no key material.
    struct ErrAdapter {
        calls: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl ProviderAdapter for ErrAdapter {
        fn describe(&self) -> AdapterInfo {
            AdapterInfo {
                backend: "err".to_owned(),
                model_id: "err".to_owned(),
            }
        }
        async fn stream_chat(&self, _request: ChatRequest) -> Result<ChatStream, EngineError> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            Err(EngineError::Inference("auth failed".to_owned()))
        }
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn stream_start_error_surfaces_typed_code() {
        let calls = Arc::new(AtomicUsize::new(0));
        let provider = ProviderBackedCloudProvider::new(Arc::new(ErrAdapter {
            calls: Arc::clone(&calls),
        }));
        let error = provider.call(request(None, "x")).expect_err("errors");
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        assert!(error.code.starts_with("stream-start:"));
        // Key-free: the adapter's typed error carries no credential material.
        assert!(!error.code.contains("sk-"));
    }
}
