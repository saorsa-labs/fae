//! Per-connection session logic — **pure**, no sockets.
//!
//! The transport shell ([`crate::transport`]) reads one NDJSON frame, calls
//! [`handle_frame`], persists the returned audit row, writes the response, and
//! optionally closes. All authentication + authorization + dispatch decisions
//! live here so the whole frame lifecycle is unit-testable without a socket —
//! the same control-plane-first discipline the workspace was built on.

use fae_audio::AudioManager;
use fae_control_plane::{
    authorize, AuditDecision, AuditEvent, AuthzDecision, ClientRecord, ClientRegistry, Command,
    ConsumedTicket, Response, Scope, AUTHENTICATE_COMMAND, PROTOCOL_VERSION,
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
            Err(code) => Response::error(&cmd.request_id, code, "command could not be completed"),
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

/// Command dispatch. Read-only `host`/`runtime` status, plus
/// `conversation.inject_text` through the engine (chunk 3c). Everything else is
/// authorized-but-unimplemented (fail loud, not a silent success).
async fn dispatch(
    backends: &SessionBackends<'_>,
    cmd: &Command,
) -> Result<serde_json::Value, &'static str> {
    match cmd.command.as_str() {
        "host.ping" => Ok(serde_json::json!({ "pong": true })),
        "host.version" => {
            Ok(serde_json::json!({ "version": DAEMON_VERSION, "protocol": PROTOCOL_VERSION }))
        }
        "runtime.status" => {
            let info = backends.engine.describe();
            let tts_info = backends.tts.describe();
            Ok(serde_json::json!({
                "status": "ok",
                "engine": { "backend": info.backend, "model_id": info.model_id },
                "tts": { "backend": tts_info.backend, "model_id": tts_info.model_id },
            }))
        }
        "conversation.inject_text" => inject_text(backends, cmd).await,
        "audio.transcribe_fallback" => transcribe_fallback(backends, cmd).await,
        // Open this connection's server-push event stream (voice spine V2). The
        // ack is the signal the transport uses to register the connection's sink
        // as a subscriber; events (e.g. `audio.level`) are then pushed to it,
        // filtered by the scopes it was granted. ConversationRead is enforced by
        // `authorize` before dispatch.
        "conversation.subscribe" => Ok(serde_json::json!({ "subscribed": true })),
        "tts.synthesize" => synthesize_tts(backends.tts, cmd).await,
        // Voice spine V3a: synthesize + play in the daemon, non-blocking, with
        // the playback level streamed on the event bus to subscribers.
        "tts.speak" => speak_tts(backends, cmd).await,
        "audio.devices" => audio_devices(backends.audio).await,
        "audio.capture_start" | "audio.start_capture" => audio_capture_start(backends.audio).await,
        "audio.capture_stop" | "audio.stop_capture" => {
            audio_capture_stop(backends.audio, cmd).await
        }
        "audio.play" | "audio.playback_control" => audio_play(backends.audio, cmd).await,
        // Voice spine V3a: barge-in — stop daemon-owned playback(s).
        "audio.stop" => audio_stop(backends, cmd).await,
        "agent.run" => agent_run(cmd).await,
        "agent.list" => agent_list(),
        "agent.session_start" => agent_session_start(backends, cmd).await,
        "agent.prompt" => agent_prompt(backends, cmd).await,
        "agent.cancel" => agent_cancel(backends, cmd),
        "agent.close" => agent_close(backends, cmd),
        "agent.session_list" => agent_session_list(backends),
        "engine.set_adapter_scale" => set_adapter_scale(backends.engine, cmd),
        "engine.reload" => reload_adapter(backends.engine, cmd).await,
        // Orb-host-owns-state: push an info set → publishes `info.update` to
        // subscribed orb hosts (the green-dot indicator). StatusRead scope.
        "info.push" => info_push(backends, cmd).await,
        _ => Err("not_implemented"),
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
        .map_err(|_| "reload_failed")?;
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

/// `agent.run` — delegate one prompt turn to an external coding agent via the
/// native ACP client, returning the collected text + stop reason + tool calls.
/// Non-streaming (Stage 1): blocks until the agent's turn completes.
async fn agent_run(cmd: &Command) -> Result<serde_json::Value, &'static str> {
    let agent = cmd
        .payload
        .get("agent")
        .and_then(serde_json::Value::as_str)
        .ok_or("bad_request")?;
    let prompt = cmd
        .payload
        .get("prompt")
        .and_then(serde_json::Value::as_str)
        .ok_or("bad_request")?;
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

    let outcome = fae_acp::run_one_shot(agent, &cwd, prompt, policy)
        .await
        .map_err(|error| {
            eprintln!("fae-daemon: agent.run failed: {error}");
            classify_agent_error(&error)
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
async fn agent_session_start(
    backends: &SessionBackends<'_>,
    cmd: &Command,
) -> Result<serde_json::Value, &'static str> {
    let agent = cmd
        .payload
        .get("agent")
        .and_then(serde_json::Value::as_str)
        .ok_or("bad_request")?;
    let cwd = cmd
        .payload
        .get("cwd")
        .and_then(serde_json::Value::as_str)
        .map(std::path::PathBuf::from)
        .or_else(|| std::env::current_dir().ok())
        .ok_or("bad_request")?;
    let policy = agent_approval_policy(cmd);

    let session = fae_acp::AcpSession::start(agent, &cwd, policy)
        .await
        .map_err(|error| {
            eprintln!("fae-daemon: agent.session_start failed: {error}");
            classify_agent_error(&error)
        })?;
    let session_id = backends
        .agents
        .insert(session, agent.to_owned(), cwd.display().to_string());
    Ok(serde_json::json!({ "session_id": session_id }))
}

/// `agent.prompt` (inline/diagnostic path, no `ServerRequester`) — permission
/// requests fall back to approve-first since there is no UI to ask.
async fn agent_prompt(
    backends: &SessionBackends<'_>,
    cmd: &Command,
) -> Result<serde_json::Value, &'static str> {
    agent_prompt_inner(backends.agents, backends.events, None, cmd).await
}

/// `agent.prompt` core — submit a prompt to a live session, republishing the
/// agent's streamed output as `agent.output` / `agent.tool_call` events on the
/// V2 bus (so the orb narrates live), driving mid-turn permission requests to
/// the client over `requester` (gap A3), and returning the final turn. Requires
/// `AgentExecute`.
async fn agent_prompt_inner(
    agents: &AgentSessionRegistry,
    events: &EventBus,
    requester: Option<ServerRequester>,
    cmd: &Command,
) -> Result<serde_json::Value, &'static str> {
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
    let session = agents.get(session_id).ok_or("unknown_session")?;
    let handle = session
        .prompt(prompt.to_owned())
        .map_err(|_| "session_closed")?;

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
            eprintln!("fae-daemon: agent.prompt turn failed: {error}");
            classify_agent_error(&error)
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
    match requester.request("permission.request", params).await {
        Ok(reply) => permission_decision_from_reply(&reply),
        Err(_) => fae_acp::AcpPermissionDecision::Cancelled,
    }
}

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
    match requester.request(method, params).await {
        Ok(reply) => match reply.get("error").and_then(serde_json::Value::as_str) {
            Some(error) => Err(error.to_owned()),
            None => Ok(reply),
        },
        Err(_) => Err("filesystem request failed".to_owned()),
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
pub async fn run_authorized_agent_prompt(
    record: &ClientRecord,
    cmd: &Command,
    agents: &AgentSessionRegistry,
    events: &EventBus,
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
            match agent_prompt_inner(agents, events, Some(requester), cmd).await {
                Ok(result) => Response::ok(&cmd.request_id, result),
                Err(code) => {
                    Response::error(&cmd.request_id, code, "command could not be completed")
                }
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

fn normalize_asr_transcript(raw: &str) -> String {
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
async fn run_turn(
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
fn manual_audit(
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
        // No agent, no prompt → bad_request before any subprocess is spawned.
        let err = super::agent_run(&agent_command(serde_json::json!({})))
            .await
            .expect_err("missing fields must fail");
        assert_eq!(err, "bad_request");
        // Agent present but no prompt is still bad_request.
        let err = super::agent_run(&agent_command(serde_json::json!({ "agent": "codex" })))
            .await
            .expect_err("missing prompt must fail");
        assert_eq!(err, "bad_request");
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
}
