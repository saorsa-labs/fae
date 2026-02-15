//! Agent-backed LLM engine using in-repo `fae_llm`.
//!
//! This module wires the pipeline-facing `generate_response` API to
//! `fae_llm::agent::AgentLoop`, provider adapters, and tool registry.

use crate::approval::{ToolApprovalRequest, ToolApprovalResponse};
use crate::canvas::registry::CanvasSessionRegistry;
use crate::canvas::tools::{CanvasExportTool, CanvasInteractTool, CanvasRenderTool};
use crate::config::{AgentToolMode, LlmApiType, LlmConfig};
use crate::error::{Result, SpeechError};
use crate::fae_llm::agent::{
    AgentConfig as FaeAgentConfig, AgentLoop, AgentLoopResult, StopReason,
    build_messages_from_result,
};
use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;
use crate::fae_llm::provider::ProviderAdapter;
use crate::fae_llm::providers::anthropic::{AnthropicAdapter, AnthropicConfig};
use crate::fae_llm::providers::fallback::FallbackProvider;
use crate::fae_llm::providers::local::{LocalMistralrsAdapter, LocalMistralrsConfig};
use crate::fae_llm::providers::message::{Message, Role};
use crate::fae_llm::providers::openai::{OpenAiAdapter, OpenAiApiMode, OpenAiConfig};
use crate::fae_llm::tools::{
    BashTool, EditTool, ReadTool, Tool, ToolRegistry, ToolResult, WriteTool,
};
use crate::llm::LocalLlm;
use crate::pipeline::messages::SentenceChunk;
use crate::runtime::RuntimeEvent;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::{broadcast, mpsc, oneshot};

const APPROVAL_TIMEOUT: Duration = Duration::from_secs(60);
const INTERRUPT_POLL_INTERVAL: Duration = Duration::from_millis(25);

static NEXT_APPROVAL_ID: AtomicU64 = AtomicU64::new(1);

pub struct FaeAgentLlm {
    provider: Arc<dyn ProviderAdapter>,
    registry: Arc<ToolRegistry>,
    agent_config: FaeAgentConfig,
    runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
    history: Vec<Message>,
    max_history_messages: usize,
    context_size_tokens: usize,
    compaction_threshold: f32,
}

impl FaeAgentLlm {
    pub async fn new(
        config: &LlmConfig,
        preloaded_llm: Option<LocalLlm>,
        runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
        tool_approval_tx: Option<mpsc::UnboundedSender<ToolApprovalRequest>>,
        canvas_registry: Option<Arc<Mutex<CanvasSessionRegistry>>>,
    ) -> Result<Self> {
        let provider = build_provider(config, preloaded_llm.as_ref());
        let registry = build_registry(config, tool_approval_tx, canvas_registry);

        let history = vec![Message::system(config.effective_system_prompt())];

        let parallel_tool_calls = matches!(config.tool_mode, AgentToolMode::ReadOnly);

        Ok(Self {
            provider,
            registry,
            agent_config: FaeAgentConfig::new()
                .with_parallel_tool_calls(parallel_tool_calls)
                .with_max_parallel_tool_calls(4),
            runtime_tx,
            history,
            max_history_messages: config.max_history_messages,
            context_size_tokens: config.context_size_tokens,
            compaction_threshold: 0.95,
        })
    }

    pub fn truncate_history(&mut self, keep_count: usize) {
        if self.history.len() > 1 + keep_count {
            self.history.truncate(1 + keep_count);
        }
    }

    pub async fn generate_response(
        &mut self,
        user_input: String,
        tx: mpsc::Sender<SentenceChunk>,
        interrupt: Arc<AtomicBool>,
    ) -> Result<bool> {
        let interrupt_flag = interrupt;

        self.history.push(Message::user(user_input));
        self.trim_history();
        self.maybe_compact_history();
        interrupt_flag.store(false, Ordering::Relaxed);

        let agent = AgentLoop::new(
            self.agent_config.clone(),
            Arc::clone(&self.provider),
            Arc::clone(&self.registry),
        );
        let cancel = agent.cancellation_token();

        let run_fut = agent.run_with_messages(self.history.clone());
        tokio::pin!(run_fut);

        let mut was_interrupted = false;
        let mut tick = tokio::time::interval(INTERRUPT_POLL_INTERVAL);
        tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        let run_result = loop {
            tokio::select! {
                _ = tick.tick() => {
                    if interrupt_flag.load(Ordering::Relaxed) {
                        was_interrupted = true;
                        cancel.cancel();
                    }
                }
                result = &mut run_fut => break result,
            }
        };

        let result = run_result.map_err(|e| SpeechError::Llm(format!("agent run failed: {e}")))?;

        if was_interrupted || matches!(result.stop_reason, StopReason::Cancelled) {
            let _ = tx
                .send(SentenceChunk {
                    text: String::new(),
                    is_final: true,
                })
                .await;
            return Ok(true);
        }

        if let StopReason::Error(message) = &result.stop_reason {
            let _ = tx
                .send(SentenceChunk {
                    text: String::new(),
                    is_final: true,
                })
                .await;
            return Err(SpeechError::Llm(format!("agent error: {message}")));
        }

        self.emit_tool_events(&result);
        self.append_result_messages(&result);
        self.trim_history();
        stream_result_to_chunks(result.final_text.clone(), tx.clone()).await?;

        Ok(false)
    }

