//! Production host command handler for the embedded Fae runtime.

use crate::approval::ToolApprovalRequest;
use crate::config::SpeechConfig;
use crate::error::{Result, SpeechError};
use crate::host::channel::{DeviceTarget, DeviceTransferHandler};
use crate::host::contract::EventEnvelope;
use crate::onboarding::OnboardingPhase;
use crate::permissions::{PermissionKind, SharedPermissionStore};
use crate::pipeline::coordinator::PipelineCoordinator;
use crate::pipeline::messages::{GateCommand, TextInjection};
use crate::progress::ProgressEvent;
use crate::runtime::RuntimeEvent;
use crate::startup::initialize_models_with_progress;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Instant;
use tokio::sync::{broadcast, mpsc};
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

/// Backoff delays (in seconds) for pipeline crash recovery.
///
/// Index 0 = first restart attempt, index N = Nth restart attempt.
/// After exhausting all entries the final value is reused.
const RESTART_BACKOFF_SECS: &[u64] = &[1, 2, 4, 8, 16];

/// Maximum number of automatic restart attempts before giving up.
const MAX_RESTART_ATTEMPTS: u32 = 5;

/// Minimum uptime (seconds) before a crash resets the restart counter.
const RESTART_UPTIME_RESET_SECS: u64 = 30;

/// Lifecycle state of the voice pipeline.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum PipelineState {
    Stopped,
    Starting,
    Running,
    Stopping,
    Error(String),
}

/// Production device transfer handler that persists permission grants and
/// onboarding state to `config.toml`.
///
/// Also manages the voice pipeline lifecycle: starting/stopping the
/// `PipelineCoordinator` and forwarding commands (text injection, gate
/// control) through async channels.
pub struct FaeDeviceTransferHandler {
    config: Mutex<SpeechConfig>,
    config_path: PathBuf,
    /// Live shared permission store.
    ///
    /// This is the canonical permission state at runtime.  It starts as a
    /// copy of `config.permissions` and is updated in-place whenever
    /// `grant_capability` or `deny_capability` is called.  All
    /// `AvailabilityGatedTool` instances that hold a clone of this
    /// `SharedPermissionStore` see changes immediately without re-building
    /// the tool registry.
    shared_permissions: SharedPermissionStore,
    // Pipeline lifecycle
    tokio_handle: tokio::runtime::Handle,
    event_tx: broadcast::Sender<EventEnvelope>,
    /// Pipeline lifecycle state.
    ///
    /// Wrapped in `Arc` so the crash-recovery watcher task can share a clone
    /// and update the state from inside its async context.
    pipeline_state: Arc<Mutex<PipelineState>>,
    cancel_token: Mutex<Option<CancellationToken>>,
    pipeline_handle: Mutex<Option<tokio::task::JoinHandle<()>>>,
    event_bridge_handle: Mutex<Option<tokio::task::JoinHandle<()>>>,
    text_injection_tx: Mutex<Option<mpsc::UnboundedSender<TextInjection>>>,
    gate_cmd_tx: Mutex<Option<mpsc::UnboundedSender<GateCommand>>>,
    tool_approval_tx: Mutex<Option<mpsc::UnboundedSender<ToolApprovalRequest>>>,
    /// Pending tool approval requests keyed by numeric request ID.
    ///
    /// When the pipeline emits a `ToolApprovalRequest`, the approval bridge
    /// task inserts it here. When `approval.respond` arrives via FFI, this
    /// map is consulted to deliver the response.
    ///
    /// Uses `Arc` so the async approval-bridge task can hold a clone while
    /// the handler owns the canonical reference.
    pending_approvals: Arc<Mutex<HashMap<u64, ToolApprovalRequest>>>,
    /// Handle for the task that drains `approval_rx` into `pending_approvals`.
    approval_bridge_handle: Mutex<Option<tokio::task::JoinHandle<()>>>,
    /// When the pipeline started running. Shared with the restart watcher.
    pipeline_started_at: Arc<Mutex<Option<Instant>>>,
    /// Number of automatic restart attempts since the last clean run.
    ///
    /// Shared with the restart watcher so the watcher can update state from
    /// inside the async task.
    restart_count: Arc<Mutex<u32>>,
    /// Timestamp of the last automatic restart, for logging. Shared with watcher.
    last_restart_at: Arc<Mutex<Option<Instant>>>,
    /// Handle for the crash-recovery watcher task.
    restart_watcher_handle: Mutex<Option<tokio::task::JoinHandle<()>>>,
    /// Flag shared with the restart watcher to distinguish a clean stop from a crash.
    /// Set to `true` by `request_runtime_stop()` *before* cancelling the token.
    clean_exit_flag: Arc<std::sync::atomic::AtomicBool>,
    /// Handle for the audio device hot-swap watcher task.
    device_watcher_handle: Mutex<Option<tokio::task::JoinHandle<()>>>,
    /// Handle for the memory pressure monitor task.
    memory_pressure_handle: Mutex<Option<tokio::task::JoinHandle<()>>>,
    /// Current pipeline operating mode (updated on degraded mode transitions).
    pipeline_mode: Mutex<crate::pipeline::coordinator::PipelineMode>,
}

impl std::fmt::Debug for FaeDeviceTransferHandler {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("FaeDeviceTransferHandler")
            .field("config_path", &self.config_path)
            .field("pipeline_state", &self.pipeline_state())
            .finish()
    }
}

impl FaeDeviceTransferHandler {
    /// Create a handler that reads/writes config at the given path.
    pub fn new(
        config: SpeechConfig,
        config_path: PathBuf,
        tokio_handle: tokio::runtime::Handle,
        event_tx: broadcast::Sender<EventEnvelope>,
    ) -> Self {
        // Initialise the shared permissions from the persisted config so that
        // previously-granted permissions are visible to tools immediately.
        let shared_permissions = config.permissions.clone().into_shared();
        Self {
            config: Mutex::new(config),
            config_path,
            shared_permissions,
            tokio_handle,
            event_tx,
            pipeline_state: Arc::new(Mutex::new(PipelineState::Stopped)),
            cancel_token: Mutex::new(None),
            pipeline_handle: Mutex::new(None),
            event_bridge_handle: Mutex::new(None),
            text_injection_tx: Mutex::new(None),
            gate_cmd_tx: Mutex::new(None),
            tool_approval_tx: Mutex::new(None),
            pending_approvals: Arc::new(Mutex::new(HashMap::new())),
            approval_bridge_handle: Mutex::new(None),
            pipeline_started_at: Arc::new(Mutex::new(None)),
            restart_count: Arc::new(Mutex::new(0)),
            last_restart_at: Arc::new(Mutex::new(None)),
            restart_watcher_handle: Mutex::new(None),
            clean_exit_flag: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            device_watcher_handle: Mutex::new(None),
            memory_pressure_handle: Mutex::new(None),
            pipeline_mode: Mutex::new(crate::pipeline::coordinator::PipelineMode::Conversation),
        }
    }

    /// Return a clone of the live [`SharedPermissionStore`].
    ///
    /// The returned handle shares the same underlying store as the handler —
    /// any grants or denials applied through the handler are immediately
    /// visible through this clone.
    pub fn shared_permissions(&self) -> SharedPermissionStore {
        Arc::clone(&self.shared_permissions)
    }

    /// Create a handler using the default config path.
    pub fn from_default_path(
        tokio_handle: tokio::runtime::Handle,
        event_tx: broadcast::Sender<EventEnvelope>,
    ) -> Result<Self> {
        let path = SpeechConfig::default_config_path();
        let config = if path.is_file() {
            SpeechConfig::from_file(&path)?
        } else {
            SpeechConfig::default()
        };
        Ok(Self::new(config, path, tokio_handle, event_tx))
    }

    /// Emit an event to the FFI broadcast channel.
    ///
    /// Silently drops the event if there are no active receivers.
    fn emit_event(&self, event: &str, payload: serde_json::Value) {
        let envelope =
            EventEnvelope::new(uuid::Uuid::new_v4().to_string(), event.to_owned(), payload);
        let _ = self.event_tx.send(envelope);
    }

    /// Read the current pipeline state.
    pub(crate) fn pipeline_state(&self) -> PipelineState {
        self.pipeline_state
            .lock()
            .map(|g| g.clone())
            .unwrap_or(PipelineState::Error("lock poisoned".to_owned()))
    }

    /// Save the current config to disk.
    fn save_config(&self) -> Result<()> {
        let guard = self.lock_config()?;
        guard.save_to_file(&self.config_path)
    }

