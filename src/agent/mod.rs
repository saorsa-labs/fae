//! Agent-backed LLM engine using `saorsa-agent`.
//!
//! Supports two inference backends:
//! - **Local** (default): In-process via `mistralrs` using `ToolingMistralrsProvider`.
//! - **Cloud**: Any OpenAI-compatible API via `HttpStreamingProvider`, configured
//!   through Pi's `~/.pi/agent/models.json`.
//!
//! `saorsa-ai` is used only for trait definitions (`Provider`, `StreamingProvider`)
//! required by `saorsa-agent`. The `mistralrs` feature is disabled.

use crate::agent::local_provider::ToolingMistralrsProvider;
use crate::approval::ToolApprovalRequest;
use crate::canvas::registry::CanvasSessionRegistry;
use crate::canvas::tools::{CanvasExportTool, CanvasInteractTool, CanvasRenderTool};
use crate::config::{AgentToolMode, LlmConfig};
use crate::error::{Result, SpeechError};
use crate::llm::LocalLlm;
use crate::pi::session::PiSession;
use crate::pi::tool::PiDelegateTool;
use crate::pipeline::messages::SentenceChunk;
use crate::runtime::RuntimeEvent;
use saorsa_agent::{
    AgentConfig, AgentEvent, AgentLoop, BashTool, EditTool, FindTool, GrepTool, LsTool, ReadTool,
    WebSearchTool, WriteTool,
};
use saorsa_ai::StreamingProvider;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::broadcast;
use tokio::sync::mpsc;

mod approval_tool;
pub mod http_provider;
mod local_provider;

pub struct SaorsaAgentLlm {
    agent: AgentLoop,
    event_rx: saorsa_agent::EventReceiver,
    runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
}