    fn emit_tool_events(&self, result: &AgentLoopResult) {
        let Some(runtime_tx) = &self.runtime_tx else {
            return;
        };

        for turn in &result.turns {
            for tool_call in &turn.tool_calls {
                let _ = runtime_tx.send(RuntimeEvent::ToolCall {
                    id: tool_call.call_id.clone(),
                    name: tool_call.function_name.clone(),
                    input_json: tool_call.arguments.to_string(),
                });

                let output_text = if tool_call.result.success {
                    Some(tool_call.result.content.clone())
                } else {
                    tool_call.result.error.clone()
                };

                let _ = runtime_tx.send(RuntimeEvent::ToolResult {
                    id: tool_call.call_id.clone(),
                    name: tool_call.function_name.clone(),
                    success: tool_call.result.success,
                    output_text,
                });
            }
        }
    }

    fn append_result_messages(&mut self, result: &AgentLoopResult) {
        for message in build_messages_from_result(result, None) {
            if message.role != Role::System {
                self.history.push(message);
            }
        }
    }

    fn trim_history(&mut self) {
        if self.max_history_messages == 0 {
            return;
        }

        if self.history.len() > 1 + self.max_history_messages {
            let drain_end = self.history.len().saturating_sub(self.max_history_messages);
            if drain_end > 1 {
                self.history.drain(1..drain_end);
            }
        }
    }

    fn maybe_compact_history(&mut self) {
        if self.context_size_tokens == 0 {
            return;
        }

        let estimated_tokens = estimate_history_tokens(&self.history);
        let threshold_tokens =
            (self.context_size_tokens as f32 * self.compaction_threshold) as usize;
        if estimated_tokens < threshold_tokens {
            return;
        }

        let system_offset = if self.history.first().is_some_and(|m| m.role == Role::System) {
            1usize
        } else {
            0usize
        };
        if self.history.len() <= system_offset + 8 {
            return;
        }

        let recent_keep = 12usize.min(self.history.len().saturating_sub(system_offset));
        let split_at = self.history.len().saturating_sub(recent_keep);
        if split_at <= system_offset {
            return;
        }

        let summary = summarize_history_slice(&self.history[system_offset..split_at]);
        let mut compacted = Vec::new();
        if system_offset == 1 {
            compacted.push(self.history[0].clone());
        }
        compacted.push(Message::assistant(format!(
            "Conversation summary (auto-compacted):\n{}",
            summary
        )));
        compacted.extend_from_slice(&self.history[split_at..]);
        self.history = compacted;
    }
}

/// Returns `true` when the config has a remote API explicitly configured
/// (non-empty API key or a cloud provider set). When neither is present,
/// there is no remote LLM to talk to and we should use local inference only.
fn has_remote_provider_configured(config: &LlmConfig) -> bool {
    config.has_remote_provider_configured()
}

