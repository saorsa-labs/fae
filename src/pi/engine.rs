//! Pi-backed LLM engine.
//!
//! Architecture: Pi runs the agent loop and tool execution; Fae hosts voice + canvas UI.
//!
//! # Model Selection Flow
//!
//! When the Pi backend starts, it determines which model to use:
//!
//! 1. **Candidate Resolution**: The internal `resolve_pi_model_candidates` function builds a sorted list
//!    of available models from local config, cloud providers, and the FAE fallback.
//!
//! 2. **Decision**: [`crate::model_selection::decide_model_selection`] determines whether to auto-select or prompt:
//!    - No candidates → Error
//!    - Single candidate → Auto-select
//!    - Multiple top-tier models → Prompt user (if channel available)
//!    - Mixed tiers → Auto-select best
//!
//! 3. **User Prompt**: If prompting, [`PiLlm::select_startup_model`] emits a
//!    [`RuntimeEvent::ModelSelectionPrompt`] through the runtime event channel.
//!
//! 4. **GUI Response**: The GUI sends the user's selection through the
//!    `model_selection_rx` mpsc channel (connected via the pipeline coordinator's
//!    `with_model_selection` builder method).
//!
//! 5. **Fallback**: On timeout or invalid selection, the first candidate is auto-selected.
//!
//! 6. **Confirmation**: A [`RuntimeEvent::ModelSelected`] event is emitted for UI feedback.
//!
//! ```text
//! ┌─────────────────┐    ┌──────────────────┐    ┌─────────────────┐
//! │  PiLlm::new()   │───►│ select_startup   │───►│ RuntimeEvent::  │
//! │  (candidates)   │    │ _model()         │    │ ModelSelected   │
//! └─────────────────┘    └────────┬─────────┘    └─────────────────┘
//!                                 │
//!                    ┌────────────▼────────────┐
//!                    │ PromptUser?             │
//!                    │ ├─ Yes: emit prompt     │
//!                    │ │  wait for channel     │
//!                    │ │  timeout → fallback   │
//!                    │ └─ No: auto-select      │
//!                    └─────────────────────────┘
//! ```

use crate::approval::{ToolApprovalRequest, ToolApprovalResponse};
use crate::config::{AgentToolMode, LlmConfig, PiConfig};
use crate::error::{Result, SpeechError};
use crate::llm::pi_config::{FAE_MODEL_ID, FAE_PROVIDER_KEY};
use crate::model_selection::{ModelSelectionDecision, ProviderModelRef, decide_model_selection};
use crate::pipeline::messages::SentenceChunk;
use crate::runtime::RuntimeEvent;

use crate::pi::manager::PiManager;
use crate::pi::session::{
    PiAgentEvent, PiExtensionUiRequest, PiOutput, PiRpcResponse, PiSession, PiToolsConfig,
};

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tokio::sync::{broadcast, mpsc, oneshot};

/// Maximum amount of tool output text to attach to UI events.
const TOOL_OUTPUT_LIMIT_CHARS: usize = 20_000;

/// Default timeout for UI confirmation requests.
const UI_CONFIRM_TIMEOUT: Duration = Duration::from_secs(60);

/// Minimal policy prompt appended to Pi.
///
/// Keep this narrowly scoped to escalation behavior so we avoid polluting Pi
/// with host-only skills/prompts.
const PI_ESCALATION_POLICY_PROMPT: &str = "\
You are operating under Fae's approval policy.
- Default to read-only exploration (read, grep, find, ls).
- If a task requires elevated/destructive actions (bash, edit, write, delete/move), explain briefly what you want to do and why.
- Then request escalation via the required tool call and wait for approval.
- Never perform destructive operations unless approval is granted.";

// ProviderModelRef moved to crate::model_selection

/// Pi-driven backend that streams assistant text to the TTS/canvas pipeline.
pub struct PiLlm {
    runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
    tool_approval_tx: Option<mpsc::UnboundedSender<ToolApprovalRequest>>,

    session: PiSession,
    next_approval_id: u64,
    model_candidates: Vec<ProviderModelRef>,
    active_model_idx: usize,

    /// Channel for receiving user model selection from the GUI picker.
    /// When `None`, the engine auto-selects the best model without prompting.
    model_selection_rx: Option<mpsc::UnboundedReceiver<String>>,

    // Per-run state.
    assistant_delta_buffer: String,
}

impl PiLlm {
    pub fn new(
        llm_config: LlmConfig,
        pi_config: PiConfig,
        runtime_tx: Option<broadcast::Sender<RuntimeEvent>>,
        tool_approval_tx: Option<mpsc::UnboundedSender<ToolApprovalRequest>>,
        model_selection_rx: Option<mpsc::UnboundedReceiver<String>>,
    ) -> Result<Self> {
        let model_candidates = resolve_pi_model_candidates(&llm_config)?;
        let primary = model_candidates
            .first()
            .cloned()
            .ok_or_else(|| SpeechError::Pi("no Pi model candidates configured".to_owned()))?;

        let mut manager = PiManager::new(&pi_config)?;
        let state = manager.ensure_pi()?;
        let pi_path = state
            .path()
            .ok_or_else(|| SpeechError::Pi(format!("Pi not installed ({state})")))?;

        let mut session = PiSession::new(
            pi_path.to_path_buf(),
            primary.provider.clone(),
            primary.model.clone(),
        );
        session.set_no_session(true);
        // In voice mode, default to HOME so "Desktop/Documents/Downloads" work naturally.
        // Using process cwd (often a repo path) makes broad file queries feel "blocked".
        session.set_cwd(default_pi_cwd());
        // Use a small Pi-specific policy prompt. Avoid appending the full Fae
        // prompt stack because it includes host-only skills (e.g. pi_delegate)
        // that do not exist inside Pi's own tool registry.
        session.set_append_system_prompt(Some(PI_ESCALATION_POLICY_PROMPT.to_owned()));

        // Load a small extension that gates dangerous tool calls behind UI confirmation.
        // Fail closed: if this extension is unavailable, do not expose risky tools.
        let gate_loaded = match ensure_fae_gate_extension() {
            Ok(ext_path) => {
                session.add_extension(ext_path);
                true
            }
            Err(e) => {
                tracing::warn!("failed to install Fae Pi permission gate extension: {e}");
                false
            }
        };
        if !gate_loaded && !matches!(llm_config.tool_mode, AgentToolMode::Off) {
            tracing::warn!(
                "Pi permission gate extension unavailable; degrading tool mode to safe read-only"
            );
        }
        session.set_tools(tools_for_mode(llm_config.tool_mode, gate_loaded));

        Ok(Self {
            runtime_tx,
            tool_approval_tx,
            session,
            next_approval_id: 1,
            model_candidates,
            active_model_idx: 0,
            model_selection_rx,
            assistant_delta_buffer: String::new(),
        })
    }

