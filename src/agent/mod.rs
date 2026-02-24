//! Agent-backed LLM engine using in-repo `fae_llm`.
//!
//! This module wires the pipeline-facing `generate_response` API to
//! `fae_llm::agent::AgentLoop`, provider adapters, and tool registry.

use crate::approval::{ToolApprovalRequest, ToolApprovalResponse};
use crate::canvas::registry::CanvasSessionRegistry;
use crate::canvas::tools::{CanvasExportTool, CanvasInteractTool, CanvasRenderTool};
use crate::config::{AgentToolMode, LlmConfig};
use crate::error::{Result, SpeechError};
use crate::fae_llm::agent::{
    AgentConfig as FaeAgentConfig, AgentLoop, AgentLoopResult, StopReason,
    build_messages_from_result,
};
use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;
use crate::fae_llm::provider::{LlmEventStream, ProviderAdapter, ToolDefinition};
use crate::fae_llm::providers::local::{LocalMistralrsAdapter, LocalMistralrsConfig};
use crate::fae_llm::providers::message::{Message, Role};

use crate::fae_llm::tools::{
    BashTool, EditTool, PythonSkillTool, ReadTool, Tool, ToolRegistry, ToolResult, WriteTool,
};
use crate::fae_llm::types::{ReasoningLevel, RequestOptions};
use crate::llm::LocalLlm;
use crate::permissions::SharedPermissionStore;
use crate::pipeline::messages::SentenceChunk;
use crate::runtime::RuntimeEvent;
use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::sync::{broadcast, mpsc, oneshot};

const APPROVAL_TIMEOUT: Duration = Duration::from_secs(60);
const INTERRUPT_POLL_INTERVAL: Duration = Duration::from_millis(25);

static NEXT_APPROVAL_ID: AtomicU64 = AtomicU64::new(1);

/// Maximum number of recent responses to track for duplicate detection.
const RECENT_RESPONSE_WINDOW: usize = 5;

pub struct FaeAgentLlm {
    provider: Arc<dyn ProviderAdapter>,
    registry: Arc<ToolRegistry>,
    agent_config: FaeAgentConfig,
    runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
    history: Vec<Message>,
    max_history_messages: usize,
    context_size_tokens: usize,
    compaction_threshold: f32,
    /// When true, tool schemas are never advertised to the model.
    /// Used for the voice conversation engine in multi-channel mode.
    tools_disabled: bool,
    /// Ring buffer of recent assistant response texts for duplicate detection.
    recent_responses: std::collections::VecDeque<String>,
    /// Counter for consecutive duplicate detections (for varied fallbacks).
    consecutive_duplicates: usize,
}

impl FaeAgentLlm {
    pub async fn new(
        config: &LlmConfig,
        preloaded_llm: Option<&LocalLlm>,
        runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
        tool_approval_tx: Option<mpsc::UnboundedSender<ToolApprovalRequest>>,
        canvas_registry: Option<Arc<Mutex<CanvasSessionRegistry>>>,
        credential_manager: &dyn crate::credentials::CredentialManager,
    ) -> Result<Self> {
        Self::new_with_permissions(
            config,
            preloaded_llm,
            runtime_tx,
            tool_approval_tx,
            canvas_registry,
            credential_manager,
            None,
        )
        .await
    }

