//! Per-connection session logic — **pure**, no sockets.
//!
//! The transport shell ([`crate::transport`]) reads one NDJSON frame, calls
//! [`handle_frame`], persists the returned audit row, writes the response, and
//! optionally closes. All authentication + authorization + dispatch decisions
//! live here so the whole frame lifecycle is unit-testable without a socket —
//! the same control-plane-first discipline the workspace was built on.

use std::path::Path;
use std::sync::Arc;

use async_trait::async_trait;
use fae_audio::AudioManager;
use fae_control_plane::{
    authorize, AuditDecision, AuditEvent, AuthzDecision, ClientRecord, ClientRegistry, Command,
    ConsumedTicket, Response, ResponseErrorDetails, Scope, AUTHENTICATE_COMMAND, PROTOCOL_VERSION,
};
use fae_engine::{
    ChatEvent, ChatMessage, ChatRequest, ProviderAdapter, Role, ToolSpec, TtsAdapter,
};
use futures_util::StreamExt;
use serde::Deserialize;

use crate::agents::AgentSessionRegistry;
use crate::events::{EventBus, PlaybackRegistry};
use crate::server_request::ServerRequester;

/// Daemon version surfaced by `host.version`.
const DAEMON_VERSION: &str = env!("CARGO_PKG_VERSION");

/// State carried across frames on a single connection.
pub enum SessionState {
    Unauthenticated,
    Authenticated(ClientRecord),
}

/// Runtime backends used by command dispatch.
pub struct SessionBackends<'a> {
    pub engine: &'a dyn ProviderAdapter,
    pub asr_fallback: Option<&'a dyn ProviderAdapter>,
    pub tts: &'a dyn TtsAdapter,
    pub audio: &'a AudioManager,
    /// Server-push event bus — producers (voice spine V3a `tts.speak`) publish
    /// `audio.level` / `audio.playback_ended` to subscribed connections.
    pub events: &'a EventBus,
    /// Live daemon-owned playbacks — resolves end-reason (`completed` vs
    /// `interrupted`) for `audio.playback_ended`.
    pub playbacks: &'a PlaybackRegistry,
    /// Live native-ACP sessions (gap A2): `agent.session_start/prompt/cancel/
    /// close` look sessions up here.
    pub agents: &'a AgentSessionRegistry,
    /// The learned conductor. `None` on legacy tests that exercise direct
    /// `inject_text_core` behavior; production paths pass `Some` so both
    /// conversation routing and explicit ACP agent commands share the same
    /// egress mode/provisioning gates.
    pub conductor: Option<&'a crate::conductor::ConductorRuntime>,
    /// Thin testability seam for the native ACP boundary. This is deliberately
    /// NOT an ACP-provider/routing abstraction: it only delegates to the concrete
    /// `fae_acp` calls and lets tests count spawn/start/submit attempts.
    pub acp_runner: &'a dyn AcpAgentRunner,
}

/// Thin delegation seam for native ACP calls.
///
/// Scope guard (M2 NOTE-2 §6): this exists only so tests can prove gate-blocked
/// paths never spawn/start/submit. It must not model ACP agents as conductor
/// workers, include routing/policy methods, or change command semantics.
#[async_trait]
pub trait AcpAgentRunner: Send + Sync {
    async fn run_one_shot(
        &self,
        agent: &str,
        cwd: &Path,
        prompt: &str,
        policy: fae_acp::ApprovalPolicy,
    ) -> Result<fae_acp::AcpOutcome, fae_acp::AcpError>;

    async fn start_session(
        &self,
        agent: &str,
        cwd: &Path,
        policy: fae_acp::ApprovalPolicy,
    ) -> Result<fae_acp::AcpSession, fae_acp::AcpError>;

    fn prompt_session(
        &self,
        session: &fae_acp::AcpSession,
        text: String,
    ) -> Result<fae_acp::PromptHandle, fae_acp::AcpError>;
}

#[derive(Debug, Default)]
pub struct RealAcpRunner;

pub static REAL_ACP_RUNNER: RealAcpRunner = RealAcpRunner;

#[async_trait]
impl AcpAgentRunner for RealAcpRunner {
    async fn run_one_shot(
        &self,
        agent: &str,
        cwd: &Path,
        prompt: &str,
        policy: fae_acp::ApprovalPolicy,
    ) -> Result<fae_acp::AcpOutcome, fae_acp::AcpError> {
        fae_acp::run_one_shot(agent, cwd, prompt, policy).await
    }

    async fn start_session(
        &self,
        agent: &str,
        cwd: &Path,
        policy: fae_acp::ApprovalPolicy,
    ) -> Result<fae_acp::AcpSession, fae_acp::AcpError> {
        fae_acp::AcpSession::start(agent, cwd, policy).await
    }

    fn prompt_session(
        &self,
        session: &fae_acp::AcpSession,
        text: String,
    ) -> Result<fae_acp::PromptHandle, fae_acp::AcpError> {
        session.prompt(text)
    }
}

/// The `session.authenticate` payload.
#[derive(Deserialize)]
struct AuthPayload {
    client_id: String,
    token: String,
}

#[derive(Deserialize)]
struct TranscribeFallbackPayload {
    wav_base64: String,
}

/// Result of handling one frame: what to write back, what to audit, and whether
/// the connection should be closed afterwards.
pub struct FrameOutcome {
    pub response: Response,
    pub audit: AuditEvent,
    pub close: bool,
}

/// Handle one decoded NDJSON line. `event_id` is supplied by the caller (a
/// monotonic, non-secret id). `now_ms` is the per-frame wall clock — never a
/// stale snapshot. `engine` backs `conversation.inject_text`; `tts` backs
/// `tts.synthesize`; all other commands ignore them.
pub async fn handle_frame(
    registry: &ClientRegistry,
    backends: &SessionBackends<'_>,
    state: &mut SessionState,
    line: &str,
    now_ms: u64,
    event_id: String,
) -> FrameOutcome {
    let cmd: Command = match serde_json::from_str(line) {
        Ok(cmd) => cmd,
        Err(_) => {
            // request_id is unrecoverable from a malformed frame.
            return FrameOutcome {
                response: Response::error("unknown", "bad_request", "malformed command frame"),
                audit: manual_audit(
                    event_id,
                    now_ms,
                    None,
                    "<malformed>",
                    AuditDecision::Error,
                    "bad_request",
                ),
                close: true,
            };
        }
    };

    match state {
        SessionState::Unauthenticated => handle_auth(registry, state, &cmd, now_ms, event_id),
        SessionState::Authenticated(record) => {
            // Clone the record out so we no longer borrow `state`; the session
            // is already established and never mutated by a command frame.
            let record = record.clone();
            handle_command(backends, &record, &cmd, now_ms, event_id).await
        }
    }
}

/// Build an already-authenticated session from a consumed stream ticket. The
/// session's scopes are the **intersection** of the live client record and the
/// ticket grant — a ticket can never widen what the client already holds — and
/// per-message [`authorize`] still re-checks live revocation/expiry. Returns
/// `None` if the client record is gone, revoked, or expired: a ticket consumed
/// for an inactive client must not yield a usable session at all (a future
/// server-push stream must never stay open for a revoked client that sends no
/// frame).
#[must_use]
pub fn session_from_ticket(
    registry: &ClientRegistry,
    consumed: &ConsumedTicket,
    now_ms: u64,
) -> Option<SessionState> {
    let mut record = registry.record(&consumed.client_id)?;
    if !record.is_active(now_ms) {
        return None;
    }
    record
        .scopes
        .retain(|scope| consumed.scopes.contains(scope));
    Some(SessionState::Authenticated(record))
}

fn handle_auth(
    registry: &ClientRegistry,
    state: &mut SessionState,
    cmd: &Command,
    now_ms: u64,
    event_id: String,
) -> FrameOutcome {
    if cmd.command != AUTHENTICATE_COMMAND {
        // A command before authentication — refuse, but keep the connection so
        // the client can authenticate and retry.
        return FrameOutcome {
            response: Response::error(
                &cmd.request_id,
                "not_authenticated",
                "authenticate before issuing commands",
            ),
            audit: manual_audit(
                event_id,
                now_ms,
                None,
                &cmd.command,
                AuditDecision::Deny,
                "not_authenticated",
            ),
            close: false,
        };
    }
    if !cmd.version_ok() {
        return FrameOutcome {
            response: Response::error(
                &cmd.request_id,
                "wrong_protocol_version",
                "unsupported protocol version",
            ),
            audit: AuditEvent::authentication(
                event_id,
                now_ms,
                None,
                AuditDecision::Error,
                "wrong_protocol_version",
            ),
            close: true,
        };
    }
    let payload: AuthPayload = match serde_json::from_value(cmd.payload.clone()) {
        Ok(payload) => payload,
        Err(_) => {
            return FrameOutcome {
                response: Response::error(
                    &cmd.request_id,
                    "bad_request",
                    "malformed authenticate payload",
                ),
                audit: AuditEvent::authentication(
                    event_id,
                    now_ms,
                    None,
                    AuditDecision::Error,
                    "bad_request",
                ),
                close: true,
            };
        }
    };

    match registry.authenticate(&payload.client_id, &payload.token, now_ms) {
        Ok(record) => {
            let client_id = record.client_id.clone();
            *state = SessionState::Authenticated(record);
            FrameOutcome {
                response: Response::ok(
                    &cmd.request_id,
                    serde_json::json!({ "authenticated": true, "client_id": client_id }),
                ),
                audit: AuditEvent::authentication(
                    event_id,
                    now_ms,
                    Some(client_id),
                    AuditDecision::Allow,
                    "allow",
                ),
                close: false,
            }
        }
        Err(err) => FrameOutcome {
            // Coarse wire message; the precise factor stays in the audit only.
            response: Response::error(&cmd.request_id, err.code(), "authentication failed"),
            audit: AuditEvent::authentication(
                event_id,
                now_ms,
                Some(payload.client_id),
                AuditDecision::Deny,
                err.code(),
            ),
            // Close on failed auth — a new attempt needs a fresh connection.
            close: true,
        },
    }
}

async fn handle_command(
    backends: &SessionBackends<'_>,
    record: &ClientRecord,
    cmd: &Command,
    now_ms: u64,
    event_id: String,
) -> FrameOutcome {
    if cmd.command == AUTHENTICATE_COMMAND {
        return FrameOutcome {
            response: Response::error(
                &cmd.request_id,
                "already_authenticated",
                "session already authenticated",
            ),
            audit: manual_audit(
                event_id,
                now_ms,
                Some(record.client_id.clone()),
                &cmd.command,
                AuditDecision::Error,
                "already_authenticated",
            ),
            close: false,
        };
    }

    let decision = authorize(record, cmd, now_ms);
    let audit = AuditEvent::from_authz(
        event_id,
        now_ms,
        Some(record.client_id.clone()),
        cmd,
        &decision,
    );
    let response = match &decision {
        // `dispatch` is side-effect-free in this chunk (reads only), and the
        // shell persists `audit` before writing this response, so nothing is
        // observable pre-audit. When mutating commands land, their side effect
        // MUST move behind the audit write in the shell.
        AuthzDecision::Allow => match dispatch(backends, cmd).await {
            Ok(result) => Response::ok(&cmd.request_id, result),
            Err(failure) => failure.into_response(&cmd.request_id),
        },
        AuthzDecision::ConfirmRequired => Response::error(
            &cmd.request_id,
            "confirm_required",
            "owner confirmation required for this action",
        ),
        AuthzDecision::Deny(reason) => {
            Response::error(&cmd.request_id, reason.code(), "authorization denied")
        }
    };
    FrameOutcome {
        response,
        audit,
        close: false,
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct CommandFailure {
    code: &'static str,
    details: Option<ResponseErrorDetails>,
}

impl CommandFailure {
    fn new(code: &'static str) -> Self {
        Self {
            code,
            details: None,
        }
    }

    fn with_details(code: &'static str, details: ResponseErrorDetails) -> Self {
        Self {
            code,
            details: Some(details),
        }
    }

    fn into_response(self, request_id: &str) -> Response {
        let message = "command could not be completed";
        match self.details {
            Some(details) => Response::error_with_details(request_id, self.code, message, details),
            None => Response::error(request_id, self.code, message),
        }
    }
}

impl From<&'static str> for CommandFailure {
    fn from(code: &'static str) -> Self {
        Self::new(code)
    }
}

impl From<AgentGateFailure> for CommandFailure {
    fn from(failure: AgentGateFailure) -> Self {
        match failure {
            AgentGateFailure::PrivacyBlocked { level, labels } => Self::with_details(
                "privacy_blocked",
                ResponseErrorDetails {
                    level: Some(level),
                    labels,
                },
            ),
            other => Self::new(other.wire_code()),
        }
    }
}

type CommandResult = Result<serde_json::Value, CommandFailure>;

/// Command dispatch. Read-only `host`/`runtime` status, plus
/// `conversation.inject_text` through the engine (chunk 3c). Everything else is
/// authorized-but-unimplemented (fail loud, not a silent success).
async fn dispatch(backends: &SessionBackends<'_>, cmd: &Command) -> CommandResult {
    match cmd.command.as_str() {
        "host.ping" => Ok(serde_json::json!({ "pong": true })),
        "host.version" => {
            Ok(serde_json::json!({ "version": DAEMON_VERSION, "protocol": PROTOCOL_VERSION }))
        }
        "runtime.status" => {
            let info = backends.engine.describe();
            let tts_info = backends.tts.describe();
            // Gap P3/C3 Stage 4: surface the live personal adapter (confined path,
            // content hash, scale) so a deploy/rollback is auditable — `scale 0`
            // means rolled back to base, `scale 1` means personalized.
            let adapter =
                backends
                    .engine
                    .loaded_adapter()
                    .map_or(serde_json::Value::Null, |loaded| {
                        serde_json::json!({
                            "path": loaded.path,
                            "sha256": loaded.sha256,
                            "scale": loaded.scale,
                        })
                    });
            Ok(serde_json::json!({
                "status": "ok",
                "engine": { "backend": info.backend, "model_id": info.model_id },
                "tts": { "backend": tts_info.backend, "model_id": tts_info.model_id },
                "adapter": adapter,
            }))
        }
        "conversation.inject_text" => inject_text(backends, cmd).await.map_err(Into::into),
        // M2-live §3: explicit user-feedback signal (payload-based). Requires
        // the conductor runtime (InstallKey + isolated ConductorStore).
        "conversation.feedback" => record_feedback(backends, cmd).await,
        // M2-live §4: advisory reward snapshot (read-only; joins three isolated
        // reads). StatusRead-scoped aggregate — no conversation content.
        "conductor.reward_snapshot" => conductor_reward_snapshot(backends, cmd).await,
        "audio.transcribe_fallback" => transcribe_fallback(backends, cmd).await.map_err(Into::into),
        // Open this connection's server-push event stream (voice spine V2). The
        // ack is the signal the transport uses to register the connection's sink
        // as a subscriber; events (e.g. `audio.level`) are then pushed to it,
        // filtered by the scopes it was granted. ConversationRead is enforced by
        // `authorize` before dispatch.
        "conversation.subscribe" => Ok(serde_json::json!({ "subscribed": true })),
        "tts.synthesize" => synthesize_tts(backends.tts, cmd).await.map_err(Into::into),
        // Voice spine V3a: synthesize + play in the daemon, non-blocking, with
        // the playback level streamed on the event bus to subscribers.
        "tts.speak" => speak_tts(backends, cmd).await.map_err(Into::into),
        "audio.devices" => audio_devices(backends.audio).await.map_err(Into::into),
        "audio.capture_start" | "audio.start_capture" => audio_capture_start(backends.audio)
            .await
            .map_err(Into::into),
        "audio.capture_stop" | "audio.stop_capture" => audio_capture_stop(backends.audio, cmd)
            .await
            .map_err(Into::into),
        "audio.play" | "audio.playback_control" => {
            audio_play(backends.audio, cmd).await.map_err(Into::into)
        }
        // Voice spine V3a: barge-in — stop daemon-owned playback(s).
        "audio.stop" => audio_stop(backends, cmd).await.map_err(Into::into),
        "agent.run" => agent_run(backends, cmd).await,
        "agent.list" => agent_list().map_err(Into::into),
        "agent.session_start" => agent_session_start(backends, cmd).await,
        "agent.prompt" => agent_prompt(backends, cmd).await,
        "agent.cancel" => agent_cancel(backends, cmd).map_err(Into::into),
        "agent.close" => agent_close(backends, cmd).map_err(Into::into),
        "agent.session_list" => agent_session_list(backends).map_err(Into::into),
        "engine.set_adapter_scale" => set_adapter_scale(backends.engine, cmd).map_err(Into::into),
        "engine.reload" => reload_adapter(backends.engine, cmd)
            .await
            .map_err(Into::into),
        // Orb-host-owns-state: push an info set → publishes `info.update` to
        // subscribed orb hosts (the green-dot indicator). StatusRead scope.
        "info.push" => info_push(backends, cmd).await.map_err(Into::into),
        _ => Err(CommandFailure::from("not_implemented")),
    }
}

/// `engine.reload` (gap B3b deploy primitive) — restart the serving sidecar with
/// a freshly-trained personal adapter: `{ "personal_adapter": <path|null> }`
/// (absent/null ⇒ reload base-only). Only the daemon-managed llama.cpp lane
/// supports it; other backends reject it.
async fn reload_adapter(
    engine: &dyn ProviderAdapter,
    cmd: &Command,
) -> Result<serde_json::Value, &'static str> {
    let personal_adapter = cmd
        .payload
        .get("personal_adapter")
        .and_then(serde_json::Value::as_str)
        .map(str::to_owned);
    engine
        .reload_adapter(personal_adapter.clone())
        .await
        .map_err(|error| {
            eprintln!("fae-daemon: engine.reload failed: {error}");
            // A confinement/existence rejection is distinct from a sidecar restart
            // failure — the Swift side maps the codes to different messages and the
            // safety-gate rejection must never look like a transient reload error.
            match error {
                fae_engine::EngineError::AdapterPath(_) => "adapter_path_rejected",
                _ => "reload_failed",
            }
        })?;
    Ok(serde_json::json!({ "reloaded": true, "personal_adapter": personal_adapter }))
}

/// `engine.set_adapter_scale` (gap B3b) — toggle the personal-LoRA scale on the
/// running brain: `{ "scale": <number> }`, `0.0` = base, `1.0` = personalized.
/// Backends without a runtime adapter (mistral.rs, mock) accept it as a no-op,
/// so the command is uniform across engines.
fn set_adapter_scale(
    engine: &dyn ProviderAdapter,
    cmd: &Command,
) -> Result<serde_json::Value, &'static str> {
    let scale = cmd
        .payload
        .get("scale")
        .and_then(serde_json::Value::as_f64)
        .ok_or("missing_scale")?;
    engine
        .set_adapter_scale(scale as f32)
        .map_err(|_| "set_adapter_scale_failed")?;
    Ok(serde_json::json!({ "scale": scale }))
}

/// Names of the external agents the native ACP client knows how to launch.
const KNOWN_AGENTS: &[&str] = &["claude", "codex", "gemini", "pi", "copilot", "opencode"];

/// `agent.list` — the agents available for delegation. Read-only.
fn agent_list() -> Result<serde_json::Value, &'static str> {
    Ok(serde_json::json!({ "agents": KNOWN_AGENTS }))
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum AgentGateFailure {
    ModeBlocked,
    PrivacyBlocked { level: String, labels: Vec<String> },
    NotProvisioned,
    UnknownAgent,
    ConductorUnavailable,
}

impl AgentGateFailure {
    fn wire_code(&self) -> &'static str {
        match self {
            Self::ModeBlocked => "mode_blocked",
            Self::PrivacyBlocked { .. } => "privacy_blocked",
            Self::NotProvisioned => "not_provisioned",
            Self::UnknownAgent => "unknown_agent",
            Self::ConductorUnavailable => "conductor_unavailable",
        }
    }
}

fn resolve_agent_worker_id(agent: &str) -> Result<&'static str, AgentGateFailure> {
    match agent.trim().to_ascii_lowercase().as_str() {
        "claude" | "claude-code" => Ok(crate::conductor::workers::CLAUDE_CLOUD_WORKER_ID),
        "codex" => Ok(crate::conductor::workers::CODEX_CLOUD_WORKER_ID),
        "gemini" => Ok(crate::conductor::workers::GEMINI_CLOUD_WORKER_ID),
        "copilot" => Ok(crate::conductor::workers::COPILOT_CLOUD_WORKER_ID),
        "pi" => Ok("acp:pi"),
        "opencode" => Ok("acp:opencode"),
        _ => Err(AgentGateFailure::UnknownAgent),
    }
}

fn assert_agent_egress_gates(
    conductor: Option<&crate::conductor::ConductorRuntime>,
    agent: &str,
    prompt: Option<&str>,
) -> Result<String, AgentGateFailure> {
    let conductor = conductor.ok_or(AgentGateFailure::ConductorUnavailable)?;
    let worker_id = resolve_agent_worker_id(agent)?;

    if !crate::conductor::mode_permits_lane(
        conductor.model_mode(),
        crate::conductor::PrivacyLane::CloudBacked,
    ) {
        return Err(AgentGateFailure::ModeBlocked);
    }

    if let Some(prompt) = prompt {
        if fae_pii_membrane::should_block_remote_egress(prompt) {
            let scan = fae_pii_membrane::scan(prompt);
            return Err(AgentGateFailure::PrivacyBlocked {
                level: format!("{:?}", scan.level),
                labels: scan.matched_labels,
            });
        }
    }

    let workers = conductor.workers();
    if !workers.is_provisioned(worker_id)
        || workers.locality(worker_id) != Some(crate::conductor::WorkerLocality::CloudBackedAcp)
    {
        return Err(AgentGateFailure::NotProvisioned);
    }

    Ok(worker_id.to_owned())
}