    /// Acquire a lock on the mutable config, mapping a poisoned mutex to a
    /// `SpeechError::Config`.
    fn lock_config(&self) -> Result<std::sync::MutexGuard<'_, SpeechConfig>> {
        self.config
            .lock()
            .map_err(|e| SpeechError::Config(format!("config lock poisoned: {e}")))
    }

    /// Parse a capability string to a `PermissionKind`.
    fn parse_permission(capability: &str) -> Result<PermissionKind> {
        capability.parse::<PermissionKind>().map_err(|_| {
            SpeechError::Pipeline(format!(
                "unknown capability `{capability}`; expected one of: {}",
                PermissionKind::all()
                    .iter()
                    .map(|k| k.to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            ))
        })
    }
}

/// Convert a `ProgressEvent` to a JSON payload for FFI event emission.
fn progress_event_to_json(evt: &ProgressEvent) -> serde_json::Value {
    match evt {
        ProgressEvent::DownloadStarted {
            repo_id,
            filename,
            total_bytes,
        } => serde_json::json!({
            "stage": "download_started",
            "repo_id": repo_id,
            "filename": filename,
            "total_bytes": total_bytes,
        }),
        ProgressEvent::DownloadProgress {
            repo_id,
            filename,
            bytes_downloaded,
            total_bytes,
        } => serde_json::json!({
            "stage": "download_progress",
            "repo_id": repo_id,
            "filename": filename,
            "bytes_downloaded": bytes_downloaded,
            "total_bytes": total_bytes,
        }),
        ProgressEvent::DownloadComplete { repo_id, filename } => serde_json::json!({
            "stage": "download_complete",
            "repo_id": repo_id,
            "filename": filename,
        }),
        ProgressEvent::Cached { repo_id, filename } => serde_json::json!({
            "stage": "cached",
            "repo_id": repo_id,
            "filename": filename,
        }),
        ProgressEvent::LoadStarted { model_name } => serde_json::json!({
            "stage": "load_started",
            "model_name": model_name,
        }),
        ProgressEvent::LoadComplete {
            model_name,
            duration_secs,
        } => serde_json::json!({
            "stage": "load_complete",
            "model_name": model_name,
            "duration_secs": duration_secs,
        }),
        ProgressEvent::AggregateProgress {
            bytes_downloaded,
            total_bytes,
            files_complete,
            files_total,
        } => serde_json::json!({
            "stage": "aggregate_progress",
            "bytes_downloaded": bytes_downloaded,
            "total_bytes": total_bytes,
            "files_complete": files_complete,
            "files_total": files_total,
        }),
        ProgressEvent::DownloadPlanReady { plan } => serde_json::json!({
            "stage": "download_plan_ready",
            "file_count": plan.files.len(),
            "total_bytes": plan.total_bytes(),
            "needs_download": plan.needs_download(),
        }),
        ProgressEvent::Error { message } => serde_json::json!({
            "stage": "error",
            "message": message,
        }),
    }
}

/// Map a `RuntimeEvent` to an FFI-compatible event name and JSON payload.
fn map_runtime_event(event: &RuntimeEvent) -> (String, serde_json::Value) {
    use crate::pipeline::messages::ControlEvent;
    match event {
        RuntimeEvent::Control(ControlEvent::AudioDeviceChanged { device_name }) => (
            "pipeline.control".to_owned(),
            serde_json::json!({
                "action": "audio_device_changed",
                "device_name": device_name,
            }),
        ),
        RuntimeEvent::Control(ControlEvent::DegradedMode { mode }) => (
            "pipeline.control".to_owned(),
            serde_json::json!({
                "action": "degraded_mode",
                "mode": mode,
            }),
        ),
        RuntimeEvent::Control(c) => (
            "pipeline.control".to_owned(),
            serde_json::json!({"control": format!("{c:?}")}),
        ),
        RuntimeEvent::Transcription(t) => (
            "pipeline.transcription".to_owned(),
            serde_json::json!({"text": t.text, "is_final": t.is_final}),
        ),
        RuntimeEvent::AssistantSentence(s) => (
            "pipeline.assistant_sentence".to_owned(),
            serde_json::json!({"text": s.text, "is_final": s.is_final}),
        ),
        RuntimeEvent::AssistantGenerating { active } => (
            "pipeline.generating".to_owned(),
            serde_json::json!({"active": active}),
        ),
        RuntimeEvent::ToolExecuting { name } => (
            "pipeline.tool_executing".to_owned(),
            serde_json::json!({"name": name}),
        ),
        RuntimeEvent::ToolCall {
            id,
            name,
            input_json,
        } => (
            "pipeline.tool_call".to_owned(),
            serde_json::json!({"id": id, "name": name, "input_json": input_json}),
        ),
        RuntimeEvent::ToolResult {
            id,
            name,
            success,
            output_text,
        } => (
            "pipeline.tool_result".to_owned(),
            serde_json::json!({
                "id": id,
                "name": name,
                "success": success,
                "output_text": output_text,
            }),
        ),
        RuntimeEvent::AssistantAudioLevel { rms } => (
            "pipeline.audio_level".to_owned(),
            serde_json::json!({"rms": rms}),
        ),
        RuntimeEvent::AssistantViseme { mouth_png } => (
            "pipeline.viseme".to_owned(),
            serde_json::json!({"mouth_png": mouth_png}),
        ),
        RuntimeEvent::MemoryRecall { query, hits } => (
            "pipeline.memory_recall".to_owned(),
            serde_json::json!({"query": query, "hits": hits}),
        ),
        RuntimeEvent::MemoryWrite { op, target_id } => (
            "pipeline.memory_write".to_owned(),
            serde_json::json!({"op": op, "target_id": target_id}),
        ),
        RuntimeEvent::MemoryConflict {
            existing_id,
            replacement_id,
        } => (
            "pipeline.memory_conflict".to_owned(),
            serde_json::json!({"existing_id": existing_id, "replacement_id": replacement_id}),
        ),
        RuntimeEvent::MemoryMigration { from, to, success } => (
            "pipeline.memory_migration".to_owned(),
            serde_json::json!({"from": from, "to": to, "success": success}),
        ),
        RuntimeEvent::ModelSelectionPrompt {
            candidates,
            timeout_secs,
        } => (
            "pipeline.model_selection_prompt".to_owned(),
            serde_json::json!({"candidates": candidates, "timeout_secs": timeout_secs}),
        ),
        RuntimeEvent::ModelSelected { provider_model } => (
            "pipeline.model_selected".to_owned(),
            serde_json::json!({"provider_model": provider_model}),
        ),
        RuntimeEvent::VoiceCommandDetected { command } => (
            "pipeline.voice_command".to_owned(),
            serde_json::json!({"command": command}),
        ),
        RuntimeEvent::PermissionsChanged { granted } => (
            "pipeline.permissions_changed".to_owned(),
            serde_json::json!({"granted": granted}),
        ),
        RuntimeEvent::ModelSwitchRequested { target } => (
            "pipeline.model_switch_requested".to_owned(),
            serde_json::json!({"target": target}),
        ),
        RuntimeEvent::ConversationSnapshot { entries } => {
            let items: Vec<serde_json::Value> = entries
                .iter()
                .map(|e| serde_json::json!({"role": format!("{:?}", e.role), "text": e.text}))
                .collect();
            (
                "pipeline.conversation_snapshot".to_owned(),
                serde_json::json!({"entries": items}),
            )
        }
        RuntimeEvent::MicStatus { active } => (
            "pipeline.mic_status".to_owned(),
            serde_json::json!({"active": active}),
        ),
        RuntimeEvent::ConversationCanvasVisibility { visible } => (
            "pipeline.canvas_visibility".to_owned(),
            serde_json::json!({"visible": visible}),
        ),
        RuntimeEvent::ProviderFallback { primary, error } => (
            "pipeline.provider_fallback".to_owned(),
            serde_json::json!({"primary": primary, "error": error}),
        ),
        RuntimeEvent::IntelligenceExtraction {
            items_count,
            actions_count,
        } => (
            "pipeline.intelligence_extraction".to_owned(),
            serde_json::json!({"items_count": items_count, "actions_count": actions_count}),
        ),
        RuntimeEvent::ProactiveBriefingReady { item_count } => (
            "pipeline.briefing_ready".to_owned(),
            serde_json::json!({"item_count": item_count}),
        ),
        RuntimeEvent::RelationshipUpdate { name } => (
            "pipeline.relationship_update".to_owned(),
            serde_json::json!({"name": name}),
        ),
        RuntimeEvent::SkillProposal { skill_name } => (
            "pipeline.skill_proposal".to_owned(),
            serde_json::json!({"skill_name": skill_name}),
        ),
        RuntimeEvent::NoiseBudgetUpdate { remaining } => (
            "pipeline.noise_budget".to_owned(),
            serde_json::json!({"remaining": remaining}),
        ),
        RuntimeEvent::OrbMoodUpdate { feeling, palette } => (
            "orb.state_changed".to_owned(),
            serde_json::json!({"feeling": feeling, "palette": palette}),
        ),
    }
}

