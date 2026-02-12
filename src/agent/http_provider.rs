//! OpenAI-compatible HTTP streaming provider for `saorsa-ai`.
//!
//! Implements [`saorsa_ai::StreamingProvider`] so that `saorsa-agent` can talk
//! to any OpenAI-compatible API (Anthropic, OpenRouter, Groq, etc.) using the
//! connection details from config (`api_url`, `api_key`, `api_model`).

use async_trait::async_trait;
use saorsa_ai::error::{Result as SaorsaResult, SaorsaAiError};
use saorsa_ai::message::ContentBlock;
use saorsa_ai::types::{
    CompletionRequest, CompletionResponse, ContentDelta, StopReason, StreamEvent, Usage,
};
use saorsa_ai::{Provider, StreamingProvider};
use std::sync::atomic::{AtomicU64, Ordering};

/// An HTTP streaming provider that speaks the OpenAI chat completions API.
///
/// This provider converts `saorsa-ai` request/response types to/from the
/// OpenAI wire format. It can talk to any server exposing `/v1/chat/completions`.
pub struct HttpStreamingProvider {
    base_url: String,
    api_key: String,
    model_id: String,
    agent: ureq::Agent,
    next_msg_id: AtomicU64,
}

impl HttpStreamingProvider {
    /// Create a new HTTP streaming provider.
    ///
    /// - `base_url`: The base URL including `/v1` (e.g. `https://api.openai.com/v1`).
    /// - `api_key`: Bearer token for authentication.
    /// - `model_id`: The model identifier to send in requests.
    pub fn new(base_url: String, api_key: String, model_id: String) -> Self {
        Self {
            base_url,
            api_key,
            model_id,
            agent: ureq::agent(),
            next_msg_id: AtomicU64::new(1),
        }
    }

    /// Build the OpenAI-compatible JSON request body from a `CompletionRequest`.
    fn build_openai_body(&self, request: &CompletionRequest) -> serde_json::Value {
        let mut messages = Vec::new();

        // System message first.
        if let Some(ref system) = request.system {
            messages.push(serde_json::json!({
                "role": "system",
                "content": system,
            }));
        }

        // Convert saorsa-ai messages to OpenAI format.
        for msg in &request.messages {
            let role = match msg.role {
                saorsa_ai::Role::User => "user",
                saorsa_ai::Role::Assistant => "assistant",
            };

            // Flatten content blocks into a single string for simple text,
            // or build multi-part content for tool use/results.
            let mut text_parts = Vec::new();
            for block in &msg.content {
                match block {
                    ContentBlock::Text { text } => text_parts.push(text.clone()),
                    ContentBlock::ToolUse { id, name, input } => {
                        // Encode tool use as text (OpenAI-compatible APIs use
                        // function_call, but for simplicity we encode as text
                        // since the agent loop handles tool parsing).
                        let input_str =
                            serde_json::to_string(input).unwrap_or_else(|_| "{}".into());
                        text_parts.push(format!(
                            "<tool_use name=\"{name}\" id=\"{id}\">{input_str}</tool_use>"
                        ));
                    }
                    ContentBlock::ToolResult {
                        tool_use_id,
                        content,
                    } => {
                        text_parts.push(format!(
                            "<tool_result id=\"{tool_use_id}\">{content}</tool_result>"
                        ));
                    }
                }
            }

            messages.push(serde_json::json!({
                "role": role,
                "content": text_parts.join("\n"),
            }));
        }

        let mut body = serde_json::json!({
            "model": self.model_id,
            "messages": messages,
            "stream": true,
            "max_tokens": request.max_tokens,
        });

        if let Some(temp) = request.temperature {
            body["temperature"] = serde_json::json!(temp);
        }

        body
    }

    /// Generate a unique message ID.
    fn next_id(&self) -> String {
        format!("msg_{}", self.next_msg_id.fetch_add(1, Ordering::Relaxed))
    }
}

#[async_trait]
impl Provider for HttpStreamingProvider {
    async fn complete(&self, request: CompletionRequest) -> SaorsaResult<CompletionResponse> {
        // Collect streaming results into a single response.
        let mut stream = self.stream(request.clone()).await?;
        let mut text = String::new();
        while let Some(ev) = stream.recv().await {
            match ev {
                Ok(StreamEvent::ContentBlockDelta {
                    delta: ContentDelta::TextDelta { text: t },
                    ..
                }) => text.push_str(&t),
                Ok(_) => {}
                Err(e) => return Err(e),
            }
        }

        Ok(CompletionResponse {
            id: self.next_id(),
            content: vec![ContentBlock::Text { text }],
            model: request.model,
            stop_reason: Some(StopReason::EndTurn),
            usage: Usage::default(),
        })
    }
}