    /// Create a new agent with an explicit live [`SharedPermissionStore`].
    ///
    /// When `shared_permissions` is `Some`, the Apple ecosystem tool gate
    /// uses this store to check permissions at execution time, enabling JIT
    /// permission grants to be reflected without rebuilding the tool registry.
    ///
    /// When `None` is passed, a fresh default store is created (backward
    /// compatible with callers that do not thread a shared store).
    pub async fn new_with_permissions(
        config: &LlmConfig,
        preloaded_llm: Option<&LocalLlm>,
        runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
        tool_approval_tx: Option<mpsc::UnboundedSender<ToolApprovalRequest>>,
        canvas_registry: Option<Arc<Mutex<CanvasSessionRegistry>>>,
        credential_manager: &dyn crate::credentials::CredentialManager,
        shared_permissions: Option<SharedPermissionStore>,
    ) -> Result<Self> {
        // Snapshot permission state for system prompt injection, then drop
        // the guard so `shared_permissions` can be moved into `build_registry`.
        let system_prompt = {
            let perm_guard = shared_permissions.as_ref().and_then(|sp| sp.lock().ok());
            config.effective_system_prompt(perm_guard.as_deref(), None)
        };

        let provider = build_provider(config, preloaded_llm, credential_manager).await;
        let registry = build_registry(
            config,
            tool_approval_tx,
            canvas_registry,
            shared_permissions,
        );

        let history = vec![Message::system(system_prompt)];

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
            compaction_threshold: 0.70,
            tools_disabled: false,
            recent_responses: std::collections::VecDeque::with_capacity(RECENT_RESPONSE_WINDOW),
            consecutive_duplicates: 0,
        })
    }

    /// Disable tool schema advertisement for this engine.
    ///
    /// When tools are disabled, `generate_response()` always passes an empty
    /// tool allowlist to the agent loop, ensuring zero tool schemas appear in
    /// the model prompt. Used for the voice conversation engine in
    /// multi-channel mode, where tool work is delegated to background agents.
    pub fn disable_tools(&mut self) {
        self.tools_disabled = true;
    }

    /// Temporarily change the reasoning level for the next generation.
    ///
    /// Used by the coordinator to enable thinking mode on the voice engine
    /// for complex conversational queries, then reset it to `Off` afterwards.
    pub fn set_reasoning_level(&mut self, level: ReasoningLevel) {
        self.agent_config = self.agent_config.clone().with_reasoning_level(level);
    }

    /// Inject a background agent result into the conversation history.
    ///
    /// Called when a background agent task completes, so the voice engine
    /// knows what Fae already told the user and maintains conversational
    /// continuity.
    pub fn inject_background_result(&mut self, result_text: &str) {
        if !result_text.trim().is_empty() {
            self.history.push(Message::assistant(format!(
                "[I completed a background task] {result_text}"
            )));
            self.trim_history();
        }
    }

    pub fn truncate_history(&mut self, keep_count: usize) {
        if self.history.len() > 1 + keep_count {
            self.history.truncate(1 + keep_count);
        }
    }

    /// Generate a response from the LLM engine.
    ///
    /// # Arguments
    ///
    /// * `user_input` — The full augmented input (memory context + user text).
    ///   Passed to the model for this turn only (ephemeral).
    /// * `tx` — Channel for streaming `SentenceChunk`s to TTS.
    /// * `interrupt` — Flag to cancel generation mid-stream.
    pub async fn generate_response(
        &mut self,
        user_input: String,
        tx: mpsc::Sender<SentenceChunk>,
        interrupt: Arc<AtomicBool>,
    ) -> Result<bool> {
        let interrupt_flag = interrupt;
        let user_message = extract_latest_user_message(&user_input);
        let tool_allowlist = if self.tools_disabled {
            Vec::new()
        } else {
            select_tool_allowlist(user_message)
        };
        tracing::debug!(
            user_message,
            tools = ?tool_allowlist,
            tools_disabled = self.tools_disabled,
            "selected per-turn tool allowlist"
        );

        // Only store the raw user utterance in persistent history — NOT the
        // full augmented input (which includes memory recall, onboarding,
        // coding context). This prevents transient context from duplicating
        // across turns and inflating prefill token counts.
        self.history.push(Message::user(user_message.to_owned()));
        self.trim_history();
        self.maybe_compact_history();
        interrupt_flag.store(false, Ordering::Relaxed);

        let mut agent = AgentLoop::new(
            self.agent_config.clone(),
            Arc::clone(&self.provider),
            Arc::clone(&self.registry),
        )
        .restrict_tools_to(&tool_allowlist);
        if let Some(ref tx) = self.runtime_tx {
            agent = agent.with_runtime_tx(tx.clone());
        }
        let cancel = agent.cancellation_token();

        // Create clause streaming channel for low-latency TTS pipelining.
        // Clauses are streamed during LLM generation so TTS can start
        // synthesizing before the full response is available.
        let (clause_tx, mut clause_rx) = mpsc::channel::<String>(16);

        // Forwarding task: convert raw clause strings into SentenceChunks.
        let chunk_tx = tx.clone();
        let fwd_handle = tokio::spawn(async move {
            while let Some(clause) = clause_rx.recv().await {
                if !clause.is_empty() {
                    let _ = chunk_tx
                        .send(SentenceChunk {
                            text: clause,
                            is_final: false,
                        })
                        .await;
                }
            }
        });

        // Build per-turn message list: history uses the raw user text, but
        // for THIS turn's inference we replace the last user message with the
        // full augmented input (memory context + user text). This gives the
        // model full context for the current turn without polluting history.
        let mut turn_messages = self.history.clone();
        if let Some(last) = turn_messages.last_mut()
            && last.role == Role::User
        {
            *last = Message::user(user_input);
        }
        let run_fut = agent.run_with_messages_streaming(turn_messages, clause_tx);
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

        // Wait for forwarding task to finish draining clauses.
        let _ = fwd_handle.await;

        let result = match run_result {
            Ok(r) => r,
            Err(e) => {
                let _ = tx
                    .send(SentenceChunk {
                        text: String::new(),
                        is_final: true,
                    })
                    .await;
                return Err(SpeechError::Llm(format!("agent run failed: {e}")));
            }
        };

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

        // Duplicate detection: if the model produced the same response as
        // one of the last N turns, replace the history entry with a varied
        // fallback and notify via logging. The streamed clauses already went
        // to TTS so this only prevents the loop from reinforcing the pattern
        // in future context windows.
        if self.is_duplicate_response(&result.final_text) {
            self.consecutive_duplicates += 1;
            tracing::warn!(
                consecutive = self.consecutive_duplicates,
                text = %result.final_text.chars().take(80).collect::<String>(),
                "duplicate response detected — suppressing history reinforcement"
            );
            // Don't add the duplicate to history — it reinforces the loop.
            // Instead, add a brief note so the model has context.
            self.history.push(Message::assistant(
                "[I just repeated myself — I should vary my response next time.]".to_owned(),
            ));
            self.trim_history();
        } else {
            self.consecutive_duplicates = 0;
            self.append_result_messages(&result);
            self.trim_history();
        }
        self.track_response(&result.final_text);

        // All clause chunks were streamed during generation; send the
        // final marker so the TTS stage knows the response is complete.
        let _ = tx
            .send(SentenceChunk {
                text: String::new(),
                is_final: true,
            })
            .await;

        Ok(false)
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
        // In voice mode (tools_disabled), use a hard token budget (~1500)
        // to keep prefill fast. In tool mode, use percentage of context.
        let threshold_tokens = if self.tools_disabled {
            1500usize
        } else {
            (self.context_size_tokens as f32 * self.compaction_threshold) as usize
        };
        if estimated_tokens < threshold_tokens {
            return;
        }
        tracing::info!(
            estimated_tokens,
            threshold_tokens,
            history_len = self.history.len(),
            "compacting conversation history"
        );

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

    /// Check if the response text is a duplicate of recent responses.
    ///
    /// Uses normalized comparison (trimmed, lowercased) to detect both exact
    /// and near-duplicates. Returns `true` if the response closely matches
    /// any of the last `RECENT_RESPONSE_WINDOW` assistant responses.
    fn is_duplicate_response(&self, response_text: &str) -> bool {
        let normalized = response_text.trim().to_ascii_lowercase();
        if normalized.is_empty() {
            return false;
        }
        self.recent_responses
            .iter()
            .any(|prev| prev.trim().to_ascii_lowercase() == normalized)
    }

    /// Track a new response in the recent response ring buffer.
    fn track_response(&mut self, response_text: &str) {
        if self.recent_responses.len() >= RECENT_RESPONSE_WINDOW {
            self.recent_responses.pop_front();
        }
        self.recent_responses.push_back(response_text.to_owned());
    }
}

