//! A deterministic [`ProviderAdapter`] for tests and for wiring the daemon's
//! conversation path end-to-end before the mistral.rs adapter (chunk 3b) exists.

use std::collections::VecDeque;
use std::sync::{Mutex, PoisonError};

use async_trait::async_trait;
use futures_util::stream;

use crate::provider::{
    AdapterInfo, ChatEvent, ChatRequest, ChatStream, EngineError, ProviderAdapter,
};

/// Echoes the last user message back as streamed tokens. No model, no I/O —
/// purely to exercise the streaming contract and the daemon plumbing.
///
/// In **scripted** mode ([`MockAdapter::scripted`]) each `stream_chat` instead
/// pops the next programmed event sequence (FIFO), so a multi-iteration agentic
/// loop (Phase F1: `fae.delegate`) can be driven deterministically with no
/// model — e.g. iteration 1 emits a `write` tool call, iteration 2 a final
/// answer. Once the scripts are exhausted it falls back to the echo behaviour.
pub struct MockAdapter {
    model_id: String,
    /// Programmed per-call event sequences (scripted mode). `None` ⇒ echo mode.
    /// `Mutex` (not a lock held across `.await`) so the adapter stays `Sync`
    /// while advancing the script cursor between calls.
    scripts: Mutex<VecDeque<Vec<ChatEvent>>>,
}

impl MockAdapter {
    #[must_use]
    pub fn new(model_id: impl Into<String>) -> MockAdapter {
        MockAdapter {
            model_id: model_id.into(),
            scripts: Mutex::new(VecDeque::new()),
        }
    }

    /// A mock that emits `scripts[i]` on its `i`-th `stream_chat` call (FIFO).
    /// Each inner `Vec<ChatEvent>` is one turn's stream (tokens/tool calls
    /// ending in `Done`). After the last script, later calls echo (as `new`).
    #[must_use]
    pub fn scripted(model_id: impl Into<String>, scripts: Vec<Vec<ChatEvent>>) -> MockAdapter {
        MockAdapter {
            model_id: model_id.into(),
            scripts: Mutex::new(scripts.into()),
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
        // Scripted mode: emit the next programmed sequence, if any remain.
        if let Some(script) = self
            .scripts
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .pop_front()
        {
            let events = script.into_iter().map(Ok).collect::<Vec<_>>();
            return Ok(Box::pin(stream::iter(events)));
        }
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
    async fn scripted_mock_emits_sequences_in_order_then_echoes(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let adapter = MockAdapter::scripted(
            "mock-scripted",
            vec![
                vec![
                    ChatEvent::ToolCall {
                        name: "write".to_owned(),
                        arguments: "{\"path\":\"a.txt\"}".to_owned(),
                    },
                    ChatEvent::Done {
                        finish_reason: "tool_calls".to_owned(),
                    },
                ],
                vec![
                    ChatEvent::Token("all done".to_owned()),
                    ChatEvent::Done {
                        finish_reason: "stop".to_owned(),
                    },
                ],
            ],
        );
        // Call 1 → the tool-call script.
        let s1: Vec<_> = adapter
            .stream_chat(user_request("go"))
            .await?
            .try_collect()
            .await?;
        assert!(matches!(s1[0], ChatEvent::ToolCall { .. }));
        // Call 2 → the final-answer script.
        let s2: Vec<_> = adapter
            .stream_chat(user_request("go"))
            .await?
            .try_collect()
            .await?;
        assert_eq!(s2[0], ChatEvent::Token("all done".to_owned()));
        // Call 3 → scripts exhausted, falls back to echo.
        let s3: Vec<_> = adapter
            .stream_chat(user_request("hi"))
            .await?
            .try_collect()
            .await?;
        assert_eq!(s3[1], ChatEvent::Token("hi".to_owned()));
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