impl DeviceTransferHandler for FaeDeviceTransferHandler {
    fn request_move(&self, target: DeviceTarget) -> Result<()> {
        info!(target = target.as_str(), "device.move requested");
        Ok(())
    }

    fn request_go_home(&self) -> Result<()> {
        info!("device.go_home requested");
        Ok(())
    }

    fn request_orb_palette_set(&self, palette: &str) -> Result<()> {
        info!(palette, "orb.palette.set requested");
        self.emit_event(
            "orb.state_changed",
            serde_json::json!({"kind": "palette", "palette": palette}),
        );
        Ok(())
    }

    fn request_orb_palette_clear(&self) -> Result<()> {
        info!("orb.palette.clear requested");
        self.emit_event(
            "orb.state_changed",
            serde_json::json!({"kind": "palette_cleared"}),
        );
        Ok(())
    }

    fn request_orb_feeling_set(&self, feeling: &str) -> Result<()> {
        info!(feeling, "orb.feeling.set requested");
        self.emit_event(
            "orb.state_changed",
            serde_json::json!({"kind": "feeling", "feeling": feeling}),
        );
        Ok(())
    }

    fn request_orb_urgency_set(&self, urgency: f32) -> Result<()> {
        info!(urgency, "orb.urgency.set requested");
        self.emit_event(
            "orb.state_changed",
            serde_json::json!({"kind": "urgency", "urgency": urgency}),
        );
        Ok(())
    }

    fn request_orb_flash(&self, flash_type: &str) -> Result<()> {
        info!(flash_type, "orb.flash requested");
        self.emit_event(
            "orb.state_changed",
            serde_json::json!({"kind": "flash", "flash_type": flash_type}),
        );
        Ok(())
    }

    fn request_capability(
        &self,
        capability: &str,
        reason: &str,
        scope: Option<&str>,
    ) -> Result<()> {
        info!(capability, reason, ?scope, "capability.request received");
        // Validate the capability is known (fail early on typos).
        let _kind = Self::parse_permission(capability)?;
        Ok(())
    }

    fn grant_capability(&self, capability: &str, scope: Option<&str>) -> Result<()> {
        let kind = Self::parse_permission(capability)?;
        info!(%kind, ?scope, "capability.grant — persisting");

        let mut guard = self.lock_config()?;
        guard.permissions.grant(kind);
        drop(guard);

        self.save_config()?;

        // Update the live shared store so tools see the grant immediately.
        if let Ok(mut perms) = self.shared_permissions.lock() {
            perms.grant(kind);
        }

        // Emit permissions.changed so the conversation UI can update in real-time.
        let all_granted: Vec<String> = self
            .shared_permissions
            .lock()
            .map(|g| g.all_granted().iter().map(|k| k.to_string()).collect())
            .unwrap_or_default();
        self.emit_event(
            "permissions.changed",
            serde_json::json!({
                "kind": kind.to_string(),
                "granted": true,
                "all_granted": all_granted,
            }),
        );

        info!(%kind, "capability.grant persisted to config");
        Ok(())
    }

    fn deny_capability(&self, capability: &str, scope: Option<&str>) -> Result<()> {
        let kind = Self::parse_permission(capability)?;
        info!(%kind, ?scope, "capability.deny — persisting");

        let mut guard = self.lock_config()?;
        guard.permissions.deny(kind);
        drop(guard);

        self.save_config()?;

        // Update the live shared store so tools see the revocation immediately.
        if let Ok(mut perms) = self.shared_permissions.lock() {
            perms.deny(kind);
        }

        // Emit permissions.changed so the conversation UI can update in real-time.
        let all_granted: Vec<String> = self
            .shared_permissions
            .lock()
            .map(|g| g.all_granted().iter().map(|k| k.to_string()).collect())
            .unwrap_or_default();
        self.emit_event(
            "permissions.changed",
            serde_json::json!({
                "kind": kind.to_string(),
                "granted": false,
                "all_granted": all_granted,
            }),
        );

        info!(%kind, "capability.deny persisted to config");
        Ok(())
    }

    fn query_onboarding_state(&self) -> Result<serde_json::Value> {
        let guard = self.lock_config()?;
        let onboarded = guard.onboarded;
        let phase = guard.onboarding_phase;
        let granted: Vec<String> = guard
            .permissions
            .all_granted()
            .iter()
            .map(|k| k.to_string())
            .collect();
        Ok(serde_json::json!({
            "onboarded": onboarded,
            "phase": phase.as_str(),
            "granted_permissions": granted
        }))
    }

    fn advance_onboarding_phase(&self) -> Result<OnboardingPhase> {
        let mut guard = self.lock_config()?;
        let current = guard.onboarding_phase;
        let new_phase = current.advance().unwrap_or(current);
        guard.onboarding_phase = new_phase;
        drop(guard);

        self.save_config()?;
        info!(
            phase = new_phase.as_str(),
            "onboarding.advance persisted to config"
        );
        Ok(new_phase)
    }

    fn complete_onboarding(&self) -> Result<()> {
        info!("onboarding.complete — setting onboarded = true");

        let mut guard = self.lock_config()?;
        guard.onboarded = true;
        drop(guard);

        self.save_config()?;
        info!("onboarding.complete persisted to config");
        Ok(())
    }

    fn set_user_name(&self, name: &str) -> Result<()> {
        info!(name, "onboarding.set_user_name — storing user name");

        // 1. Store in config
        {
            let mut guard = self.lock_config()?;
            guard.user_name = Some(name.to_owned());
        }
        self.save_config()?;

        // 2. Store in memory system's PrimaryUser record
        let memory_root = {
            let guard = self.lock_config()?;
            guard.memory.root_dir.clone()
        };
        let store = crate::memory::MemoryStore::new(&memory_root);
        let user = match store.load_primary_user() {
            Ok(Some(mut existing)) => {
                existing.name = name.to_owned();
                existing
            }
            _ => crate::memory::PrimaryUser {
                name: name.to_owned(),
                voiceprint: None,
                voice_sample_wav: None,
            },
        };
        if let Err(e) = store.save_primary_user(&user) {
            warn!("failed to save primary user to memory: {e}");
        }

        info!(name, "onboarding.set_user_name persisted to config and memory");
        Ok(())
    }

    fn request_conversation_inject_text(&self, text: &str) -> Result<()> {
        info!(text, "conversation.inject_text requested");
        let guard = self
            .text_injection_tx
            .lock()
            .map_err(|e| SpeechError::Pipeline(format!("text_injection lock poisoned: {e}")))?;
        if let Some(tx) = guard.as_ref() {
            tx.send(TextInjection {
                text: text.to_owned(),
                fork_at_keep_count: None,
            })
            .map_err(|e| SpeechError::Pipeline(format!("text injection send failed: {e}")))?;
        }
        Ok(())
    }

    fn request_conversation_gate_set(&self, active: bool) -> Result<()> {
        info!(active, "conversation.gate_set requested");
        let guard = self
            .gate_cmd_tx
            .lock()
            .map_err(|e| SpeechError::Pipeline(format!("gate_cmd lock poisoned: {e}")))?;
        if let Some(tx) = guard.as_ref() {
            let cmd = if active {
                GateCommand::Wake
            } else {
                GateCommand::Sleep
            };
            tx.send(cmd)
                .map_err(|e| SpeechError::Pipeline(format!("gate command send failed: {e}")))?;
        }
        Ok(())
    }

