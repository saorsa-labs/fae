//! Language model inference.
//!
//! Provides two backends:
//! - **Local** (default): GGUF models via `mistralrs`, with Metal GPU on Apple Silicon.
//! - **API** (remote): Any OpenAI-compatible server (MLX, vLLM, llama.cpp, etc.).

pub mod api;
pub mod fallback;

pub use api::ApiLlm;

use crate::config::LlmConfig;
use crate::error::{Result, SpeechError};
use crate::pipeline::messages::SentenceChunk;
use mistralrs::{
    GgufModelBuilder, MemoryGpuConfig, Model, PagedAttentionMetaBuilder, RequestBuilder, Response,
    TextMessageRole, TextMessages,
};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tracing::{info, warn};

/// Minimum allowed local context size.
const MIN_CONTEXT_SIZE_TOKENS: usize = 1024;
/// Abort generation when a model emits only reasoning deltas for too long.
///
/// This keeps conversational latency bounded for models that ignore no-think
/// controls and never surface visible content.
const REASONING_ONLY_EVENT_LIMIT: usize = 96;
const REASONING_ONLY_DURATION_LIMIT: Duration = Duration::from_secs(12);

/// Incrementally strips `<think>...</think>` blocks across streaming chunks.
#[derive(Debug, Default)]
struct ThinkTagStripper {
    in_think_block: bool,
    carry: String,
}

impl ThinkTagStripper {
    const OPEN: &'static str = "<think>";
    const CLOSE: &'static str = "</think>";

    /// Feed one fragment and return newly-visible text (outside think blocks).
    fn push(&mut self, fragment: &str) -> String {
        if fragment.is_empty() {
            return String::new();
        }
        self.carry.push_str(fragment);

        let mut visible = String::new();
        loop {
            if self.in_think_block {
                if let Some(end) = self.carry.find(Self::CLOSE) {
                    self.carry.drain(..end + Self::CLOSE.len());
                    self.in_think_block = false;
                    continue;
                }
                // Keep only the minimal suffix needed to detect `</think>` across chunks.
                let keep = Self::CLOSE.len().saturating_sub(1);
                if self.carry.len() > keep {
                    let drain = self.carry.len() - keep;
                    self.carry.drain(..drain);
                }
                break;
            }

            if let Some(start) = self.carry.find(Self::OPEN) {
                visible.push_str(&self.carry[..start]);
                self.carry.drain(..start + Self::OPEN.len());
                self.in_think_block = true;
                continue;
            }

            // Keep only a small suffix in case the next chunk starts with the rest of a tag.
            let keep = Self::OPEN.len().max(Self::CLOSE.len()).saturating_sub(1);
            if self.carry.len() > keep {
                let emit = self.carry.len() - keep;
                visible.push_str(&self.carry[..emit]);
                self.carry.drain(..emit);
            }
            break;
        }

        visible
    }

    /// Flush any remaining visible tail.
    fn finish(&mut self) -> String {
        if self.in_think_block {
            self.carry.clear();
            return String::new();
        }
        std::mem::take(&mut self.carry)
    }
}

/// Language model for generating conversational responses.
///
/// Uses `mistralrs` for high-level GGUF inference with streaming token
/// generation and sentence-level buffering for TTS consumption.
pub struct LocalLlm {
    model: Arc<Model>,
    config: LlmConfig,
    /// Conversation history: (role, content) pairs.
    history: Vec<(TextMessageRole, String)>,
}

impl LocalLlm {
    /// Get the underlying mistralrs model for use in provider adapters.
    pub fn shared_model(&self) -> Arc<Model> {
        Arc::clone(&self.model)
    }