    /// Select the startup model, optionally prompting the user via the GUI.
    ///
    /// When multiple top-tier models are available and a `model_selection_rx`
    /// channel exists, emits a [`RuntimeEvent::ModelSelectionPrompt`] and waits
    /// for a response. Falls back to auto-selecting the first candidate on
    /// timeout or if no channel is configured.
    pub async fn select_startup_model(&mut self, timeout: Duration) -> Result<()> {
        let decision = decide_model_selection(&self.model_candidates);

        match decision {
            ModelSelectionDecision::NoModels => {
                return Err(SpeechError::Pi("no model candidates available".to_owned()));
            }
            ModelSelectionDecision::AutoSelect(model) => {
                let label = model.display();
                tracing::info!("auto-selected model: {label}");
                self.emit_model_selected(&label);
            }
            ModelSelectionDecision::PromptUser(top_tier) => {
                // Collect candidate names before taking &mut self for the channel.
                let candidate_names: Vec<String> =
                    top_tier.iter().map(ProviderModelRef::display).collect();
                let first_display = self.model_candidates[0].display();

                // Try to prompt the user if we have a selection channel.
                let selected = self.prompt_user_for_model(&candidate_names, timeout).await;

                if let Some(chosen) = selected {
                    if let Some(idx) = self
                        .model_candidates
                        .iter()
                        .position(|c| c.display() == chosen)
                    {
                        self.active_model_idx = idx;
                        tracing::info!("user selected model: {chosen}");
                        self.emit_model_selected(&chosen);
                        return Ok(());
                    }
                    tracing::warn!("user selection '{chosen}' not found, auto-selecting first");
                }

                // Fallback: auto-select first candidate (already at index 0).
                self.active_model_idx = 0;
                tracing::info!("auto-selecting model: {first_display}");
                self.emit_model_selected(&first_display);
            }
        }

        Ok(())
    }

    /// If a model selection channel is available, emit the prompt event and
    /// wait for a user response (or timeout). Returns `Some(selection)` if the
    /// user chose, `None` otherwise.
    async fn prompt_user_for_model(
        &mut self,
        candidates: &[String],
        timeout: Duration,
    ) -> Option<String> {
        // Confirm a receiver exists before emitting the prompt.
        self.model_selection_rx.as_ref()?;
        self.emit_model_selection_prompt(candidates, timeout);

        let rx = self.model_selection_rx.as_mut()?;
        match tokio::time::timeout(timeout, rx.recv()).await {
            Ok(Some(selected)) => Some(selected),
            Ok(None) => {
                tracing::warn!("model selection channel closed, auto-selecting");
                None
            }
            Err(_) => {
                tracing::info!("model selection timed out, auto-selecting first");
                None
            }
        }
    }

    /// Emit a `ModelSelectionPrompt` event if a runtime sender is available.
    fn emit_model_selection_prompt(&self, candidates: &[String], timeout: Duration) {
        if let Some(tx) = &self.runtime_tx {
            let _ = tx.send(RuntimeEvent::ModelSelectionPrompt {
                candidates: candidates.to_vec(),
                timeout_secs: timeout.as_secs().min(u64::from(u32::MAX)) as u32,
            });
        }
    }

    /// Emit a `ModelSelected` event if a runtime sender is available.
    fn emit_model_selected(&self, provider_model: &str) {
        if let Some(tx) = &self.runtime_tx {
            let _ = tx.send(RuntimeEvent::ModelSelected {
                provider_model: provider_model.to_owned(),
            });
        }
    }

    pub async fn generate_response(
        &mut self,
        user_input: &str,
        tx: &mpsc::Sender<SentenceChunk>,
        interrupt: &Arc<AtomicBool>,
    ) -> Result<bool> {
        interrupt.store(false, Ordering::Relaxed);

        let mut tried = HashSet::new();

        loop {
            tried.insert(self.active_model_idx);

            if !self.session.is_running() {
                self.session.spawn()?;
            }

            self.assistant_delta_buffer.clear();
            self.session.send_prompt(user_input)?;

            let mut sentence_buffer = String::new();
            let mut prompt_error: Option<String> = None;
            let mut completed = false;

            let mut tick = tokio::time::interval(Duration::from_millis(50));
            tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

            loop {
                tokio::select! {
                    _ = tick.tick() => {
                        if interrupt.load(Ordering::Relaxed) {
                            // Best-effort abort and reset.
                            let _ = self.session.send_abort();
                            self.session.shutdown();
                            let _ = tx.send(SentenceChunk { text: String::new(), is_final: true }).await;
                            return Ok(true);
                        }
                    }
                    out = self.session.recv() => {
                        let Some(out) = out else {
                            prompt_error = Some("Pi output channel closed".to_owned());
                            break;
                        };

                        match out {
                            PiOutput::Response(resp) => {
                                if let Some(err) = prompt_command_failure(&resp) {
                                    prompt_error = Some(err);
                                    break;
                                }
                            }
                            PiOutput::Unknown(line) => {
                                tracing::debug!("pi rpc: unknown line: {line}");
                            }
                            PiOutput::ProcessExited => {
                                prompt_error = Some(format!(
                                    "Pi process exited while using {}",
                                    self.active_model().display()
                                ));
                                break;
                            }
                            PiOutput::ExtensionUiRequest(req) => {
                                self.handle_extension_ui_request(req, tx).await?;
                            }
                            PiOutput::Event(ev) => {
                                if self.handle_agent_event(ev, &mut sentence_buffer, tx).await? {
                                    completed = true;
                                    break;
                                }
                            }
                        }
                    }
                }
            }

            if completed {
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
                return Ok(false);
            }

            let err_msg = prompt_error.unwrap_or_else(|| {
                format!(
                    "Pi prompt failed while using {}",
                    self.active_model().display()
                )
            });
            if let Some(next_idx) = self.pick_failover_candidate(&tried, &err_msg)
                && self
                    .request_model_failover_approval(next_idx, &err_msg, tx)
                    .await?
            {
                self.switch_to_candidate(next_idx);
                continue;
            }

            return Err(SpeechError::Pi(err_msg));
        }
    }

    pub fn truncate_history(&mut self, _keep_count: usize) {
        // Pi doesn't expose "truncate to N messages" in RPC mode.
        // Reset to a fresh session (best-effort) by restarting the subprocess.
        self.session.shutdown();
    }

    fn active_model(&self) -> &ProviderModelRef {
        // `active_model_idx` is always sourced from `model_candidates`.
        &self.model_candidates[self.active_model_idx]
    }