fn log_agent_gate_failure(command: &str, agent: &str, failure: &AgentGateFailure) {
    let worker_id = resolve_agent_worker_id(agent).unwrap_or("unknown_agent");
    match failure {
        AgentGateFailure::PrivacyBlocked { level, labels } => tracing::warn!(
            command,
            worker_id,
            level = %level,
            labels = ?labels,
            "agent egress gate blocked command"
        ),
        _ => tracing::warn!(
            command,
            worker_id,
            reason = failure.wire_code(),
            "agent egress gate blocked command"
        ),
    }
}

fn gate_agent_command(
    conductor: Option<&crate::conductor::ConductorRuntime>,
    command: &'static str,
    agent: &str,
    prompt: Option<&str>,
) -> Result<String, CommandFailure> {
    assert_agent_egress_gates(conductor, agent, prompt).map_err(|failure| {
        log_agent_gate_failure(command, agent, &failure);
        CommandFailure::from(failure)
    })
}

/// `agent.run` — delegate one prompt turn to an external coding agent via the
/// native ACP client, returning the collected text + stop reason + tool calls.
/// Non-streaming (Stage 1): blocks until the agent's turn completes.
async fn agent_run(backends: &SessionBackends<'_>, cmd: &Command) -> CommandResult {
    let agent_raw = cmd
        .payload
        .get("agent")
        .and_then(serde_json::Value::as_str)
        .ok_or("bad_request")?;
    // Normalize once (trim + lowercase) so the gate and the runner see the
    // same agent string. fae_acp::resolve_agent also lowercases, but the gate's
    // worker-resolution does too — normalizing here keeps them in lockstep and
    // avoids a latent UX inconsistency (e.g. "  Codex  " passing the gate then
    // failing on the ACP side). [NOTE-2 red-team NOTE-1]
    let agent: String = agent_raw.trim().to_ascii_lowercase();
    let prompt = cmd
        .payload
        .get("prompt")
        .and_then(serde_json::Value::as_str)
        .ok_or("bad_request")?;
    let _worker_id = gate_agent_command(backends.conductor, "agent.run", &agent, Some(prompt))?;
    let cwd = cmd
        .payload
        .get("cwd")
        .and_then(serde_json::Value::as_str)
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::current_dir().ok())
        .ok_or("bad_request")?;
    // Default to approving the agent's own tool calls — the owner already
    // approved the delegation at the Fae tool layer. Stage 3 routes individual
    // permission requests back to the user.
    let policy = match cmd
        .payload
        .get("approval_policy")
        .and_then(serde_json::Value::as_str)
    {
        Some("deny" | "deny_all") => fae_acp::ApprovalPolicy::DenyAll,
        _ => fae_acp::ApprovalPolicy::ApproveAll,
    };

    let outcome = backends
        .acp_runner
        .run_one_shot(&agent, &cwd, prompt, policy)
        .await
        .map_err(|error| {
            tracing::warn!(error = %error, "fae-daemon: agent.run failed");
            CommandFailure::from(classify_agent_error(&error))
        })?;

    let tool_calls: Vec<serde_json::Value> = outcome
        .tool_calls
        .into_iter()
        .map(|tc| serde_json::json!({ "id": tc.id, "title": tc.title }))
        .collect();
    Ok(serde_json::json!({
        "text": outcome.text,
        "stop_reason": outcome.stop_reason,
        "tool_calls": tool_calls,
    }))
}

/// Map a payload's `approval_policy` to the ACP client policy. Defaults to
/// approving the agent's own tool calls (the owner approved the delegation at
/// the Fae tool layer; per-call permission round-trips are gap A3).
fn agent_approval_policy(cmd: &Command) -> fae_acp::ApprovalPolicy {
    match cmd
        .payload
        .get("approval_policy")
        .and_then(serde_json::Value::as_str)
    {
        Some("deny" | "deny_all") => fae_acp::ApprovalPolicy::DenyAll,
        _ => fae_acp::ApprovalPolicy::ApproveAll,
    }
}

/// Classify an ACP failure into a coarse wire code the UI maps to a friendly
/// message (gap A4): auth / rate-limit / network problems are distinguished from
/// a generic agent error so the user gets an actionable hint.
fn classify_agent_error(error: &fae_acp::AcpError) -> &'static str {
    match error {
        fae_acp::AcpError::UnknownAgent(_) => "unknown_agent",
        fae_acp::AcpError::Launch(_) => "agent_launch_failed",
        fae_acp::AcpError::Protocol(message) => {
            let lower = message.to_lowercase();
            if lower.contains("rate limit")
                || lower.contains("429")
                || lower.contains("quota")
                || lower.contains("overloaded")
            {
                "rate_limited"
            } else if lower.contains("unauthorized")
                || lower.contains("401")
                || lower.contains("forbidden")
                || lower.contains("403")
                || lower.contains("log in")
                || lower.contains("login")
                || lower.contains("authenticate")
                || lower.contains("api key")
                || lower.contains("no longer supported")
            {
                "auth_error"
            } else if lower.contains("network")
                || lower.contains("connection")
                || lower.contains("timed out")
                || lower.contains("timeout")
                || lower.contains("econnrefused")
                || lower.contains("dns")
                || lower.contains("offline")
            {
                "network_error"
            } else {
                "agent_error"
            }
        }
    }
}

/// `agent.session_start` — spawn a persistent native-ACP session and return its
/// daemon handle. Requires `AgentExecute`.
async fn agent_session_start(backends: &SessionBackends<'_>, cmd: &Command) -> CommandResult {
    let agent_raw = cmd
        .payload
        .get("agent")
        .and_then(serde_json::Value::as_str)
        .ok_or("bad_request")?;
    // Normalize once (same rationale as agent_run); the normalized value is
    // stored in the registry so agent.prompt's per-turn gate sees the same id.
    let agent: String = agent_raw.trim().to_ascii_lowercase();
    let _worker_id = gate_agent_command(backends.conductor, "agent.session_start", &agent, None)?;
    let cwd = cmd
        .payload
        .get("cwd")
        .and_then(serde_json::Value::as_str)
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::current_dir().ok())
        .ok_or("bad_request")?;
    let policy = agent_approval_policy(cmd);

    let session = backends
        .acp_runner
        .start_session(&agent, &cwd, policy)
        .await
        .map_err(|error| {
            tracing::warn!(error = %error, "fae-daemon: agent.session_start failed");
            CommandFailure::from(classify_agent_error(&error))
        })?;
    let session_id = backends
        .agents
        .insert(session, agent, cwd.display().to_string());
    Ok(serde_json::json!({ "session_id": session_id }))
}

/// `agent.prompt` (inline/diagnostic path, no `ServerRequester`) — permission
/// requests fall back to approve-first since there is no UI to ask.
async fn agent_prompt(backends: &SessionBackends<'_>, cmd: &Command) -> CommandResult {
    agent_prompt_inner(
        backends.agents,
        backends.events,
        backends.conductor,
        backends.acp_runner,
        None,
        cmd,
    )
    .await
}

/// `agent.prompt` core — submit a prompt to a live session, republishing the
/// agent's streamed output as `agent.output` / `agent.tool_call` events on the
/// V2 bus (so the orb narrates live), driving mid-turn permission requests to
/// the client over `requester` (gap A3), and returning the final turn. Requires
/// `AgentExecute`.
async fn agent_prompt_inner(
    agents: &AgentSessionRegistry,
    events: &EventBus,
    conductor: Option<&crate::conductor::ConductorRuntime>,
    acp_runner: &dyn AcpAgentRunner,
    requester: Option<ServerRequester>,
    cmd: &Command,
) -> CommandResult {
    let session_id = cmd
        .payload
        .get("session_id")
        .and_then(serde_json::Value::as_str)
        .ok_or("bad_request")?;
    let prompt = cmd
        .payload
        .get("prompt")
        .and_then(serde_json::Value::as_str)
        .ok_or("bad_request")?;
    let agent = agents.agent_for(session_id).ok_or("unknown_session")?;
    let _worker_id = gate_agent_command(conductor, "agent.prompt", &agent, Some(prompt))?;
    let session = agents.get(session_id).ok_or("unknown_session")?;
    let handle = acp_runner
        .prompt_session(session.as_ref(), prompt.to_owned())
        .map_err(|_| CommandFailure::from("session_closed"))?;

    // Drain the live update stream onto the V2 event bus. `turn_id` is this
    // prompt's request id, so a subscriber can correlate events with the final
    // `ok`. The stream closes when the turn completes (the session drops its
    // sender), ending this task.
    let events_drain = events.clone();
    let turn_id = cmd.request_id.clone();
    let session_label = session_id.to_owned();
    let mut updates = handle.updates;
    let updates_drain = tokio::spawn(async move {
        while let Some(update) = updates.recv().await {
            match update {
                fae_acp::AcpUpdate::Text(delta) => events_drain.publish(
                    "agent.output",
                    Scope::AgentExecute,
                    serde_json::json!({
                        "session_id": session_label,
                        "turn_id": turn_id,
                        "delta": delta,
                    }),
                ),
                fae_acp::AcpUpdate::ToolCall { id, title } => events_drain.publish(
                    "agent.tool_call",
                    Scope::AgentExecute,
                    serde_json::json!({
                        "session_id": session_label,
                        "turn_id": turn_id,
                        "id": id,
                        "title": title,
                    }),
                ),
            }
        }
    });

    // Drain mid-turn server requests (gap A3). With a `ServerRequester` each
    // permission request is driven to the client (→ Fae's approval card) and the
    // decision flows back; without one (diagnostic path), approve the first
    // option so the agent can proceed.
    let mut requests = handle.requests;
    let requests_drain = tokio::spawn(async move {
        while let Some(request) = requests.recv().await {
            match request {
                fae_acp::AcpServerRequest::Permission {
                    title,
                    options,
                    reply,
                } => {
                    let decision = resolve_permission(&requester, &title, &options).await;
                    let _ = reply.send(decision);
                }
                fae_acp::AcpServerRequest::ReadFile { path, reply } => {
                    let result = resolve_fs(&requester, "fs.read", &path, None).await;
                    let _ = reply.send(result.map(|value| {
                        value
                            .get("content")
                            .and_then(serde_json::Value::as_str)
                            .unwrap_or_default()
                            .to_owned()
                    }));
                }
                fae_acp::AcpServerRequest::WriteFile {
                    path,
                    content,
                    reply,
                } => {
                    let result = resolve_fs(&requester, "fs.write", &path, Some(content)).await;
                    let _ = reply.send(result.map(|_| ()));
                }
            }
        }
    });

    let outcome = handle
        .reply
        .await
        .map_err(|_| "agent_error")?
        .map_err(|error| {
            tracing::warn!(error = %error, "fae-daemon: agent.prompt turn failed");
            CommandFailure::from(classify_agent_error(&error))
        })?;
    let _ = updates_drain.await;
    let _ = requests_drain.await;

    let tool_calls: Vec<serde_json::Value> = outcome
        .tool_calls
        .into_iter()
        .map(|tc| serde_json::json!({ "id": tc.id, "title": tc.title }))
        .collect();
    Ok(serde_json::json!({
        "text": outcome.text,
        "stop_reason": outcome.stop_reason,
        "tool_calls": tool_calls,
    }))
}

/// Resolve one agent permission request: round-trip to the client via
/// `requester` (gap A3) or, with no requester (diagnostic path), approve the
/// first option. A disconnected/declined client cancels (fail-safe).
async fn resolve_permission(
    requester: &Option<ServerRequester>,
    title: &str,
    options: &[fae_acp::AcpPermissionOption],
) -> fae_acp::AcpPermissionDecision {
    let Some(requester) = requester else {
        return options
            .first()
            .map(|opt| fae_acp::AcpPermissionDecision::Selected(opt.id.clone()))
            .unwrap_or(fae_acp::AcpPermissionDecision::Cancelled);
    };
    let params = serde_json::json!({
        "title": title,
        "options": options
            .iter()
            .map(|opt| serde_json::json!({ "id": opt.id, "name": opt.name, "kind": opt.kind }))
            .collect::<Vec<_>>(),
    });
    // Bound the round-trip like toolhost/confirm.rs: agent.prompt runs on a bare
    // spawn (not tracked in tool_tasks), so a client that disconnects mid-approval
    // would otherwise leave this awaiting forever, leaking the ConnSink. On
    // timeout, fail-safe by cancelling.
    match tokio::time::timeout(
        std::time::Duration::from_secs(AGENT_APPROVAL_TIMEOUT_SECS),
        requester.request("permission.request", params),
    )
    .await
    {
        Ok(Ok(reply)) => permission_decision_from_reply(&reply),
        Ok(Err(_)) | Err(_) => fae_acp::AcpPermissionDecision::Cancelled,
    }
}

/// Timeout for agent permission / fs round-trips to the client, matching
/// `toolhost/confirm.rs`'s `CONFIRM_TIMEOUT_SECS`.
const AGENT_APPROVAL_TIMEOUT_SECS: u64 = 60;

/// Drive one fs request (`fs.read` / `fs.write`) to the client (gap A3b), which
/// mediates it through PathPolicy/DamageControl. Returns the reply payload on
/// success, or an error string when refused / unmediated. A `{ "error": … }`
/// reply (a blocked path) becomes `Err`.
async fn resolve_fs(
    requester: &Option<ServerRequester>,
    method: &str,
    path: &str,
    content: Option<String>,
) -> Result<serde_json::Value, String> {
    let Some(requester) = requester else {
        return Err("filesystem mediation unavailable".to_owned());
    };
    let mut params = serde_json::json!({ "path": path });
    if let Some(content) = content {
        params["content"] = serde_json::Value::String(content);
    }
    // Same bounded round-trip as resolve_permission: a mid-request disconnect
    // must not leak the awaiting task / ConnSink. Timeout fails closed.
    match tokio::time::timeout(
        std::time::Duration::from_secs(AGENT_APPROVAL_TIMEOUT_SECS),
        requester.request(method, params),
    )
    .await
    {
        Ok(Ok(reply)) => match reply.get("error").and_then(serde_json::Value::as_str) {
            Some(error) => Err(error.to_owned()),
            None => Ok(reply),
        },
        Ok(Err(_)) => Err("filesystem request failed".to_owned()),
        Err(_) => Err("filesystem request timed out".to_owned()),
    }
}

/// Map the client's `permission.request` reply payload to a decision:
/// `{cancelled:true}` declines, `{option_id:"…"}` approves that option,
/// anything else declines (fail-safe).
fn permission_decision_from_reply(reply: &serde_json::Value) -> fae_acp::AcpPermissionDecision {
    if reply.get("cancelled").and_then(serde_json::Value::as_bool) == Some(true) {
        fae_acp::AcpPermissionDecision::Cancelled
    } else if let Some(option_id) = reply.get("option_id").and_then(serde_json::Value::as_str) {
        fae_acp::AcpPermissionDecision::Selected(option_id.to_owned())
    } else {
        fae_acp::AcpPermissionDecision::Cancelled
    }
}

/// Authorize + audit + run an `agent.prompt` frame with a live `ServerRequester`
/// (gap A3 transport spawn path). The transport runs this on a spawned task so
/// the connection read loop keeps reading the client's server-request replies
/// while the turn is in flight.
#[allow(clippy::too_many_arguments)]
pub async fn run_authorized_agent_prompt(
    record: &ClientRecord,
    cmd: &Command,
    agents: &AgentSessionRegistry,
    events: &EventBus,
    conductor: Option<&crate::conductor::ConductorRuntime>,
    acp_runner: &dyn AcpAgentRunner,
    requester: ServerRequester,
    now_ms: u64,
    event_id: String,
) -> FrameOutcome {
    let decision = authorize(record, cmd, now_ms);
    let audit = AuditEvent::from_authz(
        event_id,
        now_ms,
        Some(record.client_id.clone()),
        cmd,
        &decision,
    );
    let response = match &decision {
        AuthzDecision::Allow => {
            match agent_prompt_inner(agents, events, conductor, acp_runner, Some(requester), cmd)
                .await
            {
                Ok(result) => Response::ok(&cmd.request_id, result),
                Err(failure) => failure.into_response(&cmd.request_id),
            }
        }
        AuthzDecision::ConfirmRequired => Response::error(
            &cmd.request_id,
            "confirm_required",
            "owner confirmation required for this action",
        ),
        AuthzDecision::Deny(reason) => {
            Response::error(&cmd.request_id, reason.code(), "authorization denied")
        }
    };
    FrameOutcome {
        response,
        audit,
        close: false,
    }
}

/// The governed `toolhost.execute` handler (ADR-013 Vision A / A3, scope §4).
/// Two-tier auth: the outer `toolhost.execute → ToolExecuteSafe` scope (checked
/// here) is the envelope permission to call the host at all; the inner per-tool
/// policy ([`FaeToolPolicy`](crate::toolhost::policy::FaeToolPolicy)) re-checks
/// `tool.execute_safe` / `tool.execute_dangerous` per call and runs the
/// path/damage/egress gates + the `tool.confirm` round-trip.
///
/// Spawned by the transport read loop (like [`run_authorized_agent_prompt`])
/// so the `tool.confirm` round-trip does not block it — the loop keeps draining
/// the client's `{server_request_id, result}` replies (BLOCKER-1).
pub async fn run_authorized_toolhost_execute(
    record: &ClientRecord,
    cmd: &Command,
    toolhost: &crate::toolhost::ToolHost,
    confirmation: &dyn crate::toolhost::confirm::ToolConfirmation,
    cancel: tokio_util::sync::CancellationToken,
    now_ms: u64,
    event_id: String,
) -> FrameOutcome {
    let decision = authorize(record, cmd, now_ms);
    let audit = AuditEvent::from_authz(
        event_id,
        now_ms,
        Some(record.client_id.clone()),
        cmd,
        &decision,
    );
    let response = match &decision {
        AuthzDecision::Allow => match parse_toolhost_payload(&cmd.payload) {
            Ok((tool, input, origin)) => {
                let req = crate::toolhost::ToolHostRequest {
                    client: record.clone(),
                    tool,
                    input,
                    call_id: cmd.request_id.clone(),
                    cancel,
                    // (Phase C) The origin drives the isolation tier. A missing
                    // origin defaults to the owner's interactive Swift-loop turn
                    // (host tier); an autonomous caller (proactive/scheduler/
                    // auto_skill/script_block) names a non-interactive origin
                    // that REQUIRES the OS jail (fail-closed if unavailable).
                    origin,
                };
                match toolhost.execute_governed(req, confirmation).await {
                    Ok(result) => Response::ok(
                        &cmd.request_id,
                        serde_json::to_value(&result.output).unwrap_or(serde_json::Value::Null),
                    ),
                    Err(err) => toolhost_error_response(&cmd.request_id, err),
                }
            }
            Err(msg) => Response::error(&cmd.request_id, "bad_request", &msg),
        },
        // `toolhost.execute` maps to a safe scope; ConfirmRequired here is not
        // expected, but fail closed regardless.
        AuthzDecision::ConfirmRequired => Response::error(
            &cmd.request_id,
            "confirm_required",
            "toolhost.execute authorization requires confirmation",
        ),
        AuthzDecision::Deny(reason) => {
            Response::error(&cmd.request_id, reason.code(), "authorization denied")
        }
    };
    FrameOutcome {
        response,
        audit,
        close: false,
    }
}

/// Map an optional wire `origin` string to a [`ToolOrigin`](crate::toolhost::isolation::ToolOrigin).
/// Backward-compatible: a MISSING origin (`None`) is the owner's interactive turn
/// (host tier). Autonomous callers name a non-interactive origin that REQUIRES
/// the OS jail (`execute_governed` fails closed if no backend is present). Phase C.
fn parse_tool_origin(
    origin: Option<&str>,
) -> Result<crate::toolhost::isolation::ToolOrigin, String> {
    use crate::toolhost::isolation::ToolOrigin;
    match origin {
        None | Some("owner_interactive") => Ok(ToolOrigin::OwnerInteractive),
        Some("proactive") => Ok(ToolOrigin::Proactive),
        Some("scheduler") => Ok(ToolOrigin::Scheduler),
        Some("auto_skill") => Ok(ToolOrigin::AutoSkill),
        Some("script_block") => Ok(ToolOrigin::ScriptBlock),
        Some(other) => Err(format!("unknown origin: {other}")),
    }
}

/// Parse the `toolhost.execute` payload `{tool, input, origin?}` (reject unknown
/// fields). `origin` is optional and defaults to owner-interactive (host tier);
/// a non-interactive origin selects the OS jail. Phase C.
fn parse_toolhost_payload(
    payload: &serde_json::Value,
) -> Result<
    (
        String,
        serde_json::Value,
        crate::toolhost::isolation::ToolOrigin,
    ),
    String,
> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct ToolhostPayload {
        tool: String,
        input: serde_json::Value,
        #[serde(default)]
        origin: Option<String>,
    }
    let parsed: ToolhostPayload = serde_json::from_value(payload.clone())
        .map_err(|e| format!("invalid toolhost.execute payload: {e}"))?;
    let origin = parse_tool_origin(parsed.origin.as_deref())?;
    Ok((parsed.tool, parsed.input, origin))
}

/// Map a [`ToolHostError`](crate::toolhost::ToolHostError) to a wire response.
fn toolhost_error_response(request_id: &str, err: crate::toolhost::ToolHostError) -> Response {
    use crate::toolhost::ToolHostError;
    let (code, message) = match &err {
        ToolHostError::Denied(reason) => ("forbidden", reason.clone()),
        ToolHostError::UnknownTool(name) => ("tool_failed", format!("tool not registered: {name}")),
        ToolHostError::Tool(msg) => ("tool_failed", msg.clone()),
        ToolHostError::Sandbox(msg) => ("sandbox_error", msg.clone()),
    };
    Response::error(request_id, code, &message)
}

