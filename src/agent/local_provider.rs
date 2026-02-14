//! Local `saorsa-ai` provider backed by `mistralrs` (in-process inference).
//!
//! This lets `saorsa-agent` run with tools without requiring an external
//! OpenAI-compatible HTTP server, keeping the app as a single binary.
//!
//! Note: `saorsa-ai`'s built-in mistralrs provider currently rejects tool
//! definitions/blocks. This shim encodes tool calls/results into explicit tags
//! and emits structured `StreamEvent` tool blocks so the `saorsa-agent` loop can
//! execute tools.

use crate::config::LlmConfig;
use crate::error::SpeechError;
use async_trait::async_trait;
use mistralrs::{Model, RequestBuilder, Response, TextMessageRole, TextMessages};
use saorsa_ai::error::{Result as SaorsaResult, SaorsaAiError};
use saorsa_ai::message::ContentBlock;
use saorsa_ai::types::{
    CompletionRequest, CompletionResponse, ContentDelta, StopReason, StreamEvent, Usage,
};
use saorsa_ai::{Provider, StreamingProvider};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

pub struct ToolingMistralrsProvider {
    model: Arc<Model>,
    cfg: LlmConfig,
    next_msg_id: AtomicU64,
}

impl ToolingMistralrsProvider {
    pub fn new(model: Arc<Model>, cfg: LlmConfig) -> Self {
        Self {
            model,
            cfg,
            next_msg_id: AtomicU64::new(1),
        }
    }

    fn build_system_prompt(&self, request: &CompletionRequest) -> String {
        let mut prompt = request.system.clone().unwrap_or_default();
        if !prompt.is_empty() {
            prompt.push_str("\n\n");
        }

        prompt.push_str("Tool use:\n");
        prompt.push_str("- If you need a tool, output ONLY one or more <tool_use ...> blocks.\n");
        prompt.push_str(
            "- Format (exact): <tool_use name=\"TOOL\" id=\"tool_1\">{JSON}</tool_use>\n",
        );
        prompt.push_str("- The JSON must be a single object that matches the tool schema.\n");
        prompt.push_str("- Do not wrap tool JSON in markdown.\n\n");

        if !request.tools.is_empty() {
            prompt.push_str("Available tools:\n");
            for t in &request.tools {
                let schema = serde_json::to_string(&t.input_schema).unwrap_or_else(|_| "{}".into());
                prompt.push_str("- ");
                prompt.push_str(&t.name);
                prompt.push_str(": ");
                prompt.push_str(&t.description);
                prompt.push_str(" schema=");
                prompt.push_str(&schema);
                prompt.push('\n');
            }
        }

        prompt
    }

    fn build_messages(&self, request: &CompletionRequest) -> TextMessages {
        let system = self.build_system_prompt(request);
        let mut messages = TextMessages::new().enable_thinking(false);
        if !system.is_empty() {
            messages = messages.add_message(TextMessageRole::System, system);
        }

        for m in &request.messages {
            let role = match m.role {
                saorsa_ai::Role::User => TextMessageRole::User,
                saorsa_ai::Role::Assistant => TextMessageRole::Assistant,
            };
            let mut text = String::new();
            for block in &m.content {
                match block {
                    ContentBlock::Text { text: t } => {
                        text.push_str(t);
                    }
                    ContentBlock::ToolUse { id, name, input } => {
                        let input_str =
                            serde_json::to_string(input).unwrap_or_else(|_| "{}".into());
                        text.push_str(&format!(
                            "<tool_use name=\"{name}\" id=\"{id}\">{input_str}</tool_use>"
                        ));
                    }
                    ContentBlock::ToolResult {
                        tool_use_id,
                        content,
                    } => {
                        text.push_str(&format!(
                            "<tool_result id=\"{tool_use_id}\">{content}</tool_result>"
                        ));
                    }
                }
                text.push('\n');
            }
            messages = messages.add_message(role, text.trim().to_owned());
        }

        messages
    }
}

#[async_trait]
impl Provider for ToolingMistralrsProvider {
    async fn complete(&self, request: CompletionRequest) -> SaorsaResult<CompletionResponse> {
        // Best-effort: run a streaming request and collect text into a single block.
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
            id: format!("msg_{}", self.next_msg_id.fetch_add(1, Ordering::Relaxed)),
            content: vec![ContentBlock::Text { text }],
            model: request.model,
            stop_reason: Some(StopReason::EndTurn),
            usage: Usage::default(),
        })
    }
}