#[async_trait]
impl StreamingProvider for HttpStreamingProvider {
    async fn stream(
        &self,
        request: CompletionRequest,
    ) -> SaorsaResult<tokio::sync::mpsc::Receiver<SaorsaResult<StreamEvent>>> {
        let body = self.build_openai_body(&request);
        let body_str = serde_json::to_string(&body)
            .map_err(|e| SaorsaAiError::Internal(format!("JSON serialization failed: {e}")))?;

        let base = self.base_url.trim_end_matches('/');
        let url = format!("{base}/chat/completions");
        let agent = self.agent.clone();
        let api_key = self.api_key.clone();
        let model_name = self.model_id.clone();
        let msg_id = self.next_id();

        let (tx, rx) = tokio::sync::mpsc::channel::<SaorsaResult<StreamEvent>>(64);

        tokio::task::spawn_blocking(move || {
            let mut req = agent.post(&url).set("Content-Type", "application/json");
            if !api_key.is_empty() {
                let auth = format!("Bearer {api_key}");
                req = req.set("Authorization", &auth);
            }

            let response = match req.send_string(&body_str) {
                Ok(r) => r,
                Err(e) => {
                    let _ = tx.blocking_send(Err(SaorsaAiError::Provider {
                        provider: "http".into(),
                        message: format!("HTTP request failed: {e}"),
                    }));
                    return;
                }
            };

            // Emit MessageStart.
            let _ = tx.blocking_send(Ok(StreamEvent::MessageStart {
                id: msg_id,
                model: model_name,
                usage: Usage::default(),
            }));

            // Start a text content block.
            let _ = tx.blocking_send(Ok(StreamEvent::ContentBlockStart {
                index: 0,
                content_block: ContentBlock::Text {
                    text: String::new(),
                },
            }));

            let reader = std::io::BufReader::new(response.into_reader());
            for line in std::io::BufRead::lines(reader) {
                let line = match line {
                    Ok(l) => l,
                    Err(e) => {
                        let _ = tx.blocking_send(Err(SaorsaAiError::Streaming(format!(
                            "read error: {e}"
                        ))));
                        return;
                    }
                };

                if line.is_empty() {
                    continue;
                }

                let Some(data) = line.strip_prefix("data: ") else {
                    continue;
                };

                if data == "[DONE]" {
                    break;
                }

                let chunk: serde_json::Value = match serde_json::from_str(data) {
                    Ok(v) => v,
                    Err(e) => {
                        let _ = tx.blocking_send(Err(SaorsaAiError::Streaming(format!(
                            "JSON parse error: {e}"
                        ))));
                        return;
                    }
                };

                // Extract delta content.
                if let Some(content) = chunk["choices"][0]["delta"]["content"].as_str()
                    && !content.is_empty()
                {
                    let _ = tx.blocking_send(Ok(StreamEvent::ContentBlockDelta {
                        index: 0,
                        delta: ContentDelta::TextDelta {
                            text: content.to_owned(),
                        },
                    }));
                }

                // Check for finish.
                if chunk["choices"][0]["finish_reason"].as_str() == Some("stop") {
                    break;
                }
            }

            // Close the content block.
            let _ = tx.blocking_send(Ok(StreamEvent::ContentBlockStop { index: 0 }));

            // Final message events.
            let _ = tx.blocking_send(Ok(StreamEvent::MessageDelta {
                stop_reason: Some(StopReason::EndTurn),
                usage: Usage::default(),
            }));
            let _ = tx.blocking_send(Ok(StreamEvent::MessageStop));
        });

        Ok(rx)
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;

    #[test]
    fn constructor_stores_fields() {
        let p = HttpStreamingProvider::new(
            "https://api.openai.com/v1".to_owned(),
            "sk-test".to_owned(),
            "gpt-4o".to_owned(),
        );
        assert_eq!(p.base_url, "https://api.openai.com/v1");
        assert_eq!(p.api_key, "sk-test");
        assert_eq!(p.model_id, "gpt-4o");
    }

    #[test]
    fn build_openai_body_basic() {
        let p = HttpStreamingProvider::new(
            "https://api.openai.com/v1".to_owned(),
            "sk-test".to_owned(),
            "gpt-4o".to_owned(),
        );
        let request = CompletionRequest::new(
            "gpt-4o",
            vec![saorsa_ai::message::Message::user("Hello")],
            1024,
        )
        .system("You are helpful".to_owned())
        .temperature(0.7);

        let body = p.build_openai_body(&request);
        assert_eq!(body["model"], "gpt-4o");
        assert_eq!(body["max_tokens"], 1024);
        assert_eq!(body["stream"], true);
        // f32 temperature 0.7 serializes with floating-point precision loss.
        let temp = body["temperature"].as_f64().unwrap();
        assert!((temp - 0.7).abs() < 0.001);

        let messages = body["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0]["role"], "system");
        assert_eq!(messages[0]["content"], "You are helpful");
        assert_eq!(messages[1]["role"], "user");
        assert_eq!(messages[1]["content"], "Hello");
    }

    #[test]
    fn build_openai_body_no_system() {
        let p = HttpStreamingProvider::new(
            "http://localhost:8080/v1".to_owned(),
            String::new(),
            "fae-qwen3".to_owned(),
        );
        let request = CompletionRequest::new(
            "fae-qwen3",
            vec![saorsa_ai::message::Message::user("Hi")],
            512,
        );

        let body = p.build_openai_body(&request);
        let messages = body["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 1); // No system message
        assert_eq!(messages[0]["role"], "user");
    }

    #[test]
    fn build_openai_body_tool_content_encoded() {
        let p = HttpStreamingProvider::new(
            "http://localhost/v1".to_owned(),
            String::new(),
            "test".to_owned(),
        );

        let msg = saorsa_ai::message::Message {
            role: saorsa_ai::Role::Assistant,
            content: vec![ContentBlock::ToolUse {
                id: "tool_1".to_owned(),
                name: "read".to_owned(),
                input: serde_json::json!({"path": "/tmp"}),
            }],
        };
        let request = CompletionRequest::new("test", vec![msg], 256);
        let body = p.build_openai_body(&request);
        let content = body["messages"][0]["content"].as_str().unwrap();
        assert!(content.contains("<tool_use"));
        assert!(content.contains("read"));
    }

    #[test]
    fn next_id_increments() {
        let p = HttpStreamingProvider::new(
            "http://localhost/v1".to_owned(),
            String::new(),
            "test".to_owned(),
        );
        let id1 = p.next_id();
        let id2 = p.next_id();
        assert_ne!(id1, id2);
        assert!(id1.starts_with("msg_"));
        assert!(id2.starts_with("msg_"));
    }
}