impl SaorsaAgentLlm {
    pub async fn new(
        config: &LlmConfig,
        preloaded_llm: Option<LocalLlm>,
        runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
        tool_approval_tx: Option<mpsc::UnboundedSender<ToolApprovalRequest>>,
        canvas_registry: Option<Arc<Mutex<CanvasSessionRegistry>>>,
        pi_session: Option<Arc<Mutex<PiSession>>>,
    ) -> Result<Self> {
        // Decide between local (in-process) inference and cloud provider.
        let provider: Box<dyn StreamingProvider> = if let Some(ref cloud_name) =
            config.cloud_provider
        {
            // Cloud: look up provider in Pi's models.json.
            let pi_path = crate::llm::pi_config::default_pi_models_path().ok_or_else(|| {
                SpeechError::Config("cannot determine HOME for Pi models.json".to_owned())
            })?;
            let pi_config = crate::llm::pi_config::read_pi_config(&pi_path)?;
            let provider_info = pi_config.find_provider(cloud_name).ok_or_else(|| {
                SpeechError::Config(format!(
                    "cloud provider '{cloud_name}' not found in {}",
                    pi_path.display()
                ))
            })?;
            let base_url = provider_info.base_url.clone().ok_or_else(|| {
                SpeechError::Config(format!(
                    "cloud provider '{cloud_name}' missing baseUrl in {}",
                    pi_path.display()
                ))
            })?;
            let api_key = provider_info.api_key.clone().unwrap_or_default();
            let model_id = config
                .cloud_model
                .clone()
                .or_else(|| {
                    provider_info
                        .models
                        .as_ref()
                        .and_then(|models| models.first())
                        .map(|m| m.id.clone())
                })
                .unwrap_or_else(|| config.api_model.clone());

            tracing::info!(
                "agent using cloud provider: {} (model={}, url={})",
                cloud_name,
                model_id,
                base_url
            );

            Box::new(http_provider::HttpStreamingProvider::new(
                base_url, api_key, model_id,
            ))
        } else {
            // Local: use in-process mistralrs inference, with cloud fallback.
            let local_result = match preloaded_llm {
                Some(llm) => Ok(llm.shared_model()),
                None => LocalLlm::load_local_model(config).await,
            };

            match local_result {
                Ok(model) => {
                    tracing::info!("agent using local provider: {}", config.model_id);
                    Box::new(ToolingMistralrsProvider::new(model, config.clone()))
                }
                Err(local_err) => {
                    // Fallback: try to find a cloud provider in models.json.
                    tracing::warn!(
                        "local model failed to load: {local_err}; checking models.json for fallback"
                    );
                    match try_cloud_fallback(config) {
                        Some(provider) => provider,
                        None => return Err(local_err),
                    }
                }
            }
        };

        let mut tools = saorsa_agent::ToolRegistry::new();
        let approval_timeout = Duration::from_secs(60);
        match config.tool_mode {
            AgentToolMode::Off => {}
            AgentToolMode::ReadOnly => {
                // Read-only toolset for now.
                let wd = std::env::current_dir()
                    .map_err(|e| SpeechError::Llm(format!("cannot determine working dir: {e}")))?;
                tools.register(Box::new(ReadTool::new(wd.clone())));
                tools.register(Box::new(GrepTool::new(wd.clone())));
                tools.register(Box::new(FindTool::new(wd.clone())));
                tools.register(Box::new(LsTool::new(wd)));
            }
            AgentToolMode::ReadWrite => {
                let wd = std::env::current_dir()
                    .map_err(|e| SpeechError::Llm(format!("cannot determine working dir: {e}")))?;
                tools.register(Box::new(ReadTool::new(wd.clone())));
                tools.register(Box::new(approval_tool::ApprovalTool::new(
                    Box::new(WriteTool::new(wd.clone())),
                    tool_approval_tx.clone(),
                    approval_timeout,
                )));
                tools.register(Box::new(approval_tool::ApprovalTool::new(
                    Box::new(EditTool::new(wd.clone())),
                    tool_approval_tx.clone(),
                    approval_timeout,
                )));
                tools.register(Box::new(GrepTool::new(wd.clone())));
                tools.register(Box::new(FindTool::new(wd.clone())));
                tools.register(Box::new(LsTool::new(wd)));
            }
            AgentToolMode::Full => {
                let wd = std::env::current_dir()
                    .map_err(|e| SpeechError::Llm(format!("cannot determine working dir: {e}")))?;
                tools.register(Box::new(approval_tool::ApprovalTool::new(
                    Box::new(BashTool::new(wd.clone())),
                    tool_approval_tx.clone(),
                    approval_timeout,
                )));
                tools.register(Box::new(ReadTool::new(wd.clone())));
                tools.register(Box::new(approval_tool::ApprovalTool::new(
                    Box::new(WriteTool::new(wd.clone())),
                    tool_approval_tx.clone(),
                    approval_timeout,
                )));
                tools.register(Box::new(approval_tool::ApprovalTool::new(
                    Box::new(EditTool::new(wd.clone())),
                    tool_approval_tx.clone(),
                    approval_timeout,
                )));
                tools.register(Box::new(GrepTool::new(wd.clone())));
                tools.register(Box::new(FindTool::new(wd.clone())));
                tools.register(Box::new(LsTool::new(wd)));
                tools.register(Box::new(approval_tool::ApprovalTool::new(
                    Box::new(WebSearchTool::new()),
                    tool_approval_tx.clone(),
                    approval_timeout,
                )));
            }
        }

        // Register canvas tools when a session registry is available.
        // Canvas tools are non-destructive (read/render only), so no approval needed.
        if let Some(registry) = canvas_registry
            && !matches!(config.tool_mode, AgentToolMode::Off)
        {
            tools.register(Box::new(CanvasRenderTool::new(registry.clone())));
            tools.register(Box::new(CanvasInteractTool::new(registry.clone())));
            tools.register(Box::new(CanvasExportTool::new(registry)));
        }

        // Register Pi coding agent delegate tool when a session is available.
        // Pi has full system access (bash, file writes), so it requires approval
        // gating and is only available in Full tool mode.
        if let Some(session) = pi_session
            && matches!(config.tool_mode, AgentToolMode::Full)
        {
            tools.register(Box::new(approval_tool::ApprovalTool::new(
                Box::new(PiDelegateTool::new(session)),
                tool_approval_tx.clone(),
                approval_timeout,
            )));
        }

        let max_tokens_u32 = if config.max_tokens > u32::MAX as usize {
            u32::MAX
        } else {
            config.max_tokens as u32
        };

        // For in-process inference, the "model" string is used for display / IDs.
        let agent_cfg = AgentConfig::new(config.model_id.clone())
            .system_prompt(config.effective_system_prompt())
            .max_turns(10)
            .max_tokens(max_tokens_u32);

        let (event_tx, event_rx) = saorsa_agent::event_channel(64);
        let agent = AgentLoop::new(provider, agent_cfg, tools, event_tx);

        Ok(Self {
            agent,
            event_rx,
            runtime_tx,
        })
    }

    /// Truncate history (stub — agent backend manages its own history).
    pub fn truncate_history(&mut self, _keep_count: usize) {
        // Agent backend manages its own conversation state; truncation
        // is not supported. This is a no-op.
    }