    fn switch_to_candidate(&mut self, index: usize) {
        if index >= self.model_candidates.len() {
            return;
        }
        let next = &self.model_candidates[index];
        self.active_model_idx = index;
        self.session
            .set_provider_model(next.provider.clone(), next.model.clone());
        tracing::info!("pi backend switched model to {}", next.display());
    }

    fn pick_failover_candidate(&self, tried: &HashSet<usize>, err_msg: &str) -> Option<usize> {
        if looks_like_network_error(err_msg)
            && let Some((idx, _)) =
                self.model_candidates
                    .iter()
                    .enumerate()
                    .find(|(idx, candidate)| {
                        !tried.contains(idx) && candidate.provider == FAE_PROVIDER_KEY
                    })
        {
            return Some(idx);
        }

        self.model_candidates
            .iter()
            .enumerate()
            .find_map(|(idx, _)| (!tried.contains(&idx)).then_some(idx))
    }

    async fn request_model_failover_approval(
        &mut self,
        next_idx: usize,
        err_msg: &str,
        tx: &mpsc::Sender<SentenceChunk>,
    ) -> Result<bool> {
        if next_idx >= self.model_candidates.len() {
            return Ok(false);
        }

        let current = self.active_model().clone();
        let next = self.model_candidates[next_idx].clone();
        let alternatives = self
            .model_candidates
            .iter()
            .enumerate()
            .map(|(i, candidate)| {
                let marker = if i == self.active_model_idx {
                    " (current)"
                } else if i == next_idx {
                    " (next)"
                } else {
                    ""
                };
                format!("{}. {}{}", i + 1, candidate.display(), marker)
            })
            .collect::<Vec<_>>()
            .join("\n");

        let title = if looks_like_network_error(err_msg) && next.provider == FAE_PROVIDER_KEY {
            "Switch to local-only mode?"
        } else {
            "Primary model failed. Try another model?"
        };

        let message = format!(
            "Current model: {}\n\
             Proposed next model: {}\n\n\
             Error:\n{}\n\n\
             Available models:\n{}\n\n\
             Approve to switch now.\n\
             Deny to keep current model (you can change the primary model in Settings > LLM / Intelligence).",
            current.display(),
            next.display(),
            err_msg,
            alternatives
        );

        let spoken = if looks_like_network_error(err_msg) && next.provider == FAE_PROVIDER_KEY {
            "I can't reach online models right now. I can continue in local-only mode if you approve."
        } else {
            "The current model failed. Please review the fallback options on canvas and approve if you want me to switch."
        };

        tx.send(SentenceChunk {
            text: spoken.to_owned(),
            is_final: true,
        })
        .await
        .map_err(|e| SpeechError::Channel(format!("LLM output channel closed: {e}")))?;

        let input_json = make_dialog_json(
            "model_failover",
            title,
            &message,
            UI_CONFIRM_TIMEOUT.as_millis() as u64,
        );

        let approved = matches!(
            self.request_ui_dialog_response("pi.model_failover", input_json, UI_CONFIRM_TIMEOUT)
                .await,
            ToolApprovalResponse::Approved(true)
        );

        if approved {
            let confirmation = if next.provider == FAE_PROVIDER_KEY {
                format!("Switching to local-only mode with {}.", next.display())
            } else {
                format!("Switching to {}.", next.display())
            };
            tx.send(SentenceChunk {
                text: confirmation,
                is_final: true,
            })
            .await
            .map_err(|e| SpeechError::Channel(format!("LLM output channel closed: {e}")))?;
        } else {
            tx.send(SentenceChunk {
                text: "Okay, I won't switch models right now.".to_owned(),
                is_final: true,
            })
            .await
            .map_err(|e| SpeechError::Channel(format!("LLM output channel closed: {e}")))?;
        }

        Ok(approved)
    }

    async fn handle_agent_event(
        &mut self,
        ev: PiAgentEvent,
        sentence_buffer: &mut String,
        tx: &mpsc::Sender<SentenceChunk>,
    ) -> Result<bool> {
        match ev {
            PiAgentEvent::AgentEnd { .. } => return Ok(true),

            PiAgentEvent::MessageStart { message } => {
                if message.get("role").and_then(|v| v.as_str()) == Some("assistant") {
                    self.assistant_delta_buffer.clear();
                }
            }

            PiAgentEvent::MessageUpdate {
                message,
                assistant_message_event,
            } => {
                if message.get("role").and_then(|v| v.as_str()) != Some("assistant") {
                    return Ok(false);
                }

                if let Some(chunk) =
                    assistant_text_chunk(&assistant_message_event, &self.assistant_delta_buffer)
                    && !chunk.is_empty()
                {
                    self.assistant_delta_buffer.push_str(&chunk);
                    sentence_buffer.push_str(&chunk);

                    while let Some(pos) = crate::llm::find_clause_boundary(sentence_buffer) {
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
                        *sentence_buffer = sentence_buffer[pos + 1..].to_owned();
                    }
                }
            }

            PiAgentEvent::ToolExecutionStart {
                tool_call_id,
                tool_name,
                args,
            } => {
                if let Some(rt) = &self.runtime_tx {
                    let input_json = serde_json::to_string(&args).unwrap_or_else(|_| "{}".into());
                    let _ = rt.send(RuntimeEvent::ToolCall {
                        id: tool_call_id,
                        name: tool_name,
                        input_json,
                    });
                }
            }

            PiAgentEvent::ToolExecutionEnd {
                tool_call_id,
                tool_name,
                result,
                is_error,
            } => {
                if let Some(rt) = &self.runtime_tx {
                    let output = extract_tool_text(&result);
                    let output_text = output.map(|s| truncate_text(&s, TOOL_OUTPUT_LIMIT_CHARS));
                    let _ = rt.send(RuntimeEvent::ToolResult {
                        id: tool_call_id,
                        name: tool_name,
                        success: !is_error,
                        output_text,
                    });
                }
            }

            // Ignore other events for now (turn_* lifecycle, tool_execution_update, compaction/retry).
            _ => {}
        }

        Ok(false)
    }