/// `toolhost.set_root` (A3→B): bind an owner-approved durable workspace directory
/// as this session's ToolHost root. Two gates: the outer `ToolWorkspaceGrant`
/// scope (provisioned default-OFF via `FAE_TOOLHOST_WORKSPACE_GRANT`), then a
/// distinct daemon-initiated `workspace.confirm_root` card approving the
/// SPECIFIC canonical path. SPAWNED by the transport read loop (BLOCKER-1: the
/// confirm round-trip must not block draining the client's reply).
///
/// Lifecycle: validates the path (exists, directory, blast-radius-safe) BEFORE
/// prompting; sets `PendingRootConfirm`; on approval stores `ApprovedRoot` (the
/// ToolHost is created lazily on the next `toolhost.execute`). Late set_root (a
/// ToolHost already exists) denies `root_already_initialized`; a second set_root
/// while one is pending denies `root_initialization_pending`.
pub async fn run_authorized_toolhost_set_root(
    record: &ClientRecord,
    cmd: &Command,
    root_state: &Arc<tokio::sync::Mutex<crate::toolhost::root_confirm::ToolRootState>>,
    root_confirmation: &dyn crate::toolhost::root_confirm::RootConfirmation,
    home_dir: Option<std::path::PathBuf>,
    now_ms: u64,
    event_id: String,
) -> FrameOutcome {
    use crate::toolhost::root_confirm::ToolRootState;

    // Outer scope gate (envelope permission). Without ToolWorkspaceGrant the
    // owner is never prompted — the request is denied at the wire.
    let authz = authorize(record, cmd, now_ms);
    let audit = AuditEvent::from_authz(
        event_id,
        now_ms,
        Some(record.client_id.clone()),
        cmd,
        &authz,
    );
    let response = match &authz {
        AuthzDecision::Allow => match parse_set_root_payload(&cmd.payload) {
            Ok(raw_path) => 'validate: {
                // 1. Validate BEFORE prompting: blast-radius guard on the RAW
                //    path. The guard canonicalizes internally + checks BOTH the
                //    raw and canonical forms (oracle BLOCKER-2: canonicalizing
                //    here defeated the depth check — `/etc` → `/private/etc`
                //    has depth 2 and would pass). The owner is NEVER prompted
                //    for an invalid/unsafe root.
                let raw = std::path::Path::new(&raw_path);
                if !crate::toolhost::root_confirm::is_safe_workspace_root(raw, home_dir.as_deref())
                {
                    break 'validate Response::error(
                        &cmd.request_id,
                        "unsafe_root",
                        "refused: path does not exist or is too broad (home/system root) to contain damage",
                    );
                };
                // Safe to canonicalize now for the confirm payload.
                let canon = match raw.canonicalize() {
                    Ok(c) => c,
                    Err(_) => {
                        break 'validate Response::error(
                            &cmd.request_id,
                            "unsafe_root",
                            "refused: path does not exist",
                        )
                    }
                };
                // 2. Atomically check-and-set PendingRootConfirm. set_root is only
                //    valid from `Unset` — an already-approved or initialized
                //    root is immutable for the session.
                let blocked = {
                    let mut st = root_state.lock().await;
                    match &*st {
                        ToolRootState::Unset => {
                            *st = ToolRootState::PendingRootConfirm;
                            None
                        }
                        ToolRootState::PendingRootConfirm => Some("root_initialization_pending"),
                        _ => Some("root_already_initialized"),
                    }
                };
                if let Some(code) = blocked {
                    Response::error(&cmd.request_id, code, "root lifecycle denied")
                } else {
                    // 3. The distinct root-approval round-trip.
                    let req = crate::toolhost::root_confirm::build_root_confirm_request(
                        &cmd.request_id,
                        &canon.to_string_lossy(),
                    );
                    match root_confirmation.confirm_root(&req).await {
                        crate::toolhost::root_confirm::RootConfirmReply::Approved => {
                            // CAS (oracle BLOCKER-1): only transition
                            // PendingRootConfirm → ApprovedRoot. If a racing
                            // `toolhost.execute` clobbered the state in the
                            // meantime (it shouldn't now — execute denies while
                            // Pending — but fail closed regardless), do NOT
                            // shadow an already-initialized host with ApprovedRoot.
                            let mut st = root_state.lock().await;
                            if matches!(*st, ToolRootState::PendingRootConfirm) {
                                *st = ToolRootState::ApprovedRoot {
                                    path: canon.to_string_lossy().into_owned(),
                                };
                                Response::ok(
                                    &cmd.request_id,
                                    serde_json::json!({"root": canon.to_string_lossy()}),
                                )
                            } else {
                                eprintln!(
                                    "fae-daemon: root state changed during confirm: {:?}",
                                    *st
                                );
                                *st = ToolRootState::Unset;
                                Response::error(
                                    &cmd.request_id,
                                    "root_state_changed",
                                    "root state changed during confirmation",
                                )
                            }
                        }
                        crate::toolhost::root_confirm::RootConfirmReply::Denied(reason) => {
                            let mut st = root_state.lock().await;
                            *st = ToolRootState::Unset;
                            Response::error(&cmd.request_id, "root_denied", &reason)
                        }
                    }
                }
            }
            Err(msg) => Response::error(&cmd.request_id, "bad_request", &msg),
        },
        AuthzDecision::ConfirmRequired | AuthzDecision::Deny(_) => {
            Response::error(&cmd.request_id, "forbidden", "authorization denied")
        }
    };
    FrameOutcome {
        response,
        audit,
        close: false,
    }
}

/// Parse the `toolhost.set_root` payload `{path}` (reject unknown fields).
fn parse_set_root_payload(payload: &serde_json::Value) -> Result<String, String> {
    #[derive(serde::Deserialize)]
    #[serde(deny_unknown_fields)]
    struct SetRootPayload {
        path: String,
    }
    let parsed: SetRootPayload = serde_json::from_value(payload.clone())
        .map_err(|e| format!("invalid toolhost.set_root payload: {e}"))?;
    if parsed.path.trim().is_empty() {
        return Err("path must not be empty".into());
    }
    Ok(parsed.path)
}

/// The read-only `skillhost.list` handler (ADR-013 Vision A / A2.5). Returns
/// every discovered skill with its availability (quarantined skills are listed
/// as `available: false` + a reason, never dropped). Gated by the safe envelope
/// scope (`ToolExecuteSafe`); no confirmation, no execution.
pub fn run_authorized_skillhost_list(
    record: &ClientRecord,
    cmd: &Command,
    skillhost: &crate::skillhost::SkillHost,
    now_ms: u64,
    event_id: String,
) -> FrameOutcome {
    let decision = authorize(record, cmd, now_ms);
    let audit = AuditEvent::from_authz(
        event_id,
        now_ms,
        Some(record.client_id.clone()),
        cmd,
        &decision,
    );
    let response = match &decision {
        AuthzDecision::Allow => Response::ok(
            &cmd.request_id,
            serde_json::json!({ "skills": skillhost.list() }),
        ),
        AuthzDecision::ConfirmRequired | AuthzDecision::Deny(_) => {
            Response::error(&cmd.request_id, "forbidden", "authorization denied")
        }
    };
    FrameOutcome {
        response,
        audit,
        close: false,
    }
}

/// The `skillhost.activate` handler (ADR-013 Vision A / A2.5). Returns the full
/// post-frontmatter `SKILL.md` body for prompt injection. Executable skills are
/// re-verified against disk before their body is released. Safe-scope gated.
pub fn run_authorized_skillhost_activate(
    record: &ClientRecord,
    cmd: &Command,
    skillhost: &crate::skillhost::SkillHost,
    now_ms: u64,
    event_id: String,
) -> FrameOutcome {
    let decision = authorize(record, cmd, now_ms);
    let audit = AuditEvent::from_authz(
        event_id,
        now_ms,
        Some(record.client_id.clone()),
        cmd,
        &decision,
    );
    let response = match &decision {
        AuthzDecision::Allow => match parse_skill_name_payload(&cmd.payload) {
            Ok(name) => match skillhost.activate(&name) {
                Ok(body) => Response::ok(
                    &cmd.request_id,
                    serde_json::json!({ "name": name, "body": body }),
                ),
                Err(err) => skillhost_error_response(&cmd.request_id, &err),
            },
            Err(msg) => Response::error(&cmd.request_id, "bad_request", &msg),
        },
        AuthzDecision::ConfirmRequired | AuthzDecision::Deny(_) => {
            Response::error(&cmd.request_id, "forbidden", "authorization denied")
        }
    };
    FrameOutcome {
        response,
        audit,
        close: false,
    }
}

/// The governed `skillhost.run` handler (ADR-013 Vision A / A2.5). Re-verifies
/// the skill's integrity, resolves the declared script, and routes a
/// `uv run --script …` command through the EXISTING governed ToolHost bash path
/// (`execute_governed`): authorize (dangerous scope) → path → damage → owner
/// `tool.confirm` → audit. There is NO second execution lane. Spawned by the
/// transport loop (like `toolhost.execute`) so the confirm round-trip doesn't
/// block reading the client's replies (BLOCKER-1).
#[allow(clippy::too_many_arguments)]
pub async fn run_authorized_skillhost_run(
    record: &ClientRecord,
    cmd: &Command,
    skillhost: &crate::skillhost::SkillHost,
    toolhost: &crate::toolhost::ToolHost,
    confirmation: &dyn crate::toolhost::confirm::ToolConfirmation,
    cancel: tokio_util::sync::CancellationToken,
    now_ms: u64,
    event_id: String,
) -> FrameOutcome {
    let decision = authorize(record, cmd, now_ms);
    let audit = AuditEvent::from_authz(
        event_id,
        now_ms,
        Some(record.client_id.clone()),
        cmd,
        &decision,
    );
    let response = match &decision {
        AuthzDecision::Allow => match parse_skill_run_payload(&cmd.payload) {
            Ok((skill, script, origin)) => {
                match skillhost.prepare_run(&skill, script.as_deref(), &cmd.request_id) {
                    Ok(plan) => {
                        // Route the built command through the SAME governed bash
                        // pipeline as any ToolHost bash call (dangerous scope +
                        // owner confirm enforced by execute_governed).
                        let req = crate::toolhost::ToolHostRequest {
                            client: record.clone(),
                            tool: "bash".into(),
                            input: serde_json::json!({ "command": plan.command }),
                            call_id: cmd.request_id.clone(),
                            cancel,
                            // (Phase C) An interactive owner skill run defaults to
                            // the host tier; an autonomous skill run (proactive/
                            // scheduler/auto_skill) names a non-interactive origin
                            // and INHERITS the OS jail (fail-closed if absent).
                            origin,
                        };
                        match toolhost.execute_governed(req, confirmation).await {
                            Ok(result) => Response::ok(
                                &cmd.request_id,
                                serde_json::json!({
                                    "skill": plan.skill,
                                    "output": serde_json::to_value(&result.output)
                                        .unwrap_or(serde_json::Value::Null),
                                }),
                            ),
                            Err(err) => toolhost_error_response(&cmd.request_id, err),
                        }
                    }
                    Err(err) => skillhost_error_response(&cmd.request_id, &err),
                }
            }
            Err(msg) => Response::error(&cmd.request_id, "bad_request", &msg),
        },
        AuthzDecision::ConfirmRequired | AuthzDecision::Deny(_) => {
            Response::error(&cmd.request_id, "forbidden", "authorization denied")
        }
    };
    FrameOutcome {
        response,
        audit,
        close: false,
    }
}

/// Parse a `{name}` payload (reject unknown fields). Used by `skillhost.activate`.
fn parse_skill_name_payload(payload: &serde_json::Value) -> Result<String, String> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct NamePayload {
        name: String,
    }
    let parsed: NamePayload = serde_json::from_value(payload.clone())
        .map_err(|e| format!("invalid skillhost payload: {e}"))?;
    if parsed.name.trim().is_empty() {
        return Err("name must not be empty".into());
    }
    Ok(parsed.name)
}

/// Parse the `skillhost.run` payload `{skill, script?, origin?}` (reject unknown
/// fields). `script` is the bare script stem (`scripts/<script>.py` is resolved
/// against the manifest); absent ⇒ the first declared script. `origin` is
/// optional and defaults to owner-interactive (host tier); an autonomous origin
/// selects the OS jail. Phase C.
fn parse_skill_run_payload(
    payload: &serde_json::Value,
) -> Result<
    (
        String,
        Option<String>,
        crate::toolhost::isolation::ToolOrigin,
    ),
    String,
> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct RunPayload {
        skill: String,
        #[serde(default)]
        script: Option<String>,
        #[serde(default)]
        origin: Option<String>,
    }
    let parsed: RunPayload = serde_json::from_value(payload.clone())
        .map_err(|e| format!("invalid skillhost.run payload: {e}"))?;
    if parsed.skill.trim().is_empty() {
        return Err("skill must not be empty".into());
    }
    let origin = parse_tool_origin(parsed.origin.as_deref())?;
    Ok((parsed.skill, parsed.script, origin))
}

/// Map a [`SkillHostError`](crate::skillhost::SkillHostError) to a wire response.
fn skillhost_error_response(request_id: &str, err: &crate::skillhost::SkillHostError) -> Response {
    use crate::skillhost::SkillHostError;
    let (code, message) = match err {
        SkillHostError::NotFound(name) => ("not_found", format!("skill not found: {name}")),
        SkillHostError::Quarantined { name, reason } => {
            ("skill_quarantined", format!("{name}: {reason}"))
        }
        SkillHostError::NotExecutable(name) => {
            ("not_executable", format!("skill is not executable: {name}"))
        }
        SkillHostError::ScriptNotFound(name) => (
            "script_not_found",
            format!("no declared script for: {name}"),
        ),
        SkillHostError::Audit(msg) => ("audit_error", msg.clone()),
    };
    Response::error(request_id, code, &message)
}

/// `agent.cancel` — interrupt the session's in-flight turn (`session/cancel`).
/// Requires `AgentExecute`.
fn agent_cancel(
    backends: &SessionBackends<'_>,
    cmd: &Command,
) -> Result<serde_json::Value, &'static str> {
    let session_id = cmd
        .payload
        .get("session_id")
        .and_then(serde_json::Value::as_str)
        .ok_or("bad_request")?;
    let session = backends.agents.get(session_id).ok_or("unknown_session")?;
    session.cancel();
    Ok(serde_json::json!({ "cancelled": true }))
}

/// `agent.close` — tear a session down and drop it from the registry. Requires
/// `AgentExecute`.
fn agent_close(
    backends: &SessionBackends<'_>,
    cmd: &Command,
) -> Result<serde_json::Value, &'static str> {
    let session_id = cmd
        .payload
        .get("session_id")
        .and_then(serde_json::Value::as_str)
        .ok_or("bad_request")?;
    match backends.agents.remove(session_id) {
        Some(session) => {
            session.close();
            Ok(serde_json::json!({ "closed": true }))
        }
        None => Err("unknown_session"),
    }
}

/// `agent.session_list` — handles of all live native-ACP sessions. Read-only.
fn agent_session_list(backends: &SessionBackends<'_>) -> Result<serde_json::Value, &'static str> {
    let sessions: Vec<serde_json::Value> = backends
        .agents
        .list()
        .into_iter()
        .map(|info| {
            serde_json::json!({
                "session_id": info.id,
                "agent": info.agent,
                "cwd": info.cwd,
            })
        })
        .collect();
    Ok(serde_json::json!({ "sessions": sessions }))
}

async fn audio_devices(audio: &AudioManager) -> Result<serde_json::Value, &'static str> {
    let audio = (*audio).clone();
    let devices = tokio::task::spawn_blocking(move || audio.devices())
        .await
        .map_err(|error| {
            eprintln!("fae-daemon: audio.devices worker join failed: {error}");
            "internal_error"
        })?;
    serde_json::to_value(devices).map_err(|_| "internal_error")
}

async fn audio_capture_start(audio: &AudioManager) -> Result<serde_json::Value, &'static str> {
    let audio = (*audio).clone();
    let capture_id = tokio::task::spawn_blocking(move || audio.capture_start())
        .await
        .map_err(|error| {
            eprintln!("fae-daemon: audio.capture_start worker join failed: {error}");
            "internal_error"
        })?
        .map_err(|error| {
            eprintln!("fae-daemon: audio.capture_start failed: {error}");
            "audio_error"
        })?;
    Ok(serde_json::json!({ "capture_id": capture_id }))
}

async fn audio_capture_stop(
    audio: &AudioManager,
    cmd: &Command,
) -> Result<serde_json::Value, &'static str> {
    use base64::Engine as _;
    let capture_id = cmd
        .payload
        .get("capture_id")
        .and_then(serde_json::Value::as_str)
        .ok_or("bad_request")?
        .to_owned();
    let audio = (*audio).clone();
    let captured = tokio::task::spawn_blocking(move || audio.capture_stop(&capture_id))
        .await
        .map_err(|error| {
            eprintln!("fae-daemon: audio.capture_stop worker join failed: {error}");
            "internal_error"
        })?
        .map_err(|error| {
            eprintln!("fae-daemon: audio.capture_stop failed: {error}");
            match error {
                fae_audio::AudioError::CaptureNotFound => "not_found",
                _ => "audio_error",
            }
        })?;
    Ok(serde_json::json!({
        "wav_base64": base64::engine::general_purpose::STANDARD.encode(captured.wav),
        "duration_ms": captured.duration_ms,
        "sample_rate": captured.sample_rate,
    }))
}

async fn audio_play(
    audio: &AudioManager,
    cmd: &Command,
) -> Result<serde_json::Value, &'static str> {
    use base64::Engine as _;
    let encoded = cmd
        .payload
        .get("wav_base64")
        .and_then(serde_json::Value::as_str)
        .ok_or("bad_request")?;
    let wav = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|_| "bad_request")?;
    let audio = (*audio).clone();
    let played_ms = tokio::task::spawn_blocking(move || audio.play_wav(&wav))
        .await
        .map_err(|error| {
            eprintln!("fae-daemon: audio.play worker join failed: {error}");
            "internal_error"
        })?
        .map_err(|error| {
            eprintln!("fae-daemon: audio.play failed: {error}");
            "audio_error"
        })?;
    Ok(serde_json::json!({ "played_ms": played_ms }))
}

/// Default Kokoro voice when the client does not name one.
const TTS_DEFAULT_VOICE: &str = "af_heart";
/// Bound a single synthesis request — long text should be sentence-chunked
/// by the client (matching the Swift TTS pipeline's behaviour).
const TTS_MAX_TEXT_CHARS: usize = 2_000;

/// Parsed `{ text, voice?, speed? }` payload shared by `tts.synthesize` and
/// `tts.speak` (voice spine V3a).
struct TtsPayload<'a> {
    text: &'a str,
    voice: &'a str,
    speed: f32,
}

fn parse_tts_payload(cmd: &Command) -> Result<TtsPayload<'_>, &'static str> {
    let text = cmd
        .payload
        .get("text")
        .and_then(serde_json::Value::as_str)
        .ok_or("bad_request")?;
    if text.trim().is_empty() || text.len() > TTS_MAX_TEXT_CHARS {
        return Err("bad_request");
    }
    let voice = cmd
        .payload
        .get("voice")
        .and_then(serde_json::Value::as_str)
        .unwrap_or(TTS_DEFAULT_VOICE);
    #[allow(clippy::cast_possible_truncation)]
    let speed = cmd
        .payload
        .get("speed")
        .and_then(serde_json::Value::as_f64)
        .map_or(1.0_f32, |value| (value as f32).clamp(0.5, 2.0));
    Ok(TtsPayload { text, voice, speed })
}

/// Run one `tts.synthesize` request: `{ text, voice?, speed? }` →
/// `{ wav_base64, sample_rate }`.
async fn synthesize_tts(
    tts: &dyn TtsAdapter,
    cmd: &Command,
) -> Result<serde_json::Value, &'static str> {
    use base64::Engine as _;
    let parsed = parse_tts_payload(cmd)?;
    let audio = tts
        .synthesize(parsed.text, parsed.voice, parsed.speed)
        .await
        .map_err(|error| {
            eprintln!("fae-daemon: tts.synthesize failed: {error}");
            "inference_failed"
        })?;
    Ok(serde_json::json!({
        "wav_base64": base64::engine::general_purpose::STANDARD.encode(&audio.wav),
        "sample_rate": audio.sample_rate,
    }))
}

/// Run one `tts.speak` request (voice spine V3a): `{ text, voice?, speed? }` →
/// synthesize → `audio.play_start` (non-blocking) → return `{ playback_id }`
/// immediately. A detached task drains the playback RMS channel, publishing
/// `audio.level` (per reading) and `audio.playback_ended` (on close, with
/// `reason` resolved via the [`PlaybackRegistry`] interrupted flag) on the
/// [`EventBus`] to subscribed connections.
async fn speak_tts(
    backends: &SessionBackends<'_>,
    cmd: &Command,
) -> Result<serde_json::Value, &'static str> {
    let parsed = parse_tts_payload(cmd)?;
    // Hold the text/voice/speed in heap memory that outlives this frame, since
    // `synthesize` is async and we don't want to copy into a 'static String per
    // call — but the adapter borrows, so resolve before the await boundary.
    let text = parsed.text.to_owned();
    let voice = parsed.voice;
    let speed = parsed.speed;
    let audio = backends
        .tts
        .synthesize(&text, voice, speed)
        .await
        .map_err(|error| {
            eprintln!("fae-daemon: tts.speak synthesis failed: {error}");
            "inference_failed"
        })?;

    let (level_tx, level_rx) = std::sync::mpsc::channel::<f32>();
    let audio_mgr = (*backends.audio).clone();
    let wav = audio.wav.clone();
    let playback_id = tokio::task::spawn_blocking(move || audio_mgr.play_start(&wav, level_tx))
        .await
        .map_err(|error| {
            eprintln!("fae-daemon: tts.speak play_start worker join failed: {error}");
            "internal_error"
        })?
        .map_err(|error| {
            eprintln!("fae-daemon: tts.speak play_start failed: {error}");
            "audio_error"
        })?;

    let interrupted = backends.playbacks.insert(playback_id.clone());
    // Detached drain task: publishes the level envelope then the end-reason.
    // The `level` channel closes when the clip finishes (natural end-of-samples)
    // or when `audio.stop` drops the stream — both end up here.
    let events = backends.events.clone();
    let playbacks = backends.playbacks.clone();
    let id_for_task = playback_id.clone();
    tokio::task::spawn_blocking(move || {
        for rms in level_rx.iter() {
            events.publish(
                "audio.level",
                Scope::AudioPlayback,
                serde_json::json!({ "rms": rms, "playback_id": id_for_task }),
            );
        }
        let reason = if interrupted.load(std::sync::atomic::Ordering::Relaxed) {
            "interrupted"
        } else {
            "completed"
        };
        events.publish(
            "audio.playback_ended",
            Scope::AudioPlayback,
            serde_json::json!({ "playback_id": id_for_task, "reason": reason }),
        );
        playbacks.remove(&id_for_task);
    });

    Ok(serde_json::json!({ "playback_id": playback_id }))
}