    pub(crate) async fn load_local_model(config: &LlmConfig) -> Result<Arc<Model>> {
        info!(
            "loading local LLM: {} / {}",
            config.model_id, config.gguf_file
        );

        let mut builder =
            GgufModelBuilder::new(&config.model_id, vec![&config.gguf_file]).with_logging();

        if !config.tokenizer_id.is_empty() {
            builder = builder.with_tok_model_id(&config.tokenizer_id);
        }

        let context_size = effective_context_size_tokens(config);
        info!("local LLM context_size_tokens={context_size}");

        let model = builder
            .with_paged_attn(|| {
                PagedAttentionMetaBuilder::default()
                    .with_gpu_memory(MemoryGpuConfig::ContextSize(context_size))
                    .build()
            })
            .map_err(|e| SpeechError::Llm(format!("paged attention config failed: {e}")))?
            .build()
            .await
            .map_err(|e| SpeechError::Llm(format!("model build failed: {e}")))?;

        info!("local LLM loaded successfully");
        Ok(Arc::new(model))
    }

    /// Build a new local LLM from the given configuration.
    ///
    /// This downloads the GGUF model (if not cached) and loads it onto
    /// the best available device (Metal GPU on Apple Silicon, CPU otherwise).
    ///
    /// # Errors
    ///
    /// Returns an error if model loading fails.
    pub async fn new(config: &LlmConfig) -> Result<Self> {
        let model = Self::load_local_model(config).await?;

        let history = vec![(
            TextMessageRole::System,
            config.effective_system_prompt(None),
        )];

        Ok(Self {
            model,
            config: config.clone(),
            history,
        })
    }