    async fn handle_extension_ui_request(
        &mut self,
        req: PiExtensionUiRequest,
        tx: &mpsc::Sender<SentenceChunk>,
    ) -> Result<()> {
        match req {
            PiExtensionUiRequest::Confirm {
                id,
                title,
                message,
                timeout,
            } => {
                let is_destructive = title.to_lowercase().contains("destructive")
                    || message.to_lowercase().contains("[delete risk]");
                let spoken = if is_destructive {
                    "I need your permission for a destructive file action. Please review and approve or deny."
                        .to_owned()
                } else {
                    format!("I need your permission. {title}")
                };
                tx.send(SentenceChunk {
                    text: spoken,
                    is_final: true,
                })
                .await
                .map_err(|e| SpeechError::Channel(format!("LLM output channel closed: {e}")))?;

                let timeout_ms = timeout.unwrap_or(UI_CONFIRM_TIMEOUT.as_millis() as u64);
                let input_json = make_dialog_json("confirm", &title, &message, timeout_ms);

                let t = timeout
                    .map(Duration::from_millis)
                    .unwrap_or(UI_CONFIRM_TIMEOUT);
                let approved = matches!(
                    self.request_ui_dialog_response("pi.confirm", input_json, t)
                        .await,
                    ToolApprovalResponse::Approved(true)
                );

                self.session.send_ui_confirm(&id, approved)?;
                Ok(())
            }

            PiExtensionUiRequest::Select {
                id,
                title,
                options,
                timeout,
            } => {
                tx.send(SentenceChunk {
                    text: format!("I need your choice. {title}"),
                    is_final: true,
                })
                .await
                .map_err(|e| SpeechError::Channel(format!("LLM output channel closed: {e}")))?;

                let message = if options.is_empty() {
                    "No options were provided.".to_owned()
                } else {
                    options
                        .iter()
                        .enumerate()
                        .map(|(i, opt)| format!("{}. {opt}", i + 1))
                        .collect::<Vec<_>>()
                        .join("\n")
                };
                let timeout_ms = timeout.unwrap_or(UI_CONFIRM_TIMEOUT.as_millis() as u64);
                let input_json = serde_json::json!({
                    "kind": "select",
                    "title": title,
                    "message": message,
                    "options": options,
                    "timeout_ms": timeout_ms,
                })
                .to_string();

                let t = timeout
                    .map(Duration::from_millis)
                    .unwrap_or(UI_CONFIRM_TIMEOUT);
                let response = self
                    .request_ui_dialog_response("pi.select", input_json, t)
                    .await;
                match response {
                    ToolApprovalResponse::Value(v) => self.session.send_ui_value(&id, v)?,
                    ToolApprovalResponse::Approved(true) => {
                        if let Some(first) = options.first() {
                            self.session.send_ui_value(&id, first.clone())?;
                        } else {
                            self.session.send_ui_cancel(&id)?;
                        }
                    }
                    ToolApprovalResponse::Approved(false) | ToolApprovalResponse::Cancelled => {
                        self.session.send_ui_cancel(&id)?
                    }
                }
                Ok(())
            }

            PiExtensionUiRequest::Input {
                id,
                title,
                placeholder,
                timeout,
            } => {
                tx.send(SentenceChunk {
                    text: format!("I need your input. {title}"),
                    is_final: true,
                })
                .await
                .map_err(|e| SpeechError::Channel(format!("LLM output channel closed: {e}")))?;

                let timeout_ms = timeout.unwrap_or(UI_CONFIRM_TIMEOUT.as_millis() as u64);
                let input_json = serde_json::json!({
                    "kind": "input",
                    "title": title,
                    "message": title,
                    "placeholder": placeholder,
                    "timeout_ms": timeout_ms,
                })
                .to_string();

                let t = timeout
                    .map(Duration::from_millis)
                    .unwrap_or(UI_CONFIRM_TIMEOUT);
                let response = self
                    .request_ui_dialog_response("pi.input", input_json, t)
                    .await;
                match response {
                    ToolApprovalResponse::Value(v) => self.session.send_ui_value(&id, v)?,
                    ToolApprovalResponse::Approved(true) => self.session.send_ui_value(&id, "")?,
                    ToolApprovalResponse::Approved(false) | ToolApprovalResponse::Cancelled => {
                        self.session.send_ui_cancel(&id)?
                    }
                }
                Ok(())
            }

            PiExtensionUiRequest::Editor { id, title, prefill } => {
                tx.send(SentenceChunk {
                    text: format!("I need your edits. {title}"),
                    is_final: true,
                })
                .await
                .map_err(|e| SpeechError::Channel(format!("LLM output channel closed: {e}")))?;

                let input_json = serde_json::json!({
                    "kind": "editor",
                    "title": title,
                    "message": title,
                    "prefill": prefill,
                    "timeout_ms": UI_CONFIRM_TIMEOUT.as_millis() as u64,
                })
                .to_string();

                let response = self
                    .request_ui_dialog_response("pi.editor", input_json, UI_CONFIRM_TIMEOUT)
                    .await;
                match response {
                    ToolApprovalResponse::Value(v) => self.session.send_ui_value(&id, v)?,
                    ToolApprovalResponse::Approved(true) => self
                        .session
                        .send_ui_value(&id, prefill.unwrap_or_default())?,
                    ToolApprovalResponse::Approved(false) | ToolApprovalResponse::Cancelled => {
                        self.session.send_ui_cancel(&id)?
                    }
                }
                Ok(())
            }

            // Fire-and-forget: ignore (optionally surface later).
            PiExtensionUiRequest::Notify { .. }
            | PiExtensionUiRequest::SetStatus { .. }
            | PiExtensionUiRequest::SetWidget { .. }
            | PiExtensionUiRequest::SetTitle { .. }
            | PiExtensionUiRequest::SetEditorText { .. } => Ok(()),
        }
    }

    async fn request_ui_dialog_response(
        &mut self,
        request_name: &str,
        input_json: String,
        timeout: Duration,
    ) -> ToolApprovalResponse {
        let Some(tx_approval) = &self.tool_approval_tx else {
            return ToolApprovalResponse::Cancelled;
        };

        let (respond_to, rx) = oneshot::channel::<ToolApprovalResponse>();
        let req_id = self.next_approval_id;
        self.next_approval_id = self.next_approval_id.saturating_add(1);
        let approval =
            ToolApprovalRequest::new(req_id, request_name.to_owned(), input_json, respond_to);
        if tx_approval.send(approval).is_err() {
            return ToolApprovalResponse::Cancelled;
        }

        match tokio::time::timeout(timeout, rx).await {
            Ok(Ok(resp)) => resp,
            Ok(Err(_)) => ToolApprovalResponse::Cancelled,
            Err(_) => ToolApprovalResponse::Cancelled,
        }
    }
}

/// Returns the base read-only tools common to all modes.
#[inline]
fn base_read_tools() -> Vec<String> {
    vec![
        "read".to_owned(),
        "grep".to_owned(),
        "find".to_owned(),
        "ls".to_owned(),
    ]
}

fn tools_for_mode(mode: AgentToolMode, gate_loaded: bool) -> PiToolsConfig {
    match mode {
        AgentToolMode::Off => PiToolsConfig::None,
        AgentToolMode::ReadOnly => {
            let mut tools = base_read_tools();
            if gate_loaded {
                // Allow gated shell only when the permission gate is active.
                tools.push("bash".to_owned());
            }
            PiToolsConfig::Allowlist(tools)
        }
        AgentToolMode::ReadWrite => {
            let mut tools = base_read_tools();
            if gate_loaded {
                tools.push("edit".to_owned());
                tools.push("write".to_owned());
            }
            PiToolsConfig::Allowlist(tools)
        }
        AgentToolMode::Full => {
            let mut tools = base_read_tools();
            if gate_loaded {
                tools.push("edit".to_owned());
                tools.push("write".to_owned());
                tools.push("bash".to_owned());
            }
            PiToolsConfig::Allowlist(tools)
        }
    }
}