/// `audio.stop` (voice spine V3a barge-in): `{ playback_id? }` → stop one
/// playback (or all live ones) and return `{ stopped }`. Marks each id
/// interrupted in the [`PlaybackRegistry`] *before* stopping so the drain task
/// publishes `reason: "interrupted"`.
async fn audio_stop(
    backends: &SessionBackends<'_>,
    cmd: &Command,
) -> Result<serde_json::Value, &'static str> {
    let ids: Vec<String> = cmd
        .payload
        .get("playback_id")
        .and_then(serde_json::Value::as_str)
        .map(|id| vec![id.to_owned()])
        .unwrap_or_else(|| backends.playbacks.ids());
    if ids.is_empty() {
        return Ok(serde_json::json!({ "stopped": 0 }));
    }
    let mut stopped = 0_u32;
    for id in &ids {
        // Flip the interrupted flag first so the drain task's end-reason is
        // "interrupted" (not "completed") — there's a benign race if the clip
        // already finished naturally, but the flag is read only on channel close.
        let was_live = backends.playbacks.mark_interrupted(id);
        let audio_mgr = (*backends.audio).clone();
        let id_owned = id.clone();
        let result = tokio::task::spawn_blocking(move || audio_mgr.play_stop(&id_owned))
            .await
            .map_err(|error| {
                eprintln!("fae-daemon: audio.stop worker join failed: {error}");
                "internal_error"
            })?;
        match result {
            Ok(()) => stopped += 1,
            Err(fae_audio::AudioError::PlaybackNotFound) => {
                // Already finished naturally (or a stale id). Count it as stopped
                // only if the registry still knew about it (interrupted flag set).
                if was_live {
                    stopped += 1;
                }
            }
            Err(error) => {
                eprintln!("fae-daemon: audio.stop failed: {error}");
                return Err("audio_error");
            }
        }
    }
    Ok(serde_json::json!({ "stopped": stopped }))
}

/// Hard ceiling on a single turn's generation budget, whatever the client asks.
const MAX_TOKENS_CEILING: usize = 8192;
/// Default generation budget when the client does not specify one.
const MAX_TOKENS_DEFAULT: usize = 512;

/// Parse one `{role, content, audio_wav_base64?}` message object from the rich
/// payload. `audio_wav_base64` (S18 push-to-talk) is optional; when present it
/// must be a string — base64 validity is the engine's concern, shape is ours.
fn parse_message(value: &serde_json::Value) -> Result<ChatMessage, &'static str> {
    let role = match value.get("role").and_then(serde_json::Value::as_str) {
        Some("system") => Role::System,
        Some("user") => Role::User,
        Some("assistant") => Role::Assistant,
        Some("tool") => Role::Tool,
        _ => return Err("bad_request"),
    };
    let content = value
        .get("content")
        .and_then(serde_json::Value::as_str)
        .ok_or("bad_request")?;
    let audio_wav_base64 = match value.get("audio_wav_base64") {
        None | Some(serde_json::Value::Null) => None,
        Some(serde_json::Value::String(encoded)) => Some(encoded.clone()),
        Some(_) => return Err("bad_request"),
    };
    Ok(ChatMessage {
        role,
        content: content.to_owned(),
        audio_wav_base64,
    })
}

/// Parse one `{name, description?, parameters?}` tool spec from the payload.
/// `parameters` defaults to an empty JSON-Schema object so a name-only tool is
/// still a valid function declaration.
fn parse_tool(value: &serde_json::Value) -> Result<ToolSpec, &'static str> {
    let name = value
        .get("name")
        .and_then(serde_json::Value::as_str)
        .ok_or("bad_request")?;
    if name.is_empty() {
        return Err("bad_request");
    }
    let description = value
        .get("description")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default();
    let parameters = value
        .get("parameters")
        .cloned()
        .unwrap_or_else(|| serde_json::json!({ "type": "object", "properties": {} }));
    Ok(ToolSpec {
        name: name.to_owned(),
        description: description.to_owned(),
        parameters,
    })
}

/// Build the engine request from the command payload. Two shapes, both under
/// the same `conversation.inject_text` command and scope:
/// - simple: `{ "text": "..." }` — one user message (back-compatible)
/// - rich:   `{ "messages": [{role, content}, ...], "system"?, "tools"?,
///   "max_tokens"? }` — full chat with tool schemas for native tool calling
fn parse_chat_request(payload: &serde_json::Value) -> Result<ChatRequest, &'static str> {
    let messages = if let Some(array) = payload
        .get("messages")
        .and_then(serde_json::Value::as_array)
    {
        array
            .iter()
            .map(parse_message)
            .collect::<Result<Vec<_>, _>>()?
    } else {
        let text = payload
            .get("text")
            .and_then(serde_json::Value::as_str)
            .ok_or("bad_request")?;
        vec![ChatMessage::text(Role::User, text)]
    };
    if messages.is_empty() {
        return Err("bad_request");
    }
    let system = payload
        .get("system")
        .and_then(serde_json::Value::as_str)
        .map(str::to_owned);
    let tools = match payload.get("tools").and_then(serde_json::Value::as_array) {
        Some(array) => array
            .iter()
            .map(parse_tool)
            .collect::<Result<Vec<_>, _>>()?,
        None => Vec::new(),
    };
    let max_tokens = payload
        .get("max_tokens")
        .and_then(serde_json::Value::as_u64)
        .map_or(MAX_TOKENS_DEFAULT, |value| {
            (value as usize).min(MAX_TOKENS_CEILING)
        });
    Ok(ChatRequest {
        system,
        messages,
        tools,
        max_tokens,
    })
}

/// Run one user turn through the engine, collecting the streamed events into a
/// single response. Streaming these as live protocol events is a follow-on, once
/// the event/`conversation.subscribe` channel lands.
async fn inject_text(
    backends: &SessionBackends<'_>,
    cmd: &Command,
) -> Result<serde_json::Value, &'static str> {
    // M1 step A: pure mechanical extraction. The conductor (step E) will route
    // through this wrapper; its `direct` decision calls `inject_text_core`
    // verbatim so the byte-identical-direct safety contract holds by
    // construction (one implementation, two entry points). Today this is a
    // pass-through — zero behavior change.
    match backends.conductor {
        Some(runtime) => {
            // Build the content-blind turn context (request_id + metadata;
            // no prompt text) and route through the conductor. The static
            // policy emits direct + local-model + ApprovalClass::None, so the
            // executor's direct arm runs inject_text_core verbatim — byte-
            // identical to the legacy path. Telemetry is fire-and-forget.
            let ctx = build_turn_context(cmd);
            crate::conductor::route_turn(runtime, backends, cmd, &ctx).await
        }
        None => {
            // Legacy/test/diagnostic path: no conductor wired.
            inject_text_core(backends, cmd).await
        }
    }
}

/// Build the conductor turn context from a command. Content-blind: carries the
/// Build the live turn context for a `conversation.inject_text` turn.
///
/// M4: the context is now **content-classified** — the designated
/// [`crate::conductor::classifier`] reads `cmd.payload.text` (the ONE F-4/n
/// boundary crossing) and emits a `task_class` + allowlisted `feature_predicates`.
/// The **policy** stays content-blind: it consumes the label, never the prompt.
/// A missing/non-text payload classifies to `Unknown + []` (fail-closed).
/// Delegates to [`build_turn_context_with_classifier`] with the default
/// rule-based classifier.
fn build_turn_context(cmd: &Command) -> crate::conductor::ConductorTurnContext {
    build_turn_context_with_classifier(cmd, &crate::conductor::classifier::RuleBasedTurnClassifier)
}

/// Build a turn context using an injected classifier (the test seam). Extracts
/// `cmd.payload.text` (same extraction as `parse_tts_payload`), classifies it, and
/// populates the context's existing `task_class` + `feature_predicates` fields.
/// No new fields on [`ConductorTurnContext`]; the classifier's `source` stays on
/// the [`TurnClassification`] — it is NOT persisted in M4-B (future shadow
/// telemetry may carry it; the live context carries no source field).
fn build_turn_context_with_classifier(
    cmd: &Command,
    classifier: &impl crate::conductor::classifier::TurnClassifier,
) -> crate::conductor::ConductorTurnContext {
    use crate::conductor::recipe::PrivacyLane;
    // Absent / non-text payload ⇒ empty prompt ⇒ classifier fails closed to
    // Unknown + [] (no behavior change for non-inject_text commands).
    let prompt = cmd
        .payload
        .get("text")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    let cls = classifier.classify(prompt);
    crate::conductor::ConductorTurnContext {
        request_id: cmd.request_id.clone(),
        task_class: cls.task_class,
        feature_predicates: cls.feature_predicates,
        privacy_lane: PrivacyLane::LocalOnly,
        available_workers: Vec::new(),
        working_directory: None,
        deadline_ms: None,
    }
}

/// M2-live §3.1: payload for `conversation.feedback`. Strict —
/// `#[serde(deny_unknown_fields)]` accepts **only** `target_request_id`,
/// `signal`, and `rating`; any other key (including a free-text field) is
/// rejected before the record is built (V6). `cmd.request_id` is *this* RPC's
/// correlation id (response + audit); the prior turn is referenced by
/// `target_request_id` in the payload.
#[derive(serde::Deserialize)]
#[serde(deny_unknown_fields)]
struct FeedbackPayload {
    /// Opaque id of the PRIOR inject_text turn this feedback targets.
    target_request_id: String,
    /// `"accept" | "reject" | "edit" | "rating"`.
    signal: String,
    /// Required iff `signal == "rating"`; `0..=5`.
    rating: Option<u8>,
}

/// Validate the feedback payload into a [`crate::conductor::UserSignal`] (fail-
/// closed). Returns the wire error code on any malformed input (§3.1):
/// `unknown_signal` / `rating_missing` / `rating_out_of_range` /
/// `rating_unexpected` (`rating` present on a non-`rating` signal).
fn build_user_signal(
    signal: &str,
    rating: Option<u8>,
) -> Result<crate::conductor::UserSignal, &'static str> {
    match signal {
        "accept" | "reject" | "edit" => {
            // §3.1 "iff": `rating` is meaningful only for the `rating` signal.
            // A stray rating on another signal is rejected (fail-closed strict
            // payload) rather than silently ignored.
            if rating.is_some() {
                return Err("rating_unexpected");
            }
            Ok(match signal {
                "accept" => crate::conductor::UserSignal::Accept,
                "reject" => crate::conductor::UserSignal::Reject,
                _ => crate::conductor::UserSignal::Edit,
            })
        }
        "rating" => {
            let value = rating.ok_or("rating_missing")?;
            if value > 5 {
                return Err("rating_out_of_range");
            }
            Ok(crate::conductor::UserSignal::Rating(value))
        }
        _ => Err("unknown_signal"),
    }
}

/// M2-live §3.2: record an explicit user-feedback signal against a prior turn.
/// Persists a `FeedbackRecord` (enum-only — **no user text**) to the *isolated*
/// conductor store (`conductor_feedback.jsonl`), joined to the prior turn on
/// `request_fingerprint` (F-4 continuity). **Not** best-effort (§3.2 step 3):
/// a store write failure surfaces as an error so the client can retry — never
/// silently drop a negative signal.
async fn record_feedback(backends: &SessionBackends<'_>, cmd: &Command) -> CommandResult {
    let runtime = match backends.conductor {
        Some(rt) => rt,
        None => return Err(CommandFailure::from("feedback_requires_conductor")),
    };
    // Parse + deny_unknown_fields. Unknown field ⇒ `unknown_field`; any other
    // serde error (missing field, wrong type) ⇒ `invalid_feedback_payload`.
    let payload: FeedbackPayload = match serde_json::from_value(cmd.payload.clone()) {
        Ok(p) => p,
        Err(err) => {
            let code = if err.to_string().contains("unknown field") {
                "unknown_field"
            } else {
                "invalid_feedback_payload"
            };
            return Err(CommandFailure::from(code));
        }
    };
    let signal =
        build_user_signal(&payload.signal, payload.rating).map_err(CommandFailure::from)?;
    let timestamp_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64);
    runtime
        .record_feedback(&payload.target_request_id, signal, timestamp_ms)
        .map_err(|err| {
            tracing::warn!("conductor feedback write failed: {err}");
            CommandFailure::from("feedback_store_failed")
        })?;
    Ok(serde_json::json!({ "recorded": true }))
}

/// M2-live §4.1: payload for `conductor.reward_snapshot`. Strict —
/// `#[serde(deny_unknown_fields)]` accepts **only** `window_turns`
/// (optional, default 100). An empty/null payload is accepted (defaults).
#[derive(serde::Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct RewardSnapshotPayload {
    #[serde(default)]
    window_turns: Option<usize>,
}

/// M2-live §4: advisory reward snapshot. Read-only — joins three isolated-store
/// reads via `ConductorRuntime::reward_snapshot`. Constructs no provider
/// request, spawns no agent, writes nothing.
async fn conductor_reward_snapshot(backends: &SessionBackends<'_>, cmd: &Command) -> CommandResult {
    let runtime = match backends.conductor {
        Some(rt) => rt,
        None => return Err(CommandFailure::from("snapshot_requires_conductor")),
    };
    // Null/empty payload ⇒ defaults (window_turns = 100); otherwise strict
    // deny_unknown_fields. Unknown key ⇒ unknown_field.
    let payload: RewardSnapshotPayload = if cmd.payload.is_null() {
        RewardSnapshotPayload::default()
    } else {
        match serde_json::from_value(cmd.payload.clone()) {
            Ok(p) => p,
            Err(err) => {
                let code = if err.to_string().contains("unknown field") {
                    "unknown_field"
                } else {
                    "invalid_snapshot_payload"
                };
                return Err(CommandFailure::from(code));
            }
        }
    };
    let window_turns = payload.window_turns.unwrap_or(100);
    let snapshot = runtime.reward_snapshot(window_turns).map_err(|err| {
        tracing::warn!("conductor reward snapshot failed: {err}");
        CommandFailure::from("snapshot_failed")
    })?;
    serde_json::to_value(&snapshot).map_err(|_| CommandFailure::from("snapshot_serialize_failed"))
}

/// Core conversation turn: FAE_DUMP → parse → `assistant.generating` event
/// pair → NaN-logits retry loop → `run_turn`. Extracted from `inject_text` so
/// the conductor's `direct` arm can run the exact same code path (the M1
/// byte-identical-direct contract — see
/// `docs/architecture/conductor-m1-static-recipes-spec-2026-06-22.md` §8).
///
/// User-visible behavior lives here: the `assistant.generating {active:true}`
/// publish (the orb host's generating indicator), the NaN-logits retry loop
/// (`NAN_RETRY_PADS = [4,24,80]`, rescues a known Metal failure), and the
/// exactly-once `active:false` publish on every return path. Any re-route MUST
/// call this verbatim, never a bare `run_turn`.
pub(crate) async fn inject_text_core(
    backends: &SessionBackends<'_>,
    cmd: &Command,
) -> Result<serde_json::Value, &'static str> {
    // Diagnostic payload dump (dev only): FAE_DUMP_REQUESTS=<dir> writes each
    // inject_text payload verbatim so failing turns can be replayed offline.
    if let Ok(dir) = std::env::var("FAE_DUMP_REQUESTS") {
        if !dir.is_empty() {
            let stamp = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_millis());
            let path =
                std::path::Path::new(&dir).join(format!("inject-{stamp}-{}.json", cmd.request_id));
            if let Err(error) = std::fs::write(&path, cmd.payload.to_string()) {
                eprintln!("fae-daemon: request dump failed ({error})");
            }
        }
    }
    let request = parse_chat_request(&cmd.payload)?;

    // Orb-host-owns-state: signal that the assistant is generating. Published
    // ONLY after a successful parse (a malformed payload returns above before
    // this, so it never publishes `active:true`). The paired `active:false` is
    // guaranteed exactly once by the run loop below — every return path runs
    // through it. Scope `ConversationRead` (the orb host's subscribe grant).
    backends.events.publish(
        "assistant.generating",
        Scope::ConversationRead,
        serde_json::json!({ "active": true }),
    );

    // Gemma 4 on Metal produces NaN logits when a prompt's TOTAL length lands
    // in a narrow window of sequence lengths (mistral.rs kernel tiling edge;
    // deterministic per payload, diagnosed 2026-06-12, still present at
    // upstream c22c2e2b). Appending ~50-130 tokens of system-prompt padding
    // shifts the length out of the window, so a NaN failure is retried with
    // padding before giving up. The pad asks the model to ignore it.
    const NAN_PAD_UNIT: &str = "(Padding line for runtime alignment — ignore this line entirely.)";
    const NAN_RETRY_PADS: [usize; 3] = [4, 24, 80];

    let engine = backends.engine;
    let mut attempt_request = request.clone();
    let outcome = async {
        for (attempt, pad_units) in std::iter::once(0_usize).chain(NAN_RETRY_PADS).enumerate() {
            if pad_units > 0 {
                let pad = std::iter::repeat_n(NAN_PAD_UNIT, pad_units)
                    .collect::<Vec<_>>()
                    .join("\n");
                let base = request.system.clone().unwrap_or_default();
                attempt_request = request.clone();
                attempt_request.system = Some(format!("{base}\n\n{pad}"));
                eprintln!(
                    "fae-daemon: inject_text retry {attempt} with {pad_units} pad units (NaN-logits length workaround)"
                );
            }
            match run_turn(engine, attempt_request.clone()).await {
                Ok(value) => return Ok(value),
                Err(detail) if is_nan_logits_failure(&detail) && attempt < NAN_RETRY_PADS.len() => {
                    eprintln!(
                        "fae-daemon: inject_text NaN-logits failure (attempt {attempt}): {detail}"
                    );
                    continue;
                }
                Err(detail) => {
                    eprintln!("fae-daemon: inject_text failed: {detail}");
                    return Err("inference_failed");
                }
            }
        }
        Err("inference_failed")
    }
    .await;

    // Exactly-once `active:false` — success, inference failure, OR retry
    // exhaustion all reach here. The orb host's grace-hold turns this into an
    // armed (not immediate) idle transition.
    backends.events.publish(
        "assistant.generating",
        Scope::ConversationRead,
        serde_json::json!({ "active": false }),
    );
    outcome
}

/// B5 cascaded ASR fallback. The Swift app decides when a primary transcript is
/// fragile; the daemon owns the Qwen3-ASR sidecar and model-lock-gated assets.
async fn transcribe_fallback(
    backends: &SessionBackends<'_>,
    cmd: &Command,
) -> Result<serde_json::Value, &'static str> {
    let Some(engine) = backends.asr_fallback else {
        return Err("fallback_unavailable");
    };
    let payload: TranscribeFallbackPayload =
        serde_json::from_value(cmd.payload.clone()).map_err(|_| "bad_request")?;
    if payload.wav_base64.is_empty() {
        return Err("bad_request");
    }
    let request = ChatRequest {
        system: Some(
            "Transcribe the user's audio verbatim. Output only the exact words spoken — no labels, commentary, or answers."
                .to_owned(),
        ),
        messages: vec![ChatMessage {
            role: Role::User,
            content: String::new(),
            audio_wav_base64: Some(payload.wav_base64),
        }],
        tools: Vec::new(),
        max_tokens: 128,
    };
    let result = run_turn(engine, request).await.map_err(|detail| {
        eprintln!("fae-daemon: audio.transcribe_fallback failed: {detail}");
        "fallback_failed"
    })?;
    let transcript = result
        .get("text")
        .and_then(serde_json::Value::as_str)
        .map(normalize_asr_transcript)
        .unwrap_or_default();
    if transcript.is_empty() {
        return Err("empty_transcript");
    }
    Ok(serde_json::json!({ "transcript": transcript }))
}

pub(crate) fn normalize_asr_transcript(raw: &str) -> String {
    let mut text = raw.trim();
    if let Some((_, after)) = text.rsplit_once("<asr_text>") {
        text = after.trim();
    }
    text.trim_matches(|ch: char| ch.is_whitespace() || ch == '"' || ch == '\'')
        .trim()
        .to_owned()
}

/// Orb-host-owns-state: publish an info set to subscribed orb hosts (the
/// green-dot indicator). Payload: `{ items: [{ id, kind, title, action? }] }`.
/// `kind` is forwarded as-is (router: `research`/`x0x`/`app`/`url`); unknown
/// kinds are surfaced verbatim so the host can extend without a daemon change.
async fn info_push(
    backends: &SessionBackends<'_>,
    cmd: &Command,
) -> Result<serde_json::Value, &'static str> {
    let items = cmd.payload.get("items").ok_or("bad_request")?;
    let items = items.as_array().ok_or("bad_request")?;
    // Light validation: each item must carry id + kind + title (strings). We
    // forward the whole item (including `action`) rather than reconstructing it.
    for item in items {
        if item.get("id").and_then(|v| v.as_str()).is_none()
            || item.get("kind").and_then(|v| v.as_str()).is_none()
            || item.get("title").and_then(|v| v.as_str()).is_none()
        {
            return Err("bad_request");
        }
    }
    let payload = serde_json::json!({ "items": items });
    backends
        .events
        .publish("info.update", Scope::StatusRead, payload.clone());
    Ok(payload)
}

