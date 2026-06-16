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

use crate::events::{EventBus, PlaybackRegistry};

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
    pub tts: &'a dyn TtsAdapter,
    pub audio: &'a AudioManager,
    /// Server-push event bus — producers (voice spine V3a `tts.speak`) publish
    /// `audio.level` / `audio.playback_ended` to subscribed connections.
    pub events: &'a EventBus,
    /// Live daemon-owned playbacks — resolves end-reason (`completed` vs
    /// `interrupted`) for `audio.playback_ended`.
    pub playbacks: &'a PlaybackRegistry,
}

/// The `session.authenticate` payload.
#[derive(Deserialize)]
struct AuthPayload {
    client_id: String,
    token: String,
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
        "conversation.inject_text" => inject_text(backends.engine, cmd).await,
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
        "engine.set_adapter_scale" => set_adapter_scale(backends.engine, cmd),
        "engine.reload" => reload_adapter(backends.engine, cmd).await,
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
            match error {
                fae_acp::AcpError::UnknownAgent(_) => "unknown_agent",
                _ => "agent_error",
            }
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
    engine: &dyn ProviderAdapter,
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

    // Gemma 4 on Metal produces NaN logits when a prompt's TOTAL length lands
    // in a narrow window of sequence lengths (mistral.rs kernel tiling edge;
    // deterministic per payload, diagnosed 2026-06-12, still present at
    // upstream c22c2e2b). Appending ~50-130 tokens of system-prompt padding
    // shifts the length out of the window, so a NaN failure is retried with
    // padding before giving up. The pad asks the model to ignore it.
    const NAN_PAD_UNIT: &str = "(Padding line for runtime alignment — ignore this line entirely.)";
    const NAN_RETRY_PADS: [usize; 3] = [4, 24, 80];

    let mut attempt_request = request.clone();
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
    Ok(serde_json::json!({
        "text": answer,
        "tool_calls": tool_calls,
        "finish_reason": finish_reason,
    }))
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
        let backends = SessionBackends {
            engine,
            tts,
            audio,
            events: &events,
            playbacks: &playbacks,
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
}