#[async_trait]
impl StreamingProvider for ToolingMistralrsProvider {
    async fn stream(
        &self,
        request: CompletionRequest,
    ) -> SaorsaResult<tokio::sync::mpsc::Receiver<SaorsaResult<StreamEvent>>> {
        let messages = self.build_messages(&request);

        let req = RequestBuilder::from(messages)
            .set_sampler_temperature(self.cfg.temperature)
            .set_sampler_topp(self.cfg.top_p)
            .set_sampler_max_len(request.max_tokens as usize)
            .enable_thinking(false);

        let (tx, rx) = tokio::sync::mpsc::channel::<SaorsaResult<StreamEvent>>(64);
        let model_name = request.model.clone();
        let msg_id = format!("msg_{}", self.next_msg_id.fetch_add(1, Ordering::Relaxed));
        let model = Arc::clone(&self.model);

        tokio::spawn(async move {
            let mut stream = match model.stream_chat_request(req).await {
                Ok(s) => s,
                Err(e) => {
                    let _ = tx
                        .send(Err(SaorsaAiError::Provider {
                            provider: "mistralrs".into(),
                            message: format!("{e}"),
                        }))
                        .await;
                    return;
                }
            };

            let mut block_index: u32 = 0;
            let mut open_text = false;
            let mut open_tool: Option<(String, String)> = None;
            let mut tool_used = false;

            let mut buffer = String::new();

            let _ = tx
                .send(Ok(StreamEvent::MessageStart {
                    id: msg_id,
                    model: model_name,
                    usage: Usage::default(),
                }))
                .await;

            while let Some(resp) = stream.next().await {
                let chunk = match resp {
                    Response::Chunk(c) => Some(c),
                    Response::Done(done) => {
                        // Some models only surface final text in the terminal Done response.
                        if let Some(choice) = done.choices.first()
                            && let Some(content) = choice.message.content.as_deref()
                            && !content.is_empty()
                        {
                            buffer.push_str(content);
                        }
                        None
                    }
                    Response::ModelError(msg, _) => {
                        let _ = tx
                            .send(Err(SaorsaAiError::Streaming(format!("model error: {msg}"))))
                            .await;
                        return;
                    }
                    Response::InternalError(e) => {
                        let _ = tx
                            .send(Err(SaorsaAiError::Streaming(format!(
                                "internal error: {e}"
                            ))))
                            .await;
                        return;
                    }
                    Response::ValidationError(e) => {
                        let _ = tx
                            .send(Err(SaorsaAiError::InvalidRequest(format!(
                                "validation error: {e}"
                            ))))
                            .await;
                        return;
                    }
                    _ => continue,
                };
                let Some(chunk) = chunk else { break };

                let Some(choice) = chunk.choices.first() else {
                    continue;
                };
                let Some(content) = choice.delta.content.as_deref() else {
                    continue;
                };
                if content.is_empty() {
                    continue;
                }

                buffer.push_str(content);

                loop {
                    if open_tool.is_some() {
                        if let Some(end_pos) = buffer.find("</tool_use>") {
                            let json = buffer[..end_pos].to_owned();

                            let _ = tx
                                .send(Ok(StreamEvent::ContentBlockDelta {
                                    index: block_index,
                                    delta: ContentDelta::InputJsonDelta { partial_json: json },
                                }))
                                .await;

                            let _ = tx
                                .send(Ok(StreamEvent::ContentBlockStop { index: block_index }))
                                .await;

                            tool_used = true;
                            open_tool = None;
                            block_index = block_index.saturating_add(1);
                            buffer = buffer[end_pos + "</tool_use>".len()..].to_owned();
                            continue;
                        }
                        break;
                    }

                    let Some(start_pos) = buffer.find("<tool_use") else {
                        // No tool tag yet; emit safe text but keep a suffix that might start a tag.
                        let keep = tool_tag_prefix_len(&buffer);
                        let emit_len = buffer.len().saturating_sub(keep);
                        if emit_len > 0 {
                            let text = buffer[..emit_len].to_owned();
                            if !open_text {
                                let _ = tx
                                    .send(Ok(StreamEvent::ContentBlockStart {
                                        index: block_index,
                                        content_block: ContentBlock::Text {
                                            text: String::new(),
                                        },
                                    }))
                                    .await;
                                open_text = true;
                            }
                            let _ = tx
                                .send(Ok(StreamEvent::ContentBlockDelta {
                                    index: block_index,
                                    delta: ContentDelta::TextDelta { text },
                                }))
                                .await;
                            buffer = buffer[emit_len..].to_owned();
                        }
                        break;
                    };

                    // Emit any text before the tool tag.
                    if start_pos > 0 {
                        let text = buffer[..start_pos].to_owned();
                        if !text.is_empty() {
                            if !open_text {
                                let _ = tx
                                    .send(Ok(StreamEvent::ContentBlockStart {
                                        index: block_index,
                                        content_block: ContentBlock::Text {
                                            text: String::new(),
                                        },
                                    }))
                                    .await;
                                open_text = true;
                            }
                            let _ = tx
                                .send(Ok(StreamEvent::ContentBlockDelta {
                                    index: block_index,
                                    delta: ContentDelta::TextDelta { text },
                                }))
                                .await;
                        }
                        buffer = buffer[start_pos..].to_owned();
                    }

                    // Close text block before tool use.
                    if open_text {
                        let _ = tx
                            .send(Ok(StreamEvent::ContentBlockStop { index: block_index }))
                            .await;
                        open_text = false;
                        block_index = block_index.saturating_add(1);
                    }

                    // Need the full start tag to proceed.
                    let Some(tag_end) = buffer.find('>') else {
                        break;
                    };
                    let tag = buffer[..=tag_end].to_owned();
                    let (tool_name, tool_id) = parse_tool_use_tag(&tag);
                    let tool_name = tool_name.unwrap_or_else(|| "unknown".into());
                    let tool_id = tool_id.unwrap_or_else(|| format!("tool_{block_index}"));

                    let _ = tx
                        .send(Ok(StreamEvent::ContentBlockStart {
                            index: block_index,
                            content_block: ContentBlock::ToolUse {
                                id: tool_id.clone(),
                                name: tool_name.clone(),
                                input: serde_json::Value::Object(serde_json::Map::new()),
                            },
                        }))
                        .await;

                    open_tool = Some((tool_id, tool_name));
                    buffer = buffer[tag_end + 1..].to_owned();
                }
            }

            // If the model started a tool use but never closed it, close it best-effort.
            if open_tool.is_some() && !buffer.is_empty() {
                let _ = tx
                    .send(Ok(StreamEvent::ContentBlockDelta {
                        index: block_index,
                        delta: ContentDelta::InputJsonDelta {
                            partial_json: buffer.clone(),
                        },
                    }))
                    .await;
                let _ = tx
                    .send(Ok(StreamEvent::ContentBlockStop { index: block_index }))
                    .await;
                tool_used = true;
                buffer.clear();
                block_index = block_index.saturating_add(1);
            }

            // Flush any remaining text.
            if !buffer.is_empty() {
                if !open_text {
                    let _ = tx
                        .send(Ok(StreamEvent::ContentBlockStart {
                            index: block_index,
                            content_block: ContentBlock::Text {
                                text: String::new(),
                            },
                        }))
                        .await;
                    open_text = true;
                }
                let _ = tx
                    .send(Ok(StreamEvent::ContentBlockDelta {
                        index: block_index,
                        delta: ContentDelta::TextDelta { text: buffer },
                    }))
                    .await;
            }

            if open_text {
                let _ = tx
                    .send(Ok(StreamEvent::ContentBlockStop { index: block_index }))
                    .await;
            }

            let stop_reason = if tool_used {
                Some(StopReason::ToolUse)
            } else {
                Some(StopReason::EndTurn)
            };

            let _ = tx
                .send(Ok(StreamEvent::MessageDelta {
                    stop_reason,
                    usage: Usage::default(),
                }))
                .await;
            let _ = tx.send(Ok(StreamEvent::MessageStop)).await;
        });

        Ok(rx)
    }
}

fn tool_tag_prefix_len(s: &str) -> usize {
    const TAG: &str = "<tool_use";
    let max = s.len().min(TAG.len());
    for k in (1..=max).rev() {
        if s.ends_with(&TAG[..k]) {
            return k;
        }
    }
    0
}

fn parse_tool_use_tag(tag: &str) -> (Option<String>, Option<String>) {
    // Very small parser: look for name="..." and id="...".
    // We keep this tolerant because models may omit attributes.
    fn extract(tag: &str, key: &str) -> Option<String> {
        let needle = format!("{key}=\"");
        let start = tag.find(&needle)?;
        let rest = &tag[start + needle.len()..];
        let end = rest.find('"')?;
        Some(rest[..end].to_owned())
    }

    (extract(tag, "name"), extract(tag, "id"))
}

impl From<SpeechError> for SaorsaAiError {
    fn from(e: SpeechError) -> Self {
        SaorsaAiError::Internal(e.to_string())
    }
}