fn extract_latest_user_message(input: &str) -> &str {
    const PREFIX: &str = "User message:\n";
    if let Some((_, message)) = input.rsplit_once(PREFIX) {
        message.trim()
    } else {
        input.trim()
    }
}

use crate::intent;
use crate::intent::contains_any;

/// Select a small per-turn tool allowlist based on explicit user intent.
///
/// Normal conversational turns return an empty allowlist (no tool schemas),
/// which reduces prompt bloat and improves first-token latency.
fn select_tool_allowlist(user_text: &str) -> Vec<String> {
    let lower = user_text.to_ascii_lowercase();
    let mut allow: HashSet<&'static str> = HashSet::new();

    if contains_any(&lower, intent::WEB_KEYWORDS) {
        allow.insert("web_search");
        allow.insert("fetch_url");
    }

    if contains_any(&lower, intent::CALENDAR_KEYWORDS) {
        allow.insert("list_calendars");
        allow.insert("list_calendar_events");
        allow.insert("create_calendar_event");
        allow.insert("update_calendar_event");
        allow.insert("delete_calendar_event");
    }

    if contains_any(&lower, intent::REMINDERS_KEYWORDS) {
        allow.insert("list_reminder_lists");
        allow.insert("list_reminders");
        allow.insert("create_reminder");
        allow.insert("set_reminder_completed");
    }

    if contains_any(&lower, intent::NOTES_KEYWORDS) {
        allow.insert("list_notes");
        allow.insert("get_note");
        allow.insert("create_note");
        allow.insert("append_to_note");
    }

    if contains_any(&lower, intent::MAIL_KEYWORDS) {
        allow.insert("search_mail");
        allow.insert("get_mail");
        allow.insert("compose_mail");
    }

    if contains_any(&lower, intent::CONTACTS_KEYWORDS) {
        allow.insert("search_contacts");
        allow.insert("get_contact");
        allow.insert("create_contact");
    }

    if contains_any(&lower, intent::SCHEDULER_KEYWORDS) {
        allow.insert("list_scheduled_tasks");
        allow.insert("create_scheduled_task");
        allow.insert("update_scheduled_task");
        allow.insert("delete_scheduled_task");
        allow.insert("trigger_scheduled_task");
    }

    // System utility queries that need bash (date, time, disk, etc.).
    if contains_any(&lower, intent::BASH_KEYWORDS) {
        allow.insert("bash");
    }

    if contains_any(&lower, intent::FILE_KEYWORDS) {
        allow.insert("read");
    }

    if contains_any(&lower, intent::X0X_KEYWORDS) {
        allow.insert("x0x");
    }

    let mut tools: Vec<String> = allow.into_iter().map(str::to_owned).collect();
    tools.sort();
    tools
}

