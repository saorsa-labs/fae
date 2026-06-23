//! Unix-domain-socket transport — the thin async shell over [`crate::session`].
//!
//! NDJSON framing (one JSON [`Command`](fae_control_plane::Command) per line);
//! one response line per request. The socket is the default transport for the
//! local Swift frontend. TCP-loopback + WS/SSE diagnostics with single-use
//! stream tickets are a later chunk (2c); this shell deliberately opens no TCP
//! port.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use fae_audio::AudioManager;
use fae_control_plane::{append_audit_jsonl, ClientRegistry, Command, Response, Scope};
use fae_engine::{ProviderAdapter, TtsAdapter};
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::net::{UnixListener, UnixStream};

use crate::agents::AgentSessionRegistry;
use crate::events::{ConnSink, EventBus, EventSink, PlaybackRegistry};
use crate::server_request::{ServerReply, ServerRequester};
use crate::session::{handle_frame, run_authorized_agent_prompt, SessionBackends, SessionState};
use crate::{next_event_id, now_ms};

/// Reject any single NDJSON frame larger than this **before authentication**.
/// The control socket is same-user (OS-enforced peer credentials), so this is a
/// sanity bound against a runaway/buggy client, not a hard anti-DoS guard — a
/// streaming cap for the less-trusted TCP/WS path lands in chunk 2c. Control
/// frames are sub-kilobyte.
const MAX_FRAME_BYTES_UNAUTHENTICATED: usize = 64 * 1024;

/// Frame ceiling for an **authenticated** session. `conversation.inject_text`
/// can carry a base64 WAV clip (S18 push-to-talk: ~1.3 MB for a 30 s
/// utterance), so authenticated frames get headroom; everything pre-auth stays
/// on the tight control-frame bound.
const MAX_FRAME_BYTES_AUTHENTICATED: usize = 8 * 1024 * 1024;

/// Bind the Unix socket (owner-only) and serve connections until the process is
/// killed. Fails closed: if a stale socket cannot be cleared, the bind fails, or
/// owner-only permissions cannot be set, the daemon refuses to serve.
#[allow(clippy::too_many_arguments)]
pub async fn serve_unix(
    socket_path: PathBuf,
    registry: Arc<ClientRegistry>,
    engine: Arc<dyn ProviderAdapter>,
    asr_fallback: Option<Arc<dyn ProviderAdapter>>,
    tts: Arc<dyn TtsAdapter>,
    audio: Arc<AudioManager>,
    audit_path: PathBuf,
    events: EventBus,
    playbacks: PlaybackRegistry,
    agents: AgentSessionRegistry,
    conductor: Arc<crate::conductor::ConductorRuntime>,
) -> std::io::Result<()> {
    // Clear any stale socket left by a previous run (bind fails on EADDRINUSE).
    match std::fs::remove_file(&socket_path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }

    let listener = UnixListener::bind(&socket_path)?;
    tighten_socket_permissions(&socket_path)?;
    eprintln!(
        "fae-daemon: listening on {} (NDJSON)",
        socket_path.display()
    );

    loop {
        let (stream, _addr) = listener.accept().await?;
        let registry = Arc::clone(&registry);
        let engine = Arc::clone(&engine);
        let asr_fallback = asr_fallback.as_ref().map(Arc::clone);
        let tts = Arc::clone(&tts);
        let audio = Arc::clone(&audio);
        let audit_path = audit_path.clone();
        let events = events.clone();
        let playbacks = playbacks.clone();
        let agents = agents.clone();
        let conductor = Arc::clone(&conductor);
        tokio::spawn(async move {
            if let Err(error) = handle_connection(
                stream,
                &registry,
                engine.as_ref(),
                asr_fallback.as_deref(),
                tts.as_ref(),
                audio.as_ref(),
                &audit_path,
                &events,
                &playbacks,
                &agents,
                conductor,
            )
            .await
            {
                // One bad connection must never take the daemon down.
                eprintln!("fae-daemon: connection ended: {error}");
            }
        });
    }
}

