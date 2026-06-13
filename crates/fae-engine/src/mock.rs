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
        // Echo the last user message; an attached audio clip is decoded (so
        // malformed base64 fails here exactly as it would in a real adapter)
        // and surfaced as a deterministic `[audio:<n> bytes]` marker.
        let last_user = request
            .messages
            .iter()
            .rev()
            .find(|message| message.role == crate::provider::Role::User);
        let echo = match last_user {
            None => String::new(),
            Some(message) => match message.decode_audio()? {
                Some(bytes) => format!("[audio:{} bytes] {}", bytes.len(), message.content),
                None => message.content.clone(),
            },
        };
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
    use futures_util::TryStreamExt;

    fn user_request(text: &str) -> ChatRequest {
        ChatRequest {
            system: None,
            messages: vec![ChatMessage::text(Role::User, text)],
            tools: Vec::new(),
            max_tokens: 64,
        }
    }

    #[tokio::test]
    async fn mock_streams_echo_then_done() -> Result<(), Box<dyn std::error::Error>> {
        let adapter = MockAdapter::new("mock-1");
        assert_eq!(adapter.describe().backend, "mock");

        let stream = adapter.stream_chat(user_request("hello")).await?;
        let events: Vec<_> = stream.try_collect().await?;
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
        Ok(())
    }

    #[tokio::test]
    async fn mock_echoes_audio_marker_for_audio_messages() -> Result<(), Box<dyn std::error::Error>>
    {
        use base64::Engine as _;
        let adapter = MockAdapter::new("mock-1");
        let mut request = user_request("speak");
        request.messages[0].audio_wav_base64 =
            Some(base64::engine::general_purpose::STANDARD.encode([0u8; 16]));
        let stream = adapter.stream_chat(request).await?;
        let events: Vec<_> = stream.try_collect().await?;
        assert_eq!(
            events[1],
            ChatEvent::Token("[audio:16 bytes] speak".to_owned())
        );
        Ok(())
    }

    #[tokio::test]
    async fn mock_rejects_malformed_audio_base64() {
        let adapter = MockAdapter::new("mock-1");
        let mut request = user_request("speak");
        request.messages[0].audio_wav_base64 = Some("not-base64!!!".to_owned());
        assert!(adapter.stream_chat(request).await.is_err());
    }
}