    pub async fn generate_response(
        &mut self,
        user_input: &str,
        tx: &mpsc::Sender<SentenceChunk>,
        interrupt: &Arc<AtomicBool>,
    ) -> Result<bool> {
        // Best-effort drain of old events (e.g., if a previous run was interrupted).
        while self.event_rx.try_recv().is_ok() {}

        interrupt.store(false, Ordering::Relaxed);

        let run_fut = self.agent.run(user_input);
        tokio::pin!(run_fut);

        let mut sentence_buffer = String::new();
        let mut was_interrupted = false;

        let mut tick = tokio::time::interval(Duration::from_millis(25));
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        loop {
            tokio::select! {
                _ = tick.tick() => {
                    if interrupt.load(Ordering::Relaxed) {
                        was_interrupted = true;
                        break;
                    }
                }
                ev = self.event_rx.recv() => {
                    let Some(ev) = ev else { continue; };
                    if interrupt.load(Ordering::Relaxed) {
                        was_interrupted = true;
                        break;
                    }

                    match ev {
                        AgentEvent::TextDelta { text } => {
                            if text.is_empty() {
                                continue;
                            }
                            sentence_buffer.push_str(&text);

                            while let Some(pos) = crate::llm::find_clause_boundary(&sentence_buffer) {
                                let sentence = sentence_buffer[..=pos].trim().to_owned();
                                if !sentence.is_empty() {
                                    tx.send(SentenceChunk {
                                        text: sentence,
                                        is_final: false,
                                    })
                                    .await
                                    .map_err(|e| {
                                        SpeechError::Channel(format!("LLM output channel closed: {e}"))
                                    })?;
                                }
                                sentence_buffer = sentence_buffer[pos + 1..].to_owned();
                            }
                        }
                        AgentEvent::ToolCall { id, name, input } => {
                            if let Some(rt) = &self.runtime_tx {
                                let input_json =
                                    serde_json::to_string(&input).unwrap_or_else(|_| "{}".into());
                                let _ = rt.send(RuntimeEvent::ToolCall {
                                    id,
                                    name,
                                    input_json,
                                });
                            }
                        }
                        AgentEvent::ToolResult {
                            id,
                            name,
                            output,
                            success,
                        } => {
                            if let Some(rt) = &self.runtime_tx {
                                let _ = rt.send(RuntimeEvent::ToolResult {
                                    id,
                                    name,
                                    success,
                                    output_text: Some(output),
                                });
                            }
                        }
                        AgentEvent::Error { message } => {
                            let _ = tx
                                .send(SentenceChunk {
                                    text: String::new(),
                                    is_final: true,
                                })
                                .await;
                            return Err(SpeechError::Llm(format!("agent error: {message}")));
                        }
                        _ => {}
                    }
                }
                res = &mut run_fut => {
                    match res {
                        Ok(_) => break,
                        Err(e) => {
                            // Ensure downstream stages terminate cleanly.
                            let _ = tx.send(SentenceChunk { text: String::new(), is_final: true }).await;
                            return Err(SpeechError::Llm(format!("agent run failed: {e}")));
                        }
                    }
                }
            }
        }

        if was_interrupted {
            let _ = tx
                .send(SentenceChunk {
                    text: String::new(),
                    is_final: true,
                })
                .await;
            return Ok(true);
        }

        let remaining = sentence_buffer.trim().to_owned();
        if !remaining.is_empty() {
            tx.send(SentenceChunk {
                text: remaining,
                is_final: true,
            })
            .await
            .map_err(|e| SpeechError::Channel(format!("LLM output channel closed: {e}")))?;
        } else {
            tx.send(SentenceChunk {
                text: String::new(),
                is_final: true,
            })
            .await
            .map_err(|e| SpeechError::Channel(format!("LLM output channel closed: {e}")))?;
        }

        Ok(false)
    }
}

/// Try to find a cloud provider in Pi's models.json as a fallback when
/// the local model fails to load.
///
/// Returns `None` if no cloud providers are available, allowing the caller
/// to propagate the original local-model error.
fn try_cloud_fallback(config: &LlmConfig) -> Option<Box<dyn StreamingProvider>> {
    let pi_path = crate::llm::pi_config::default_pi_models_path()?;
    let pi_config = crate::llm::pi_config::read_pi_config(&pi_path).ok()?;
    let cloud = pi_config.cloud_providers();
    let (name, provider) = cloud
        .iter()
        .find(|(_, provider)| provider.base_url.is_some())
        .copied()?;
    let base_url = provider.base_url.clone()?;
    let api_key = provider.api_key.clone().unwrap_or_default();

    let model_id = provider
        .models
        .as_ref()
        .and_then(|models| models.first())
        .map(|m| m.id.clone())
        .unwrap_or_else(|| config.api_model.clone());

    tracing::info!(
        "falling back to cloud provider: {} (model={}, url={})",
        name,
        model_id,
        base_url
    );

    Some(Box::new(http_provider::HttpStreamingProvider::new(
        base_url, api_key, model_id,
    )))
}