#[allow(clippy::too_many_arguments)]
async fn handle_connection(
    stream: UnixStream,
    registry: &ClientRegistry,
    engine: &dyn ProviderAdapter,
    asr_fallback: Option<&dyn ProviderAdapter>,
    tts: &dyn TtsAdapter,
    audio: &AudioManager,
    audit_path: &Path,
    events: &EventBus,
    playbacks: &PlaybackRegistry,
    agents: &AgentSessionRegistry,
    conductor: Arc<crate::conductor::ConductorRuntime>,
) -> std::io::Result<()> {
    let (read_half, write_half) = stream.into_split();
    let mut reader = BufReader::new(read_half);
    // All outbound bytes — request responses AND server-push events — funnel
    // through one writer task, so an async event push can never interleave
    // mid-frame with a response.
    let (sink, writer) = ConnSink::spawn(write_half);
    // Per-connection issuer of server-initiated requests (gap A3). The long
    // `agent.prompt` runs on a spawned task so this read loop keeps reading the
    // client's `{server_request_id, result}` replies, which `resolve` routes.
    let requester = ServerRequester::new(Arc::clone(&sink));
    let mut state = SessionState::Unauthenticated;
    let mut line = String::new();

    let result: std::io::Result<()> = async {
        loop {
            line.clear();
            let bytes = reader.read_line(&mut line).await?;
            if bytes == 0 {
                return Ok(()); // peer closed
            }
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            let max_frame_bytes = match state {
                SessionState::Unauthenticated => MAX_FRAME_BYTES_UNAUTHENTICATED,
                SessionState::Authenticated(_) => MAX_FRAME_BYTES_AUTHENTICATED,
            };
            if trimmed.len() > max_frame_bytes {
                let response =
                    Response::error("unknown", "frame_too_large", "command frame exceeds limit");
                sink.send_line(response_line(&response)?);
                return Ok(());
            }

            let now = now_ms();
            let event_id = next_event_id(now);

            // A3: a `{server_request_id, result}` frame is the client's reply to
            // a server-initiated request, not a command — route it and move on.
            if let Ok(reply) = serde_json::from_str::<ServerReply>(trimmed) {
                requester.resolve(&reply.server_request_id, reply.result);
                continue;
            }

            // A3: `agent.prompt` can issue mid-turn server-requests (permission/
            // fs) whose replies arrive on THIS connection, so it must not block
            // the read loop — run it on a spawned task that audits + responds via
            // the sink. Every other command stays on the inline path below.
            if let SessionState::Authenticated(record) = &state {
                if let Ok(cmd) = serde_json::from_str::<Command>(trimmed) {
                    if cmd.command == "agent.prompt" {
                        let record = record.clone();
                        let agents = agents.clone();
                        let events = events.clone();
                        let requester = requester.clone();
                        let audit_path = audit_path.to_path_buf();
                        let sink = Arc::clone(&sink);
                        let conductor = Arc::clone(&conductor);
                        tokio::spawn(async move {
                            let outcome = run_authorized_agent_prompt(
                                &record,
                                &cmd,
                                &agents,
                                &events,
                                Some(conductor.as_ref()),
                                &crate::session::REAL_ACP_RUNNER,
                                requester,
                                now,
                                event_id,
                            )
                            .await;
                            // Same fail-closed contract: audit before responding.
                            if append_audit_jsonl(&audit_path, &outcome.audit).is_err() {
                                let response = Response::error(
                                    &outcome.response.request_id,
                                    "audit_error",
                                    "audit write failed",
                                );
                                if let Ok(line) = response_line(&response) {
                                    sink.send_line(line);
                                }
                                return;
                            }
                            if let Ok(line) = response_line(&outcome.response) {
                                sink.send_line(line);
                            }
                        });
                        continue;
                    }
                }
            }

            let backends = SessionBackends {
                engine,
                asr_fallback,
                tts,
                audio,
                events,
                playbacks,
                agents,
                conductor: Some(conductor.as_ref()),
                acp_runner: &crate::session::REAL_ACP_RUNNER,
            };
            let outcome =
                handle_frame(registry, &backends, &mut state, trimmed, now, event_id).await;

            // Fail closed: a frame must be audited before its response is sent.
            // If the audit write fails, queue an error response and drop the
            // connection rather than answer unaudited.
            if let Err(error) = append_audit_jsonl(audit_path, &outcome.audit) {
                let response = Response::error(
                    &outcome.response.request_id,
                    "audit_error",
                    "audit write failed",
                );
                sink.send_line(response_line(&response)?);
                return Err(std::io::Error::other(format!(
                    "audit write failed: {error}"
                )));
            }

            // A successful `conversation.subscribe` opens this connection's
            // server-push stream: register its sink, scoped to what the session
            // was granted (per-event scope filtering happens at publish time).
            if outcome.response.ok {
                if let Ok(cmd) = serde_json::from_str::<Command>(trimmed) {
                    if cmd.command == "conversation.subscribe" {
                        if let SessionState::Authenticated(record) = &state {
                            let scopes: HashSet<Scope> = record.scopes.iter().copied().collect();
                            let sink_dyn: Arc<dyn EventSink> = sink.clone();
                            events.subscribe(Arc::downgrade(&sink_dyn), scopes);
                        }
                    }
                }
            }

            sink.send_line(response_line(&outcome.response)?);
            if outcome.close {
                return Ok(());
            }
        }
    }
    .await;

    // Dropping every strong ref to the sink closes the writer channel; the task
    // flushes any queued frames (including a final error response) and exits.
    drop(sink);
    let _ = writer.await;
    result
}

/// Serialize a response into a newline-terminated NDJSON line for the sink.
fn response_line(response: &Response) -> std::io::Result<Arc<Vec<u8>>> {
    let mut line =
        serde_json::to_vec(response).map_err(|error| std::io::Error::other(error.to_string()))?;
    line.push(b'\n');
    Ok(Arc::new(line))
}

/// Set the bound socket file to owner-only (`0600`). The parent run dir is
/// already `0700`, but the socket itself is tightened too; fail closed on Unix
/// if it cannot be done.
fn tighten_socket_permissions(socket_path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(socket_path, std::fs::Permissions::from_mode(0o600))?;
    }
    #[cfg(not(unix))]
    let _ = socket_path;
    Ok(())
}