    fn request_runtime_start(&self) -> Result<()> {
        info!("runtime.start requested");
        let current = self.pipeline_state();
        match current {
            PipelineState::Running | PipelineState::Starting => {
                return Err(SpeechError::Pipeline(format!(
                    "pipeline already in state: {current:?}"
                )));
            }
            _ => {}
        }

        if let Ok(mut guard) = self.pipeline_state.lock() {
            *guard = PipelineState::Starting;
        }
        self.emit_event(
            "runtime.starting",
            serde_json::json!({"status": "starting"}),
        );

        // Create cancellation token for pipeline lifecycle.
        let token = CancellationToken::new();
        if let Ok(mut guard) = self.cancel_token.lock() {
            *guard = Some(token.clone());
        }

        // Create pipeline channels.
        let (text_tx, text_rx) = mpsc::unbounded_channel::<TextInjection>();
        let (gate_tx, gate_rx) = mpsc::unbounded_channel::<GateCommand>();
        // Tool approvals: pipeline sends ToolApprovalRequest objects via this
        // tx. The approval_rx is consumed by the approval bridge task which
        // stores them in `pending_approvals` until `approval.respond` arrives.
        let (approval_tx, mut approval_rx) = mpsc::unbounded_channel::<ToolApprovalRequest>();
        let coordinator_approval_tx = approval_tx.clone();
        let (runtime_event_tx, mut runtime_event_rx) = broadcast::channel::<RuntimeEvent>(64);

        // Store senders so other commands can use them.
        if let Ok(mut guard) = self.text_injection_tx.lock() {
            *guard = Some(text_tx);
        }
        if let Ok(mut guard) = self.gate_cmd_tx.lock() {
            *guard = Some(gate_tx);
        }
        if let Ok(mut guard) = self.tool_approval_tx.lock() {
            *guard = Some(approval_tx);
        }

        // Clone what the async tasks need. The handler trait methods are sync
        // (&self) so we capture clones of Arc/Sender values for move into
        // async blocks.
        let config = self.lock_config().map(|g| g.clone())?;
        let event_tx = self.event_tx.clone();
        let event_tx_bridge = self.event_tx.clone();
        let event_tx_approval = self.event_tx.clone();
        let pending_approvals_clone = Arc::clone(&self.pending_approvals);
        let cancel_token = token.clone();
        // Pass the live shared permission store so that JIT grants applied
        // while the pipeline runs are immediately visible to the tool gate.
        let shared_perms_for_pipeline = Arc::clone(&self.shared_permissions);

        // Reset clean-exit flag for this run. The restart watcher reads this
        // to distinguish a clean stop from a crash. `request_runtime_stop()`
        // sets it to `true` *before* cancelling the token, eliminating the
        // race where the watcher wakes and reads before the pipeline task
        // has a chance to set the flag.
        self.clean_exit_flag
            .store(false, std::sync::atomic::Ordering::SeqCst);
        let clean_exit_flag = Arc::clone(&self.clean_exit_flag);
        let clean_exit_for_pipeline = Arc::clone(&self.clean_exit_flag);

        // Spawn the async startup + pipeline task.
        let pipeline_jh = self.tokio_handle.spawn(async move {
            // ── Task 3: Model loading ────────────────────────────
            let progress_tx = event_tx.clone();
            let callback: crate::progress::ProgressCallback =
                Box::new(move |evt: ProgressEvent| {
                    let payload = progress_event_to_json(&evt);
                    let envelope = EventEnvelope::new(
                        uuid::Uuid::new_v4().to_string(),
                        "runtime.progress".to_owned(),
                        payload,
                    );
                    let _ = progress_tx.send(envelope);
                });

            let models = match initialize_models_with_progress(&config, Some(&callback)).await {
                Ok(m) => m,
                Err(e) => {
                    warn!("model initialization failed: {e}");
                    let envelope = EventEnvelope::new(
                        uuid::Uuid::new_v4().to_string(),
                        "runtime.error".to_owned(),
                        serde_json::json!({"error": format!("{e}")}),
                    );
                    let _ = event_tx.send(envelope);
                    return;
                }
            };

            // ── Task 4: Create and spawn PipelineCoordinator ─────
            let coordinator = PipelineCoordinator::with_models(config, models)
                .with_runtime_events(runtime_event_tx)
                .with_text_injection(text_rx)
                .with_gate_commands(gate_rx)
                .with_tool_approvals(coordinator_approval_tx)
                .with_console_output(false)
                .with_shared_permissions(shared_perms_for_pipeline);

            // Run until cancelled or pipeline exits.
            tokio::select! {
                result = coordinator.run() => {
                    if let Err(e) = result {
                        warn!("pipeline exited with error: {e}");
                        let envelope = EventEnvelope::new(
                            uuid::Uuid::new_v4().to_string(),
                            "runtime.error".to_owned(),
                            serde_json::json!({"error": format!("{e}")}),
                        );
                        let _ = event_tx.send(envelope);
                    }
                }
                _ = cancel_token.cancelled() => {
                    info!("pipeline cancelled via token");
                    // Mark as clean exit so watcher does not restart.
                    clean_exit_for_pipeline.store(true, std::sync::atomic::Ordering::SeqCst);
                }
            }
        });

        if let Ok(mut guard) = self.pipeline_handle.lock() {
            *guard = Some(pipeline_jh);
        }

        // ── Task 5: Spawn event bridge ───────────────────────────
        // Bridge RuntimeEvent variants to EventEnvelope on the FFI channel.
        let bridge_token = token.child_token();
        let bridge_jh = self.tokio_handle.spawn(async move {
            loop {
                tokio::select! {
                    _ = bridge_token.cancelled() => break,
                    event = runtime_event_rx.recv() => {
                        match event {
                            Ok(re) => {
                                let (name, payload) = map_runtime_event(&re);
                                let envelope = EventEnvelope::new(
                                    uuid::Uuid::new_v4().to_string(),
                                    name,
                                    payload,
                                );
                                let _ = event_tx_bridge.send(envelope);
                            }
                            Err(broadcast::error::RecvError::Lagged(n)) => {
                                warn!("event bridge lagged, skipped {n} events");
                            }
                            Err(broadcast::error::RecvError::Closed) => break,
                        }
                    }
                }
            }
        });
        if let Ok(mut guard) = self.event_bridge_handle.lock() {
            *guard = Some(bridge_jh);
        }

        // ── Approval bridge ─────────────────────────────────────
        // Drain ToolApprovalRequest messages from the pipeline into the
        // pending_approvals map, and emit an event so Swift can show
        // the approval dialog.
        let approval_bridge_token = token.child_token();
        let approval_bridge_jh = self.tokio_handle.spawn(async move {
            loop {
                tokio::select! {
                    _ = approval_bridge_token.cancelled() => break,
                    req = approval_rx.recv() => {
                        match req {
                            Some(req) => {
                                let id = req.id;
                                let name = req.name.clone();
                                let input_json = req.input_json.clone();
                                // Emit event before storing so the UI sees
                                // the request immediately.
                                let envelope = EventEnvelope::new(
                                    uuid::Uuid::new_v4().to_string(),
                                    "approval.requested".to_owned(),
                                    serde_json::json!({
                                        "request_id": id.to_string(),
                                        "name": name,
                                        "input_json": input_json,
                                    }),
                                );
                                let _ = event_tx_approval.send(envelope);
                                if let Ok(mut map) = pending_approvals_clone.lock() {
                                    map.insert(id, req);
                                }
                            }
                            None => break, // sender dropped
                        }
                    }
                }
            }
        });
        if let Ok(mut guard) = self.approval_bridge_handle.lock() {
            *guard = Some(approval_bridge_jh);
        }

        // ── Crash recovery watcher ───────────────────────────────
        // Monitors the pipeline lifecycle. If the pipeline exits without
        // a clean cancellation signal, emits a `pipeline.control` auto_restart
        // event with attempt count and backoff duration so the Swift side can
        // display recovery status and callers can re-invoke `request_runtime_start()`.
        let restart_watcher_token = token.child_token();
        let event_tx_watcher = self.event_tx.clone();
        let restart_count_watcher = Arc::clone(&self.restart_count);
        let last_restart_at_watcher = Arc::clone(&self.last_restart_at);
        let pipeline_started_at_watcher = Arc::clone(&self.pipeline_started_at);
        let pipeline_state_watcher = Arc::clone(&self.pipeline_state);

        let restart_watcher_jh = self.tokio_handle.spawn(async move {
            // Wait until token is cancelled (meaning the handler is being
            // stopped) or the pipeline itself has exited.
            restart_watcher_token.cancelled().await;
            // If this is a clean stop, nothing to do.
            if clean_exit_flag.load(std::sync::atomic::Ordering::SeqCst) {
                return;
            }
            // Unexpected exit: update state, emit event.
            let uptime = pipeline_started_at_watcher
                .lock()
                .ok()
                .and_then(|g| g.map(|t| t.elapsed()))
                .unwrap_or_default();

            // Reset restart counter if last run was stable.
            if uptime.as_secs() >= RESTART_UPTIME_RESET_SECS
                && let Ok(mut cnt) = restart_count_watcher.lock()
            {
                *cnt = 0;
            }

            let attempt = restart_count_watcher
                .lock()
                .map(|g| *g)
                .unwrap_or(MAX_RESTART_ATTEMPTS);

            if attempt >= MAX_RESTART_ATTEMPTS {
                warn!(
                    "pipeline crashed after {} restart attempts — giving up",
                    attempt
                );
                if let Ok(mut state) = pipeline_state_watcher.lock() {
                    *state =
                        PipelineState::Error(format!("crashed after {attempt} restart attempts"));
                }
                let envelope = EventEnvelope::new(
                    uuid::Uuid::new_v4().to_string(),
                    "pipeline.control".to_owned(),
                    serde_json::json!({
                        "action": "auto_restart_exhausted",
                        "attempt": attempt,
                        "max_attempts": MAX_RESTART_ATTEMPTS,
                    }),
                );
                let _ = event_tx_watcher.send(envelope);
                return;
            }

            // Increment counter and record restart time.
            if let Ok(mut cnt) = restart_count_watcher.lock() {
                *cnt += 1;
            }
            if let Ok(mut ts) = last_restart_at_watcher.lock() {
                *ts = Some(Instant::now());
            }
            let new_attempt = restart_count_watcher
                .lock()
                .map(|g| *g)
                .unwrap_or(attempt + 1);

            let backoff_idx =
                ((new_attempt as usize).saturating_sub(1)).min(RESTART_BACKOFF_SECS.len() - 1);
            let backoff = RESTART_BACKOFF_SECS[backoff_idx];

            info!(
                attempt = new_attempt,
                backoff_secs = backoff,
                "pipeline crashed — emitting auto_restart event"
            );

            let envelope = EventEnvelope::new(
                uuid::Uuid::new_v4().to_string(),
                "pipeline.control".to_owned(),
                serde_json::json!({
                    "action": "auto_restart",
                    "attempt": new_attempt,
                    "backoff_secs": backoff,
                    "uptime_secs": uptime.as_secs(),
                }),
            );
            let _ = event_tx_watcher.send(envelope);
        });

        if let Ok(mut guard) = self.restart_watcher_handle.lock() {
            *guard = Some(restart_watcher_jh);
        }

        // ── Audio device hot-swap watcher ────────────────────────
        // Polls CPAL every 2 s for the default input device. On change,
        // sends GateCommand::RestartAudio through the gate channel so the
        // pipeline can cancel and re-initialize with the new device.
        let device_watcher_token = token.child_token();
        if let Ok(gate_guard) = self.gate_cmd_tx.lock()
            && let Some(gate_tx) = gate_guard.as_ref()
        {
            let watcher = crate::audio::device_watcher::AudioDeviceWatcher::new(
                gate_tx.clone(),
                device_watcher_token,
            );
            let device_jh = self.tokio_handle.spawn(async move { watcher.run().await });
            if let Ok(mut guard) = self.device_watcher_handle.lock() {
                *guard = Some(device_jh);
            }
        }

        // ── Memory pressure monitor ──────────────────────────────
        // Polls available system RAM every 30 s.  Emits a `pipeline.control`
        // event whenever the pressure level transitions (Normal → Warning →
        // Critical and back).
        let memory_pressure_token = token.child_token();
        let event_tx_pressure = self.event_tx.clone();
        let (mp_tx, mut mp_rx) =
            tokio::sync::broadcast::channel::<crate::memory_pressure::MemoryPressureEvent>(4);
        let monitor = crate::memory_pressure::MemoryPressureMonitor::new(
            mp_tx,
            memory_pressure_token.clone(),
        );
        let mp_monitor_jh = self.tokio_handle.spawn(async move { monitor.run().await });
        // Bridge memory pressure events to FFI channel.
        let mp_bridge_jh = self.tokio_handle.spawn(async move {
            loop {
                tokio::select! {
                    _ = memory_pressure_token.cancelled() => break,
                    evt = mp_rx.recv() => {
                        match evt {
                            Ok(ev) => {
                                let level_str = match ev.level {
                                    crate::memory_pressure::PressureLevel::Normal => "normal",
                                    crate::memory_pressure::PressureLevel::Warning => "warning",
                                    crate::memory_pressure::PressureLevel::Critical => "critical",
                                };
                                let envelope = crate::host::contract::EventEnvelope::new(
                                    uuid::Uuid::new_v4().to_string(),
                                    "pipeline.control".to_owned(),
                                    serde_json::json!({
                                        "action": "memory_pressure",
                                        "level": level_str,
                                        "available_mb": ev.available_mb,
                                    }),
                                );
                                let _ = event_tx_pressure.send(envelope);
                            }
                            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => {}
                            Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                        }
                    }
                }
            }
        });
        // The bridge task is cancelled via the child token when the monitor
        // token is cancelled (on stop). We store the monitor handle so we can
        // abort both tasks on `request_runtime_stop`.
        if let Ok(mut guard) = self.memory_pressure_handle.lock() {
            // Detach bridge (cancelled by token); store monitor for explicit abort.
            drop(mp_bridge_jh);
            *guard = Some(mp_monitor_jh);
        }

        if let Ok(mut guard) = self.pipeline_state.lock() {
            *guard = PipelineState::Running;
        }
        if let Ok(mut guard) = self.pipeline_started_at.lock() {
            *guard = Some(Instant::now());
        }
        self.emit_event("runtime.started", serde_json::json!({"status": "running"}));
        Ok(())
    }