fn default_pi_cwd() -> Option<PathBuf> {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::current_dir().ok())
}

fn prompt_command_failure(resp: &PiRpcResponse) -> Option<String> {
    if resp.command != "prompt" || resp.success {
        return None;
    }

    let err = resp
        .error
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(ToOwned::to_owned)
        .or_else(|| {
            let data = resp.data.as_ref()?;
            if let Some(msg) = data.get("message").and_then(|v| v.as_str()) {
                let m = msg.trim();
                if !m.is_empty() {
                    return Some(m.to_owned());
                }
            }
            if let Some(msg) = data.as_str() {
                let m = msg.trim();
                if !m.is_empty() {
                    return Some(m.to_owned());
                }
            }
            None
        })
        .unwrap_or_else(|| "Pi rejected the prompt request".to_owned());

    Some(err)
}

fn looks_like_network_error(message: &str) -> bool {
    let lower = message.to_lowercase();
    [
        "network",
        "timed out",
        "timeout",
        "econnrefused",
        "econnreset",
        "enotfound",
        "host unreachable",
        "dns",
        "temporary failure",
        "offline",
        "no internet",
        "connection refused",
        "could not resolve",
    ]
    .iter()
    .any(|needle| lower.contains(needle))
}

fn resolve_pi_provider_model(config: &LlmConfig) -> Result<(String, String)> {
    if let Some(provider) = &config.cloud_provider {
        if let Some(model) = &config.cloud_model {
            return Ok((provider.clone(), model.clone()));
        }

        // If the provider is custom-defined in models.json with an explicit model list,
        // pick its first model as a fallback. Built-in providers won't have this list.
        if let Some(pi_path) = crate::llm::pi_config::default_pi_models_path() {
            match crate::llm::pi_config::read_pi_config(&pi_path) {
                Ok(pi_config) => {
                    if let Some(provider_info) = pi_config.find_provider(provider)
                        && let Some(model) = provider_info
                            .models
                            .as_ref()
                            .and_then(|models| models.first())
                            .map(|m| m.id.clone())
                    {
                        return Ok((provider.clone(), model));
                    }
                }
                Err(e) => {
                    tracing::warn!(
                        "failed reading Pi models.json at {}: {e}",
                        pi_path.display()
                    );
                }
            }
        }

        if !config.api_model.trim().is_empty() {
            tracing::warn!(
                "cloud provider '{}' has no explicit cloud_model; using api_model='{}'",
                provider,
                config.api_model
            );
            return Ok((provider.clone(), config.api_model.clone()));
        }

        tracing::warn!(
            "cloud provider '{}' has no discoverable model; falling back to local brain",
            provider
        );
    }

    Ok((FAE_PROVIDER_KEY.to_owned(), FAE_MODEL_ID.to_owned()))
}

fn resolve_pi_model_candidates(config: &LlmConfig) -> Result<Vec<ProviderModelRef>> {
    let primary = resolve_pi_provider_model(config)?;
    let mut out = Vec::<ProviderModelRef>::new();
    let mut seen = HashSet::<(String, String)>::new();

    // Optional pi_config for priority lookups.
    let pi_config = crate::llm::pi_config::default_pi_models_path()
        .and_then(|p| crate::llm::pi_config::read_pi_config(&p).ok());

    let priority_for =
        |pi_cfg: &Option<crate::llm::pi_config::PiModelsConfig>, prov: &str, model: &str| -> i32 {
            pi_cfg
                .as_ref()
                .and_then(|c| c.find_model(prov, model))
                .and_then(|m| m.priority)
                .unwrap_or(0)
        };

    let push = |out: &mut Vec<ProviderModelRef>,
                seen: &mut HashSet<(String, String)>,
                provider: String,
                model: String,
                priority: i32| {
        let p = provider.trim().to_owned();
        let m = model.trim().to_owned();
        if p.is_empty() || m.is_empty() {
            return;
        }
        if seen.insert((p.clone(), m.clone())) {
            out.push(ProviderModelRef::new(p, m, priority));
        }
    };

    let pri = priority_for(&pi_config, &primary.0, &primary.1);
    push(&mut out, &mut seen, primary.0, primary.1, pri);

    if !matches!(
        out.first(),
        Some(ProviderModelRef {
            provider,
            model: _,
            ..
        }) if provider == FAE_PROVIDER_KEY
    ) {
        let pri = priority_for(&pi_config, FAE_PROVIDER_KEY, FAE_MODEL_ID);
        push(
            &mut out,
            &mut seen,
            FAE_PROVIDER_KEY.to_owned(),
            FAE_MODEL_ID.to_owned(),
            pri,
        );
    }

    if let Some(provider) = &config.cloud_provider
        && let Some(model) = &config.cloud_model
    {
        let pri = priority_for(&pi_config, provider, model);
        push(&mut out, &mut seen, provider.clone(), model.clone(), pri);
    }

    if let Some(provider) = &config.cloud_provider
        && config.cloud_model.is_none()
        && !config.api_model.trim().is_empty()
    {
        let pri = priority_for(&pi_config, provider, &config.api_model);
        push(
            &mut out,
            &mut seen,
            provider.clone(),
            config.api_model.clone(),
            pri,
        );
    }

    if let Some(ref pi_cfg) = pi_config {
        for (provider, model) in pi_cfg.provider_model_pairs() {
            let pri = priority_for(&pi_config, &provider, &model);
            push(&mut out, &mut seen, provider, model, pri);
        }
    } else if let Some(pi_path) = crate::llm::pi_config::default_pi_models_path() {
        tracing::debug!(
            "Pi models.json not available at {} for model discovery",
            pi_path.display()
        );
    }

    if out.is_empty() {
        push(
            &mut out,
            &mut seen,
            FAE_PROVIDER_KEY.to_owned(),
            FAE_MODEL_ID.to_owned(),
            0,
        );
    }

    // Sort: best tier first, then highest priority within each tier.
    out.sort_by(|a, b| {
        a.tier
            .cmp(&b.tier)
            .then_with(|| b.priority.cmp(&a.priority))
    });

    Ok(out)
}