fn build_provider(
    config: &LlmConfig,
    preloaded_llm: Option<&LocalLlm>,
) -> Arc<dyn ProviderAdapter> {
    // All runtime paths use the agent loop; backend selects which provider
    // the agent should use as its "brain":
    // - Local: local mistralrs only
    // - Api: remote provider only (with optional local fallback)
    // - Agent: compatibility auto mode (local when remote isn't configured)
    let use_local_only = match config.backend {
        crate::config::LlmBackend::Local => true,
        crate::config::LlmBackend::Api => false,
        crate::config::LlmBackend::Agent => !has_remote_provider_configured(config),
    };

    if use_local_only {
        if let Some(local_llm) = preloaded_llm {
            tracing::info!(
                "agent using local mistralrs provider (model={})",
                config.model_id
            );
            let provider_cfg =
                LocalMistralrsConfig::new(local_llm.shared_model(), config.model_id.clone())
                    .with_temperature(config.temperature as f32)
                    .with_top_p(config.top_p as f32)
                    .with_max_tokens(config.max_tokens);
            return Arc::new(LocalMistralrsAdapter::new(provider_cfg));
        }
        tracing::warn!(
            "no remote provider configured and no local model available — agent will not function"
        );
    }

    // Build the remote provider (only reached when a remote API is configured)
    let remote = build_remote_provider(config);

    // Wrap with local fallback when enabled and a local model is available
    if config.enable_local_fallback {
        if let Some(local_llm) = preloaded_llm {
            tracing::info!(
                "local fallback enabled: {} + local/{}",
                config.effective_provider_name(),
                config.model_id
            );
            let local_cfg =
                LocalMistralrsConfig::new(local_llm.shared_model(), config.model_id.clone())
                    .with_temperature(config.temperature as f32)
                    .with_top_p(config.top_p as f32)
                    .with_max_tokens(config.max_tokens);
            let local: Arc<dyn ProviderAdapter> = Arc::new(LocalMistralrsAdapter::new(local_cfg));
            return Arc::new(FallbackProvider::new(remote, local));
        }
        tracing::warn!(
            "enable_local_fallback=true but no local model available; fallback disabled"
        );
    }

    remote
}

/// Build the remote (API) provider from config.
fn build_remote_provider(config: &LlmConfig) -> Arc<dyn ProviderAdapter> {
    if config.api_url.trim().is_empty() {
        tracing::warn!("no API URL configured - agent will not function without an LLM provider");
    }

    let model_id = config
        .cloud_model
        .clone()
        .unwrap_or_else(|| config.api_model.clone());
    let provider_hint = config
        .cloud_provider
        .clone()
        .unwrap_or_default()
        .to_ascii_lowercase();
    let resolved_api_type = match config.api_type {
        LlmApiType::Auto => {
            if provider_hint == "anthropic" || config.api_url.contains("anthropic.com") {
                LlmApiType::AnthropicMessages
            } else {
                LlmApiType::OpenAiCompletions
            }
        }
        explicit => explicit,
    };

    match resolved_api_type {
        LlmApiType::AnthropicMessages => {
            let mut provider_cfg =
                AnthropicConfig::new(config.api_key.resolve_plaintext(), model_id);
            if !config.api_url.trim().is_empty() {
                provider_cfg = provider_cfg.with_base_url(normalize_base_url(&config.api_url));
            }
            if let Some(version) = config.api_version.as_deref()
                && !version.trim().is_empty()
            {
                provider_cfg = provider_cfg.with_api_version(version.to_owned());
            }
            provider_cfg = provider_cfg.with_max_tokens(config.max_tokens);
            Arc::new(AnthropicAdapter::new(provider_cfg))
        }
        LlmApiType::OpenAiCompletions | LlmApiType::OpenAiResponses | LlmApiType::Auto => {
            let mut provider_cfg = if let Some(provider_name) = config.cloud_provider.as_deref() {
                OpenAiConfig::for_provider(
                    provider_name,
                    config.api_key.resolve_plaintext(),
                    model_id,
                )
            } else {
                OpenAiConfig::new(config.api_key.resolve_plaintext(), model_id)
            };
            if !config.api_url.trim().is_empty() {
                provider_cfg = provider_cfg.with_base_url(normalize_base_url(&config.api_url));
            }
            if let Some(org) = config.api_organization.as_deref()
                && !org.trim().is_empty()
            {
                provider_cfg = provider_cfg.with_org_id(org.to_owned());
            }
            if matches!(resolved_api_type, LlmApiType::OpenAiResponses) {
                provider_cfg = provider_cfg.with_api_mode(OpenAiApiMode::Responses);
            }
            Arc::new(OpenAiAdapter::new(provider_cfg))
        }
    }
}

fn normalize_base_url(url: &str) -> String {
    let trimmed = url.trim().trim_end_matches('/');
    if let Some(base) = trimmed.strip_suffix("/v1") {
        base.to_string()
    } else {
        trimmed.to_string()
    }
}