    /// Generate a response to the given user input, streaming sentences to the channel.
    ///
    /// Tokens are accumulated into sentences (split on `.`, `!`, `?`, `\n`).
    /// Each complete sentence is sent to the TTS stage immediately for
    /// low-latency speech output.
    ///
    /// The `interrupt` flag is checked every chunk. If set, generation stops
    /// early and the partial response is saved. Returns `true` if interrupted.
    ///
    /// # Errors
    ///
    /// Returns an error if generation fails.
    pub async fn generate_response(
        &mut self,
        user_input: String,
        tx: mpsc::Sender<SentenceChunk>,
        interrupt: Arc<AtomicBool>,
    ) -> Result<bool> {
        // Add user message to history
        self.history
            .push((TextMessageRole::User, user_input.clone()));
        self.trim_history();

        // Clear interrupt flag at the start of each generation
        interrupt.store(false, Ordering::Relaxed);

        info!("generating response to: {user_input}");
        let gen_start = Instant::now();

        // Build messages from history, disabling thinking blocks natively
        let mut messages = TextMessages::new().enable_thinking(false);
        for (role, content) in &self.history {
            messages = messages.add_message(role.clone(), content);
        }

        // Configure sampling parameters
        let request = RequestBuilder::from(messages)
            .set_sampler_temperature(self.config.temperature)
            .set_sampler_topp(self.config.top_p)
            .set_sampler_max_len(self.config.max_tokens)
            .enable_thinking(false);

        // Start streaming
        info!("sending stream request to mistralrs engine");
        let model = Arc::clone(&self.model);
        let mut stream = model
            .stream_chat_request(request)
            .await
            .map_err(|e| SpeechError::Llm(format!("stream request failed: {e}")))?;
        info!("stream started, waiting for first token");

        let mut generated_text = String::new();
        let mut sentence_buffer = String::new();
        let mut token_count: usize = 0;
        let mut reasoning_only_events: usize = 0;
        let mut has_visible_output = false;
        let mut was_interrupted = false;
        let mut think_stripper = ThinkTagStripper::default();
        let mut first_token_received = false;

        /// Maximum time to wait for the first token before giving up.
        const FIRST_TOKEN_TIMEOUT: Duration = Duration::from_secs(120);

        loop {
            let response = if !first_token_received {
                // Apply a timeout for the first token — model warm-up on CPU can be slow
                // but shouldn't take more than 2 minutes.
                match tokio::time::timeout(FIRST_TOKEN_TIMEOUT, stream.next()).await {
                    Ok(Some(r)) => r,
                    Ok(None) => break,
                    Err(_) => {
                        warn!(
                            "first token timeout after {}s — model may be too slow on CPU; \
                             consider enabling the 'metal' feature for GPU acceleration",
                            FIRST_TOKEN_TIMEOUT.as_secs()
                        );
                        return Err(SpeechError::Llm(
                            "first token timeout — model did not produce output in time".to_owned(),
                        ));
                    }
                }
            } else {
                match stream.next().await {
                    Some(r) => r,
                    None => break,
                }
            };

            // Check interrupt flag (set by conversation gate on barge-in)
            if interrupt.load(Ordering::Relaxed) {
                info!("generation interrupted after {token_count} tokens");
                was_interrupted = true;
                break;
            }

            match response {
                Response::Chunk(chunk) => {
                    if let Some(choice) = chunk.choices.first() {
                        let content = choice.delta.content.as_deref().unwrap_or_default();
                        let reasoning = choice
                            .delta
                            .reasoning_content
                            .as_deref()
                            .unwrap_or_default();
                        if content.is_empty() && reasoning.is_empty() {
                            continue;
                        }
                        if !first_token_received {
                            first_token_received = true;
                            let ttft = gen_start.elapsed();
                            info!("first token received in {:.1}s", ttft.as_secs_f64());
                        }

                        token_count += 1;
                        if content.is_empty() && !reasoning.is_empty() {
                            reasoning_only_events += 1;
                            if should_abort_reasoning_only(
                                reasoning_only_events,
                                has_visible_output,
                                gen_start.elapsed(),
                            ) {
                                warn!(
                                    "aborting generation after {reasoning_only_events} \
                                     reasoning-only events in {:.1}s (no visible output)",
                                    gen_start.elapsed().as_secs_f64()
                                );
                                return Err(SpeechError::Llm(
                                    "model produced reasoning-only output for too long".to_owned(),
                                ));
                            }
                            continue;
                        }

                        let visible = think_stripper.push(content);
                        if !visible.is_empty() {
                            has_visible_output = true;
                        }
                        append_visible_text(
                            &visible,
                            &mut generated_text,
                            &mut sentence_buffer,
                            &tx,
                        )
                        .await?;
                    }
                }
                Response::Done(done) => {
                    if let Some(choice) = done.choices.first() {
                        let content = choice.message.content.as_deref().unwrap_or_default();
                        let reasoning = choice
                            .message
                            .reasoning_content
                            .as_deref()
                            .unwrap_or_default();
                        if content.is_empty() && !reasoning.is_empty() {
                            reasoning_only_events += 1;
                        }
                        if !content.is_empty() {
                            let visible = think_stripper.push(content);
                            append_visible_text(
                                &visible,
                                &mut generated_text,
                                &mut sentence_buffer,
                                &tx,
                            )
                            .await?;
                        }
                    }
                    break;
                }
                Response::ModelError(msg, _) => {
                    return Err(SpeechError::Llm(format!("model error: {msg}")));
                }
                Response::InternalError(e) => {
                    return Err(SpeechError::Llm(format!("internal error: {e}")));
                }
                Response::ValidationError(e) => {
                    return Err(SpeechError::Llm(format!("validation error: {e}")));
                }
                _ => {}
            }
        }

        // Flush any non-think tail left in the incremental parser.
        let tail = think_stripper.finish();
        if !tail.is_empty() {
            append_visible_text(&tail, &mut generated_text, &mut sentence_buffer, &tx).await?;
        }

        // Send any remaining text as the final sentence
        let remaining = sentence_buffer.trim().to_owned();
        if !remaining.is_empty() {
            let chunk = SentenceChunk {
                text: remaining,
                is_final: true,
            };
            tx.send(chunk)
                .await
                .map_err(|e| SpeechError::Channel(format!("LLM output channel closed: {e}")))?;
        } else {
            // Signal end-of-response to the pipeline
            let chunk = SentenceChunk {
                text: String::new(),
                is_final: true,
            };
            tx.send(chunk)
                .await
                .map_err(|e| SpeechError::Channel(format!("LLM output channel closed: {e}")))?;
        }

        // Add assistant response to history (even partial, if non-empty)
        let final_text = generated_text.trim().to_owned();
        if !final_text.is_empty() {
            self.history.push((TextMessageRole::Assistant, final_text));
        } else if reasoning_only_events > 0 {
            warn!(
                "local model produced {reasoning_only_events} reasoning-only events \
                 without visible content"
            );
        }
        self.trim_history();

        let elapsed = gen_start.elapsed();
        let tokens_per_sec = if elapsed.as_secs_f64() > 0.0 {
            token_count as f64 / elapsed.as_secs_f64()
        } else {
            0.0
        };
        info!(
            "generated {token_count} tokens in {:.1}s ({:.1} tok/s){}",
            elapsed.as_secs_f64(),
            tokens_per_sec,
            if was_interrupted {
                " [interrupted]"
            } else {
                ""
            },
        );
        Ok(was_interrupted)
    }