fn extract_tool_text(result: &serde_json::Value) -> Option<String> {
    let content = result.get("content")?.as_array()?;
    let mut out = String::new();
    for block in content {
        if block.get("type").and_then(|v| v.as_str()) != Some("text") {
            continue;
        }
        let text = block.get("text").and_then(|v| v.as_str()).unwrap_or("");
        if text.is_empty() {
            continue;
        }
        if !out.is_empty() {
            out.push('\n');
        }
        out.push_str(text);
    }
    if out.is_empty() { None } else { Some(out) }
}

fn truncate_text(text: &str, max_chars: usize) -> String {
    if text.len() <= max_chars {
        return text.to_owned();
    }
    // Find the last char boundary at or before `max_chars` to avoid panicking
    // on multi-byte UTF-8 sequences.
    let end = text
        .char_indices()
        .map(|(i, _)| i)
        .take_while(|&i| i <= max_chars)
        .last()
        .unwrap_or(0);
    let mut out = text[..end].to_owned();
    out.push_str("\n… (truncated)");
    out
}

fn assistant_text_chunk(event: &serde_json::Value, accumulated: &str) -> Option<String> {
    let tp = event.get("type").and_then(|v| v.as_str()).unwrap_or("");
    if tp != "text_delta" && tp != "text_start" && tp != "text_end" {
        return None;
    }

    let delta = event.get("delta").and_then(|v| v.as_str()).unwrap_or("");
    let content = event.get("content").and_then(|v| v.as_str()).unwrap_or("");

    let mut chunk = String::new();
    if tp == "text_delta" {
        chunk.push_str(delta);
        return Some(chunk);
    }

    if !delta.is_empty() {
        chunk.push_str(delta);
        return Some(chunk);
    }

    if content.is_empty() {
        return None;
    }

    // Some providers resend full content on `text_end`. Only append a suffix to keep output monotonic.
    if let Some(stripped) = content.strip_prefix(accumulated) {
        chunk.push_str(stripped);
        if chunk.is_empty() { None } else { Some(chunk) }
    } else if accumulated.starts_with(content) {
        None
    } else if !accumulated.contains(content) {
        chunk.push_str(content);
        Some(chunk)
    } else {
        None
    }
}

/// Constructs a JSON envelope for UI dialog requests.
///
/// Standardizes the JSON structure across different dialog kinds
/// (confirm, select, input, editor, model_failover).
#[inline]
fn make_dialog_json(kind: &str, title: &str, message: &str, timeout_ms: u64) -> String {
    serde_json::json!({
        "kind": kind,
        "title": title,
        "message": message,
        "timeout_ms": timeout_ms,
    })
    .to_string()
}

fn ensure_fae_gate_extension() -> Result<PathBuf> {
    const EXT_SOURCE: &str = r#"/**
 * Fae Permission Gate
 *
 * Blocks dangerous tools unless the host UI explicitly approves.
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  const gated = new Set(["bash", "edit", "write"]);
  const deletePatterns = [
    /\brm\b/i,
    /\bunlink\b/i,
    /\brmdir\b/i,
    /\bdel\b/i,
    /\berase\b/i,
    /\bfind\b[\s\S]*\s-delete\b/i,
    /\btrash\b/i,
  ];

  function isDestructiveBash(command: string): boolean {
    return deletePatterns.some((rx) => rx.test(command));
  }

  pi.on("tool_call", async (event, ctx) => {
    const tool = event.toolName;
    if (!gated.has(tool)) return undefined;

    const details =
      tool === "bash"
        ? String((event.input as any)?.command ?? "")
        : JSON.stringify(event.input ?? {}, null, 2);
    const destructive = tool === "bash" && isDestructiveBash(details);
    const title = destructive ? `Allow destructive command: ${tool}?` : `Allow tool: ${tool}?`;
    const reason = destructive
      ? "[DELETE RISK] Why: this command appears to delete or remove files."
      : `Why: ${tool} needs elevated access beyond read-only tools.`;
    const message = `${reason}\n\nProposed action:\n${details}`;

    if (!ctx.hasUI) {
      return { block: true, reason: `Blocked ${tool} (no UI for confirmation)` };
    }

    const ok = await ctx.ui.confirm(title, message.slice(0, 5000));
    if (!ok) {
      return { block: true, reason: "Blocked by user" };
    }
    return undefined;
  });
}
"#;

    let path = default_fae_gate_extension_path();
    write_atomic(&path, EXT_SOURCE)?;
    Ok(path)
}

fn default_fae_gate_extension_path() -> PathBuf {
    if let Some(home) = std::env::var_os("HOME") {
        PathBuf::from(home)
            .join(".fae")
            .join("pi")
            .join("extensions")
            .join("fae-gate.ts")
    } else {
        std::env::temp_dir()
            .join(".fae")
            .join("pi")
            .join("extensions")
            .join("fae-gate.ts")
    }
}