/// Intent classification result from `classify_intent()`.
///
/// Determines whether a user message requires background tool execution
/// and provides context for the background agent.
pub struct IntentClassification {
    /// Tool names the background agent should have access to.
    pub tool_allowlist: Vec<String>,
    /// Natural language description of the task for the background agent.
    pub task_description: String,
    /// Whether this message needs tool use (true) or is purely conversational (false).
    pub needs_tools: bool,
    /// Whether this message is complex enough to benefit from deeper reasoning,
    /// even when no tools are needed. Triggers thinking acknowledgment and
    /// temporarily enables reasoning mode on the voice engine.
    pub needs_thinking: bool,
}

/// Classify user intent and determine routing.
///
/// Enhanced version of `select_tool_allowlist()` that also produces a
/// task description for the background agent. Also detects complex
/// conversational queries that benefit from deeper reasoning (thinking mode)
/// even when no tools are needed.
pub fn classify_intent(user_text: &str) -> IntentClassification {
    let tools = select_tool_allowlist(user_text);
    let needs_tools = !tools.is_empty();

    let task_description = if needs_tools {
        format!(
            "The user said: \"{user_text}\"\n\
             Complete this request using your available tools and provide a concise spoken summary."
        )
    } else {
        String::new()
    };

    // Detect complex conversational queries that benefit from thinking mode.
    // These don't need tools but are analytical / reasoning-heavy enough that
    // the model produces better answers with its internal reasoning chain.
    let needs_thinking = if needs_tools {
        // Tool path already uses thinking via background agent.
        false
    } else {
        needs_deeper_reasoning(user_text)
    };

    IntentClassification {
        tool_allowlist: tools,
        task_description,
        needs_tools,
        needs_thinking,
    }
}

/// Heuristic: does this conversational query benefit from deeper reasoning?
///
/// Checks for analytical, comparative, explanatory, or planning keywords
/// that suggest the model should engage its internal reasoning chain rather
/// than producing a quick surface-level response.
fn needs_deeper_reasoning(user_text: &str) -> bool {
    let lower = user_text.to_ascii_lowercase();

    // Minimum length filter — very short messages are rarely complex.
    if lower.split_whitespace().count() < 5 {
        return false;
    }

    contains_any(&lower, intent::DEEPER_REASONING_KEYWORDS)
}

/// A background agent task spawned from the voice conversation.
pub struct BackgroundAgentTask {
    /// Unique task identifier.
    pub id: String,
    /// Human-readable description for logging/events.
    pub description: String,
    /// The user's original message that triggered this task.
    pub user_message: String,
    /// Recent conversation context (last few turns) for continuity.
    pub conversation_context: String,
    /// Tool names this agent should have access to.
    pub tool_allowlist: Vec<String>,
}

/// Result from a completed background agent task.
pub struct BackgroundAgentResult {
    /// Task identifier (matches `BackgroundAgentTask::id`).
    pub task_id: String,
    /// Whether the task completed successfully.
    pub success: bool,
    /// Text to speak via TTS (the agent's final answer).
    pub spoken_summary: String,
}

/// Select the reasoning level for a background agent task.
///
/// Pure system-utility queries (bash-only + factual keywords like "what time")
/// get [`ReasoningLevel::Off`]. Multi-tool tasks or analytical questions get
/// [`ReasoningLevel::Medium`]. Everything else defaults to
/// [`ReasoningLevel::Low`].
fn select_background_reasoning_level(task: &BackgroundAgentTask) -> ReasoningLevel {
    let lower = task.user_message.to_ascii_lowercase();
    let only_bash = task.tool_allowlist.len() == 1 && task.tool_allowlist[0] == "bash";

    // Pure system utility questions don't need internal reasoning.
    if only_bash && contains_any(&lower, intent::BRIEF_REASONING_KEYWORDS) {
        return ReasoningLevel::Off;
    }

    // Multi-tool tasks or analytical asks benefit from deeper reasoning.
    if task.tool_allowlist.len() > 1 || needs_deeper_reasoning(task.user_message.as_str()) {
        return ReasoningLevel::Medium;
    }

    // Keep lightweight reasoning for ordinary tool tasks.
    ReasoningLevel::Low
}