    /// Truncate the conversation history to keep only the system prompt and
    /// the first `keep_count` messages after it.
    ///
    /// This is used by conversation forking to rewind to a specific point.
    pub fn truncate_history(&mut self, keep_count: usize) {
        if self.history.len() > 1 + keep_count {
            self.history.truncate(1 + keep_count);
        }
    }

    fn trim_history(&mut self) {
        let max = self.config.max_history_messages;
        if max == 0 {
            return;
        }
        // Keep the system prompt at index 0, then retain the last `max` messages.
        if self.history.len() > 1 + max {
            let drain_end = self.history.len().saturating_sub(max);
            if drain_end > 1 {
                self.history.drain(1..drain_end);
            }
        }
    }
}

async fn append_visible_text(
    text: &str,
    generated_text: &mut String,
    sentence_buffer: &mut String,
    tx: &mpsc::Sender<SentenceChunk>,
) -> Result<()> {
    if text.is_empty() {
        return Ok(());
    }

    generated_text.push_str(text);
    sentence_buffer.push_str(text);

    // Check for clause/sentence boundaries for streaming TTS.
    if let Some(pos) = find_clause_boundary(sentence_buffer) {
        let sentence = sentence_buffer[..=pos].trim().to_owned();
        if !sentence.is_empty() {
            let sentence_chunk = SentenceChunk {
                text: sentence,
                is_final: false,
            };
            tx.send(sentence_chunk)
                .await
                .map_err(|e| SpeechError::Channel(format!("LLM output channel closed: {e}")))?;
        }
        *sentence_buffer = sentence_buffer[pos + 1..].to_owned();
    }

    Ok(())
}

fn should_abort_reasoning_only(
    reasoning_only_events: usize,
    has_visible_output: bool,
    elapsed: Duration,
) -> bool {
    !has_visible_output
        && reasoning_only_events >= REASONING_ONLY_EVENT_LIMIT
        && elapsed >= REASONING_ONLY_DURATION_LIMIT
}

pub(crate) fn effective_context_size_tokens(config: &LlmConfig) -> usize {
    if config.context_size_tokens < MIN_CONTEXT_SIZE_TOKENS {
        warn!(
            "llm.context_size_tokens={} too small, clamping to {}",
            config.context_size_tokens, MIN_CONTEXT_SIZE_TOKENS
        );
        return MIN_CONTEXT_SIZE_TOKENS;
    }
    config.context_size_tokens
}

/// Find the position of a sentence-ending character (`.`, `!`, `?`, `\n`).
///
/// Returns the byte index of the boundary character, or `None` if no
/// boundary is found.
pub(crate) fn find_sentence_boundary(text: &str) -> Option<usize> {
    // Look for sentence-ending punctuation followed by a space or end of text
    for (i, c) in text.char_indices() {
        if matches!(c, '.' | '!' | '?' | '\n') {
            // Check if this is likely a sentence boundary (not a decimal point, etc.)
            let rest = &text[i + c.len_utf8()..];
            if rest.is_empty() || rest.starts_with(' ') || rest.starts_with('\n') {
                return Some(i);
            }
        }
    }
    None
}