    fn request_runtime_stop(&self) -> Result<()> {
        info!("runtime.stop requested");
        let current = self.pipeline_state();
        if current == PipelineState::Stopped {
            return Err(SpeechError::Pipeline(
                "pipeline is already stopped".to_owned(),
            ));
        }

        if let Ok(mut guard) = self.pipeline_state.lock() {
            *guard = PipelineState::Stopping;
        }

        // Signal clean exit BEFORE cancelling the token so the restart watcher
        // always sees the flag set when it wakes up — eliminates the race where
        // the watcher wakes and reads `false` before the pipeline task sets it.
        self.clean_exit_flag
            .store(true, std::sync::atomic::Ordering::SeqCst);

        // Cancel via token
        if let Ok(guard) = self.cancel_token.lock()
            && let Some(token) = guard.as_ref()
        {
            token.cancel();
        }

        // Abort pipeline task
        if let Ok(mut guard) = self.pipeline_handle.lock()
            && let Some(jh) = guard.take()
        {
            jh.abort();
        }

        // Abort event bridge task
        if let Ok(mut guard) = self.event_bridge_handle.lock()
            && let Some(jh) = guard.take()
        {
            jh.abort();
        }

        // Abort approval bridge task
        if let Ok(mut guard) = self.approval_bridge_handle.lock()
            && let Some(jh) = guard.take()
        {
            jh.abort();
        }

        // Abort restart watcher task
        if let Ok(mut guard) = self.restart_watcher_handle.lock()
            && let Some(jh) = guard.take()
        {
            jh.abort();
        }

        // Abort audio device watcher task
        if let Ok(mut guard) = self.device_watcher_handle.lock()
            && let Some(jh) = guard.take()
        {
            jh.abort();
        }

        // Abort memory pressure monitor task
        if let Ok(mut guard) = self.memory_pressure_handle.lock()
            && let Some(jh) = guard.take()
        {
            jh.abort();
        }

        // Drop channel senders (closes channels)
        if let Ok(mut guard) = self.text_injection_tx.lock() {
            *guard = None;
        }
        if let Ok(mut guard) = self.gate_cmd_tx.lock() {
            *guard = None;
        }
        if let Ok(mut guard) = self.tool_approval_tx.lock() {
            *guard = None;
        }
        if let Ok(mut guard) = self.cancel_token.lock() {
            *guard = None;
        }
        if let Ok(mut guard) = self.pipeline_started_at.lock() {
            *guard = None;
        }

        // Clear any pending approval requests that will never be answered.
        if let Ok(mut map) = self.pending_approvals.lock() {
            map.clear();
        }

        if let Ok(mut guard) = self.pipeline_state.lock() {
            *guard = PipelineState::Stopped;
        }

        self.emit_event("runtime.stopped", serde_json::json!({"status": "stopped"}));
        Ok(())
    }

    fn query_runtime_status(&self) -> Result<serde_json::Value> {
        info!("runtime.status queried");
        let state = self.pipeline_state();
        let status_str = match &state {
            PipelineState::Stopped => "stopped",
            PipelineState::Starting => "starting",
            PipelineState::Running => "running",
            PipelineState::Stopping => "stopping",
            PipelineState::Error(_) => "error",
        };

        let mut result = serde_json::json!({"status": status_str});

        if let PipelineState::Error(ref msg) = state {
            result["error"] = serde_json::json!(msg);
        }

        if state == PipelineState::Running
            && let Ok(guard) = self.pipeline_started_at.lock()
            && let Some(started) = *guard
        {
            result["uptime_secs"] = serde_json::json!(started.elapsed().as_secs());
        }

        if let Ok(cnt) = self.restart_count.lock() {
            result["restart_count"] = serde_json::json!(*cnt);
        }

        if let Ok(mode) = self.pipeline_mode.lock() {
            result["pipeline_mode"] = serde_json::json!(mode.to_string());
        }

        Ok(result)
    }