/// Spawn a background agent to execute a tool-heavy task.
///
/// Creates a fresh `FaeAgentLlm` sharing the same LLM model weights,
/// runs it with a focused prompt and restricted tool set, and collects
/// the result text for narration via TTS.
///
/// # Arguments
///
/// * `task` — The background task to execute
/// * `config` — LLM configuration (cloned from pipeline)
/// * `preloaded_llm` — Shared local model (cheap `Arc` clone). Must be `Some`
///   for the local backend to work; `None` falls back to `MissingLocalModelAdapter`.
/// * `runtime_tx` — Runtime event sender for telemetry
/// * `tool_approval_tx` — Optional approval channel
/// * `canvas_registry` — Optional canvas registry
/// * `credential_manager` — Credential manager for provider setup
/// * `shared_permissions` — Live permission store
pub async fn spawn_background_agent(
    task: BackgroundAgentTask,
    config: LlmConfig,
    preloaded_llm: Option<&LocalLlm>,
    runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
    tool_approval_tx: Option<mpsc::UnboundedSender<ToolApprovalRequest>>,
    canvas_registry: Option<Arc<Mutex<CanvasSessionRegistry>>>,
    shared_permissions: Option<SharedPermissionStore>,
) -> BackgroundAgentResult {
    let reasoning_level = select_background_reasoning_level(&task);
    tracing::info!(
        task_id = %task.id,
        reasoning_level = ?reasoning_level,
        tools = ?task.tool_allowlist,
        "selected background agent reasoning level"
    );

    // Build a background-specific config with the agent prompt.
    let bg_system_prompt = {
        let perm_guard = shared_permissions.as_ref().and_then(|sp| sp.lock().ok());
        let base = config.effective_system_prompt_with_vision_and_mode(
            perm_guard.as_deref(),
            config.enable_vision,
            None,
            false,
        );
        format!(
            "{}\n\n{}",
            crate::personality::BACKGROUND_AGENT_PROMPT.trim(),
            base
        )
    };

    let credential_manager = crate::credentials::create_manager();
    let provider = build_provider(&config, preloaded_llm, credential_manager.as_ref()).await;
    let registry = build_registry(
        &config,
        tool_approval_tx,
        canvas_registry,
        shared_permissions,
    );

    let parallel_tool_calls = matches!(config.tool_mode, AgentToolMode::ReadOnly);
    let agent_config = FaeAgentConfig::new()
        .with_parallel_tool_calls(parallel_tool_calls)
        .with_max_parallel_tool_calls(4)
        .with_reasoning_level(reasoning_level);

    // Build the input prompt with conversation context.
    let input = if task.conversation_context.is_empty() {
        format!("User message:\n{}", task.user_message)
    } else {
        format!(
            "Recent conversation context:\n{}\n\nUser message:\n{}",
            task.conversation_context, task.user_message
        )
    };

    let history = vec![Message::system(bg_system_prompt)];

    let mut agent = AgentLoop::new(agent_config, Arc::clone(&provider), Arc::clone(&registry))
        .restrict_tools_to(&task.tool_allowlist);
    if let Some(ref tx) = runtime_tx {
        agent = agent.with_runtime_tx(tx.clone());
    }

    // Collect output text (no streaming to TTS — we batch the result).
    let (collect_tx, mut collect_rx) = mpsc::channel::<String>(32);
    let collector_handle = tokio::spawn(async move {
        let mut full_text = String::new();
        while let Some(clause) = collect_rx.recv().await {
            if !clause.is_empty() {
                if !full_text.is_empty() {
                    full_text.push(' ');
                }
                full_text.push_str(clause.trim());
            }
        }
        full_text
    });

    let mut messages = history;
    messages.push(Message::user(input));

    let run_result = agent
        .run_with_messages_streaming(messages, collect_tx)
        .await;

    let collected_text = collector_handle.await.unwrap_or_default();

    match run_result {
        Ok(result) => {
            // Prefer streamed text; fall back to result's final_text.
            let spoken = if collected_text.trim().is_empty() {
                result.final_text.trim().to_owned()
            } else {
                collected_text
            };

            BackgroundAgentResult {
                task_id: task.id,
                success: true,
                spoken_summary: spoken,
            }
        }
        Err(e) => {
            tracing::error!(task_id = %task.id, error = %e, "background agent failed");
            BackgroundAgentResult {
                task_id: task.id,
                success: false,
                spoken_summary: format!("Sorry, I couldn't complete that. {e}"),
            }
        }
    }
}

struct MissingLocalModelAdapter;

#[async_trait::async_trait]
impl ProviderAdapter for MissingLocalModelAdapter {
    fn name(&self) -> &str {
        "missing_provider_config"
    }

    async fn send(
        &self,
        _messages: &[Message],
        _options: &RequestOptions,
        _tools: &[ToolDefinition],
    ) -> std::result::Result<LlmEventStream, FaeLlmError> {
        Err(FaeLlmError::ConfigValidationError(
            "local backend selected but no preloaded local model is available. \
             Ensure a GGUF or vision model is configured."
                .to_owned(),
        ))
    }
}

