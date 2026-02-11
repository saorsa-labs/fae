//! OpenAI-compatible API backend for LLM inference.
//!
//! Supports any server implementing the OpenAI chat completions API:
//! - Ollama (`http://localhost:11434`)
//! - MLX server (`http://localhost:8080`)
//! - vLLM, llama.cpp server, etc.

use crate::config::LlmConfig;
use crate::error::{Result, SpeechError};
use crate::pipeline::messages::SentenceChunk;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;
use tokio::sync::mpsc;
use tracing::info;

/// LLM backend using an OpenAI-compatible HTTP API.
///
/// Streams responses via Server-Sent Events (SSE) for low-latency
/// sentence delivery to TTS.
///
/// Connection details (URL, model, API key) can come from either:
/// - Direct config (`api_url`, `api_model`, `api_key`), or
/// - Pi's `~/.pi/agent/models.json` when `cloud_provider` is set.
pub struct ApiLlm {
    config: LlmConfig,
    /// Resolved connection details (may come from models.json).
    conn: ResolvedConnection,
    history: Vec<ChatMessage>,
    agent: ureq::Agent,
}

/// Resolved connection details for the API backend.
#[derive(Debug, Clone)]
struct ResolvedConnection {
    api_url: String,
    api_model: String,
    api_key: String,
}

/// A single message in the conversation history.
#[derive(Debug, Clone)]
struct ChatMessage {
    role: &'static str,
    content: String,
}

impl ApiLlm {
    /// Create a new API-based LLM instance.
    ///
    /// When `cloud_provider` is set in config, connection details are
    /// resolved from Pi's `~/.pi/agent/models.json`. Otherwise, the
    /// `api_url`, `api_model`, and `api_key` config fields are used directly.
    ///
    /// # Errors
    ///
    /// Returns an error if configuration is invalid or the cloud provider
    /// cannot be found in models.json.
    pub fn new(config: &LlmConfig) -> Result<Self> {
        let agent = ureq::agent();

        let conn = resolve_connection(config)?;

        info!(
            "API LLM configured: {} model={}",
            conn.api_url, conn.api_model
        );

        let history = vec![ChatMessage {
            role: "system",
            content: config.effective_system_prompt(),
        }];

        Ok(Self {
            config: config.clone(),
            conn,
            history,
            agent,
        })
    }

    /// Generate a streaming response from the API.
    ///
    /// Tokens are accumulated into sentences and sent to the TTS stage.
    /// The `interrupt` flag is checked every token. Returns `true` if
    /// the generation was interrupted.
    ///
    /// # Errors
    ///
    /// Returns an error if the API call or streaming fails.
    pub async fn generate_response(
        &mut self,
        user_input: &str,
        tx: &mpsc::Sender<SentenceChunk>,
        interrupt: &Arc<AtomicBool>,
    ) -> Result<bool> {
        self.history.push(ChatMessage {
            role: "user",
            content: user_input.to_owned(),
        });
        self.trim_history();

        interrupt.store(false, Ordering::Relaxed);

        info!("API generating response to: {user_input}");
        let gen_start = Instant::now();

        // Build the messages array for the OpenAI-compatible API
        let messages: Vec<serde_json::Value> = self
            .history
            .iter()
            .map(|m| {
                serde_json::json!({
                    "role": m.role,
                    "content": m.content,
                })
            })
            .collect();

        let body = serde_json::json!({
            "model": self.conn.api_model,
            "messages": messages,
            "stream": true,
            "temperature": self.config.temperature,
            "top_p": self.config.top_p,
            "max_tokens": self.config.max_tokens,
        });

        let body_str = serde_json::to_string(&body)
            .map_err(|e| SpeechError::Llm(format!("JSON serialization failed: {e}")))?;

        let base = match self.conn.api_url.strip_suffix("/v1") {
            Some(u) => u,
            None => &self.conn.api_url,
        };
        let base = base.trim_end_matches('/');
        let url = format!("{base}/v1/chat/completions");

        // Bridge sync HTTP streaming to async via a channel
        let (token_tx, mut token_rx) = mpsc::channel::<String>(64);
        let agent = self.agent.clone();
        let interrupt_clone = Arc::clone(interrupt);
        let api_key = self.conn.api_key.clone();

        let http_handle =
            tokio::task::spawn_blocking(move || -> std::result::Result<(), String> {
                let mut req = agent.post(&url).set("Content-Type", "application/json");
                if !api_key.is_empty() {
                    let auth = format!("Bearer {}", api_key);
                    req = req.set("Authorization", &auth);
                }

                let response = req
                    .send_string(&body_str)
                    .map_err(|e| format!("API request failed: {e}"))?;

                let reader = std::io::BufReader::new(response.into_reader());
                for line in std::io::BufRead::lines(reader) {
                    if interrupt_clone.load(Ordering::Relaxed) {
                        break;
                    }

                    let line = line.map_err(|e| format!("read error: {e}"))?;
                    if line.is_empty() {
                        continue;
                    }

                    let Some(data) = line.strip_prefix("data: ") else {
                        continue;
                    };

                    if data == "[DONE]" {
                        break;
                    }

                    let chunk: serde_json::Value =
                        serde_json::from_str(data).map_err(|e| format!("JSON parse error: {e}"))?;

                    if let Some(content) = chunk["choices"][0]["delta"]["content"].as_str()
                        && !content.is_empty()
                        && token_tx.blocking_send(content.to_owned()).is_err()
                    {
                        break;
                    }

                    if chunk["choices"][0]["finish_reason"].as_str() == Some("stop") {
                        break;
                    }
                }
                Ok(())
            });

        // Async loop: accumulate tokens into sentences
        let mut generated_text = String::new();
        let mut sentence_buffer = String::new();
        let mut token_count: usize = 0;
        let mut was_interrupted = false;
        let mut in_think_block = false;

        while let Some(token_text) = token_rx.recv().await {
            if interrupt.load(Ordering::Relaxed) {
                was_interrupted = true;
                break;
            }

            token_count += 1;

            // Filter <think>...</think> blocks (some models output reasoning)
            if token_text.contains("<think>") {
                in_think_block = true;
                continue;
            }
            if token_text.contains("</think>") {
                in_think_block = false;
                continue;
            }
            if in_think_block {
                continue;
            }

            generated_text.push_str(&token_text);
            sentence_buffer.push_str(&token_text);

            // Check for sentence boundaries and send complete sentences
            if let Some(pos) = super::find_clause_boundary(&sentence_buffer) {
                let sentence = sentence_buffer[..=pos].trim().to_owned();
                if !sentence.is_empty() {
                    let chunk = SentenceChunk {
                        text: sentence,
                        is_final: false,
                    };
                    tx.send(chunk).await.map_err(|e| {
                        SpeechError::Channel(format!("LLM output channel closed: {e}"))
                    })?;
                }
                sentence_buffer = sentence_buffer[pos + 1..].to_owned();
            }
        }

        // Wait for the HTTP streaming task to finish
        match http_handle.await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                if !was_interrupted {
                    return Err(SpeechError::Llm(e));
                }
            }
            Err(e) => {
                if !was_interrupted {
                    return Err(SpeechError::Llm(format!("HTTP task panicked: {e}")));
                }
            }
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