fn build_registry(
    config: &LlmConfig,
    tool_approval_tx: Option<mpsc::UnboundedSender<ToolApprovalRequest>>,
    canvas_registry: Option<Arc<Mutex<CanvasSessionRegistry>>>,
) -> Arc<ToolRegistry> {
    let mode = match config.tool_mode {
        AgentToolMode::Off | AgentToolMode::ReadOnly => ToolMode::ReadOnly,
        AgentToolMode::ReadWrite | AgentToolMode::Full | AgentToolMode::FullNoApproval => {
            ToolMode::Full
        }
    };
    let mut registry = ToolRegistry::new(mode);

    match config.tool_mode {
        AgentToolMode::Off => {}
        AgentToolMode::ReadOnly => {
            registry.register(Arc::new(ReadTool::new()));
        }
        AgentToolMode::ReadWrite => {
            registry.register(Arc::new(ReadTool::new()));
            registry.register(Arc::new(ApprovalTool::new(
                Arc::new(WriteTool::new()),
                tool_approval_tx.clone(),
                APPROVAL_TIMEOUT,
            )));
            registry.register(Arc::new(ApprovalTool::new(
                Arc::new(EditTool::new()),
                tool_approval_tx.clone(),
                APPROVAL_TIMEOUT,
            )));
        }
        AgentToolMode::Full => {
            registry.register(Arc::new(ApprovalTool::new(
                Arc::new(BashTool::new()),
                tool_approval_tx.clone(),
                APPROVAL_TIMEOUT,
            )));
            registry.register(Arc::new(ReadTool::new()));
            registry.register(Arc::new(ApprovalTool::new(
                Arc::new(WriteTool::new()),
                tool_approval_tx.clone(),
                APPROVAL_TIMEOUT,
            )));
            registry.register(Arc::new(ApprovalTool::new(
                Arc::new(EditTool::new()),
                tool_approval_tx,
                APPROVAL_TIMEOUT,
            )));
        }
        AgentToolMode::FullNoApproval => {
            // No approval needed - register tools directly
            registry.register(Arc::new(BashTool::new()));
            registry.register(Arc::new(ReadTool::new()));
            registry.register(Arc::new(WriteTool::new()));
            registry.register(Arc::new(EditTool::new()));
        }
    }

    if !matches!(config.tool_mode, AgentToolMode::Off)
        && let Some(canvas_registry) = canvas_registry
    {
        registry.register(Arc::new(CanvasRenderTool::new(canvas_registry.clone())));
        registry.register(Arc::new(CanvasInteractTool::new(canvas_registry.clone())));
        registry.register(Arc::new(CanvasExportTool::new(canvas_registry)));
    }

    // Web search tools (read-only, allowed in all non-Off modes).
    if !matches!(config.tool_mode, AgentToolMode::Off) {
        use crate::fae_llm::tools::{FetchUrlTool, WebSearchTool};
        registry.register(Arc::new(WebSearchTool::new()));
        registry.register(Arc::new(FetchUrlTool::new()));
    }

    // Scheduler tools (mode gating handled by each tool's allowed_in_mode).
    if !matches!(config.tool_mode, AgentToolMode::Off) {
        use crate::fae_llm::tools::{
            SchedulerCreateTool, SchedulerDeleteTool, SchedulerListTool, SchedulerTriggerTool,
            SchedulerUpdateTool,
        };
        registry.register(Arc::new(SchedulerListTool::new()));
        registry.register(Arc::new(SchedulerCreateTool::new()));
        registry.register(Arc::new(SchedulerUpdateTool::new()));
        registry.register(Arc::new(SchedulerDeleteTool::new()));
        registry.register(Arc::new(SchedulerTriggerTool::new()));
    }

    Arc::new(registry)
}

async fn stream_result_to_chunks(text: String, tx: mpsc::Sender<SentenceChunk>) -> Result<()> {
    if text.trim().is_empty() {
        tx.send(SentenceChunk {
            text: String::new(),
            is_final: true,
        })
        .await
        .map_err(|e| SpeechError::Channel(format!("LLM output channel closed: {e}")))?;
        return Ok(());
    }

    let mut sentence_buffer = text;
    while let Some(pos) = crate::llm::find_clause_boundary(&sentence_buffer) {
        let sentence = sentence_buffer[..=pos].trim().to_owned();
        if !sentence.is_empty() {
            tx.send(SentenceChunk {
                text: sentence,
                is_final: false,
            })
            .await
            .map_err(|e| SpeechError::Channel(format!("LLM output channel closed: {e}")))?;
        }
        sentence_buffer = sentence_buffer[pos + 1..].to_owned();
    }

    let remaining = sentence_buffer.trim().to_owned();
    tx.send(SentenceChunk {
        text: remaining,
        is_final: true,
    })
    .await
    .map_err(|e| SpeechError::Channel(format!("LLM output channel closed: {e}")))?;

    Ok(())
}

fn estimate_history_tokens(messages: &[Message]) -> usize {
    messages
        .iter()
        .map(|message| {
            let mut chars = match &message.content {
                crate::fae_llm::providers::message::MessageContent::Text { text } => text.len(),
                crate::fae_llm::providers::message::MessageContent::ToolResult {
                    content, ..
                } => content.len(),
            };
            for tool_call in &message.tool_calls {
                chars = chars
                    .saturating_add(tool_call.function_name.len())
                    .saturating_add(tool_call.arguments.len());
            }
            chars / 4 + 8
        })
        .sum()
}

