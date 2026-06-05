//! A deterministic [`ProviderAdapter`] for tests and for wiring the daemon's
//! conversation path end-to-end before the mistral.rs adapter (chunk 3b) exists.

use async_trait::async_trait;
use futures_util::stream;

use crate::provider::{
    AdapterInfo, ChatEvent, ChatRequest, ChatStream, EngineError, ProviderAdapter,
};

/// Echoes the last user message back as streamed tokens. No model, no I/O —
/// purely to exercise the streaming contract and the daemon plumbing.
pub struct MockAdapter {
    model_id: String,
}

impl MockAdapter {
    #[must_use]
    pub fn new(model_id: impl Into<String>) -> MockAdapter {
        MockAdapter {
            model_id: model_id.into(),
        }
    }
}

#[async_trait]
impl ProviderAdapter for MockAdapter {
    fn describe(&self) -> AdapterInfo {
        AdapterInfo {
            backend: "mock".to_owned(),
            model_id: self.model_id.clone(),
        }
    }

    async fn stream_chat(&self, request: ChatRequest) -> Result<ChatStream, EngineError> {
        let echo = request.last_user().unwrap_or_default().to_owned();
        let events = vec![
            Ok(ChatEvent::Token("echo: ".to_owned())),
            Ok(ChatEvent::Token(echo)),
            Ok(ChatEvent::Done {
                finish_reason: "stop".to_owned(),
            }),
        ];
        Ok(Box::pin(stream::iter(events)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider::{ChatMessage, Role};
    use futures_util::StreamExt;

    fn user_request(text: &str) -> ChatRequest {
        ChatRequest {
            system: None,
            messages: vec![ChatMessage {
                role: Role::User,
                content: text.to_owned(),
            }],
            tools: Vec::new(),
            max_tokens: 64,
        }
    }

    #[tokio::test]
    async fn mock_streams_echo_then_done() {
        let adapter = MockAdapter::new("mock-1");
        assert_eq!(adapter.describe().backend, "mock");

        let stream = adapter
            .stream_chat(user_request("hello"))
            .await
            .expect("stream");
        let events: Vec<_> = stream.map(|event| event.expect("event")).collect().await;
        assert_eq!(
            events,
            vec![
                ChatEvent::Token("echo: ".to_owned()),
                ChatEvent::Token("hello".to_owned()),
                ChatEvent::Done {
                    finish_reason: "stop".to_owned()
                },
            ]
        );
    }
}