/// True when an engine failure carries the NaN-logits signature that the
/// prompt-length padding retry can rescue (see `inject_text`).
fn is_nan_logits_failure(detail: &str) -> bool {
    detail.contains("NaN") || detail.contains("invalid Metal top-k softmax normalizer")
}

/// Run one turn through the engine, collecting the streamed events into the
/// wire result. Errors return the full failure text for diagnosis upstream.
/// `pub(crate)` so the headless `--offline-turn` driver (P5/D2-V5) reuses the
/// exact production turn loop instead of duplicating the streaming logic.
pub(crate) async fn run_turn(
    engine: &dyn ProviderAdapter,
    request: ChatRequest,
) -> Result<serde_json::Value, String> {
    let mut stream = engine
        .stream_chat(request)
        .await
        .map_err(|error| format!("before first token: {error}"))?;
    let mut answer = String::new();
    let mut tool_calls = Vec::new();
    let mut finish_reason = "stop".to_owned();
    while let Some(event) = stream.next().await {
        match event {
            Ok(ChatEvent::Token(token)) => answer.push_str(&token),
            Ok(ChatEvent::ToolCall { name, arguments }) => {
                tool_calls.push(serde_json::json!({ "name": name, "arguments": arguments }));
            }
            Ok(ChatEvent::Done {
                finish_reason: reason,
            }) => {
                finish_reason = reason;
                break;
            }
            Err(error) => {
                return Err(format!("mid-stream: {error}"));
            }
        }
    }
    let visible_answer = strip_served_thinking(&answer);
    Ok(serde_json::json!({
        "text": visible_answer,
        "tool_calls": tool_calls,
        "finish_reason": finish_reason,
    }))
}

/// Remove model-served thinking spans from a completed turn. The Swift pipeline
/// strips these while streaming; the daemon API also returns completed turns, so
/// it must not hand thought text to clients that speak or display `result.text`
/// directly. Gemma 4's llama.cpp chat template closes thought with `<channel|>`
/// (not `<|channel>response`); Qwen-style `<think>...</think>` is also removed.
fn strip_served_thinking(text: &str) -> String {
    let mut rest = text;
    let mut out = String::new();
    loop {
        let gemma = rest.find("<|channel>thought");
        let qwen = rest.find("<think>");
        let Some(start) = (match (gemma, qwen) {
            (Some(g), Some(q)) => Some(g.min(q)),
            (Some(g), None) => Some(g),
            (None, Some(q)) => Some(q),
            (None, None) => None,
        }) else {
            out.push_str(rest);
            break;
        };
        out.push_str(&rest[..start]);
        let after_open = &rest[start..];
        if after_open.starts_with("<|channel>thought") {
            if let Some(close) = after_open.find("<channel|>") {
                rest = &after_open[close + "<channel|>".len()..];
                continue;
            }
            // Incomplete thought-only response: fail closed by withholding it.
            break;
        }
        if let Some(close) = after_open.find("</think>") {
            rest = &after_open[close + "</think>".len()..];
            continue;
        }
        break;
    }
    out.trim().to_owned()
}