fn summarize_history_slice(messages: &[Message]) -> String {
    let mut lines = Vec::new();
    let keep = messages.len().min(10);
    for message in messages.iter().rev().take(keep).rev() {
        let role = match message.role {
            Role::System => "system",
            Role::User => "user",
            Role::Assistant => "assistant",
            Role::Tool => "tool",
        };
        let snippet = match &message.content {
            crate::fae_llm::providers::message::MessageContent::Text { text } => {
                truncate_summary_text(text)
            }
            crate::fae_llm::providers::message::MessageContent::ToolResult { content, .. } => {
                truncate_summary_text(content)
            }
        };
        if !snippet.is_empty() {
            lines.push(format!("- {role}: {snippet}"));
        }
    }

    if lines.is_empty() {
        "- no significant prior content".to_string()
    } else {
        lines.join("\n")
    }
}

fn truncate_summary_text(text: &str) -> String {
    const MAX_CHARS: usize = 180;
    let clean = text.replace('\n', " ").trim().to_string();
    if clean.chars().count() <= MAX_CHARS {
        return clean;
    }
    let truncated: String = clean.chars().take(MAX_CHARS).collect();
    format!("{truncated}...")
}

/// Tool wrapper that gates execution behind UI approval.
struct ApprovalTool {
    inner: Arc<dyn Tool>,
    approval_tx: Option<mpsc::UnboundedSender<ToolApprovalRequest>>,
    timeout: Duration,
}

impl ApprovalTool {
    fn new(
        inner: Arc<dyn Tool>,
        approval_tx: Option<mpsc::UnboundedSender<ToolApprovalRequest>>,
        timeout: Duration,
    ) -> Self {
        Self {
            inner,
            approval_tx,
            timeout,
        }
    }

    fn next_approval_id() -> u64 {
        NEXT_APPROVAL_ID.fetch_add(1, Ordering::Relaxed)
    }
}

impl Tool for ApprovalTool {
    fn name(&self) -> &str {
        self.inner.name()
    }

    fn description(&self) -> &str {
        self.inner.description()
    }

    fn schema(&self) -> serde_json::Value {
        self.inner.schema()
    }

    fn execute(&self, args: serde_json::Value) -> std::result::Result<ToolResult, FaeLlmError> {
        let Some(approval_tx) = &self.approval_tx else {
            tracing::info!("no approval channel, executing tool directly");
            return self.inner.execute(args);
        };

        let (respond_to, mut response_rx) = oneshot::channel::<ToolApprovalResponse>();
        let input_json = match serde_json::to_string(&args) {
            Ok(serialized) => serialized,
            Err(e) => format!("{{\"_error\":\"failed to serialize tool input: {e}\"}}"),
        };
        let request = ToolApprovalRequest::new(
            Self::next_approval_id(),
            self.inner.name().to_string(),
            input_json,
            respond_to,
        );

        tracing::info!("requesting tool approval for: {}", self.inner.name());

        if approval_tx.send(request).is_err() {
            return Err(FaeLlmError::ToolExecutionError(
                "tool approval handler is unavailable".to_string(),
            ));
        }

        let start = Instant::now();
        loop {
            match response_rx.try_recv() {
                Ok(ToolApprovalResponse::Approved(true)) => {
                    tracing::info!("tool approved, executing: {}", self.inner.name());
                    return self.inner.execute(args);
                }
                Ok(ToolApprovalResponse::Approved(false))
                | Ok(ToolApprovalResponse::Cancelled)
                | Ok(ToolApprovalResponse::Value(_)) => {
                    tracing::warn!("tool denied by user: {}", self.inner.name());
                    return Err(FaeLlmError::ToolExecutionError(
                        "tool call denied by user".to_string(),
                    ));
                }
                Err(tokio::sync::oneshot::error::TryRecvError::Empty) => {
                    if start.elapsed() >= self.timeout {
                        tracing::error!("tool approval timed out after {:?}", self.timeout);
                        return Err(FaeLlmError::ToolExecutionError(
                            "tool approval timed out".to_string(),
                        ));
                    }
                    std::thread::sleep(Duration::from_millis(25));
                }
                Err(tokio::sync::oneshot::error::TryRecvError::Closed) => {
                    return Err(FaeLlmError::ToolExecutionError(
                        "tool approval response channel closed".to_string(),
                    ));
                }
            }
        }
    }

    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        self.inner.allowed_in_mode(mode)
    }
}