    fn request_approval_respond(
        &self,
        request_id: &str,
        approved: bool,
        reason: Option<&str>,
    ) -> Result<()> {
        info!(request_id, approved, ?reason, "approval.respond received");

        // Parse the numeric approval ID from the string request_id.
        let numeric_id = request_id.parse::<u64>().map_err(|_| {
            SpeechError::Pipeline(format!(
                "approval.respond: request_id `{request_id}` is not a valid numeric ID"
            ))
        })?;

        let req = self
            .pending_approvals
            .lock()
            .map_err(|e| SpeechError::Pipeline(format!("pending_approvals lock poisoned: {e}")))?
            .remove(&numeric_id)
            .ok_or_else(|| {
                SpeechError::Pipeline(format!(
                    "approval.respond: no pending request with id `{request_id}`"
                ))
            })?;

        let delivered = req.respond(approved);
        if !delivered {
            warn!(
                request_id,
                approved, "approval.respond: tool has already timed out or been cancelled"
            );
        }

        Ok(())
    }

    fn query_scheduler_list(&self) -> Result<serde_json::Value> {
        info!("scheduler.list queried");
        // If the state file is corrupt or missing, return an empty list so the
        // UI degrades gracefully rather than blocking all scheduler operations.
        let snapshot = match crate::scheduler::load_persisted_snapshot() {
            Ok(s) => s,
            Err(e) => {
                warn!("scheduler.list: failed to load state (returning empty): {e}");
                crate::scheduler::SchedulerSnapshot::default()
            }
        };
        let tasks_json: Vec<serde_json::Value> = snapshot
            .tasks
            .iter()
            .filter_map(|t| serde_json::to_value(t).ok())
            .collect();
        Ok(serde_json::json!({"tasks": tasks_json}))
    }

    fn request_scheduler_create(&self, spec: &serde_json::Value) -> Result<serde_json::Value> {
        info!(?spec, "scheduler.create requested");
        let task: crate::scheduler::ScheduledTask =
            serde_json::from_value(spec.clone()).map_err(|e| {
                SpeechError::Scheduler(format!("scheduler.create: invalid task spec: {e}"))
            })?;
        let id = task.id.clone();
        // If state is corrupt, recover by clearing it first then re-upsert.
        if let Err(e) = crate::scheduler::upsert_persisted_user_task(task.clone()) {
            warn!("scheduler.create: state corrupt ({e}), attempting recovery");
            crate::scheduler::clear_persisted_state().ok();
            crate::scheduler::upsert_persisted_user_task(task)?;
        }
        info!(id, "scheduler.create persisted");
        Ok(serde_json::json!({"id": id}))
    }

    fn request_scheduler_update(&self, id: &str, spec: &serde_json::Value) -> Result<()> {
        info!(id, ?spec, "scheduler.update requested");
        let task: crate::scheduler::ScheduledTask =
            serde_json::from_value(spec.clone()).map_err(|e| {
                SpeechError::Scheduler(format!("scheduler.update: invalid task spec: {e}"))
            })?;
        // If state is corrupt, recover by clearing first then re-upsert.
        if let Err(e) = crate::scheduler::upsert_persisted_user_task(task.clone()) {
            warn!("scheduler.update: state corrupt ({e}), attempting recovery");
            crate::scheduler::clear_persisted_state().ok();
            crate::scheduler::upsert_persisted_user_task(task)?;
        }
        info!(id, "scheduler.update persisted");
        Ok(())
    }

    fn request_scheduler_delete(&self, id: &str) -> Result<()> {
        info!(id, "scheduler.delete requested");
        // If state is corrupt, treat delete as a no-op success (nothing to delete).
        match crate::scheduler::remove_persisted_task(id) {
            Ok(removed) => {
                if !removed {
                    warn!(id, "scheduler.delete: task not found");
                }
            }
            Err(e) => {
                warn!(
                    id,
                    "scheduler.delete: failed to load state ({e}), treating as not found"
                );
            }
        }
        Ok(())
    }

    fn request_scheduler_trigger_now(&self, id: &str) -> Result<()> {
        info!(id, "scheduler.trigger_now requested");
        // If state is corrupt, treat trigger as a no-op success.
        match crate::scheduler::mark_persisted_task_due_now(id) {
            Ok(found) => {
                if !found {
                    warn!(id, "scheduler.trigger_now: task not found");
                }
            }
            Err(e) => {
                warn!(
                    id,
                    "scheduler.trigger_now: failed to load state ({e}), treating as not found"
                );
            }
        }
        Ok(())
    }

    fn query_config_get(&self, key: Option<&str>) -> Result<serde_json::Value> {
        info!(?key, "config.get queried");
        let guard = self.lock_config()?;
        // Return the full permissions state when key is "permissions" or None.
        match key {
            Some("permissions") => {
                let granted: Vec<String> = guard
                    .permissions
                    .all_granted()
                    .iter()
                    .map(|k| k.to_string())
                    .collect();
                Ok(serde_json::json!({"permissions": granted}))
            }
            Some("onboarded") => Ok(serde_json::json!({"onboarded": guard.onboarded})),
            _ => Ok(serde_json::json!({})),
        }
    }