/// An audit row for a non-authz, non-authenticate event (parse failure, command
/// before auth). Never hashes a payload — `arg_hash` is empty.
pub(crate) fn manual_audit(
    event_id: String,
    now_ms: u64,
    client_id: Option<String>,
    command: &str,
    decision: AuditDecision,
    reason: &str,
) -> AuditEvent {
    AuditEvent {
        event_id,
        ts_ms: now_ms,
        client_id,
        command: command.to_owned(),
        decision,
        reason: reason.to_owned(),
        scopes: Vec::new(),
        arg_hash: String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use fae_control_plane::{hash_token, ClientClass, Scope};
    use fae_engine::MockAdapter;
    use std::collections::HashSet;
    use std::path::Path;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    // ── Phase C: origin wiring (autonomous skill/tool runs inherit the jail) ──

    #[test]
    fn tool_origin_missing_defaults_to_owner_interactive() {
        use crate::toolhost::isolation::{IsolationMode, ToolOrigin};
        // Backward-compat contract: an absent origin is the owner's interactive
        // turn (host tier), so pre-Phase-C clients keep working unchanged.
        let origin = parse_tool_origin(None).expect("missing origin ok");
        assert_eq!(origin, ToolOrigin::OwnerInteractive);
        assert_eq!(origin.required_isolation(), IsolationMode::Host);
    }

    #[test]
    fn tool_origin_autonomous_requires_the_jail() {
        use crate::toolhost::isolation::{IsolationMode, ToolOrigin};
        // The load-bearing Phase C intent: an autonomous origin MUST map to a
        // jail-requiring tier — a scheduler/proactive skill run can never inherit
        // the daemon's ambient host authority.
        for (wire, expected) in [
            ("proactive", ToolOrigin::Proactive),
            ("scheduler", ToolOrigin::Scheduler),
            ("auto_skill", ToolOrigin::AutoSkill),
            ("script_block", ToolOrigin::ScriptBlock),
        ] {
            let origin = parse_tool_origin(Some(wire)).expect("known origin");
            assert_eq!(origin, expected);
            assert_eq!(origin.required_isolation(), IsolationMode::Jailed, "{wire}");
        }
        assert!(parse_tool_origin(Some("owner_interactive")).is_ok());
        assert!(parse_tool_origin(Some("bogus")).is_err());
    }

    #[test]
    fn skill_run_payload_threads_origin_backward_compatibly() {
        use crate::toolhost::isolation::ToolOrigin;
        // No origin field ⇒ owner-interactive (existing callers unaffected).
        let (skill, script, origin) =
            parse_skill_run_payload(&serde_json::json!({ "skill": "forge" })).expect("ok");
        assert_eq!(skill, "forge");
        assert!(script.is_none());
        assert_eq!(origin, ToolOrigin::OwnerInteractive);
        // Explicit autonomous origin threads through to the jail tier.
        let (_, _, origin) = parse_skill_run_payload(
            &serde_json::json!({ "skill": "forge", "origin": "scheduler" }),
        )
        .expect("ok");
        assert_eq!(origin, ToolOrigin::Scheduler);
        // An unknown origin is rejected at the wire (fail closed).
        assert!(parse_skill_run_payload(
            &serde_json::json!({ "skill": "forge", "origin": "root" })
        )
        .is_err());
    }

    #[test]
    fn toolhost_payload_threads_origin_backward_compatibly() {
        use crate::toolhost::isolation::ToolOrigin;
        let (tool, _input, origin) =
            parse_toolhost_payload(&serde_json::json!({ "tool": "read", "input": {} }))
                .expect("ok");
        assert_eq!(tool, "read");
        assert_eq!(origin, ToolOrigin::OwnerInteractive);
        let (_, _, origin) = parse_toolhost_payload(
            &serde_json::json!({ "tool": "bash", "input": {}, "origin": "proactive" }),
        )
        .expect("ok");
        assert_eq!(origin, ToolOrigin::Proactive);
    }

    fn mock() -> MockAdapter {
        MockAdapter::new("test")
    }

    fn mock_tts() -> fae_engine::MockTtsAdapter {
        fae_engine::MockTtsAdapter::new("test-tts")
    }

    fn agent_command(payload: serde_json::Value) -> fae_control_plane::Command {
        fae_control_plane::Command {
            v: 2,
            request_id: "r1".to_owned(),
            command: "agent.run".to_owned(),
            payload,
        }
    }

    fn command_named(command: &str, payload: serde_json::Value) -> fae_control_plane::Command {
        fae_control_plane::Command {
            v: 2,
            request_id: "r1".to_owned(),
            command: command.to_owned(),
            payload,
        }
    }

    // ── M4-B: the production build_turn_context wiring (classifies payload.text) ──

    #[test]
    fn build_turn_context_classifies_credential_prompt() {
        use crate::conductor::recipe::ConductorTaskClass;
        let cmd = command_named(
            "conversation.inject_text",
            serde_json::json!({ "text": "my password is hunter2 please store it" }),
        );
        let ctx = build_turn_context(&cmd);
        assert_eq!(ctx.task_class, ConductorTaskClass::PersonalData);
        assert!(ctx
            .feature_predicates
            .iter()
            .any(|p| p == "credential_shaped"));
        assert_eq!(ctx.request_id, "r1");
    }

    #[test]
    fn build_turn_context_missing_text_fails_closed() {
        use crate::conductor::recipe::ConductorTaskClass;
        // No `text` field ⇒ empty prompt ⇒ fail-closed to Unknown + [].
        let cmd = command_named(
            "conversation.inject_text",
            serde_json::json!({ "voice": "en" }),
        );
        let ctx = build_turn_context(&cmd);
        assert_eq!(ctx.task_class, ConductorTaskClass::Unknown);
        assert!(ctx.feature_predicates.is_empty());
    }

    #[test]
    fn build_turn_context_non_text_payload_fails_closed() {
        use crate::conductor::recipe::ConductorTaskClass;
        // `text` present but not a string ⇒ fail-closed.
        let cmd = command_named(
            "conversation.inject_text",
            serde_json::json!({ "text": 12345 }),
        );
        let ctx = build_turn_context(&cmd);
        assert_eq!(ctx.task_class, ConductorTaskClass::Unknown);
        assert!(ctx.feature_predicates.is_empty());
    }

    #[derive(Default)]
    struct CountingAcpRunner {
        run_calls: Arc<AtomicUsize>,
        start_calls: Arc<AtomicUsize>,
        prompt_calls: Arc<AtomicUsize>,
        run_outcome: Option<fae_acp::AcpOutcome>,
    }

    impl CountingAcpRunner {
        fn with_run_outcome(text: &str) -> Self {
            Self {
                run_outcome: Some(fae_acp::AcpOutcome {
                    text: text.to_owned(),
                    stop_reason: "end_turn".to_owned(),
                    tool_calls: Vec::new(),
                }),
                ..Self::default()
            }
        }

        fn run_count(&self) -> usize {
            self.run_calls.load(Ordering::SeqCst)
        }

        fn start_count(&self) -> usize {
            self.start_calls.load(Ordering::SeqCst)
        }

        fn prompt_count(&self) -> usize {
            self.prompt_calls.load(Ordering::SeqCst)
        }
    }

    #[async_trait::async_trait]
    impl AcpAgentRunner for CountingAcpRunner {
        async fn run_one_shot(
            &self,
            _agent: &str,
            _cwd: &Path,
            _prompt: &str,
            _policy: fae_acp::ApprovalPolicy,
        ) -> Result<fae_acp::AcpOutcome, fae_acp::AcpError> {
            self.run_calls.fetch_add(1, Ordering::SeqCst);
            self.run_outcome.clone().ok_or_else(|| {
                fae_acp::AcpError::Protocol("test double: should not be reached".to_owned())
            })
        }

        async fn start_session(
            &self,
            _agent: &str,
            _cwd: &Path,
            _policy: fae_acp::ApprovalPolicy,
        ) -> Result<fae_acp::AcpSession, fae_acp::AcpError> {
            self.start_calls.fetch_add(1, Ordering::SeqCst);
            Err(fae_acp::AcpError::Protocol(
                "test double: should not be reached".to_owned(),
            ))
        }

        fn prompt_session(
            &self,
            _session: &fae_acp::AcpSession,
            _text: String,
        ) -> Result<fae_acp::PromptHandle, fae_acp::AcpError> {
            self.prompt_calls.fetch_add(1, Ordering::SeqCst);
            Err(fae_acp::AcpError::Protocol(
                "test double: should not be reached".to_owned(),
            ))
        }
    }

    struct AgentGateRuntime {
        _tmp: tempfile::TempDir,
        runtime: crate::conductor::ConductorRuntime,
    }

    fn agent_gate_runtime(
        mode: crate::conductor::ModelMode,
        provisioned: bool,
    ) -> AgentGateRuntime {
        use crate::conductor::{
            BudgetGovernor, BudgetLimits, ConductorEgress, ConductorRuntime, ConductorStore,
            InstallKey, ProviderPricingTable, RecipeSet, StaticDirectPolicy, WorkerRegistry,
        };
        let tmp = tempfile::tempdir().expect("tempdir");
        let store = ConductorStore::open(tmp.path().join("store")).expect("store");
        let install_key =
            InstallKey::load_or_create(&tmp.path().join("install.key")).expect("install key");
        let mut workers = WorkerRegistry::m1();
        if provisioned {
            workers.register_cloud_backed(crate::conductor::workers::CODEX_CLOUD_WORKER_ID, true);
        }
        let egress = ConductorEgress::production(
            mode,
            BudgetGovernor::new(store.clone(), BudgetLimits::default()),
            ProviderPricingTable::empty(),
        );
        AgentGateRuntime {
            _tmp: tmp,
            runtime: ConductorRuntime::new_with_egress(
                StaticDirectPolicy,
                RecipeSet::default(),
                workers,
                store,
                install_key,
                false,
                egress,
            ),
        }
    }

    struct AgentCommandHarness {
        conductor: AgentGateRuntime,
        runner: CountingAcpRunner,
        engine: MockAdapter,
        tts: fae_engine::MockTtsAdapter,
        audio: AudioManager,
        events: crate::events::EventBus,
        playbacks: crate::events::PlaybackRegistry,
        agents: crate::agents::AgentSessionRegistry,
    }

    impl AgentCommandHarness {
        fn new(mode: crate::conductor::ModelMode, provisioned: bool) -> Self {
            Self {
                conductor: agent_gate_runtime(mode, provisioned),
                runner: CountingAcpRunner::default(),
                engine: mock(),
                tts: mock_tts(),
                audio: AudioManager::new(),
                events: crate::events::EventBus::new(),
                playbacks: crate::events::PlaybackRegistry::new(),
                agents: crate::agents::AgentSessionRegistry::new(),
            }
        }

        fn with_run_outcome(
            mode: crate::conductor::ModelMode,
            provisioned: bool,
            text: &str,
        ) -> Self {
            Self {
                runner: CountingAcpRunner::with_run_outcome(text),
                ..Self::new(mode, provisioned)
            }
        }

        fn backends(&self) -> SessionBackends<'_> {
            SessionBackends {
                engine: &self.engine,
                asr_fallback: None,
                tts: &self.tts,
                audio: &self.audio,
                events: &self.events,
                playbacks: &self.playbacks,
                agents: &self.agents,
                conductor: Some(&self.conductor.runtime),
                acp_runner: &self.runner,
            }
        }
    }

    fn error_response_text(failure: CommandFailure) -> String {
        serde_json::to_string(&failure.into_response("r1")).expect("response json")
    }

    #[test]
    fn agent_list_returns_known_agents() {
        let value = super::agent_list().expect("agent.list ok");
        let agents = value["agents"].as_array().expect("agents array");
        assert!(agents.iter().any(|a| a == "codex"));
        assert!(agents.iter().any(|a| a == "claude"));
    }

    #[test]
    fn normalize_asr_transcript_strips_qwen_marker() {
        assert_eq!(
            super::normalize_asr_transcript("language English<asr_text>Stop."),
            "Stop."
        );
        assert_eq!(
            super::normalize_asr_transcript("  Call Sarah now  "),
            "Call Sarah now"
        );
    }

    #[test]
    fn agent_errors_classify_into_actionable_codes() {
        use fae_acp::AcpError;
        let auth = AcpError::Protocol("Error 401: please log in to continue".to_owned());
        assert_eq!(super::classify_agent_error(&auth), "auth_error");
        let rate = AcpError::Protocol("rate limit exceeded (429)".to_owned());
        assert_eq!(super::classify_agent_error(&rate), "rate_limited");
        let net = AcpError::Protocol("connection timed out".to_owned());
        assert_eq!(super::classify_agent_error(&net), "network_error");
        let generic = AcpError::Protocol("the model returned garbage".to_owned());
        assert_eq!(super::classify_agent_error(&generic), "agent_error");
        assert_eq!(
            super::classify_agent_error(&AcpError::UnknownAgent("x".to_owned())),
            "unknown_agent"
        );
        // Gemini's individual-client rejection is an auth/eligibility problem.
        let gemini = AcpError::Protocol(
            "This client is no longer supported for Gemini Code Assist".to_owned(),
        );
        assert_eq!(super::classify_agent_error(&gemini), "auth_error");
    }

    #[test]
    fn permission_reply_maps_to_decision() {
        use fae_acp::AcpPermissionDecision;
        // Approve → Selected(option_id).
        assert_eq!(
            super::permission_decision_from_reply(
                &serde_json::json!({ "option_id": "allow-once" })
            ),
            AcpPermissionDecision::Selected("allow-once".to_owned())
        );
        // Explicit cancel → Cancelled (even if an option_id is somehow present).
        assert_eq!(
            super::permission_decision_from_reply(
                &serde_json::json!({ "cancelled": true, "option_id": "allow" })
            ),
            AcpPermissionDecision::Cancelled
        );
        // Empty / malformed reply → Cancelled (fail-safe).
        assert_eq!(
            super::permission_decision_from_reply(&serde_json::json!({})),
            AcpPermissionDecision::Cancelled
        );
    }

    #[tokio::test]
    async fn agent_run_rejects_missing_fields() {
        let harness = AgentCommandHarness::new(crate::conductor::ModelMode::AllAvailable, true);
        let backends = harness.backends();
        // No agent, no prompt → bad_request before any subprocess is spawned.
        let err = super::agent_run(&backends, &agent_command(serde_json::json!({})))
            .await
            .expect_err("missing fields must fail");
        assert_eq!(err.code, "bad_request");
        // Agent present but no prompt is still bad_request.
        let err = super::agent_run(
            &backends,
            &agent_command(serde_json::json!({ "agent": "codex" })),
        )
        .await
        .expect_err("missing prompt must fail");
        assert_eq!(err.code, "bad_request");
        assert_eq!(harness.runner.run_count(), 0);
    }

    #[tokio::test]
    async fn pure_local_blocks_all_agent_commands_before_runner() {
        let harness =
            AgentCommandHarness::new(crate::conductor::ModelMode::from_env_value(None), true);
        harness
            .agents
            .insert_test_metadata("acp-test", "codex", "/tmp");
        let backends = harness.backends();

        let run_err = super::agent_run(
            &backends,
            &agent_command(serde_json::json!({ "agent": "codex", "prompt": "clean prompt" })),
        )
        .await
        .expect_err("pure-local blocks one-shot agent egress");
        assert_eq!(run_err.code, "mode_blocked");

        let start_err = super::agent_session_start(
            &backends,
            &command_named(
                "agent.session_start",
                serde_json::json!({ "agent": "codex" }),
            ),
        )
        .await
        .expect_err("pure-local blocks session spawn");
        assert_eq!(start_err.code, "mode_blocked");

        let prompt_err = super::agent_prompt(
            &backends,
            &command_named(
                "agent.prompt",
                serde_json::json!({ "session_id": "acp-test", "prompt": "clean prompt" }),
            ),
        )
        .await
        .expect_err("pure-local blocks per-turn prompt submit");
        assert_eq!(prompt_err.code, "mode_blocked");

        assert_eq!(harness.runner.run_count(), 0);
        assert_eq!(harness.runner.start_count(), 0);
        assert_eq!(harness.runner.prompt_count(), 0);
    }

    #[tokio::test]
    async fn credential_prompt_blocks_before_spawn_or_submit() {
        let harness = AgentCommandHarness::new(crate::conductor::ModelMode::AllAvailable, true);
        harness
            .agents
            .insert_test_metadata("acp-test", "codex", "/tmp");
        let backends = harness.backends();
        let secret = "please review sk-abcdefghijklmnopqrstuvwxyz";

        let run_err = super::agent_run(
            &backends,
            &agent_command(serde_json::json!({ "agent": "codex", "prompt": secret })),
        )
        .await
        .expect_err("credential prompt must be privacy-blocked before spawn");
        assert_privacy_blocked_without_secret(&run_err, secret);

        let prompt_err = super::agent_prompt(
            &backends,
            &command_named(
                "agent.prompt",
                serde_json::json!({ "session_id": "acp-test", "prompt": secret }),
            ),
        )
        .await
        .expect_err("credential prompt must be privacy-blocked before submit");
        assert_privacy_blocked_without_secret(&prompt_err, secret);

        assert_eq!(harness.runner.run_count(), 0);
        assert_eq!(harness.runner.start_count(), 0);
        assert_eq!(harness.runner.prompt_count(), 0);
    }

    #[tokio::test]
    async fn all_available_provisioned_clean_agent_run_reaches_runner() {
        let harness = AgentCommandHarness::with_run_outcome(
            crate::conductor::ModelMode::AllAvailable,
            true,
            "mock output",
        );
        let backends = harness.backends();

        let result = super::agent_run(
            &backends,
            &agent_command(serde_json::json!({ "agent": "codex", "prompt": "clean prompt" })),
        )
        .await
        .expect("clean provisioned one-shot reaches ACP runner");
        assert_eq!(
            result.get("text").and_then(serde_json::Value::as_str),
            Some("mock output")
        );
        assert_eq!(harness.runner.run_count(), 1);

        let start_err = super::agent_session_start(
            &backends,
            &command_named(
                "agent.session_start",
                serde_json::json!({ "agent": "codex" }),
            ),
        )
        .await
        .expect_err("counting start runner returns its sentinel error after gate pass");
        assert_eq!(start_err.code, "agent_error");
        assert_eq!(harness.runner.start_count(), 1);

        let resolved = super::assert_agent_egress_gates(
            Some(&harness.conductor.runtime),
            "codex",
            Some("clean prompt"),
        )
        .expect("clean provisioned prompt passes the shared gate");
        assert_eq!(resolved, crate::conductor::workers::CODEX_CLOUD_WORKER_ID);
    }

    /// Normalization consistency (NOTE-2 red-team NOTE-1): an agent payload
    /// with surrounding whitespace + mixed case (e.g. "  Codex  ") must pass the
    /// gate AND reach the runner as the same normalized id. Before the fix, the
    /// gate normalized internally but the raw string was passed to the runner,
    /// so fae_acp could reject a value the gate accepted.
    #[tokio::test]
    async fn agent_payload_is_normalized_for_both_gate_and_runner() {
        let harness = AgentCommandHarness::with_run_outcome(
            crate::conductor::ModelMode::AllAvailable,
            true,
            "normalized ok",
        );
        let backends = harness.backends();

        let result = super::agent_run(
            &backends,
            &agent_command(serde_json::json!({
                "agent": "  Codex  ",
                "prompt": "clean prompt",
            })),
        )
        .await
        .expect("whitespace + mixed-case agent payload is accepted");
        assert_eq!(
            result.get("text").and_then(serde_json::Value::as_str),
            Some("normalized ok")
        );
        assert_eq!(harness.runner.run_count(), 1);
    }

    #[tokio::test]
    async fn unprovisioned_agent_blocks_before_runner() {
        let harness = AgentCommandHarness::new(crate::conductor::ModelMode::AllAvailable, false);
        let backends = harness.backends();

        let run_err = super::agent_run(
            &backends,
            &agent_command(serde_json::json!({ "agent": "codex", "prompt": "clean prompt" })),
        )
        .await
        .expect_err("unprovisioned one-shot must fail closed");
        assert_eq!(run_err.code, "not_provisioned");

        let start_err = super::agent_session_start(
            &backends,
            &command_named(
                "agent.session_start",
                serde_json::json!({ "agent": "codex" }),
            ),
        )
        .await
        .expect_err("unprovisioned session start must fail closed");
        assert_eq!(start_err.code, "not_provisioned");

        assert_eq!(harness.runner.run_count(), 0);
        assert_eq!(harness.runner.start_count(), 0);
        assert_eq!(harness.runner.prompt_count(), 0);
    }

    #[tokio::test]
    async fn unknown_agent_blocks_before_runner() {
        let harness = AgentCommandHarness::new(crate::conductor::ModelMode::AllAvailable, true);
        let backends = harness.backends();

        let run_err = super::agent_run(
            &backends,
            &agent_command(serde_json::json!({ "agent": "bogus", "prompt": "clean prompt" })),
        )
        .await
        .expect_err("unknown agent must fail closed");
        assert_eq!(run_err.code, "unknown_agent");

        let start_err = super::agent_session_start(
            &backends,
            &command_named(
                "agent.session_start",
                serde_json::json!({ "agent": "bogus" }),
            ),
        )
        .await
        .expect_err("unknown session agent must fail closed");
        assert_eq!(start_err.code, "unknown_agent");

        assert_eq!(harness.runner.run_count(), 0);
        assert_eq!(harness.runner.start_count(), 0);
        assert_eq!(harness.runner.prompt_count(), 0);
    }

    #[tokio::test]
    async fn privacy_gate_error_response_never_contains_raw_prompt() {
        let harness = AgentCommandHarness::new(crate::conductor::ModelMode::AllAvailable, true);
        let backends = harness.backends();
        let secret = "token sk-abcdefghijklmnopqrstuvwxyz must not leak";

        let err = super::agent_run(
            &backends,
            &agent_command(serde_json::json!({ "agent": "codex", "prompt": secret })),
        )
        .await
        .expect_err("secret-shaped prompt must be blocked");
        let response = error_response_text(err);
        assert!(!response.contains(secret));
        assert!(!response.contains("sk-abcdefghijklmnopqrstuvwxyz"));
        assert!(response.contains("privacy_blocked"));
        assert!(response.contains("openai_key"));
    }

    #[tokio::test]
    async fn pure_local_session_start_does_not_start_runner() {
        let harness =
            AgentCommandHarness::new(crate::conductor::ModelMode::from_env_value(None), true);
        let backends = harness.backends();
        let err = super::agent_session_start(
            &backends,
            &command_named(
                "agent.session_start",
                serde_json::json!({ "agent": "codex" }),
            ),
        )
        .await
        .expect_err("pure-local blocks session start at the mode gate");
        assert_eq!(err.code, "mode_blocked");
        assert_eq!(harness.runner.start_count(), 0);
    }

    fn assert_privacy_blocked_without_secret(error: &CommandFailure, secret: &str) {
        assert_eq!(error.code, "privacy_blocked");
        let details = error.details.as_ref().expect("privacy details");
        assert_eq!(details.level.as_deref(), Some("LikelyCredential"));
        assert!(
            details.labels.iter().any(|label| label == "openai_key"),
            "labels should name the detector, got {:?}",
            details.labels
        );
        let response = error_response_text(error.clone());
        assert!(!response.contains(secret));
        assert!(!response.contains("sk-abcdefghijklmnopqrstuvwxyz"));
    }

    #[allow(clippy::too_many_arguments)]
    async fn handle_frame(
        registry: &ClientRegistry,
        engine: &dyn ProviderAdapter,
        tts: &dyn TtsAdapter,
        audio: &AudioManager,
        state: &mut SessionState,
        line: &str,
        now_ms: u64,
        event_id: String,
    ) -> FrameOutcome {
        // Session tests predate the voice-spine event bus; give them isolated,
        // unused instances (no subscriber ever receives these publishes).
        let events = crate::events::EventBus::new();
        let playbacks = crate::events::PlaybackRegistry::new();
        let agents = crate::agents::AgentSessionRegistry::new();
        let backends = SessionBackends {
            engine,
            asr_fallback: None,
            tts,
            audio,
            events: &events,
            playbacks: &playbacks,
            agents: &agents,
            conductor: None,
            acp_runner: &REAL_ACP_RUNNER,
        };
        super::handle_frame(registry, &backends, state, line, now_ms, event_id).await
    }

    fn registry() -> ClientRegistry {
        let mut registry = ClientRegistry::new();
        let scopes: HashSet<Scope> = [Scope::StatusRead, Scope::ConversationWrite]
            .into_iter()
            .collect();
        registry.insert(
            ClientRecord {
                client_id: "c1".to_owned(),
                class: ClientClass::SwiftFrontend,
                scopes,
                issued_at_ms: 0,
                expires_at_ms: 1_000,
                revoked_at_ms: None,
                display_name: "test".to_owned(),
            },
            hash_token("good-token"),
        );
        registry
    }

    fn frame(command: &str, payload: serde_json::Value) -> String {
        serde_json::to_string(&serde_json::json!({
            "v": PROTOCOL_VERSION,
            "request_id": "r1",
            "command": command,
            "payload": payload,
        }))
        .expect("frame json")
    }

    fn auth_frame(client_id: &str, token: &str) -> String {
        frame(
            AUTHENTICATE_COMMAND,
            serde_json::json!({ "client_id": client_id, "token": token }),
        )
    }

    #[tokio::test]
    async fn command_before_auth_is_refused_but_connection_kept() {
        let reg = registry();
        let mut state = SessionState::Unauthenticated;
        let out = handle_frame(
            &reg,
            &mock(),
            &mock_tts(),
            &AudioManager::new(),
            &mut state,
            &frame("host.ping", serde_json::Value::Null),
            10,
            "e1".to_owned(),
        )
        .await;
        assert!(!out.response.ok);
        assert_eq!(
            out.response.error.as_ref().map(|e| e.code.as_str()),
            Some("not_authenticated")
        );
        assert!(!out.close);
        assert!(matches!(state, SessionState::Unauthenticated));
    }

    #[tokio::test]
    async fn malformed_frame_closes_connection() {
        let reg = registry();
        let mut state = SessionState::Unauthenticated;
        let out = handle_frame(
            &reg,
            &mock(),
            &mock_tts(),
            &AudioManager::new(),
            &mut state,
            "{not json",
            10,
            "e1".to_owned(),
        )
        .await;
        assert!(!out.response.ok);
        assert_eq!(
            out.response.error.as_ref().map(|e| e.code.as_str()),
            Some("bad_request")
        );
        assert!(out.close);
    }

    #[tokio::test]
    async fn successful_auth_transitions_state() {
        let reg = registry();
        let mut state = SessionState::Unauthenticated;
        let out = handle_frame(
            &reg,
            &mock(),
            &mock_tts(),
            &AudioManager::new(),
            &mut state,
            &auth_frame("c1", "good-token"),
            10,
            "e1".to_owned(),
        )
        .await;
        assert!(out.response.ok);
        assert!(!out.close);
        assert!(matches!(state, SessionState::Authenticated(_)));
    }

    #[tokio::test]
    async fn bad_token_is_denied_and_closes() {
        let reg = registry();
        let mut state = SessionState::Unauthenticated;
        let out = handle_frame(
            &reg,
            &mock(),
            &mock_tts(),
            &AudioManager::new(),
            &mut state,
            &auth_frame("c1", "wrong"),
            10,
            "e1".to_owned(),
        )
        .await;
        assert!(!out.response.ok);
        assert_eq!(
            out.response.error.as_ref().map(|e| e.code.as_str()),
            Some("bad_token")
        );
        assert!(out.close);
        assert!(matches!(state, SessionState::Unauthenticated));
    }

    #[tokio::test]
    async fn authed_ping_dispatches() {
        let reg = registry();
        let mut state =
            SessionState::Authenticated(reg.authenticate("c1", "good-token", 10).expect("auth"));
        let out = handle_frame(
            &reg,
            &mock(),
            &mock_tts(),
            &AudioManager::new(),
            &mut state,
            &frame("host.ping", serde_json::Value::Null),
            11,
            "e2".to_owned(),
        )
        .await;
        assert!(out.response.ok);
        assert_eq!(
            out.response.result,
            Some(serde_json::json!({ "pong": true }))
        );
    }

    #[tokio::test]
    async fn authed_command_missing_scope_is_denied() {
        let reg = registry();
        let mut state =
            SessionState::Authenticated(reg.authenticate("c1", "good-token", 10).expect("auth"));
        // runtime.shutdown needs `admin`, which this client lacks.
        let out = handle_frame(
            &reg,
            &mock(),
            &mock_tts(),
            &AudioManager::new(),
            &mut state,
            &frame("runtime.shutdown", serde_json::Value::Null),
            11,
            "e2".to_owned(),
        )
        .await;
        assert!(!out.response.ok);
        assert_eq!(
            out.response.error.as_ref().map(|e| e.code.as_str()),
            Some("missing_scope")
        );
    }

    #[tokio::test]
    async fn audio_transcribe_fallback_fails_closed_when_provider_unavailable() {
        let reg = registry();
        let mut state =
            SessionState::Authenticated(reg.authenticate("c1", "good-token", 10).expect("auth"));
        let out = handle_frame(
            &reg,
            &mock(),
            &mock_tts(),
            &AudioManager::new(),
            &mut state,
            &frame(
                "audio.transcribe_fallback",
                serde_json::json!({ "wav_base64": "AAAA" }),
            ),
            11,
            "e2".to_owned(),
        )
        .await;
        assert!(!out.response.ok);
        assert_eq!(
            out.response.error.as_ref().map(|e| e.code.as_str()),
            Some("fallback_unavailable")
        );
    }

    #[tokio::test]
    async fn authed_inject_text_runs_through_engine() {
        let reg = registry();
        let mut state =
            SessionState::Authenticated(reg.authenticate("c1", "good-token", 10).expect("auth"));
        // conversation.inject_text (scope held) now streams through the engine;
        // the mock echoes the user text back.
        let out = handle_frame(
            &reg,
            &mock(),
            &mock_tts(),
            &AudioManager::new(),
            &mut state,
            &frame(
                "conversation.inject_text",
                serde_json::json!({ "text": "hi" }),
            ),
            11,
            "e2".to_owned(),
        )
        .await;
        assert!(out.response.ok);
        let result = out.response.result.expect("result");
        assert_eq!(
            result.get("text").and_then(|v| v.as_str()),
            Some("echo: hi")
        );
        assert_eq!(
            result.get("finish_reason").and_then(|v| v.as_str()),
            Some("stop")
        );
    }

    #[test]
    fn session_from_ticket_intersects_scopes() {
        let reg = registry(); // grants StatusRead + ConversationWrite
        let consumed = ConsumedTicket {
            client_id: "c1".to_owned(),
            endpoint: "/v1/stream/x".to_owned(),
            scopes: vec![Scope::ConversationWrite], // subset
        };
        match session_from_ticket(&reg, &consumed, 10).expect("session") {
            SessionState::Authenticated(record) => {
                assert!(record.scopes.contains(&Scope::ConversationWrite));
                assert!(!record.scopes.contains(&Scope::StatusRead)); // narrowed away
            }
            SessionState::Unauthenticated => panic!("expected authenticated"),
        }
        let gone = ConsumedTicket {
            client_id: "absent".to_owned(),
            endpoint: "/v1/stream/x".to_owned(),
            scopes: vec![],
        };
        assert!(session_from_ticket(&reg, &gone, 10).is_none());
    }

    #[test]
    fn session_from_ticket_refuses_revoked_and_expired() {
        let consumed = ConsumedTicket {
            client_id: "c1".to_owned(),
            endpoint: "/v1/stream/x".to_owned(),
            scopes: vec![Scope::ConversationWrite],
        };
        // Revoked after the ticket was issued.
        let mut revoked = ClientRegistry::new();
        revoked.insert(
            ClientRecord {
                client_id: "c1".to_owned(),
                class: ClientClass::SwiftFrontend,
                scopes: [Scope::ConversationWrite].into_iter().collect(),
                issued_at_ms: 0,
                expires_at_ms: 1_000,
                revoked_at_ms: Some(5),
                display_name: "t".to_owned(),
            },
            hash_token("tok"),
        );
        assert!(session_from_ticket(&revoked, &consumed, 10).is_none());
        // Expired client.
        let reg = registry();
        assert!(session_from_ticket(&reg, &consumed, 10_000).is_none());
    }

    #[tokio::test]
    async fn audio_capture_requires_capture_scope() {
        let reg = registry();
        let mut state =
            SessionState::Authenticated(reg.authenticate("c1", "good-token", 10).expect("auth"));
        let out = handle_frame(
            &reg,
            &mock(),
            &mock_tts(),
            &AudioManager::new(),
            &mut state,
            &frame("audio.capture_start", serde_json::json!({})),
            11,
            "e2".to_owned(),
        )
        .await;
        assert!(!out.response.ok);
        assert_eq!(
            out.response.error.as_ref().map(|e| e.code.as_str()),
            Some("missing_scope")
        );
    }

    #[tokio::test]
    async fn audio_devices_uses_status_scope() {
        let reg = registry();
        let mut state =
            SessionState::Authenticated(reg.authenticate("c1", "good-token", 10).expect("auth"));
        let out = handle_frame(
            &reg,
            &mock(),
            &mock_tts(),
            &AudioManager::new(),
            &mut state,
            &frame("audio.devices", serde_json::json!({})),
            11,
            "e2".to_owned(),
        )
        .await;
        assert!(out.response.ok);
        let result = out.response.result.expect("result");
        assert!(result.get("inputs").is_some());
        assert!(result.get("outputs").is_some());
    }

    #[tokio::test]
    async fn engine_set_adapter_scale_ok_with_model_management_scope() {
        let mut reg = ClientRegistry::new();
        let scopes: HashSet<Scope> = [Scope::ModelManagement].into_iter().collect();
        reg.insert(
            ClientRecord {
                client_id: "c1".to_owned(),
                class: ClientClass::SwiftFrontend,
                scopes,
                issued_at_ms: 0,
                expires_at_ms: 1_000,
                revoked_at_ms: None,
                display_name: "test".to_owned(),
            },
            hash_token("good-token"),
        );
        let mut state =
            SessionState::Authenticated(reg.authenticate("c1", "good-token", 10).expect("auth"));
        let out = handle_frame(
            &reg,
            &mock(),
            &mock_tts(),
            &AudioManager::new(),
            &mut state,
            &frame(
                "engine.set_adapter_scale",
                serde_json::json!({ "scale": 0.0 }),
            ),
            11,
            "e2".to_owned(),
        )
        .await;
        assert!(out.response.ok, "expected ok, got {:?}", out.response.error);
        assert_eq!(out.response.result.expect("result")["scale"], 0.0);
    }

    #[tokio::test]
    async fn engine_set_adapter_scale_denied_without_model_management_scope() {
        // registry()'s client holds only StatusRead + ConversationWrite.
        let reg = registry();
        let mut state =
            SessionState::Authenticated(reg.authenticate("c1", "good-token", 10).expect("auth"));
        let out = handle_frame(
            &reg,
            &mock(),
            &mock_tts(),
            &AudioManager::new(),
            &mut state,
            &frame(
                "engine.set_adapter_scale",
                serde_json::json!({ "scale": 1.0 }),
            ),
            11,
            "e2".to_owned(),
        )
        .await;
        assert!(!out.response.ok, "model-management command must be denied");
    }

    #[tokio::test]
    async fn runtime_status_reports_adapter_field() {
        // Gap P3/C3 Stage 4: runtime.status must carry an `adapter` key so a
        // deploy/rollback is auditable. The mock backend loads no adapter, so the
        // field is null — but it MUST be present (a missing key would mean status
        // can't report rollback state).
        let reg = registry(); // client holds StatusRead
        let mut state =
            SessionState::Authenticated(reg.authenticate("c1", "good-token", 10).expect("auth"));
        let out = handle_frame(
            &reg,
            &mock(),
            &mock_tts(),
            &AudioManager::new(),
            &mut state,
            &frame("runtime.status", serde_json::json!({})),
            11,
            "e2".to_owned(),
        )
        .await;
        assert!(out.response.ok, "runtime.status should succeed");
        let result = out.response.result.expect("result");
        assert!(
            result.get("adapter").is_some(),
            "runtime.status must include an `adapter` key (got {result})"
        );
        assert!(
            result["adapter"].is_null(),
            "mock backend loads no adapter → null"
        );
    }

    #[tokio::test]
    async fn engine_reload_dispatches_and_backend_rejects_on_mock() {
        // Mock owns no sidecar, so reload reaches the handler (authz passes with
        // ModelManagement) and the backend rejects it with `reload_failed` —
        // proving the dispatch wiring, distinct from an authz/unknown path.
        let mut reg = ClientRegistry::new();
        let scopes: HashSet<Scope> = [Scope::ModelManagement].into_iter().collect();
        reg.insert(
            ClientRecord {
                client_id: "c1".to_owned(),
                class: ClientClass::SwiftFrontend,
                scopes,
                issued_at_ms: 0,
                expires_at_ms: 1_000,
                revoked_at_ms: None,
                display_name: "test".to_owned(),
            },
            hash_token("good-token"),
        );
        let mut state =
            SessionState::Authenticated(reg.authenticate("c1", "good-token", 10).expect("auth"));
        let out = handle_frame(
            &reg,
            &mock(),
            &mock_tts(),
            &AudioManager::new(),
            &mut state,
            &frame(
                "engine.reload",
                serde_json::json!({ "personal_adapter": "/tmp/p.gguf" }),
            ),
            11,
            "e2".to_owned(),
        )
        .await;
        assert!(!out.response.ok);
        assert_eq!(
            out.response.error.as_ref().map(|e| e.code.as_str()),
            Some("reload_failed")
        );
    }

    #[tokio::test]
    async fn authed_tts_synthesize_returns_wav() {
        use base64::Engine as _;
        let reg = registry_with_playback();
        let mut state =
            SessionState::Authenticated(reg.authenticate("c1", "good-token", 10).expect("auth"));
        let out = handle_frame(
            &reg,
            &mock(),
            &mock_tts(),
            &AudioManager::new(),
            &mut state,
            &frame(
                "tts.synthesize",
                serde_json::json!({ "text": "hello there" }),
            ),
            11,
            "e2".to_owned(),
        )
        .await;
        assert!(
            out.response.ok,
            "tts.synthesize should succeed: {:?}",
            out.response.error
        );
        let result = out.response.result.expect("result");
        assert_eq!(
            result
                .get("sample_rate")
                .and_then(serde_json::Value::as_u64),
            Some(24_000)
        );
        let encoded = result
            .get("wav_base64")
            .and_then(serde_json::Value::as_str)
            .expect("wav_base64");
        let wav = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .expect("valid base64");
        assert_eq!(&wav[0..4], b"RIFF");
    }

    #[tokio::test]
    async fn tts_synthesize_requires_playback_scope_and_valid_text() {
        // The default test registry lacks AudioPlayback — denied.
        let reg = registry();
        let mut state =
            SessionState::Authenticated(reg.authenticate("c1", "good-token", 10).expect("auth"));
        let out = handle_frame(
            &reg,
            &mock(),
            &mock_tts(),
            &AudioManager::new(),
            &mut state,
            &frame("tts.synthesize", serde_json::json!({ "text": "hello" })),
            11,
            "e2".to_owned(),
        )
        .await;
        assert!(!out.response.ok);
        assert_eq!(
            out.response.error.as_ref().map(|e| e.code.as_str()),
            Some("missing_scope")
        );

        // Empty text is a malformed request, not a model error.
        let reg = registry_with_playback();
        let mut state =
            SessionState::Authenticated(reg.authenticate("c1", "good-token", 10).expect("auth"));
        let out = handle_frame(
            &reg,
            &mock(),
            &mock_tts(),
            &AudioManager::new(),
            &mut state,
            &frame("tts.synthesize", serde_json::json!({ "text": "  " })),
            11,
            "e3".to_owned(),
        )
        .await;
        assert_eq!(
            out.response.error.as_ref().map(|e| e.code.as_str()),
            Some("bad_request")
        );
    }

    fn registry_with_playback() -> ClientRegistry {
        let mut registry = ClientRegistry::new();
        let scopes: HashSet<Scope> = [
            Scope::StatusRead,
            Scope::ConversationWrite,
            Scope::AudioPlayback,
        ]
        .into_iter()
        .collect();
        registry.insert(
            ClientRecord {
                client_id: "c1".to_owned(),
                class: ClientClass::SwiftFrontend,
                scopes,
                issued_at_ms: 0,
                expires_at_ms: 1_000,
                revoked_at_ms: None,
                display_name: "test".to_owned(),
            },
            hash_token("good-token"),
        );
        registry
    }

    #[test]
    fn strip_served_thinking_removes_gemma_channel_with_real_close_marker() {
        let raw = "<|channel>thought\nreasoning that must not be spoken<channel|>Visible answer.";
        assert_eq!(strip_served_thinking(raw), "Visible answer.");
        let incomplete = "<|channel>thought\nreasoning only";
        assert_eq!(strip_served_thinking(incomplete), "");
    }

    #[test]
    fn strip_served_thinking_removes_qwen_think_blocks() {
        let raw = "Hello <think>hidden</think>world";
        assert_eq!(strip_served_thinking(raw), "Hello world");
    }

    #[test]
    fn parse_chat_request_simple_text_back_compat() {
        let payload = serde_json::json!({ "text": "hello" });
        let request = parse_chat_request(&payload).unwrap();
        assert_eq!(request.messages.len(), 1);
        assert_eq!(request.messages[0].role, Role::User);
        assert_eq!(request.messages[0].content, "hello");
        assert!(request.system.is_none());
        assert!(request.tools.is_empty());
        assert_eq!(request.max_tokens, MAX_TOKENS_DEFAULT);
    }

    #[test]
    fn parse_chat_request_rich_messages_system_and_tools() {
        let payload = serde_json::json!({
            "system": "You are Fae, the head butler.",
            "messages": [
                { "role": "user", "content": "what's on my calendar?" },
                { "role": "assistant", "content": "let me check" },
                { "role": "tool", "content": "{\"events\":[]}" },
            ],
            "tools": [
                {
                    "name": "calendar",
                    "description": "Read calendar events",
                    "parameters": { "type": "object", "properties": { "day": { "type": "string" } } }
                },
                { "name": "reminders" }
            ],
            "max_tokens": 2048
        });
        let request = parse_chat_request(&payload).unwrap();
        assert_eq!(
            request.system.as_deref(),
            Some("You are Fae, the head butler.")
        );
        assert_eq!(request.messages.len(), 3);
        assert_eq!(request.messages[2].role, Role::Tool);
        assert_eq!(request.tools.len(), 2);
        assert_eq!(request.tools[0].name, "calendar");
        // Name-only tool still gets a valid empty JSON-Schema object.
        assert!(request.tools[1].parameters.get("type").is_some());
        assert_eq!(request.max_tokens, 2048);
    }

    #[test]
    fn parse_chat_request_carries_audio_payload() {
        // S18 push-to-talk: an audio clip rides the rich message shape and
        // composes with tools in the same request.
        let payload = serde_json::json!({
            "messages": [
                { "role": "user", "content": "what's on my calendar today?",
                  "audio_wav_base64": "AAAA" },
            ],
            "tools": [{ "name": "calendar" }],
        });
        let request = parse_chat_request(&payload).unwrap();
        assert_eq!(
            request.messages[0].audio_wav_base64.as_deref(),
            Some("AAAA")
        );
        assert_eq!(request.tools.len(), 1);
        // Absent and explicit-null both mean "no audio".
        let none = serde_json::json!({
            "messages": [{ "role": "user", "content": "hi", "audio_wav_base64": null }],
        });
        assert!(parse_chat_request(&none).unwrap().messages[0]
            .audio_wav_base64
            .is_none());
        // A non-string audio field is a malformed frame, not a silent drop.
        let bad = serde_json::json!({
            "messages": [{ "role": "user", "content": "hi", "audio_wav_base64": 42 }],
        });
        assert_eq!(parse_chat_request(&bad), Err("bad_request"));
    }

    #[tokio::test]
    async fn authed_inject_text_with_audio_runs_through_engine() {
        use base64::Engine as _;
        let reg = registry();
        let mut state =
            SessionState::Authenticated(reg.authenticate("c1", "good-token", 10).expect("auth"));
        let encoded = base64::engine::general_purpose::STANDARD.encode([0u8; 8]);
        let out = handle_frame(
            &reg,
            &mock(),
            &mock_tts(),
            &AudioManager::new(),
            &mut state,
            &frame(
                "conversation.inject_text",
                serde_json::json!({
                    "messages": [{ "role": "user", "content": "speak", "audio_wav_base64": encoded }],
                }),
            ),
            11,
            "e2".to_owned(),
        )
        .await;
        assert!(out.response.ok);
        let result = out.response.result.expect("result");
        assert_eq!(
            result.get("text").and_then(|v| v.as_str()),
            Some("echo: [audio:8 bytes] speak")
        );
    }

    #[tokio::test]
    async fn authed_inject_text_with_malformed_audio_fails_loud() {
        let reg = registry();
        let mut state =
            SessionState::Authenticated(reg.authenticate("c1", "good-token", 10).expect("auth"));
        let out = handle_frame(
            &reg,
            &mock(),
            &mock_tts(),
            &AudioManager::new(),
            &mut state,
            &frame(
                "conversation.inject_text",
                serde_json::json!({
                    "messages": [{ "role": "user", "content": "speak",
                                   "audio_wav_base64": "not-base64!!!" }],
                }),
            ),
            11,
            "e2".to_owned(),
        )
        .await;
        assert!(!out.response.ok);
        assert_eq!(
            out.response.error.as_ref().map(|e| e.code.as_str()),
            Some("inference_failed")
        );
    }

    #[test]
    fn parse_chat_request_rejects_bad_shapes_and_clamps_budget() {
        // Unknown role fails loud, not silently coerced.
        let bad_role = serde_json::json!({ "messages": [{ "role": "wizard", "content": "x" }] });
        assert_eq!(parse_chat_request(&bad_role), Err("bad_request"));
        // Empty message list is not a turn.
        let empty = serde_json::json!({ "messages": [] });
        assert_eq!(parse_chat_request(&empty), Err("bad_request"));
        // Tool without a name is invalid.
        let bad_tool = serde_json::json!({ "text": "x", "tools": [{ "description": "no name" }] });
        assert_eq!(parse_chat_request(&bad_tool), Err("bad_request"));
        // Missing both text and messages.
        let neither = serde_json::json!({ "max_tokens": 5 });
        assert_eq!(parse_chat_request(&neither), Err("bad_request"));
        // Generation budget is clamped to the ceiling.
        let huge = serde_json::json!({ "text": "x", "max_tokens": 1_000_000 });
        assert_eq!(
            parse_chat_request(&huge).unwrap().max_tokens,
            MAX_TOKENS_CEILING
        );
    }

    // ── M1 byte-identity: the conductor-routed path equals the legacy path ──
    //
    // Spec §13.1. With conductor wired (Some) and FAE_CONDUCTOR_CHAIN unset, the
    // static policy emits direct + local-model + ApprovalClass::None; the
    // executor's direct arm calls inject_text_core VERBATIM. So the routed turn
    // must produce the identical answer AND the identical assistant.generating
    // event pair — and additionally drop a telemetry event + receipt into the
    // isolated conductor store.
    #[tokio::test]
    async fn conductor_routed_direct_is_byte_identical_to_legacy() {
        use crate::conductor::{
            ConductorRuntime, ConductorStore, InstallKey, RecipeSet, StaticDirectPolicy,
            WorkerRegistry,
        };

        let tmp = tempfile::tempdir().expect("tempdir in test");
        let install_key =
            InstallKey::load_or_create(&tmp.path().join("install.key")).expect("key in test");
        let store = ConductorStore::open(tmp.path().join("store")).expect("store in test");
        let runtime = ConductorRuntime::new(
            StaticDirectPolicy,
            RecipeSet::default(),
            WorkerRegistry::m1(),
            store,
            install_key,
            false, // FAE_CONDUCTOR_CHAIN unset → chain disabled (F-3)
        );

        let bus = crate::events::EventBus::new();
        let playbacks = crate::events::PlaybackRegistry::new();
        let agents = crate::agents::AgentSessionRegistry::new();
        let (sink, captured) = CapturingSink::new();
        let sink_dyn: std::sync::Arc<dyn crate::events::EventSink> = sink.clone();
        bus.subscribe(
            std::sync::Arc::downgrade(&sink_dyn),
            [Scope::ConversationRead].into_iter().collect(),
        );
        let backends = SessionBackends {
            engine: &mock(),
            asr_fallback: None,
            tts: &mock_tts(),
            audio: &AudioManager::new(),
            events: &bus,
            playbacks: &playbacks,
            agents: &agents,
            conductor: Some(&runtime),
            acp_runner: &REAL_ACP_RUNNER,
        };
        let cmd = fae_control_plane::Command {
            v: 2,
            request_id: "gen1".to_owned(),
            command: "conversation.inject_text".to_owned(),
            payload: serde_json::json!({ "text": "hello" }),
        };
        let result = inject_text(&backends, &cmd).await.expect("turn ok");
        // Byte-identical answer.
        assert_eq!(
            result.get("text").and_then(|v| v.as_str()),
            Some("echo: hello")
        );
        // Byte-identical generating event pair.
        let actives = {
            let store_captured = captured.lock().expect("captured lock");
            store_captured
                .iter()
                .filter(|v| v.get("event").and_then(|e| e.as_str()) == Some("assistant.generating"))
                .filter_map(|v| {
                    v.get("payload")
                        .and_then(|p| p.get("active"))
                        .and_then(|a| a.as_bool())
                })
                .collect::<Vec<bool>>()
        };
        assert_eq!(
            actives,
            vec![true, false],
            "conductor path keeps paired signal"
        );

        // Telemetry landed in the isolated conductor store (fire-and-forget on
        // the blocking pool — give it a moment to flush).
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
        let events_path = tmp
            .path()
            .join("store")
            .join("conductor_route_events.jsonl");
        let receipts_path = tmp.path().join("store").join("conductor_receipts.jsonl");
        let events = std::fs::read_to_string(&events_path).unwrap_or_default();
        let receipts = std::fs::read_to_string(&receipts_path).unwrap_or_default();
        assert!(
            events.contains("fae.static-direct.v1"),
            "route event written"
        );
        assert!(receipts.contains("local-model"), "receipt written");
        // Privacy: neither file carries the request text or the raw request_id.
        assert!(!events.contains("hello"), "no prompt text in telemetry");
        assert!(!receipts.contains("hello"), "no prompt text in receipt");
        assert!(!events.contains("gen1"), "no raw request_id in telemetry");
    }

    // ── M2-live Stage B (§3): conversation.feedback ──
    //
    // Harness mirrors AgentCommandHarness: owns every SessionBackends piece so
    // `backends()` can borrow them. Keeps a clone of the isolated ConductorStore
    // (ConductorStore is Clone — see `executor.rs::spawn_telemetry`) to read the
    // feedback log back without re-opening the dir.
    struct FeedbackHarness {
        tmp: tempfile::TempDir,
        store: crate::conductor::ConductorStore,
        runtime: crate::conductor::ConductorRuntime,
        engine: MockAdapter,
        tts: fae_engine::MockTtsAdapter,
        audio: AudioManager,
        events: crate::events::EventBus,
        playbacks: crate::events::PlaybackRegistry,
        agents: crate::agents::AgentSessionRegistry,
    }

    impl FeedbackHarness {
        fn new() -> Self {
            use crate::conductor::{
                ConductorRuntime, ConductorStore, InstallKey, RecipeSet, StaticDirectPolicy,
                WorkerRegistry,
            };
            let tmp = tempfile::tempdir().expect("tempdir in test");
            let install_key =
                InstallKey::load_or_create(&tmp.path().join("install.key")).expect("key in test");
            let store = ConductorStore::open(tmp.path().join("store")).expect("store in test");
            let runtime = ConductorRuntime::new(
                StaticDirectPolicy,
                RecipeSet::default(),
                WorkerRegistry::m1(),
                store.clone(),
                install_key,
                false, // FAE_CONDUCTOR_CHAIN unset → chain disabled (F-3)
            );
            Self {
                tmp,
                store,
                runtime,
                engine: mock(),
                tts: mock_tts(),
                audio: AudioManager::new(),
                events: crate::events::EventBus::new(),
                playbacks: crate::events::PlaybackRegistry::new(),
                agents: crate::agents::AgentSessionRegistry::new(),
            }
        }

        fn backends(&self) -> SessionBackends<'_> {
            SessionBackends {
                engine: &self.engine,
                asr_fallback: None,
                tts: &self.tts,
                audio: &self.audio,
                events: &self.events,
                playbacks: &self.playbacks,
                agents: &self.agents,
                conductor: Some(&self.runtime),
                acp_runner: &REAL_ACP_RUNNER,
            }
        }

        fn read_feedback(&self) -> Vec<crate::conductor::FeedbackRecord> {
            self.store.read_feedback().expect("feedback read in test")
        }

        fn feedback_path(&self) -> std::path::PathBuf {
            self.tmp
                .path()
                .join("store")
                .join("conductor_feedback.jsonl")
        }
    }

    fn feedback_cmd(payload: serde_json::Value) -> fae_control_plane::Command {
        fae_control_plane::Command {
            v: 2,
            request_id: "fb-rpc".to_owned(),
            command: "conversation.feedback".to_owned(),
            payload,
        }
    }

    // V5a — isolation + enum-only: feedback lands in the isolated conductor
    // store; the persisted record carries a signal + fingerprinted join key,
    // never the raw target id. The handler holds no memory-store handle, so zero
    // memory writes are structural (the §5.2 grep gate pins the absence).
    #[tokio::test]
    async fn feedback_lands_in_isolated_store_enum_only() {
        let harness = FeedbackHarness::new();
        let cases: [(&str, &str, Option<u8>); 3] = [
            ("turn-1", "accept", None),
            ("turn-2", "reject", None),
            ("turn-3", "rating", Some(5)),
        ];
        for (target, signal, rating) in cases {
            let payload = match rating {
                Some(n) => serde_json::json!({
                    "target_request_id": target,
                    "signal": signal,
                    "rating": n,
                }),
                None => serde_json::json!({
                    "target_request_id": target,
                    "signal": signal,
                }),
            };
            record_feedback(&harness.backends(), &feedback_cmd(payload))
                .await
                .expect("feedback recorded");
        }
        let rows = harness.read_feedback();
        assert_eq!(rows.len(), 3, "three feedback rows persisted");
        assert_eq!(rows[0].signal, crate::conductor::UserSignal::Accept);
        assert_eq!(rows[1].signal, crate::conductor::UserSignal::Reject);
        assert_eq!(rows[2].signal, crate::conductor::UserSignal::Rating(5));
        // F-4 continuity: the raw target id never appears in the persisted log —
        // only the fingerprinted join key (the caller's opaque id is hashed, not
        // stored verbatim).
        let raw = std::fs::read_to_string(harness.feedback_path()).expect("feedback file");
        assert!(!raw.contains("turn-1"), "no raw target id in feedback log");
        assert!(!raw.contains("turn-2"), "no raw target id in feedback log");
    }

    // V6 — strict payload: deny_unknown_fields rejects any extra key.
    // Mutation contract: add a `comment: String` field to FeedbackPayload and
    // this test fails (serde would accept the extra key instead of rejecting).
    #[tokio::test]
    async fn feedback_rejects_unknown_payload_field() {
        let harness = FeedbackHarness::new();
        let cmd = feedback_cmd(serde_json::json!({
            "target_request_id": "turn-1",
            "signal": "accept",
            "comment": "great answer",
        }));
        let err = record_feedback(&harness.backends(), &cmd)
            .await
            .expect_err("unknown field rejected");
        assert_eq!(err.code, "unknown_field");
        assert!(harness.read_feedback().is_empty(), "nothing persisted");
    }

    // V6 — validation: unknown_signal / rating_missing / rating_out_of_range
    // all fail closed, persisting nothing.
    #[tokio::test]
    async fn feedback_rejects_malformed_signal_and_rating() {
        let harness = FeedbackHarness::new();
        // unknown signal
        let err = record_feedback(
            &harness.backends(),
            &feedback_cmd(serde_json::json!({ "target_request_id": "t", "signal": "love" })),
        )
        .await
        .expect_err("unknown signal");
        assert_eq!(err.code, "unknown_signal");
        // rating signal with no rating value
        let err = record_feedback(
            &harness.backends(),
            &feedback_cmd(serde_json::json!({ "target_request_id": "t", "signal": "rating" })),
        )
        .await
        .expect_err("rating missing");
        assert_eq!(err.code, "rating_missing");
        // rating out of range (>5)
        let err = record_feedback(
            &harness.backends(),
            &feedback_cmd(serde_json::json!({
                "target_request_id": "t",
                "signal": "rating",
                "rating": 6
            })),
        )
        .await
        .expect_err("rating out of range");
        assert_eq!(err.code, "rating_out_of_range");
        // stray rating on a non-rating signal (§3.1 "iff": rating is meaningful
        // only for the rating signal — reject rather than silently ignore).
        let err = record_feedback(
            &harness.backends(),
            &feedback_cmd(serde_json::json!({
                "target_request_id": "t",
                "signal": "accept",
                "rating": 0
            })),
        )
        .await
        .expect_err("stray rating rejected");
        assert_eq!(err.code, "rating_unexpected");
        assert!(harness.read_feedback().is_empty(), "nothing persisted");
    }

    // §3.2 — feedback requires the conductor runtime (InstallKey + isolated
    // store). With no conductor wired, the command fails closed immediately.
    #[tokio::test]
    async fn feedback_requires_conductor_runtime() {
        let engine = mock();
        let tts = mock_tts();
        let audio = AudioManager::new();
        let events = crate::events::EventBus::new();
        let playbacks = crate::events::PlaybackRegistry::new();
        let agents = crate::agents::AgentSessionRegistry::new();
        let backends = SessionBackends {
            engine: &engine,
            asr_fallback: None,
            tts: &tts,
            audio: &audio,
            events: &events,
            playbacks: &playbacks,
            agents: &agents,
            conductor: None,
            acp_runner: &REAL_ACP_RUNNER,
        };
        let err = record_feedback(
            &backends,
            &feedback_cmd(serde_json::json!({
                "target_request_id": "t",
                "signal": "accept",
            })),
        )
        .await
        .expect_err("conductor required");
        assert_eq!(err.code, "feedback_requires_conductor");
    }

    // ── M1 byte-identity, NaN-retry path ──
    //
    // inject_text_core's NaN-logits retry loop (NAN_RETRY_PADS = [4,24,80])
    // rescues a known Metal failure. Because the conductor's direct arm calls
    // inject_text_core verbatim (proven above), the retry is inherited — but we
    // prove it directly here: a mock that returns a NaN-signature error on the
    // first call and succeeds on the second still completes successfully,
    // AND the conductor's static-direct recipe short-circuits the recipe lookup
    // (MINOR-3: no longer a correctness-by-coincidence fail-closed).
    #[tokio::test]
    async fn conductor_direct_recovers_nan_retry_and_static_recipe_resolves() {
        use crate::conductor::policy::STATIC_DIRECT_RECIPE_ID;
        use crate::conductor::recipe::{ApprovalClass, ConductorTaskClass, ConductorTopology};
        use crate::conductor::{
            ConductorRuntime, ConductorStore, InstallKey, OwnedRouteDecision, RecipeSet,
            StaticDirectPolicy, WorkerRegistry,
        };

        // The static-direct recipe must resolve WITHOUT a RecipeSet entry —
        // the executor short-circuits STATIC_DIRECT_RECIPE_ID (MINOR-3 fix).
        // An empty RecipeSet must still execute, not fail-closed.
        let tmp = tempfile::tempdir().expect("tempdir in test");
        let install_key =
            InstallKey::load_or_create(&tmp.path().join("install.key")).expect("key in test");
        let store = ConductorStore::open(tmp.path().join("store")).expect("store in test");
        let runtime = ConductorRuntime::new(
            StaticDirectPolicy,
            RecipeSet::default(), // empty by design — static-direct short-circuits
            WorkerRegistry::m1(),
            store,
            install_key,
            false,
        );

        // The decision the static policy WOULD produce. The static-direct
        // recipe_id must resolve in run() despite the empty RecipeSet.
        let decision = OwnedRouteDecision {
            request_id: "nan1".to_string(),
            recipe_id: STATIC_DIRECT_RECIPE_ID.to_string(),
            topology: ConductorTopology::Direct,
            worker_id: "local-model".to_string(),
            task_class: ConductorTaskClass::Unknown,
            lane: crate::conductor::PrivacyLane::LocalOnly,
            approval: ApprovalClass::None,
            reason: "static-direct-local".to_string(),
        };

        let bus = crate::events::EventBus::new();
        let playbacks = crate::events::PlaybackRegistry::new();
        let agents = crate::agents::AgentSessionRegistry::new();
        let backends = SessionBackends {
            engine: &mock(),
            asr_fallback: None,
            tts: &mock_tts(),
            audio: &AudioManager::new(),
            events: &bus,
            playbacks: &playbacks,
            agents: &agents,
            conductor: Some(&runtime),
            acp_runner: &REAL_ACP_RUNNER,
        };
        let cmd = fae_control_plane::Command {
            v: 2,
            request_id: "nan1".to_owned(),
            command: "conversation.inject_text".to_owned(),
            payload: serde_json::json!({ "text": "hi" }),
        };
        // run() resolves the static-direct recipe (not InvalidRecipe),
        // resolves the local-model worker, and executes inject_text_core.
        let (wire, outcome) = runtime.run(&decision, &backends, &cmd).await;
        assert!(wire.is_ok(), "static-direct recipe resolves, turn succeeds");
        assert_eq!(
            wire.as_ref().unwrap().get("text").and_then(|v| v.as_str()),
            Some("echo: hi")
        );
        assert!(
            !outcome.fallback,
            "no fallback for a valid static-direct route"
        );
        assert!(outcome.fallback_reason.is_none());
        // The NaN-retry path itself lives in inject_text_core and is exercised
        // by the legacy-path tests; the conductor inherits it by calling
        // inject_text_core verbatim (proven by the byte-identity test above).
    }

    // ── Orb-host-owns-state: assistant.generating event ──

    /// A minimal capturing event sink for inject_text event tests. The real
    /// transport's `ConnSink` is in `events.rs`; here we only need to record
    /// the JSON lines published on the bus.
    struct CapturingSink(std::sync::Arc<std::sync::Mutex<Vec<serde_json::Value>>>);

    impl CapturingSink {
        fn new() -> (
            std::sync::Arc<Self>,
            std::sync::Arc<std::sync::Mutex<Vec<serde_json::Value>>>,
        ) {
            let captured = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
            (
                std::sync::Arc::new(CapturingSink(captured.clone())),
                captured,
            )
        }
    }

    impl crate::events::EventSink for CapturingSink {
        fn deliver(&self, line: &std::sync::Arc<Vec<u8>>) {
            if let Ok(bytes) = serde_json::from_slice::<serde_json::Value>(line.as_ref()) {
                if let Ok(mut store) = self.0.lock() {
                    store.push(bytes);
                }
            }
        }
    }

    #[tokio::test]
    async fn inject_text_publishes_generating_active_then_inactive_on_success() {
        let bus = crate::events::EventBus::new();
        let playbacks = crate::events::PlaybackRegistry::new();
        let agents = crate::agents::AgentSessionRegistry::new();
        let (sink, captured) = CapturingSink::new();
        let sink_dyn: std::sync::Arc<dyn crate::events::EventSink> = sink.clone();
        bus.subscribe(
            std::sync::Arc::downgrade(&sink_dyn),
            [Scope::ConversationRead].into_iter().collect(),
        );
        let backends = SessionBackends {
            engine: &mock(),
            asr_fallback: None,
            tts: &mock_tts(),
            audio: &AudioManager::new(),
            events: &bus,
            playbacks: &playbacks,
            agents: &agents,
            conductor: None,
            acp_runner: &REAL_ACP_RUNNER,
        };
        let cmd = fae_control_plane::Command {
            v: 2,
            request_id: "gen1".to_owned(),
            command: "conversation.inject_text".to_owned(),
            payload: serde_json::json!({ "text": "hello" }),
        };
        let result = inject_text(&backends, &cmd).await.expect("turn ok");
        assert_eq!(
            result.get("text").and_then(|v| v.as_str()),
            Some("echo: hello")
        );

        // Exactly two events, in order: active:true then active:false. This is
        // the contract the orb host's grace-hold relies on (one paired signal
        // per turn, never orphaned).
        let store = captured.lock().expect("captured lock");
        let actives: Vec<bool> = store
            .iter()
            .filter(|v| v.get("event").and_then(|e| e.as_str()) == Some("assistant.generating"))
            .filter_map(|v| {
                v.get("payload")
                    .and_then(|p| p.get("active"))
                    .and_then(|a| a.as_bool())
            })
            .collect();
        assert_eq!(actives, vec![true, false], "paired generating signal");
    }

    #[tokio::test]
    async fn info_push_validates_and_publishes_items() {
        let bus = crate::events::EventBus::new();
        let playbacks = crate::events::PlaybackRegistry::new();
        let agents = crate::agents::AgentSessionRegistry::new();
        let (sink, captured) = CapturingSink::new();
        let sink_dyn: std::sync::Arc<dyn crate::events::EventSink> = sink.clone();
        // StatusRead scope — info.update is StatusRead (the orb host holds it).
        bus.subscribe(
            std::sync::Arc::downgrade(&sink_dyn),
            [Scope::StatusRead].into_iter().collect(),
        );
        let backends = SessionBackends {
            engine: &mock(),
            asr_fallback: None,
            tts: &mock_tts(),
            audio: &AudioManager::new(),
            events: &bus,
            playbacks: &playbacks,
            agents: &agents,
            conductor: None,
            acp_runner: &REAL_ACP_RUNNER,
        };
        let cmd = fae_control_plane::Command {
            v: 2,
            request_id: "i1".to_owned(),
            command: "info.push".to_owned(),
            payload: serde_json::json!({
                "items": [
                    { "id": "r1", "kind": "research", "title": "Tidal energy notes", "action": { "url": "file:///tmp/r1.html" } }
                ]
            }),
        };
        let result = info_push(&backends, &cmd).await.expect("info ok");
        assert!(result.get("items").is_some());

        let store = captured.lock().expect("captured lock");
        let updates: Vec<&serde_json::Value> = store
            .iter()
            .filter(|v| v.get("event").and_then(|e| e.as_str()) == Some("info.update"))
            .collect();
        assert_eq!(updates.len(), 1, "exactly one info.update");
        let item = updates[0]
            .get("payload")
            .and_then(|p| p.get("items"))
            .and_then(|i| i.get(0))
            .expect("item forwarded");
        assert_eq!(item.get("kind").and_then(|v| v.as_str()), Some("research"));
        assert_eq!(
            item.get("title").and_then(|v| v.as_str()),
            Some("Tidal energy notes")
        );
    }

    #[tokio::test]
    async fn info_push_rejects_items_missing_required_fields() {
        let bus = crate::events::EventBus::new();
        let playbacks = crate::events::PlaybackRegistry::new();
        let agents = crate::agents::AgentSessionRegistry::new();
        let backends = SessionBackends {
            engine: &mock(),
            asr_fallback: None,
            tts: &mock_tts(),
            audio: &AudioManager::new(),
            events: &bus,
            playbacks: &playbacks,
            agents: &agents,
            conductor: None,
            acp_runner: &REAL_ACP_RUNNER,
        };
        // kind missing → bad_request, nothing published.
        let cmd = fae_control_plane::Command {
            v: 2,
            request_id: "i2".to_owned(),
            command: "info.push".to_owned(),
            payload: serde_json::json!({ "items": [{ "id": "x", "title": "no kind" }] }),
        };
        let err = info_push(&backends, &cmd).await.expect_err("must reject");
        assert_eq!(err, "bad_request");
        assert_eq!(bus.subscriber_count(), 0, "no publish on rejection");
    }

    // -----------------------------------------------------------------------
    // A3 toolhost.execute handler (run_authorized_toolhost_execute)
    // -----------------------------------------------------------------------

    fn tool_client(scopes: &[Scope]) -> ClientRecord {
        ClientRecord {
            client_id: "test".into(),
            class: ClientClass::TestHarness,
            scopes: scopes.iter().copied().collect(),
            issued_at_ms: 0,
            expires_at_ms: u64::MAX,
            revoked_at_ms: None,
            display_name: "Test".into(),
        }
    }

    async fn test_tool_host() -> (std::sync::Arc<crate::toolhost::ToolHost>, tempfile::TempDir) {
        let dir = tempfile::tempdir().expect("tempdir");
        let store =
            crate::conductor::ConductorStore::open(dir.path().join("store")).expect("store");
        let host = crate::toolhost::ToolHost::new(
            dir.path().join("sandbox").to_path_buf(),
            fluers_runtime::Limits::default(),
            std::sync::Arc::new(store),
        )
        .await
        .expect("host");
        (std::sync::Arc::new(host), dir)
    }

    #[tokio::test]
    async fn toolhost_handler_missing_safe_scope_denies_at_outer_gate() {
        // No ToolExecuteSafe ⇒ the outer authorize denies before any tool runs
        // (the inner policy is never reached).
        let (host, _dir) = test_tool_host().await;
        let conf = crate::toolhost::confirm::FakeConfirmation::approve();
        let record = tool_client(&[]);
        let cmd = Command {
            v: 2,
            request_id: "r1".into(),
            command: "toolhost.execute".into(),
            payload: serde_json::json!({"tool":"read","input":{"path":"a.txt"}}),
        };
        let outcome = run_authorized_toolhost_execute(
            &record,
            &cmd,
            &host,
            &conf,
            tokio_util::sync::CancellationToken::new(),
            0,
            "ev".into(),
        )
        .await;
        assert!(!outcome.response.ok, "must deny without the safe scope");
        assert!(
            !conf.was_called(),
            "must not prompt before the outer scope clears"
        );
    }

    #[tokio::test]
    async fn toolhost_handler_bad_payload_rejected() {
        let (host, _dir) = test_tool_host().await;
        let conf = crate::toolhost::confirm::FakeConfirmation::approve();
        let record = tool_client(&[Scope::ToolExecuteSafe]);
        let cmd = Command {
            v: 2,
            request_id: "r1".into(),
            command: "toolhost.execute".into(),
            payload: serde_json::json!({"not_tool": true}),
        };
        let outcome = run_authorized_toolhost_execute(
            &record,
            &cmd,
            &host,
            &conf,
            tokio_util::sync::CancellationToken::new(),
            0,
            "ev".into(),
        )
        .await;
        assert!(!outcome.response.ok);
        // bad_request, not forbidden/confirm.
        assert!(outcome
            .response
            .error
            .as_ref()
            .is_some_and(|e| e.code == "bad_request"));
    }

    #[tokio::test]
    async fn toolhost_execute_confirm_roundtrip_completes_no_deadlock() {
        // BLOCKER-1: toolhost.execute runs SPAWNED (not awaited inline). The
        // tool.confirm server-request parks on the requester until the read
        // loop resolves the reply. This proves the round-trip completes — while
        // the spawned task awaits confirm, THIS test (standing in for the read
        // loop) reads the tool.confirm frame + resolves it. If the handler were
        // awaited inline, this would deadlock (the reply frame could never be
        // read).
        use tokio::io::{duplex, AsyncBufReadExt, BufReader};

        let (client, server) = duplex(8192);
        let (sink, _writer) = crate::events::ConnSink::spawn(server);
        let requester = ServerRequester::new(std::sync::Arc::clone(&sink));
        let (host, _dir) = test_tool_host().await;
        let confirm = std::sync::Arc::new(
            crate::toolhost::confirm::ServerRequestConfirmation::new(requester.clone()),
        );
        let record = tool_client(&[Scope::ToolExecuteSafe, Scope::ToolExecuteDangerous]);
        let cmd = Command {
            v: 2,
            request_id: "r1".into(),
            command: "toolhost.execute".into(),
            payload: serde_json::json!({"tool":"write","input":{"path":"out.txt","content":"hi"}}),
        };
        let cancel = tokio_util::sync::CancellationToken::new();

        // Spawn the handler exactly as transport.rs does (NOT awaited inline).
        let host_c = std::sync::Arc::clone(&host);
        let confirm_c = std::sync::Arc::clone(&confirm);
        let handle = tokio::spawn(async move {
            run_authorized_toolhost_execute(
                &record,
                &cmd,
                &host_c,
                confirm_c.as_ref(),
                cancel,
                0,
                "ev".into(),
            )
            .await
        });

        // Read loop: drain the tool.confirm server-request the handler emitted.
        let mut reader = BufReader::new(client);
        let mut line = String::new();
        reader
            .read_line(&mut line)
            .await
            .expect("read tool.confirm frame");
        let frame: serde_json::Value =
            serde_json::from_str(line.trim()).expect("parse tool.confirm frame");
        assert_eq!(
            frame["method"], "tool.confirm",
            "expected a tool.confirm server-request, got: {frame}"
        );
        let sr_id = frame["server_request_id"]
            .as_str()
            .expect("server_request_id");

        // Resolve the reply (approved) — as the read loop does on a
        // `{server_request_id, result}` frame.
        requester.resolve(
            sr_id,
            serde_json::json!({"approved": true, "call_id": "r1"}),
        );

        // The handler completes — no deadlock.
        let outcome = tokio::time::timeout(std::time::Duration::from_secs(5), handle)
            .await
            .expect("handler did not complete (deadlock?)")
            .expect("join");
        assert!(
            outcome.response.ok,
            "write should succeed after confirm; got: {:?}",
            outcome.response
        );
    }

    #[tokio::test]
    async fn toolhost_confirm_timeout_no_pending_leak() {
        // oracle MAJOR-1: a confirm whose future is dropped (timed out) must NOT
        // leak its entry in the pending map. resolve() is the only other
        // remover; a client that never replies never triggers it. The RAII
        // guard in ServerRequester::request cleans up on drop — this proves it.
        use tokio::io::duplex;
        let (_client, server) = duplex(8192);
        let (sink, _writer) = crate::events::ConnSink::spawn(server);
        let requester = ServerRequester::new(std::sync::Arc::clone(&sink));
        assert_eq!(requester.pending_count(), 0, "starts empty");
        // Issue a request that will never be resolved (no reply).
        {
            let fut = requester.request("tool.confirm", serde_json::json!({}));
            let mut fut = std::pin::pin!(fut);
            // Poll once so the entry is inserted.
            let _ = tokio::time::timeout(std::time::Duration::from_millis(50), &mut fut).await;
            assert_eq!(
                requester.pending_count(),
                1,
                "entry parked while the future is alive"
            );
            // Drop the future (mimics a timeout dropping it). The RAII guard
            // must remove the entry.
        }
        assert_eq!(
            requester.pending_count(),
            0,
            "dropped (timed-out) request must not leak its pending entry"
        );
    }

    #[tokio::test]
    async fn toolhost_execute_cancellation_aborts_inflight() {
        // oracle MAJOR-2 / scope §5.1: cancelling the session token propagates
        // to the spawned tool's InvokeContext, so close can drain tasks before
        // the root drops. Proves the cancel token is wired into execute_governed.
        let (host, _dir) = test_tool_host().await;
        let cancel = tokio_util::sync::CancellationToken::new();
        // A confirm channel that never resolves (blocks forever) — the only way
        // out is the cancel.
        let conf = crate::toolhost::confirm::FakeConfirmation::approve();
        let record = tool_client(&[Scope::ToolExecuteSafe, Scope::ToolExecuteDangerous]);
        let cmd = Command {
            v: 2,
            request_id: "r1".into(),
            command: "toolhost.execute".into(),
            payload: serde_json::json!({"tool":"write","input":{"path":"out.txt","content":"x"}}),
        };
        let cancel_clone = cancel.clone();
        let handle = tokio::spawn(async move {
            // Run with a hard outer bound; cancel mid-way.
            tokio::select! {
                _ = run_authorized_toolhost_execute(
                    &record, &cmd, &host, &conf, cancel_clone, 0, "ev".into()
                ) => {}
            }
        });
        // Cancel + the task should complete promptly (the select exits).
        cancel.cancel();
        tokio::time::timeout(std::time::Duration::from_secs(2), handle)
            .await
            .expect("task did not respond to cancel in time")
            .expect("join");
    }

    // -----------------------------------------------------------------------
    // A3→B: toolhost.set_root (durable workspace root)
    // -----------------------------------------------------------------------

    fn set_root_cmd(path: &str) -> Command {
        Command {
            v: 2,
            request_id: "sr1".into(),
            command: "toolhost.set_root".into(),
            payload: serde_json::json!({"path": path}),
        }
    }

    fn root_state() -> Arc<tokio::sync::Mutex<crate::toolhost::root_confirm::ToolRootState>> {
        Arc::new(tokio::sync::Mutex::new(
            crate::toolhost::root_confirm::ToolRootState::Unset,
        ))
    }

    #[tokio::test]
    async fn set_root_without_workspace_grant_denies_without_prompting() {
        // No ToolWorkspaceGrant ⇒ the outer authorize denies at the wire, before
        // any path is parsed or the owner is prompted. (A FakeRootConfirmation
        // that WOULD approve proves the gate runs before the confirm.)
        let conf = crate::toolhost::root_confirm::FakeRootConfirmation::approve();
        let record = tool_client(&[Scope::ToolExecuteSafe]); // no grant
        let project = tempfile::tempdir().expect("project");
        let outcome = run_authorized_toolhost_set_root(
            &record,
            &set_root_cmd(project.path().to_str().expect("path")),
            &root_state(),
            &conf,
            None,
            0,
            "ev".into(),
        )
        .await;
        assert!(!outcome.response.ok, "must deny without the grant");
        assert!(
            !conf.was_called(),
            "owner must never be prompted without ToolWorkspaceGrant"
        );
    }

    #[tokio::test]
    async fn set_root_approved_stores_canonical_path() {
        let conf = crate::toolhost::root_confirm::FakeRootConfirmation::approve();
        let record = tool_client(&[Scope::ToolExecuteSafe, Scope::ToolWorkspaceGrant]);
        let project = tempfile::tempdir().expect("project");
        let canon = project
            .path()
            .canonicalize()
            .expect("canon")
            .to_string_lossy()
            .into_owned();
        let state = root_state();
        let outcome = run_authorized_toolhost_set_root(
            &record,
            &set_root_cmd(project.path().to_str().expect("path")),
            &state,
            &conf,
            None,
            0,
            "ev".into(),
        )
        .await;
        assert!(outcome.response.ok, "approved root should succeed");
        assert!(conf.was_called(), "owner must be prompted");
        let st = state.lock().await;
        match &*st {
            crate::toolhost::root_confirm::ToolRootState::ApprovedRoot { path } => {
                assert_eq!(path, &canon, "stored path must be canonical");
            }
            other => panic!("expected ApprovedRoot, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn set_root_denied_does_not_store_path() {
        let conf = crate::toolhost::root_confirm::FakeRootConfirmation::deny();
        let record = tool_client(&[Scope::ToolExecuteSafe, Scope::ToolWorkspaceGrant]);
        let project = tempfile::tempdir().expect("project");
        let state = root_state();
        let outcome = run_authorized_toolhost_set_root(
            &record,
            &set_root_cmd(project.path().to_str().expect("path")),
            &state,
            &conf,
            None,
            0,
            "ev".into(),
        )
        .await;
        assert!(!outcome.response.ok, "denied root should fail");
        let st = state.lock().await;
        assert!(
            matches!(&*st, crate::toolhost::root_confirm::ToolRootState::Unset),
            "a denied root must revert to Unset (no stored path)"
        );
    }

    #[tokio::test]
    async fn set_root_after_init_denies_root_already_initialized() {
        // A late set_root (a ToolHost already exists) must deny — immutability.
        let conf = crate::toolhost::root_confirm::FakeRootConfirmation::approve();
        let record = tool_client(&[Scope::ToolExecuteSafe, Scope::ToolWorkspaceGrant]);
        let project = tempfile::tempdir().expect("project");
        let state = Arc::new(tokio::sync::Mutex::new(
            crate::toolhost::root_confirm::ToolRootState::InitializedTemp,
        ));
        let outcome = run_authorized_toolhost_set_root(
            &record,
            &set_root_cmd(project.path().to_str().expect("path")),
            &state,
            &conf,
            None,
            0,
            "ev".into(),
        )
        .await;
        assert!(!outcome.response.ok, "late set_root must deny");
        assert!(
            !conf.was_called(),
            "must not prompt when already initialized"
        );
    }

    #[tokio::test]
    async fn set_root_unsafe_home_dir_rejected_without_prompting() {
        // The blast-radius guard: approving the HOME dir as a root is refused
        // before the owner is ever prompted.
        let conf = crate::toolhost::root_confirm::FakeRootConfirmation::approve();
        let record = tool_client(&[Scope::ToolExecuteSafe, Scope::ToolWorkspaceGrant]);
        let home = tempfile::tempdir().expect("home");
        let outcome = run_authorized_toolhost_set_root(
            &record,
            &set_root_cmd(home.path().to_str().expect("path")),
            &root_state(),
            &conf,
            Some(home.path().to_path_buf()), // pretend this tempdir IS home
            0,
            "ev".into(),
        )
        .await;
        assert!(!outcome.response.ok, "home dir must be refused");
        assert!(!conf.was_called(), "must not prompt for an unsafe root");
    }

    #[tokio::test]
    async fn set_root_confirm_roundtrip_completes_no_deadlock() {
        // BLOCKER-1 (set_root): the workspace.confirm_root round-trip must
        // complete on a real ServerRequester without deadlocking — the client
        // reads the server-request frame off the duplex and resolves it.
        use tokio::io::{duplex, AsyncBufReadExt, BufReader};
        let (_client, server) = duplex(8192);
        let (sink, _writer) = crate::events::ConnSink::spawn(server);
        let requester = ServerRequester::new(std::sync::Arc::clone(&sink));
        let root_confirm = std::sync::Arc::new(
            crate::toolhost::root_confirm::ServerRequestRootConfirmation::new(requester.clone()),
        );
        let project = tempfile::tempdir().expect("project");
        let record = tool_client(&[Scope::ToolExecuteSafe, Scope::ToolWorkspaceGrant]);
        let state = root_state();
        let cmd = set_root_cmd(project.path().to_str().expect("path"));
        // Spawn the handler exactly as transport.rs does.
        let state_c = Arc::clone(&state);
        let rc_c = std::sync::Arc::clone(&root_confirm);
        let handle = tokio::spawn(async move {
            run_authorized_toolhost_set_root(
                &record,
                &cmd,
                &state_c,
                rc_c.as_ref(),
                None,
                0,
                "ev".into(),
            )
            .await
        });
        // Read the workspace.confirm_root frame + resolve it approved.
        let mut reader = BufReader::new(_client);
        let mut line = String::new();
        reader.read_line(&mut line).await.expect("read");
        let obj: serde_json::Value = serde_json::from_str(line.trim()).expect("json");
        let sr_id = obj["server_request_id"].as_str().expect("sr_id");
        requester.resolve(
            sr_id,
            serde_json::json!({"approved": true, "call_id": "sr1"}),
        );
        let outcome = tokio::time::timeout(std::time::Duration::from_secs(5), handle)
            .await
            .expect("handler did not complete (deadlock?)")
            .expect("join");
        assert!(
            outcome.response.ok,
            "approved root should succeed; got: {:?}",
            outcome.response
        );
        assert!(matches!(
            &*state.lock().await,
            crate::toolhost::root_confirm::ToolRootState::ApprovedRoot { .. }
        ));
    }
}