/// Minimum accumulated buffer length (chars) before splitting on clause punctuation.
const CLAUSE_MIN_LEN: usize = 20;

/// Find the position of a clause boundary for streaming TTS.
///
/// Always splits on sentence-ending punctuation (`. ! ? \n`). Additionally,
/// when the buffer exceeds [`CLAUSE_MIN_LEN`] characters, also splits on
/// clause punctuation (`, ; : — –`) to enable lower-latency streaming.
///
/// Returns the byte index of the last byte of the boundary character, or `None`.
///
/// Callers use `text[..=pos]` and `text[pos + 1..]`, so we must return the
/// last byte of the (possibly multi-byte) punctuation character to ensure
/// both slices land on valid UTF-8 char boundaries.
pub(crate) fn find_clause_boundary(text: &str) -> Option<usize> {
    // Sentence boundaries take priority.
    if let Some(pos) = find_sentence_boundary(text) {
        return Some(pos);
    }

    // Only split on clause punctuation when we have enough text.
    if text.len() < CLAUSE_MIN_LEN {
        return None;
    }

    // Find the *last* clause-level punctuation mark so we send the
    // longest possible chunk rather than splitting too early.
    let mut last_clause: Option<usize> = None;
    for (i, c) in text.char_indices() {
        if matches!(c, ',' | ';' | ':' | '\u{2014}' | '\u{2013}') {
            // Only count if followed by a space or end of text.
            let rest = &text[i + c.len_utf8()..];
            if rest.is_empty() || rest.starts_with(' ') {
                // Return last byte of the character so [..=pos] is char-safe.
                last_clause = Some(i + c.len_utf8() - 1);
            }
        }
    }
    last_clause
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;

    #[test]
    fn effective_context_size_uses_config_value() {
        let cfg = LlmConfig {
            context_size_tokens: 65_536,
            ..Default::default()
        };
        assert_eq!(effective_context_size_tokens(&cfg), 65_536);
    }

    #[test]
    fn effective_context_size_clamps_small_values() {
        let cfg = LlmConfig {
            context_size_tokens: 0,
            ..Default::default()
        };
        assert_eq!(effective_context_size_tokens(&cfg), MIN_CONTEXT_SIZE_TOKENS);
    }

    #[test]
    fn think_stripper_passes_plain_text() {
        let mut s = ThinkTagStripper::default();
        let out = s.push("hello world");
        assert_eq!(out, "hell");
        let tail = s.finish();
        assert_eq!(tail, "o world");
    }

    #[test]
    fn think_stripper_removes_inline_block() {
        let mut s = ThinkTagStripper::default();
        let out = s.push("hi <think>hidden</think> there");
        let tail = s.finish();
        assert_eq!(format!("{out}{tail}"), "hi  there");
    }

    #[test]
    fn think_stripper_handles_split_tags() {
        let mut s = ThinkTagStripper::default();
        let a = s.push("pre<thi");
        let b = s.push("nk>hide");
        let c = s.push("n</thin");
        let d = s.push("k>post");
        let tail = s.finish();
        assert_eq!(format!("{a}{b}{c}{d}{tail}"), "prepost");
    }

    #[test]
    fn reasoning_only_cutoff_triggers_without_visible_output() {
        assert!(should_abort_reasoning_only(
            REASONING_ONLY_EVENT_LIMIT,
            false,
            REASONING_ONLY_DURATION_LIMIT
        ));
    }

    #[test]
    fn reasoning_only_cutoff_does_not_trigger_with_visible_output() {
        assert!(!should_abort_reasoning_only(
            REASONING_ONLY_EVENT_LIMIT * 2,
            true,
            REASONING_ONLY_DURATION_LIMIT * 2
        ));
    }

    #[test]
    fn reasoning_only_cutoff_does_not_trigger_before_time_limit() {
        assert!(!should_abort_reasoning_only(
            REASONING_ONLY_EVENT_LIMIT * 2,
            false,
            REASONING_ONLY_DURATION_LIMIT.saturating_sub(Duration::from_secs(1))
        ));
    }
}