        // Add assistant response to history
        let final_text = generated_text.trim().to_owned();
        if !final_text.is_empty() {
            self.history.push(ChatMessage {
                role: "assistant",
                content: final_text,
            });
        }
        self.trim_history();

        let elapsed = gen_start.elapsed();
        let tokens_per_sec = if elapsed.as_secs_f64() > 0.0 {
            token_count as f64 / elapsed.as_secs_f64()
        } else {
            0.0
        };
        info!(
            "API generated {token_count} tokens in {:.1}s ({:.1} tok/s){}",
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
        if self.history.len() > 1 + max {
            let drain_end = self.history.len().saturating_sub(max);
            if drain_end > 1 {
                self.history.drain(1..drain_end);
            }
        }
    }
}

/// Resolve API connection details from either `cloud_provider` (models.json)
/// or direct config fields.
fn resolve_connection(config: &LlmConfig) -> Result<ResolvedConnection> {
    if let Some(ref cloud_name) = config.cloud_provider {
        let pi_path = crate::llm::pi_config::default_pi_models_path().ok_or_else(|| {
            SpeechError::Config("cannot determine HOME for Pi models.json".to_owned())
        })?;
        let pi_config = crate::llm::pi_config::read_pi_config(&pi_path)?;
        let provider = pi_config.find_provider(cloud_name).ok_or_else(|| {
            SpeechError::Config(format!(
                "cloud provider '{cloud_name}' not found in {}",
                pi_path.display()
            ))
        })?;

        let api_url = provider.base_url.clone().ok_or_else(|| {
            SpeechError::Config(format!(
                "cloud provider '{cloud_name}' missing baseUrl in {}",
                pi_path.display()
            ))
        })?;

        let model_id = config
            .cloud_model
            .clone()
            .or_else(|| {
                provider
                    .models
                    .as_ref()
                    .and_then(|models| models.first())
                    .map(|m| m.id.clone())
            })
            .unwrap_or_else(|| config.api_model.clone());

        Ok(ResolvedConnection {
            api_url,
            api_model: model_id,
            api_key: provider.api_key.clone().unwrap_or_default(),
        })
    } else {
        Ok(ResolvedConnection {
            api_url: config.api_url.clone(),
            api_model: config.api_model.clone(),
            api_key: config.api_key.clone(),
        })
    }
}