async fn build_provider(
    config: &LlmConfig,
    preloaded_llm: Option<&LocalLlm>,
    _manager: &dyn crate::credentials::CredentialManager,
) -> Arc<dyn ProviderAdapter> {
    if let Some(local_llm) = preloaded_llm {
        tracing::info!(
            "agent using embedded local provider (model={})",
            config.model_id
        );
        let mut provider_cfg =
            LocalMistralrsConfig::new(local_llm.shared_model(), config.model_id.clone())
                .with_temperature(config.temperature as f32)
                .with_top_p(config.top_p as f32)
                .with_max_tokens(config.max_tokens);
        if let Some(k) = config.top_k {
            provider_cfg = provider_cfg.with_top_k(k);
        }
        return Arc::new(LocalMistralrsAdapter::new(provider_cfg));
    }
    let reason = "local backend selected but no preloaded local model is available. \
Ensure a GGUF or vision model is configured.";
    tracing::warn!("{reason}");
    Arc::new(MissingLocalModelAdapter)
}

/// Build a tool registry from the config.
///
/// `shared_permissions` is the live permission store to pass to all
/// `AvailabilityGatedTool` instances.  When `None`, a default (empty) shared
/// store is created — this is the fallback for callers that don't thread the
/// handler's store (e.g. `brain.rs`, `gui.rs`).  Production callers
/// (pipeline coordinator) should pass the handler's `shared_permissions()` so
/// that runtime grants are immediately visible to tools without a registry
/// rebuild.
fn build_registry(
    config: &LlmConfig,
    tool_approval_tx: Option<mpsc::UnboundedSender<ToolApprovalRequest>>,
    canvas_registry: Option<Arc<Mutex<CanvasSessionRegistry>>>,
    shared_permissions: Option<SharedPermissionStore>,
) -> Arc<ToolRegistry> {
    let mode = match config.tool_mode {
        AgentToolMode::Off | AgentToolMode::ReadOnly => ToolMode::ReadOnly,
        AgentToolMode::ReadWrite | AgentToolMode::Full | AgentToolMode::FullNoApproval => {
            ToolMode::Full
        }
    };
    let mut registry = ToolRegistry::new(mode);

    // Helper: wrap a tool with approval gating and register it.
    let register_with_approval = |tool: Arc<dyn crate::fae_llm::tools::Tool>,
                                  reg: &mut ToolRegistry| {
        reg.register(Arc::new(ApprovalTool::new(
            tool,
            tool_approval_tx.clone(),
            APPROVAL_TIMEOUT,
        )));
    };

    match config.tool_mode {
        AgentToolMode::Off => {}
        AgentToolMode::ReadOnly => {
            registry.register(Arc::new(ReadTool::new()));
        }
        AgentToolMode::ReadWrite => {
            registry.register(Arc::new(ReadTool::new()));
            register_with_approval(Arc::new(WriteTool::new()), &mut registry);
            register_with_approval(Arc::new(EditTool::new()), &mut registry);
        }
        AgentToolMode::Full => {
            register_with_approval(Arc::new(BashTool::new()), &mut registry);
            registry.register(Arc::new(ReadTool::new()));
            register_with_approval(Arc::new(WriteTool::new()), &mut registry);
            register_with_approval(Arc::new(EditTool::new()), &mut registry);
            register_with_approval(Arc::new(PythonSkillTool::with_default_dir()), &mut registry);
            // Desktop automation (Full mode, with approval).
            if let Some(desktop_tool) = crate::fae_llm::tools::DesktopTool::try_new() {
                register_with_approval(Arc::new(desktop_tool), &mut registry);
            }
        }
        AgentToolMode::FullNoApproval => {
            // No approval needed - register tools directly
            registry.register(Arc::new(BashTool::new()));
            registry.register(Arc::new(ReadTool::new()));
            registry.register(Arc::new(WriteTool::new()));
            registry.register(Arc::new(EditTool::new()));
            registry.register(Arc::new(PythonSkillTool::with_default_dir()));
            // Desktop automation (no approval).
            if let Some(desktop_tool) = crate::fae_llm::tools::DesktopTool::try_new() {
                registry.register(Arc::new(desktop_tool));
            }
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

    // x0x gossip network tool — gated by Network permission.
    // Registered in Full/FullNoApproval modes; gracefully fails when x0xd is not running.
    if matches!(
        config.tool_mode,
        AgentToolMode::Full | AgentToolMode::FullNoApproval
    ) {
        let has_network_perm = shared_permissions
            .as_ref()
            .and_then(|sp| sp.lock().ok())
            .is_some_and(|guard| guard.is_granted(crate::permissions::PermissionKind::Network));
        if has_network_perm {
            use crate::fae_llm::tools::X0xTool;
            registry.register(Arc::new(X0xTool::new()));
        }
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

    // Apple ecosystem tools — always registered in non-Off modes.
    // Each tool is wrapped with AvailabilityGatedTool so execution is blocked
    // at runtime when the required permission has not been granted.
    //
    // The `shared_permissions` parameter threads the live permission store from
    // the command handler so that JIT grants (capability.grant via FFI) are
    // immediately visible to the gate without rebuilding the registry.
    if !matches!(config.tool_mode, AgentToolMode::Off) {
        use crate::fae_llm::tools::apple::{
            AppendToNoteTool, AvailabilityGatedTool, ComposeMailTool, CreateContactTool,
            CreateEventTool, CreateNoteTool, CreateReminderTool, DeleteEventTool, GetContactTool,
            GetMailTool, GetNoteTool, ListCalendarsTool, ListEventsTool, ListNotesTool,
            ListReminderListsTool, ListRemindersTool, SearchContactsTool, SearchMailTool,
            SetReminderCompletedTool, UpdateEventTool, global_calendar_store, global_contact_store,
            global_mail_store, global_note_store, global_reminder_store,
        };
        use crate::permissions::PermissionStore;

        let perms: SharedPermissionStore =
            shared_permissions.unwrap_or_else(PermissionStore::default_shared);
        let contacts = global_contact_store();
        let calendars = global_calendar_store();
        let reminders = global_reminder_store();
        let notes = global_note_store();
        let mail = global_mail_store();

        // Helper to wrap an AppleEcosystemTool with permission gating.
        macro_rules! gated {
            ($tool:expr) => {
                Arc::new(AvailabilityGatedTool::new(
                    Arc::new($tool),
                    Arc::clone(&perms),
                ))
            };
        }

        registry.register(gated!(SearchContactsTool::new(Arc::clone(&contacts))));
        registry.register(gated!(GetContactTool::new(Arc::clone(&contacts))));
        registry.register(gated!(CreateContactTool::new(contacts)));
        registry.register(gated!(ListCalendarsTool::new(Arc::clone(&calendars))));
        registry.register(gated!(ListEventsTool::new(Arc::clone(&calendars))));
        registry.register(gated!(CreateEventTool::new(Arc::clone(&calendars))));
        registry.register(gated!(UpdateEventTool::new(Arc::clone(&calendars))));
        registry.register(gated!(DeleteEventTool::new(calendars)));
        registry.register(gated!(ListReminderListsTool::new(Arc::clone(&reminders))));
        registry.register(gated!(ListRemindersTool::new(Arc::clone(&reminders))));
        registry.register(gated!(CreateReminderTool::new(Arc::clone(&reminders))));
        registry.register(gated!(SetReminderCompletedTool::new(reminders)));
        registry.register(gated!(ListNotesTool::new(Arc::clone(&notes))));
        registry.register(gated!(GetNoteTool::new(Arc::clone(&notes))));
        registry.register(gated!(CreateNoteTool::new(Arc::clone(&notes))));
        registry.register(gated!(AppendToNoteTool::new(notes)));
        registry.register(gated!(SearchMailTool::new(Arc::clone(&mail))));
        registry.register(gated!(GetMailTool::new(Arc::clone(&mail))));
        registry.register(gated!(ComposeMailTool::new(mail)));
    }

    Arc::new(registry)
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
            // Fail-closed: refuse to execute mutating tools when no approval
            // channel is wired.  This prevents channel-originated requests
            // (Discord, etc.) from silently bypassing interactive approval.
            tracing::warn!(
                "tool '{}' denied: no approval channel available (fail-closed)",
                self.inner.name()
            );
            return Err(FaeLlmError::ToolExecutionError(format!(
                "tool '{}' requires approval but no approval channel is available",
                self.inner.name()
            )));
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

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;
    use crate::credentials::{CredentialError, CredentialManager, CredentialRef};

    struct NoopCredentialManager;

    impl CredentialManager for NoopCredentialManager {
        fn store(
            &self,
            _account: &str,
            _value: &str,
        ) -> std::result::Result<CredentialRef, CredentialError> {
            Ok(CredentialRef::None)
        }

        fn retrieve(
            &self,
            cred_ref: &CredentialRef,
        ) -> std::result::Result<Option<String>, CredentialError> {
            match cred_ref {
                CredentialRef::Plaintext(value) => Ok(Some(value.clone())),
                _ => Ok(None),
            }
        }

        fn delete(&self, _cred_ref: &CredentialRef) -> std::result::Result<(), CredentialError> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn local_backend_without_local_model_returns_config_error_provider() {
        let config = LlmConfig::default();
        let manager = NoopCredentialManager;

        let provider = build_provider(&config, None, &manager).await;
        assert_eq!(provider.name(), "missing_provider_config");

        let result = provider
            .send(&[Message::user("hello")], &RequestOptions::new(), &[])
            .await;
        assert!(matches!(result, Err(FaeLlmError::ConfigValidationError(_))));
    }

    #[test]
    fn full_mode_registers_python_skill_tool() {
        let config = LlmConfig {
            tool_mode: AgentToolMode::Full,
            ..LlmConfig::default()
        };

        let registry = build_registry(&config, None, None, None);
        assert!(
            registry.exists("python_skill"),
            "python_skill tool should be registered in full mode"
        );
    }

    #[test]
    fn extract_latest_user_message_prefers_user_message_suffix() {
        let input =
            "<memory_context>\nfoo\n</memory_context>\n\nUser message:\nFind latest Apple news";
        assert_eq!(extract_latest_user_message(input), "Find latest Apple news");
    }

    #[test]
    fn select_tool_allowlist_empty_for_plain_conversation() {
        let tools = select_tool_allowlist("How are you feeling today?");
        assert!(
            tools.is_empty(),
            "plain chat should return empty allowlist (strips all tools for speed)"
        );
    }

    #[test]
    fn select_tool_allowlist_adds_web_tools_for_search_intent() {
        let tools = select_tool_allowlist("Can you search the web for today's AI news?");
        assert!(tools.contains(&"web_search".to_string()));
        assert!(tools.contains(&"fetch_url".to_string()));
    }

    #[test]
    fn select_tool_allowlist_adds_calendar_tools_for_calendar_intent() {
        let tools = select_tool_allowlist("What's on my calendar tomorrow?");
        assert!(tools.contains(&"list_calendars".to_string()));
        assert!(tools.contains(&"list_calendar_events".to_string()));
    }

    #[test]
    fn select_tool_allowlist_multi_category_overlap() {
        // "search for meetings" should trigger both web and calendar tools.
        let tools = select_tool_allowlist("search for meetings this week");
        assert!(
            tools.contains(&"web_search".to_string()),
            "should include web_search for 'search'"
        );
        assert!(
            tools.contains(&"list_calendar_events".to_string()),
            "should include calendar for 'meeting'"
        );
    }

    #[test]
    fn select_tool_allowlist_case_insensitive() {
        let tools = select_tool_allowlist("CHECK MY CALENDAR");
        assert!(
            tools.contains(&"list_calendar_events".to_string()),
            "uppercase input should still match"
        );
    }

    #[test]
    fn select_tool_allowlist_plurals_match_via_substring() {
        // "reminders" contains "reminder" → should match.
        let tools = select_tool_allowlist("show me my reminders");
        assert!(
            tools.contains(&"list_reminders".to_string()),
            "plural 'reminders' should match substring 'reminder'"
        );
    }

    #[test]
    fn needs_deeper_reasoning_short_messages_false() {
        // Very short messages should never trigger thinking mode.
        assert!(!needs_deeper_reasoning("hi"));
        assert!(!needs_deeper_reasoning("how are you?"));
        assert!(!needs_deeper_reasoning("thanks"));
    }

    #[test]
    fn needs_deeper_reasoning_analytical_queries() {
        assert!(needs_deeper_reasoning(
            "can you explain how quantum computing works?"
        ));
        assert!(needs_deeper_reasoning(
            "what are the pros and cons of remote work?"
        ));
        assert!(needs_deeper_reasoning(
            "help me understand why this design pattern is useful"
        ));
        assert!(needs_deeper_reasoning(
            "walk me through the process of building a compiler"
        ));
        assert!(needs_deeper_reasoning(
            "what would happen if we switched to a microservices architecture?"
        ));
    }

    #[test]
    fn needs_deeper_reasoning_simple_conversations_false() {
        assert!(!needs_deeper_reasoning(
            "what is the weather like today in Dublin?"
        ));
        assert!(!needs_deeper_reasoning(
            "tell me a joke about programmers please"
        ));
        assert!(!needs_deeper_reasoning(
            "good morning Fae, hope you're well"
        ));
    }

    #[test]
    fn classify_intent_sets_needs_thinking() {
        let intent = classify_intent("can you explain the difference between TCP and UDP?");
        assert!(!intent.needs_tools);
        assert!(intent.needs_thinking);

        // Tool intent should not set needs_thinking (background agent handles that).
        let intent = classify_intent("search the web for latest Rust news");
        assert!(intent.needs_tools);
        assert!(!intent.needs_thinking);

        // Simple conversation: neither.
        let intent = classify_intent("hi Fae, how are you today?");
        assert!(!intent.needs_tools);
        assert!(!intent.needs_thinking);
    }

    #[test]
    fn background_reasoning_off_for_simple_time_query() {
        let task = BackgroundAgentTask {
            id: "bg-test".to_owned(),
            description: "time".to_owned(),
            user_message: "What time is it right now?".to_owned(),
            conversation_context: String::new(),
            tool_allowlist: vec!["bash".to_owned()],
        };
        assert_eq!(
            select_background_reasoning_level(&task),
            ReasoningLevel::Off
        );
    }

    #[test]
    fn background_reasoning_medium_for_multi_tool_tasks() {
        let task = BackgroundAgentTask {
            id: "bg-test".to_owned(),
            description: "calendar+search".to_owned(),
            user_message: "Search the web and compare options for my meeting plan".to_owned(),
            conversation_context: String::new(),
            tool_allowlist: vec!["web_search".to_owned(), "list_calendar_events".to_owned()],
        };
        assert_eq!(
            select_background_reasoning_level(&task),
            ReasoningLevel::Medium
        );
    }
}