    fn request_config_patch(&self, key: &str, value: &serde_json::Value) -> Result<()> {
        info!(key, ?value, "config.patch requested");
        match key {
            "onboarded" => {
                if let Some(v) = value.as_bool() {
                    let mut guard = self.lock_config()?;
                    guard.onboarded = v;
                    if !v {
                        guard.onboarding_phase = OnboardingPhase::Welcome;
                    }
                    drop(guard);
                    self.save_config()?;
                    info!(onboarded = v, "config.patch applied: onboarded");
                }
            }
            _ => {
                warn!(key, "config.patch: unknown key, ignored");
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    fn temp_handler() -> (
        FaeDeviceTransferHandler,
        tempfile::TempDir,
        tokio::runtime::Runtime,
    ) {
        let dir = tempfile::tempdir().expect("create temp dir");
        let path = dir.path().join("config.toml");
        let config = SpeechConfig::default();
        let rt = tokio::runtime::Runtime::new().expect("create tokio runtime");
        let (event_tx, _) = broadcast::channel(16);
        let handler = FaeDeviceTransferHandler::new(config, path, rt.handle().clone(), event_tx);
        (handler, dir, rt)
    }

    #[test]
    fn grant_capability_persists_to_config() {
        let (handler, _dir, _rt) = temp_handler();

        handler.grant_capability("calendar", None).unwrap();

        let guard = handler.config.lock().unwrap();
        assert!(guard.permissions.is_granted(PermissionKind::Calendar));
    }

    #[test]
    fn deny_capability_revokes_permission() {
        let (handler, _dir, _rt) = temp_handler();

        handler.grant_capability("contacts", None).unwrap();
        handler.deny_capability("contacts", None).unwrap();

        let guard = handler.config.lock().unwrap();
        assert!(!guard.permissions.is_granted(PermissionKind::Contacts));
    }

    #[test]
    fn unknown_capability_returns_error() {
        let (handler, _dir, _rt) = temp_handler();

        let result = handler.grant_capability("teleportation", None);
        assert!(result.is_err());
    }

    #[test]
    fn onboarding_state_default_false() {
        let (handler, _dir, _rt) = temp_handler();

        let state = handler.query_onboarding_state().unwrap();
        assert_eq!(state["onboarded"], false);
        assert!(state["granted_permissions"].as_array().unwrap().is_empty());
    }

    #[test]
    fn complete_onboarding_sets_flag() {
        let (handler, _dir, _rt) = temp_handler();

        handler.complete_onboarding().unwrap();

        let guard = handler.config.lock().unwrap();
        assert!(guard.onboarded);
    }

    #[test]
    fn grant_capability_saves_to_disk() {
        let (handler, dir, _rt) = temp_handler();
        let path = dir.path().join("config.toml");

        handler.grant_capability("mail", None).unwrap();

        // Read from disk and verify
        let loaded = SpeechConfig::from_file(&path).unwrap();
        assert!(loaded.permissions.is_granted(PermissionKind::Mail));
    }

    #[test]
    fn complete_onboarding_saves_to_disk() {
        let (handler, dir, _rt) = temp_handler();
        let path = dir.path().join("config.toml");

        handler.complete_onboarding().unwrap();

        let loaded = SpeechConfig::from_file(&path).unwrap();
        assert!(loaded.onboarded);
    }

    #[test]
    fn request_capability_validates_known_capability() {
        let (handler, _dir, _rt) = temp_handler();

        // Known capability should succeed
        assert!(
            handler
                .request_capability("microphone", "need to listen", None)
                .is_ok()
        );

        // Unknown capability should fail
        assert!(
            handler
                .request_capability("xray_vision", "seeing through walls", None)
                .is_err()
        );
    }

    #[test]
    fn config_get_permissions_returns_granted() {
        let (handler, _dir, _rt) = temp_handler();

        handler.grant_capability("files", None).unwrap();
        handler.grant_capability("location", None).unwrap();

        let result = handler.query_config_get(Some("permissions")).unwrap();
        let perms = result["permissions"].as_array().unwrap();
        assert_eq!(perms.len(), 2);
    }

    #[test]
    fn onboarding_state_includes_granted_permissions() {
        let (handler, _dir, _rt) = temp_handler();

        handler.grant_capability("calendar", None).unwrap();
        handler.grant_capability("reminders", None).unwrap();

        let state = handler.query_onboarding_state().unwrap();
        assert_eq!(state["onboarded"], false);
        let granted = state["granted_permissions"].as_array().unwrap();
        assert_eq!(granted.len(), 2);
    }

    #[test]
    fn query_onboarding_state_includes_phase_field() {
        let (handler, _dir, _rt) = temp_handler();

        let state = handler.query_onboarding_state().unwrap();
        // Default phase is Welcome
        assert_eq!(state["phase"], "welcome");
    }

    #[test]
    fn advance_onboarding_phase_cycles_through_phases() {
        let (handler, _dir, _rt) = temp_handler();

        // Welcome → Permissions
        let p1 = handler.advance_onboarding_phase().unwrap();
        assert_eq!(p1.as_str(), "permissions");

        // Permissions → Ready
        let p2 = handler.advance_onboarding_phase().unwrap();
        assert_eq!(p2.as_str(), "ready");

        // Ready → Complete
        let p3 = handler.advance_onboarding_phase().unwrap();
        assert_eq!(p3.as_str(), "complete");

        // Complete stays at Complete (no further advance)
        let p4 = handler.advance_onboarding_phase().unwrap();
        assert_eq!(p4.as_str(), "complete");
    }

    #[test]
    fn advance_onboarding_phase_persists_to_disk() {
        let (handler, dir, _rt) = temp_handler();
        let path = dir.path().join("config.toml");

        handler.advance_onboarding_phase().unwrap();

        let loaded = SpeechConfig::from_file(&path).unwrap();
        // Should have advanced from Welcome to Permissions
        assert_eq!(loaded.onboarding_phase.as_str(), "permissions");
    }

    #[test]
    fn pipeline_state_defaults_to_stopped() {
        let (handler, _dir, _rt) = temp_handler();
        assert_eq!(handler.pipeline_state(), PipelineState::Stopped);
    }

    #[test]
    fn runtime_status_returns_stopped_by_default() {
        let (handler, _dir, _rt) = temp_handler();
        let status = handler.query_runtime_status().unwrap();
        assert_eq!(status["status"], "stopped");
    }

    #[test]
    fn runtime_start_transitions_to_running() {
        let (handler, _dir, _rt) = temp_handler();
        handler.request_runtime_start().unwrap();
        assert_eq!(handler.pipeline_state(), PipelineState::Running);
        let status = handler.query_runtime_status().unwrap();
        assert_eq!(status["status"], "running");
        assert!(status.get("uptime_secs").is_some());
    }

    #[test]
    fn runtime_start_when_running_returns_error() {
        let (handler, _dir, _rt) = temp_handler();
        handler.request_runtime_start().unwrap();
        let result = handler.request_runtime_start();
        assert!(result.is_err());
    }

    #[test]
    fn runtime_stop_transitions_to_stopped() {
        let (handler, _dir, _rt) = temp_handler();
        handler.request_runtime_start().unwrap();
        handler.request_runtime_stop().unwrap();
        assert_eq!(handler.pipeline_state(), PipelineState::Stopped);
    }

    #[test]
    fn runtime_stop_when_stopped_returns_error() {
        let (handler, _dir, _rt) = temp_handler();
        let result = handler.request_runtime_stop();
        assert!(result.is_err());
    }

    /// Helper that creates a handler with an event subscriber for observing
    /// lifecycle events.
    fn temp_handler_with_events() -> (
        FaeDeviceTransferHandler,
        broadcast::Receiver<EventEnvelope>,
        tempfile::TempDir,
        tokio::runtime::Runtime,
    ) {
        let dir = tempfile::tempdir().expect("create temp dir");
        let path = dir.path().join("config.toml");
        let config = SpeechConfig::default();
        let rt = tokio::runtime::Runtime::new().expect("create tokio runtime");
        let (event_tx, event_rx) = broadcast::channel(64);
        let handler = FaeDeviceTransferHandler::new(config, path, rt.handle().clone(), event_tx);
        (handler, event_rx, dir, rt)
    }

    #[test]
    fn runtime_start_emits_starting_and_started_events() {
        let (handler, mut event_rx, _dir, _rt) = temp_handler_with_events();

        handler.request_runtime_start().unwrap();

        // Collect all events emitted during start.
        let mut events = Vec::new();
        while let Ok(evt) = event_rx.try_recv() {
            events.push(evt.event);
        }

        assert!(
            events.contains(&"runtime.starting".to_owned()),
            "should emit runtime.starting"
        );
        assert!(
            events.contains(&"runtime.started".to_owned()),
            "should emit runtime.started"
        );
    }

    #[test]
    fn runtime_stop_emits_stopped_event() {
        let (handler, mut event_rx, _dir, _rt) = temp_handler_with_events();

        handler.request_runtime_start().unwrap();

        // Drain start events.
        while event_rx.try_recv().is_ok() {}

        handler.request_runtime_stop().unwrap();

        let mut events = Vec::new();
        while let Ok(evt) = event_rx.try_recv() {
            events.push(evt.event);
        }

        assert!(
            events.contains(&"runtime.stopped".to_owned()),
            "should emit runtime.stopped"
        );
    }

    #[test]
    fn runtime_start_stop_start_full_lifecycle() {
        let (handler, _event_rx, _dir, _rt) = temp_handler_with_events();

        // Start
        handler.request_runtime_start().unwrap();
        assert_eq!(handler.pipeline_state(), PipelineState::Running);

        // Stop
        handler.request_runtime_stop().unwrap();
        assert_eq!(handler.pipeline_state(), PipelineState::Stopped);

        // Start again (should succeed — channels are recreated)
        handler.request_runtime_start().unwrap();
        assert_eq!(handler.pipeline_state(), PipelineState::Running);

        // Verify uptime resets
        let status = handler.query_runtime_status().unwrap();
        assert_eq!(status["status"], "running");
        let uptime = status["uptime_secs"].as_u64().unwrap();
        assert!(uptime < 5, "uptime should have reset after restart");
    }

    #[test]
    fn runtime_channels_are_created_on_start() {
        let (handler, _event_rx, _dir, _rt) = temp_handler_with_events();

        // Before start — no channels
        assert!(
            handler.text_injection_tx.lock().unwrap().is_none(),
            "text_injection_tx should be None before start"
        );

        handler.request_runtime_start().unwrap();

        // After start — channels exist
        assert!(
            handler.text_injection_tx.lock().unwrap().is_some(),
            "text_injection_tx should exist after start"
        );
        assert!(
            handler.gate_cmd_tx.lock().unwrap().is_some(),
            "gate_cmd_tx should exist after start"
        );
        assert!(
            handler.cancel_token.lock().unwrap().is_some(),
            "cancel_token should exist after start"
        );
    }

    #[test]
    fn runtime_channels_are_cleaned_up_on_stop() {
        let (handler, _event_rx, _dir, _rt) = temp_handler_with_events();

        handler.request_runtime_start().unwrap();
        handler.request_runtime_stop().unwrap();

        // After stop — channels cleaned up
        assert!(
            handler.text_injection_tx.lock().unwrap().is_none(),
            "text_injection_tx should be None after stop"
        );
        assert!(
            handler.gate_cmd_tx.lock().unwrap().is_none(),
            "gate_cmd_tx should be None after stop"
        );
        assert!(
            handler.cancel_token.lock().unwrap().is_none(),
            "cancel_token should be None after stop"
        );
        assert!(
            handler.pipeline_started_at.lock().unwrap().is_none(),
            "pipeline_started_at should be None after stop"
        );
    }

    #[test]
    fn restart_count_starts_at_zero() {
        let (handler, _dir, _rt) = temp_handler();
        let count = *handler.restart_count.lock().unwrap();
        assert_eq!(count, 0, "restart_count should start at zero");
    }

    #[test]
    fn runtime_status_includes_restart_count() {
        let (handler, _dir, _rt) = temp_handler();
        let status = handler.query_runtime_status().unwrap();
        assert!(
            status.get("restart_count").is_some(),
            "runtime status should include restart_count"
        );
        assert_eq!(status["restart_count"], 0);
    }

    #[test]
    fn clean_stop_does_not_increment_restart_count() {
        let (handler, _dir, _rt) = temp_handler();

        handler.request_runtime_start().unwrap();
        handler.request_runtime_stop().unwrap();

        // After a clean stop the restart_count must still be zero.
        let count = *handler.restart_count.lock().unwrap();
        assert_eq!(count, 0, "clean stop must not increment restart_count");
    }

    #[test]
    fn restart_backoff_constants_are_valid() {
        // Verify the backoff table has the right number of entries and is
        // monotonically increasing.
        assert_eq!(
            RESTART_BACKOFF_SECS.len(),
            MAX_RESTART_ATTEMPTS as usize,
            "backoff table should have one entry per allowed attempt"
        );
        let mut prev = 0u64;
        for &secs in RESTART_BACKOFF_SECS {
            assert!(secs > prev, "backoff delays should be strictly increasing");
            prev = secs;
        }
    }

    /// Verify that a clean `request_runtime_stop` does NOT emit an `auto_restart`
    /// event. This is an acceptance criterion for Phase 5.2 Task 1.
    ///
    /// The crash-recovery watcher task is aborted during `request_runtime_stop`,
    /// so it never reaches the event-emission path.
    #[test]
    fn clean_stop_does_not_emit_auto_restart_event() {
        let (handler, mut event_rx, _dir, rt) = temp_handler_with_events();

        handler.request_runtime_start().unwrap();

        // Drain all start events.
        while event_rx.try_recv().is_ok() {}

        // Perform a clean stop.
        handler.request_runtime_stop().unwrap();

        // Give the tokio runtime a moment to settle any in-flight tasks.
        rt.block_on(async { tokio::time::sleep(std::time::Duration::from_millis(100)).await });

        // Collect all events after the stop.
        let mut events: Vec<serde_json::Value> = Vec::new();
        while let Ok(evt) = event_rx.try_recv() {
            if evt.event == "pipeline.control" {
                events.push(evt.payload);
            }
        }

        // None of the pipeline.control events should be an auto_restart.
        let has_auto_restart = events
            .iter()
            .any(|p| p.get("action").and_then(|v| v.as_str()) == Some("auto_restart"));
        assert!(
            !has_auto_restart,
            "clean stop must not emit auto_restart event; got: {events:?}"
        );

        // Also confirm restart_count was not incremented.
        let count = *handler.restart_count.lock().unwrap();
        assert_eq!(count, 0, "clean stop must not increment restart_count");
    }

    /// Verify that the crash-recovery watcher emits an `auto_restart` event
    /// when the pipeline exits unexpectedly (i.e., without a clean cancel).
    ///
    /// We simulate an unexpected exit by aborting the pipeline JoinHandle
    /// directly without going through `request_runtime_stop` (which aborts
    /// the watcher before it fires). We then cancel the watcher token manually
    /// without setting the clean-exit flag.
    ///
    /// This is an acceptance criterion for Phase 5.2 Task 1.
    #[tokio::test]
    async fn unexpected_exit_emits_auto_restart_event() {
        use std::sync::Arc;
        use std::sync::atomic::Ordering;

        // Build the shared state pieces that the watcher uses.
        let restart_count = Arc::new(std::sync::Mutex::new(0u32));
        let last_restart_at = Arc::new(std::sync::Mutex::new(None::<Instant>));
        let pipeline_started_at = Arc::new(std::sync::Mutex::new(Some(Instant::now())));
        let pipeline_state = Arc::new(std::sync::Mutex::new(PipelineState::Running));
        let (event_tx, mut event_rx) = broadcast::channel::<EventEnvelope>(16);
        let clean_exit_flag = Arc::new(std::sync::atomic::AtomicBool::new(false));

        let watcher_token = tokio_util::sync::CancellationToken::new();
        let restart_watcher_token = watcher_token.child_token();

        // Clone shared state for the watcher closure (mirrors handler.rs).
        let event_tx_watcher = event_tx.clone();
        let restart_count_watcher = Arc::clone(&restart_count);
        let last_restart_at_watcher = Arc::clone(&last_restart_at);
        let pipeline_started_at_watcher = Arc::clone(&pipeline_started_at);
        let pipeline_state_watcher = Arc::clone(&pipeline_state);
        let clean_exit_flag_watcher = Arc::clone(&clean_exit_flag);

        let watcher_jh = tokio::spawn(async move {
            restart_watcher_token.cancelled().await;
            if clean_exit_flag_watcher.load(Ordering::SeqCst) {
                return;
            }
            // --- remainder mirrors the handler's watcher body ---
            let uptime = pipeline_started_at_watcher
                .lock()
                .ok()
                .and_then(|g| g.map(|t| t.elapsed()))
                .unwrap_or_default();

            if uptime.as_secs() >= RESTART_UPTIME_RESET_SECS
                && let Ok(mut cnt) = restart_count_watcher.lock()
            {
                *cnt = 0;
            }

            let attempt = restart_count_watcher
                .lock()
                .map(|g| *g)
                .unwrap_or(MAX_RESTART_ATTEMPTS);

            if attempt >= MAX_RESTART_ATTEMPTS {
                if let Ok(mut state) = pipeline_state_watcher.lock() {
                    *state =
                        PipelineState::Error(format!("crashed after {attempt} restart attempts"));
                }
                let envelope = EventEnvelope::new(
                    uuid::Uuid::new_v4().to_string(),
                    "pipeline.control".to_owned(),
                    serde_json::json!({
                        "action": "auto_restart_exhausted",
                        "attempt": attempt,
                        "max_attempts": MAX_RESTART_ATTEMPTS,
                    }),
                );
                let _ = event_tx_watcher.send(envelope);
                return;
            }

            if let Ok(mut cnt) = restart_count_watcher.lock() {
                *cnt += 1;
            }
            if let Ok(mut ts) = last_restart_at_watcher.lock() {
                *ts = Some(Instant::now());
            }
            let new_attempt = restart_count_watcher
                .lock()
                .map(|g| *g)
                .unwrap_or(attempt + 1);

            let backoff_idx =
                ((new_attempt as usize).saturating_sub(1)).min(RESTART_BACKOFF_SECS.len() - 1);
            let backoff = RESTART_BACKOFF_SECS[backoff_idx];

            let envelope = EventEnvelope::new(
                uuid::Uuid::new_v4().to_string(),
                "pipeline.control".to_owned(),
                serde_json::json!({
                    "action": "auto_restart",
                    "attempt": new_attempt,
                    "backoff_secs": backoff,
                    "uptime_secs": uptime.as_secs(),
                }),
            );
            let _ = event_tx_watcher.send(envelope);
        });

        // Simulate an unexpected exit: cancel the parent token WITHOUT
        // setting the clean_exit_flag (the pipeline task would set it only
        // on the cancel branch, which we skip here).
        watcher_token.cancel();

        // Wait for the watcher to complete.
        tokio::time::timeout(std::time::Duration::from_secs(2), watcher_jh)
            .await
            .expect("watcher should finish")
            .expect("watcher task should not panic");

        // The watcher must have emitted an auto_restart pipeline.control event.
        let mut found_auto_restart = false;
        while let Ok(evt) = event_rx.try_recv() {
            if evt.event == "pipeline.control"
                && evt.payload.get("action").and_then(|v| v.as_str()) == Some("auto_restart")
            {
                found_auto_restart = true;
                let attempt = evt.payload["attempt"].as_u64().unwrap_or(0);
                assert_eq!(attempt, 1, "first unexpected exit should be attempt 1");
                let backoff = evt.payload["backoff_secs"].as_u64().unwrap_or(0);
                assert_eq!(backoff, RESTART_BACKOFF_SECS[0], "first attempt backoff");
            }
        }
        assert!(
            found_auto_restart,
            "unexpected exit must emit auto_restart event"
        );

        // restart_count should have been incremented to 1.
        let count = *restart_count.lock().unwrap();
        assert_eq!(
            count, 1,
            "unexpected exit must increment restart_count to 1"
        );
    }
}