fn write_atomic(path: &Path, content: &str) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| SpeechError::Pi(format!("create extension dir: {e}")))?;

        // Restrict directory permissions so other users can't tamper with extensions.
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let perms = std::fs::Permissions::from_mode(0o700);
            let _ = std::fs::set_permissions(parent, perms);
        }
    }

    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, content)
        .map_err(|e| SpeechError::Pi(format!("write extension tmp: {e}")))?;
    std::fs::rename(&tmp, path).map_err(|e| SpeechError::Pi(format!("rename extension: {e}")))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model_tier::ModelTier;

    #[test]
    fn tool_allowlists_match_expected_modes() {
        let ro = tools_for_mode(AgentToolMode::ReadOnly, true);
        match ro {
            PiToolsConfig::Allowlist(list) => {
                assert!(list.contains(&"read".to_owned()));
                assert!(list.contains(&"bash".to_owned()));
                assert!(!list.contains(&"edit".to_owned()));
                assert!(!list.contains(&"write".to_owned()));
            }
            _ => panic!("expected allowlist"),
        }
    }

    #[test]
    fn tool_allowlists_fail_closed_when_gate_missing() {
        let ro = tools_for_mode(AgentToolMode::ReadOnly, false);
        match ro {
            PiToolsConfig::Allowlist(list) => {
                assert!(list.contains(&"read".to_owned()));
                assert!(!list.contains(&"bash".to_owned()));
                assert!(!list.contains(&"edit".to_owned()));
                assert!(!list.contains(&"write".to_owned()));
            }
            _ => panic!("expected allowlist"),
        }
    }

    #[test]
    fn prompt_response_failure_extracts_error_text() {
        let resp = PiRpcResponse {
            id: None,
            command: "prompt".to_owned(),
            success: false,
            data: Some(serde_json::json!({"message":"rate limit"})),
            error: None,
        };
        let err = prompt_command_failure(&resp);
        assert_eq!(err.as_deref(), Some("rate limit"));
    }

    #[test]
    fn network_error_classifier_matches_common_messages() {
        assert!(looks_like_network_error("ECONNREFUSED while connecting"));
        assert!(looks_like_network_error("request timed out"));
        assert!(!looks_like_network_error("invalid json schema"));
    }

    #[test]
    fn candidate_list_includes_local_fallback_for_cloud_primary() {
        let cfg = LlmConfig {
            cloud_provider: Some("openai".to_owned()),
            cloud_model: Some("gpt-5".to_owned()),
            ..LlmConfig::default()
        };

        let candidates = resolve_pi_model_candidates(&cfg).unwrap();
        assert!(
            candidates
                .iter()
                .any(|c| c.provider == "openai" && c.model == "gpt-5")
        );
        assert!(
            candidates
                .iter()
                .any(|c| c.provider == FAE_PROVIDER_KEY && c.model == FAE_MODEL_ID)
        );
    }

    #[test]
    fn provider_model_ref_new_computes_tier() {
        let flagship = ProviderModelRef::new("anthropic".into(), "claude-opus-4".into(), 0);
        assert_eq!(flagship.tier, ModelTier::Flagship);

        let mid = ProviderModelRef::new("openai".into(), "gpt-4o-mini".into(), 0);
        assert_eq!(mid.tier, ModelTier::Mid);

        let local = ProviderModelRef::new(FAE_PROVIDER_KEY.into(), FAE_MODEL_ID.into(), 0);
        assert_eq!(local.tier, ModelTier::Small);
    }

    #[test]
    fn candidates_sorted_by_tier_then_priority() {
        // Build candidates in deliberately wrong order.
        let mut candidates = [
            ProviderModelRef::new("local".into(), "qwen3-4b".into(), 0), // Small, p=0
            ProviderModelRef::new("openai".into(), "gpt-4o".into(), 5),  // Flagship, p=5
            ProviderModelRef::new("anthropic".into(), "claude-opus-4".into(), 10), // Flagship, p=10
            ProviderModelRef::new("openai".into(), "gpt-4o-mini".into(), 0), // Mid, p=0
        ];

        candidates.sort_by(|a, b| {
            a.tier
                .cmp(&b.tier)
                .then_with(|| b.priority.cmp(&a.priority))
        });

        // Flagship tier first (higher priority first within tier).
        assert_eq!(candidates[0].model, "claude-opus-4");
        assert_eq!(candidates[0].tier, ModelTier::Flagship);
        assert_eq!(candidates[0].priority, 10);
        assert_eq!(candidates[1].model, "gpt-4o");
        assert_eq!(candidates[1].tier, ModelTier::Flagship);
        assert_eq!(candidates[1].priority, 5);

        // Mid tier.
        assert_eq!(candidates[2].model, "gpt-4o-mini");
        assert_eq!(candidates[2].tier, ModelTier::Mid);

        // Small tier last.
        assert_eq!(candidates[3].model, "qwen3-4b");
        assert_eq!(candidates[3].tier, ModelTier::Small);
    }

    /// Helper: assert ModelSelected event matches expected provider/model.
    fn assert_model_selected(rx: &mut broadcast::Receiver<RuntimeEvent>, expected: &str) {
        match rx.try_recv() {
            Ok(RuntimeEvent::ModelSelected { provider_model }) => {
                assert_eq!(provider_model, expected);
            }
            other => panic!("expected ModelSelected, got: {other:?}"),
        }
    }

    /// Helper: build PiLlm with runtime tx and no selection channel.
    fn test_pi_no_rx(
        candidates: Vec<ProviderModelRef>,
    ) -> (PiLlm, broadcast::Receiver<RuntimeEvent>) {
        let (tx, rx) = broadcast::channel(16);
        let pi = PiLlm {
            runtime_tx: Some(tx),
            tool_approval_tx: None,
            session: PiSession::new("/fake".into(), "p".into(), "m".into()),
            next_approval_id: 1,
            model_candidates: candidates,
            active_model_idx: 0,
            model_selection_rx: None,
            assistant_delta_buffer: String::new(),
        };
        (pi, rx)
    }

    #[test]
    fn emit_model_selected_sends_event_when_tx_present() {
        let (pi, mut rx) = test_pi_no_rx(vec![]);
        pi.emit_model_selected("openai/gpt-4o");
        assert_model_selected(&mut rx, "openai/gpt-4o");
    }

    #[test]
    fn emit_model_selection_prompt_sends_event() {
        let (pi, mut rx) = test_pi_no_rx(vec![]);
        pi.emit_model_selection_prompt(
            &["openai/gpt-4o".to_owned(), "anthropic/claude".to_owned()],
            Duration::from_secs(30),
        );
        match rx.try_recv() {
            Ok(RuntimeEvent::ModelSelectionPrompt {
                candidates,
                timeout_secs,
            }) => {
                assert_eq!(candidates.len(), 2);
                assert_eq!(timeout_secs, 30);
            }
            other => panic!("expected ModelSelectionPrompt, got: {other:?}"),
        }
    }

    #[test]
    fn emit_functions_are_noop_without_runtime_tx() {
        let pi = PiLlm {
            runtime_tx: None,
            tool_approval_tx: None,
            session: PiSession::new("/fake".into(), "p".into(), "m".into()),
            next_approval_id: 1,
            model_candidates: vec![],
            active_model_idx: 0,
            model_selection_rx: None,
            assistant_delta_buffer: String::new(),
        };
        // Should not panic even without runtime_tx.
        pi.emit_model_selected("test/model");
        pi.emit_model_selection_prompt(&["a".to_owned()], Duration::from_secs(5));
    }

    /// Helper: build a PiLlm with given candidates and optional selection channel.
    fn test_pi(
        candidates: Vec<ProviderModelRef>,
        model_selection_rx: Option<mpsc::UnboundedReceiver<String>>,
    ) -> (PiLlm, broadcast::Receiver<RuntimeEvent>) {
        let (tx, rx) = broadcast::channel(16);
        let pi = PiLlm {
            runtime_tx: Some(tx),
            tool_approval_tx: None,
            session: PiSession::new("/fake".into(), "p".into(), "m".into()),
            next_approval_id: 1,
            model_candidates: candidates,
            active_model_idx: 0,
            model_selection_rx,
            assistant_delta_buffer: String::new(),
        };
        (pi, rx)
    }

    #[tokio::test]
    async fn select_startup_model_single_candidate_auto_selects() {
        let candidates = vec![ProviderModelRef::new(
            "anthropic".into(),
            "claude-opus-4".into(),
            0,
        )];
        let (mut pi, mut event_rx) = test_pi(candidates, None);

        pi.select_startup_model(Duration::from_secs(1))
            .await
            .unwrap();

        assert_eq!(pi.active_model_idx, 0);
        match event_rx.try_recv() {
            Ok(RuntimeEvent::ModelSelected { provider_model }) => {
                assert_eq!(provider_model, "anthropic/claude-opus-4");
            }
            other => panic!("expected ModelSelected, got: {other:?}"),
        }
    }

    #[tokio::test]
    async fn select_startup_model_no_candidates_returns_error() {
        let (mut pi, _rx) = test_pi(vec![], None);

        let result = pi.select_startup_model(Duration::from_secs(1)).await;
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn select_startup_model_multiple_top_tier_emits_prompt_then_times_out() {
        let candidates = vec![
            ProviderModelRef::new("anthropic".into(), "claude-opus-4".into(), 10),
            ProviderModelRef::new("openai".into(), "gpt-4o".into(), 5),
        ];
        // Channel with no sender = will never receive anything.
        let (_sel_tx, sel_rx) = mpsc::unbounded_channel::<String>();
        let (mut pi, mut event_rx) = test_pi(candidates, Some(sel_rx));

        // Use a very short timeout to avoid slowing down tests.
        pi.select_startup_model(Duration::from_millis(50))
            .await
            .unwrap();

        // Should have emitted a prompt first.
        match event_rx.try_recv() {
            Ok(RuntimeEvent::ModelSelectionPrompt {
                candidates,
                timeout_secs: _,
            }) => {
                assert_eq!(candidates.len(), 2);
                assert_eq!(candidates[0], "anthropic/claude-opus-4");
                assert_eq!(candidates[1], "openai/gpt-4o");
            }
            other => panic!("expected ModelSelectionPrompt, got: {other:?}"),
        }

        // Then fell back to auto-select first.
        assert_eq!(pi.active_model_idx, 0);
        match event_rx.try_recv() {
            Ok(RuntimeEvent::ModelSelected { provider_model }) => {
                assert_eq!(provider_model, "anthropic/claude-opus-4");
            }
            other => panic!("expected ModelSelected, got: {other:?}"),
        }
    }

    #[tokio::test]
    async fn select_startup_model_user_picks_second_candidate() {
        let candidates = vec![
            ProviderModelRef::new("anthropic".into(), "claude-opus-4".into(), 10),
            ProviderModelRef::new("openai".into(), "gpt-4o".into(), 5),
        ];
        let (sel_tx, sel_rx) = mpsc::unbounded_channel::<String>();
        let (mut pi, mut event_rx) = test_pi(candidates, Some(sel_rx));

        // Simulate user picking second candidate after a tiny delay.
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(10)).await;
            let _ = sel_tx.send("openai/gpt-4o".to_owned());
        });

        pi.select_startup_model(Duration::from_secs(5))
            .await
            .unwrap();

        // Prompt should have been emitted.
        match event_rx.try_recv() {
            Ok(RuntimeEvent::ModelSelectionPrompt { .. }) => {}
            other => panic!("expected ModelSelectionPrompt, got: {other:?}"),
        }

        // User's choice should be reflected.
        assert_eq!(pi.active_model_idx, 1);
        match event_rx.try_recv() {
            Ok(RuntimeEvent::ModelSelected { provider_model }) => {
                assert_eq!(provider_model, "openai/gpt-4o");
            }
            other => panic!("expected ModelSelected, got: {other:?}"),
        }
    }

    #[tokio::test]
    async fn select_startup_model_different_tiers_auto_selects_best() {
        let candidates = vec![
            ProviderModelRef::new("anthropic".into(), "claude-opus-4".into(), 0),
            ProviderModelRef::new("local".into(), "qwen3-4b".into(), 0),
        ];
        let (mut pi, mut event_rx) = test_pi(candidates, None);

        pi.select_startup_model(Duration::from_secs(1))
            .await
            .unwrap();

        // Should auto-select the flagship model without prompting.
        assert_eq!(pi.active_model_idx, 0);

        // Verify no prompt was emitted (because both have same tier score of 0).
        match event_rx.try_recv() {
            Ok(RuntimeEvent::ModelSelected { provider_model }) => {
                assert_eq!(provider_model, "anthropic/claude-opus-4");
            }
            other => panic!("expected ModelSelected (no prompt), got: {other:?}"),
        }
    }

    #[tokio::test]
    async fn select_startup_model_channel_closed_falls_back_to_first() {
        let candidates = vec![
            ProviderModelRef::new("anthropic".into(), "claude-opus-4".into(), 10),
            ProviderModelRef::new("openai".into(), "gpt-4o".into(), 5),
        ];
        // Create channel and immediately drop the sender so recv returns None.
        let (sel_tx, sel_rx) = mpsc::unbounded_channel::<String>();
        drop(sel_tx);
        let (mut pi, mut event_rx) = test_pi(candidates, Some(sel_rx));

        pi.select_startup_model(Duration::from_secs(5))
            .await
            .unwrap();

        // Prompt emitted, then channel closed → fallback to first.
        match event_rx.try_recv() {
            Ok(RuntimeEvent::ModelSelectionPrompt { .. }) => {}
            other => panic!("expected ModelSelectionPrompt, got: {other:?}"),
        }
        assert_eq!(pi.active_model_idx, 0);
    }

    #[tokio::test]
    async fn select_startup_model_invalid_user_choice_falls_back() {
        let candidates = vec![
            ProviderModelRef::new("anthropic".into(), "claude-opus-4".into(), 10),
            ProviderModelRef::new("openai".into(), "gpt-4o".into(), 5),
        ];
        let (sel_tx, sel_rx) = mpsc::unbounded_channel::<String>();
        let (mut pi, _event_rx) = test_pi(candidates, Some(sel_rx));

        // Send an invalid model name that doesn't match any candidate.
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(10)).await;
            let _ = sel_tx.send("nonexistent/model-xyz".to_owned());
        });

        pi.select_startup_model(Duration::from_millis(100))
            .await
            .unwrap();

        // Unknown selection → auto-select first candidate.
        assert_eq!(pi.active_model_idx, 0);
    }

    #[tokio::test]
    async fn select_startup_model_no_channel_auto_selects_without_prompt() {
        // Multiple top-tier models but NO selection channel (no GUI).
        let candidates = vec![
            ProviderModelRef::new("anthropic".into(), "claude-opus-4".into(), 10),
            ProviderModelRef::new("openai".into(), "gpt-4o".into(), 5),
        ];
        let (mut pi, mut event_rx) = test_pi(candidates, None);

        pi.select_startup_model(Duration::from_secs(5))
            .await
            .unwrap();

        // Without a channel, no prompt is emitted — just a ModelSelected event.
        match event_rx.try_recv() {
            Ok(RuntimeEvent::ModelSelected { provider_model }) => {
                assert_eq!(provider_model, "anthropic/claude-opus-4");
            }
            other => panic!("expected ModelSelected (no prompt), got: {other:?}"),
        }
        assert_eq!(pi.active_model_idx, 0);
    }
}
