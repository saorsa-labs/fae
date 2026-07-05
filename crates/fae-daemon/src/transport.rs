//! Unix-domain-socket transport — the thin async shell over [`crate::session`].
//!
//! NDJSON framing (one JSON [`Command`](fae_control_plane::Command) per line);
//! one response line per request. The socket is the default transport for the
//! local Swift frontend. TCP-loopback + WS/SSE diagnostics with single-use
//! stream tickets are a later chunk (2c); this shell deliberately opens no TCP
//! port.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::Duration;

use fae_audio::AudioManager;
use fae_control_plane::{append_audit_jsonl, ClientRegistry, Command, Response, Scope};
use fae_engine::{ProviderAdapter, TtsAdapter};
use fluers_runtime::Limits;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::task::JoinSet;
use tokio_util::sync::CancellationToken;

use crate::agents::AgentSessionRegistry;
use crate::conductor::ConductorStore;
use crate::events::{ConnSink, EventBus, EventSink, PlaybackRegistry};
use crate::mcp::McpCatalog;
use crate::server_request::{ServerReply, ServerRequester};
use crate::session::{
    handle_frame, run_authorized_agent_prompt, run_authorized_delegate, run_authorized_mcp_list,
    run_authorized_skillhost_activate, run_authorized_skillhost_archive,
    run_authorized_skillhost_list, run_authorized_skillhost_run, run_authorized_skillhost_usage,
    run_authorized_toolhost_execute, SessionBackends, SessionState,
};
use crate::skillhost::SkillHost;
use crate::toolhost::confirm::ServerRequestConfirmation;
use crate::toolhost::ToolHost;
use crate::{next_event_id, now_ms};

/// (Phase G3) Attach the shared MCP catalog to a freshly built ToolHost, if MCP
/// is configured. A `None` catalog leaves the host with no MCP tier (every
/// `mcp:` call denies `mcp_not_configured`).
fn attach_mcp(host: ToolHost, mcp_catalog: &Option<Arc<McpCatalog>>) -> ToolHost {
    match mcp_catalog {
        Some(catalog) => host.with_mcp_catalog(Arc::clone(catalog)),
        None => host,
    }
}

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

/// A hot-swappable [`ClientRegistry`]. The bootstrap-token rotation task
/// (`main::rotation_loop`) publishes a fresh registry here at token half-life; the
/// accept loop snapshots the current one per connection, so new connections after
/// rotation authenticate against the new token while in-flight ones keep the
/// registry they authenticated with. Held behind a `std::sync::Mutex` — every
/// critical section is a single `Arc` clone/store with no `.await` in between.
pub type SharedRegistry = Arc<Mutex<Arc<ClientRegistry>>>;

/// Bind the Unix socket (owner-only) and serve connections until the process is
/// killed. Fails closed: if a stale socket cannot be cleared, the bind fails, or
/// owner-only permissions cannot be set, the daemon refuses to serve.
#[allow(clippy::too_many_arguments)]
pub async fn serve_unix(
    socket_path: PathBuf,
    registry: SharedRegistry,
    engine: Arc<dyn ProviderAdapter>,
    asr_fallback: Option<Arc<dyn ProviderAdapter>>,
    tts: Arc<dyn TtsAdapter>,
    audio: Arc<AudioManager>,
    audit_path: PathBuf,
    events: EventBus,
    playbacks: PlaybackRegistry,
    agents: AgentSessionRegistry,
    conductor: Arc<crate::conductor::ConductorRuntime>,
    conductor_store: Arc<ConductorStore>,
    skill_host: Arc<SkillHost>,
    mcp_catalog: Option<Arc<McpCatalog>>,
    peer_outbound: Option<Arc<crate::peer::PeerOutbound>>,
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
        // Snapshot the live registry for this connection; a later rotation swaps
        // in a new one for subsequent connections without disturbing this task.
        let registry_snapshot = {
            let guard = registry.lock().unwrap_or_else(PoisonError::into_inner);
            Arc::clone(&guard)
        };
        let engine = Arc::clone(&engine);
        let asr_fallback = asr_fallback.as_ref().map(Arc::clone);
        let tts = Arc::clone(&tts);
        let audio = Arc::clone(&audio);
        let audit_path = audit_path.clone();
        let events = events.clone();
        let playbacks = playbacks.clone();
        let agents = agents.clone();
        let conductor = Arc::clone(&conductor);
        let conductor_store = Arc::clone(&conductor_store);
        let skill_host = Arc::clone(&skill_host);
        let mcp_catalog = mcp_catalog.clone();
        let peer_outbound = peer_outbound.clone();
        tokio::spawn(async move {
            if let Err(error) = handle_connection(
                stream,
                &registry_snapshot,
                engine,
                asr_fallback.as_deref(),
                tts.as_ref(),
                audio.as_ref(),
                &audit_path,
                &events,
                &playbacks,
                &agents,
                conductor,
                conductor_store,
                skill_host,
                mcp_catalog,
                peer_outbound.as_deref(),
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
    // (F1) Owned `Arc` (not a borrow): `conversation.delegate` spawns a
    // long-running task that must hold the engine for the whole jailed loop.
    engine: Arc<dyn ProviderAdapter>,
    asr_fallback: Option<&dyn ProviderAdapter>,
    tts: &dyn TtsAdapter,
    audio: &AudioManager,
    audit_path: &Path,
    events: &EventBus,
    playbacks: &PlaybackRegistry,
    agents: &AgentSessionRegistry,
    conductor: Arc<crate::conductor::ConductorRuntime>,
    conductor_store: Arc<ConductorStore>,
    skill_host: Arc<SkillHost>,
    // (Phase G3) The shared external MCP catalog (or `None` when no servers are
    // declared). Attached to each per-session ToolHost so `mcp:` calls route
    // through the gate; also read directly for the `mcp.list` command.
    mcp_catalog: Option<Arc<McpCatalog>>,
    peer_outbound: Option<&crate::peer::PeerOutbound>,
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
    let mut line: Vec<u8> = Vec::new();

    // A3: per-session ephemeral tool sandbox (owner Q2 — created post-auth on
    // the first `toolhost.execute`, torn down on close). `tool_root` is the
    // `tempfile::TempDir` guard held HERE so it is deleted on close, AFTER
    // in-flight tool tasks are cancelled (scope §5.1 / oracle MAJOR-2). Lazily
    // created so an unauthenticated connection (or one that never uses tools)
    // allocates nothing. Networked tools still deny (DisabledGate; the real
    // 3-gate egress adapter is A2.5/P7).
    let session_cancel = CancellationToken::new();
    let mut tool_tasks: JoinSet<()> = JoinSet::new();
    let confirm = Arc::new(ServerRequestConfirmation::new(requester.clone()));
    let mut tool_root: Option<tempfile::TempDir> = None;
    let mut toolhost: Option<Arc<ToolHost>> = None;

    // A3→B: the per-session durable-root lifecycle (advisor #3 state machine). Set
    // by `toolhost.set_root` (owner-approved), consumed by the lazy ToolHost init
    // (layer 2 binds the durable root). `tokio::sync::Mutex` — never held across
    // a long await (only the brief state transition). `home_dir` bounds the
    // blast-radius guard (reject approving the home dir as a root).
    let root_state = Arc::new(tokio::sync::Mutex::new(
        crate::toolhost::root_confirm::ToolRootState::Unset,
    ));
    let root_confirm = Arc::new(
        crate::toolhost::root_confirm::ServerRequestRootConfirmation::new(requester.clone()),
    );
    let home_dir = dirs::home_dir();

    let result: std::io::Result<()> = async {
        loop {
            // The per-frame byte cap depends on auth state, which is known
            // before the read — so bound the read to it. A runaway client that
            // never sends a newline cannot grow this buffer without limit
            // (enforced at the read layer via `take`, not after `read_line` has
            // already buffered the entire line).
            let max_frame_bytes = match state {
                SessionState::Unauthenticated => MAX_FRAME_BYTES_UNAUTHENTICATED,
                SessionState::Authenticated(_) => MAX_FRAME_BYTES_AUTHENTICATED,
            };
            line.clear();
            let bytes = (&mut reader)
                .take(max_frame_bytes as u64 + 1)
                .read_until(b'\n', &mut line)
                .await?;
            if bytes == 0 {
                return Ok(()); // peer closed
            }
            // Reading `cap + 1` bytes with no terminating newline means the
            // frame exceeds the cap (or the client is streaming an unbounded
            // frame): reject and close. A shorter final frame at EOF that lacks
            // a newline stays legal (bytes ≤ cap), preserving prior behavior.
            if bytes > max_frame_bytes && line.last() != Some(&b'\n') {
                let response =
                    Response::error("unknown", "frame_too_large", "command frame exceeds limit");
                sink.send_line(response_line(&response)?);
                return Ok(());
            }
            let line_str = String::from_utf8_lossy(&line);
            let trimmed = line_str.trim();
            if trimmed.is_empty() {
                continue;
            }
            // Defensive: the read-layer cap already bounds the frame; this
            // logical guard stays as a belt-and-braces check on the exact
            // boundary frame.
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
                    // A3→B: `toolhost.set_root` — bind an owner-approved durable
                    // workspace root. SPAWNED like `toolhost.execute` (BLOCKER-1:
                    // the `workspace.confirm_root` round-trip must not block the
                    // read loop). The handler validates the path + runs the
                    // distinct root-approval card + stores `ApprovedRoot`.
                    if cmd.command == "toolhost.set_root" {
                        let record = record.clone();
                        let root_state = Arc::clone(&root_state);
                        let root_confirm = Arc::clone(&root_confirm);
                        let home_dir = home_dir.clone();
                        let audit_path_t = audit_path.to_path_buf();
                        let sink_t = Arc::clone(&sink);
                        tool_tasks.spawn(async move {
                            let outcome = crate::session::run_authorized_toolhost_set_root(
                                &record,
                                &cmd,
                                &root_state,
                                root_confirm.as_ref(),
                                home_dir,
                                now,
                                event_id,
                            )
                            .await;
                            if append_audit_jsonl(&audit_path_t, &outcome.audit).is_err() {
                                let response = Response::error(
                                    &outcome.response.request_id,
                                    "audit_error",
                                    "audit write failed",
                                );
                                if let Ok(line) = response_line(&response) {
                                    sink_t.send_line(line);
                                }
                                return;
                            }
                            if let Ok(line) = response_line(&outcome.response) {
                                sink_t.send_line(line);
                            }
                        });
                        continue;
                    }
                    // A3: `toolhost.execute` — spawned like `agent.prompt` (BLOCKER-1) so the
                    // `tool.confirm` round-trip doesn't block the read loop.
                    // Tracked in `tool_tasks` (not fire-and-forget) so close can
                    // cancel + await before the sandbox root drops (scope §5.1).
                    // The client is authenticated here (we're inside the
                    // `Authenticated(record)` arm), so lazy creation is post-auth
                    // by construction (oracle MAJOR-2).
                    if cmd.command == "toolhost.execute" {
                        // A3→B: ONE atomic lock acquisition decides pending-deny
                        // vs the durable/temp init plan. There is NO window for a
                        // concurrent `set_root` to interleave between the
                        // pending-check and the plan (oracle BLOCKER-1: a
                        // separate check-then-plan race could clobber
                        // PendingRootConfirm → InitializedTemp, then a later
                        // approval would shadow a temp host with ApprovedRoot).
                        if toolhost.is_none() {
                            enum Plan {
                                Deny,
                                Durable(std::path::PathBuf),
                                Temp,
                                Inconsistent,
                            }
                            let plan = {
                                use crate::toolhost::root_confirm::ToolRootState;
                                let mut st = root_state.lock().await;
                                match &*st {
                                    // A root confirm is in flight: the root is
                                    // mid-transition. Racing a tool against it
                                    // could bind the wrong root. Fail-closed.
                                    ToolRootState::PendingRootConfirm => Plan::Deny,
                                    // Owner approved a durable root but the host
                                    // isn't created yet. Bind it now.
                                    ToolRootState::ApprovedRoot { path } => {
                                        let p = std::path::PathBuf::from(path);
                                        *st = ToolRootState::InitializedDurable {
                                            path: p.to_string_lossy().into_owned(),
                                        };
                                        Plan::Durable(p)
                                    }
                                    // No root: ephemeral temp sandbox (A3 default).
                                    ToolRootState::Unset => {
                                        *st = ToolRootState::InitializedTemp;
                                        Plan::Temp
                                    }
                                    // Initialized* should have a host bound; if
                                    // toolhost is None here, state is inconsistent
                                    // (e.g. a failed durable init that didn't
                                    // revert). Fail-closed rather than guess a root.
                                    ToolRootState::InitializedTemp
                                    | ToolRootState::InitializedDurable { .. } => {
                                        Plan::Inconsistent
                                    }
                                }
                            };
                            match plan {
                                Plan::Deny => {
                                    let audit = crate::session::manual_audit(
                                        event_id,
                                        now,
                                        Some(record.client_id.clone()),
                                        "toolhost.execute",
                                        fae_control_plane::AuditDecision::Error,
                                        "root_initialization_pending",
                                    );
                                    let _ = append_audit_jsonl(audit_path, &audit);
                                    let response = Response::error(
                                        &cmd.request_id,
                                        "root_initialization_pending",
                                        "a workspace root confirm is in flight",
                                    );
                                    sink.send_line(response_line(&response)?);
                                    continue;
                                }
                                Plan::Inconsistent => {
                                    eprintln!(
                                        "fae-daemon: toolhost missing despite Initialized root"
                                    );
                                    let audit = crate::session::manual_audit(
                                        event_id,
                                        now,
                                        Some(record.client_id.clone()),
                                        "toolhost.execute",
                                        fae_control_plane::AuditDecision::Error,
                                        "toolhost_inconsistent_state",
                                    );
                                    let _ = append_audit_jsonl(audit_path, &audit);
                                    let response = Response::error(
                                        &cmd.request_id,
                                        "internal_error",
                                        "toolhost state is inconsistent",
                                    );
                                    sink.send_line(response_line(&response)?);
                                    continue;
                                }
                                Plan::Durable(path) => {
                                    match ToolHost::new_durable(
                                        path,
                                        Limits::default(),
                                        Arc::clone(&conductor_store),
                                    )
                                    .await
                                    {
                                        Ok(h) => {
                                            toolhost = Some(Arc::new(attach_mcp(h, &mcp_catalog)))
                                        }
                                        Err(e) => {
                                            eprintln!(
                                                "fae-daemon: durable toolhost init failed: {e}"
                                            );
                                            // Revert so a later attempt can retry.
                                            let mut st = root_state.lock().await;
                                            *st =
                                                crate::toolhost::root_confirm::ToolRootState::Unset;
                                        }
                                    }
                                }
                                Plan::Temp => match tempfile::tempdir() {
                                    Ok(dir) => {
                                        match ToolHost::new(
                                            dir.path().to_path_buf(),
                                            Limits::default(),
                                            Arc::clone(&conductor_store),
                                        )
                                        .await
                                        {
                                            Ok(h) => {
                                                toolhost =
                                                    Some(Arc::new(attach_mcp(h, &mcp_catalog)));
                                                tool_root = Some(dir);
                                            }
                                            Err(e) => {
                                                eprintln!("fae-daemon: toolhost init failed: {e}");
                                            }
                                        }
                                    }
                                    Err(e) => {
                                        eprintln!("fae-daemon: toolhost sandbox init failed: {e}");
                                    }
                                },
                            }
                        }
                        if let Some(host) = toolhost.as_ref() {
                            let record = record.clone();
                            let host = Arc::clone(host);
                            let confirm = Arc::clone(&confirm);
                            let cancel = session_cancel.clone();
                            let audit_path_t = audit_path.to_path_buf();
                            let sink_t = Arc::clone(&sink);
                            tool_tasks.spawn(async move {
                                let outcome = run_authorized_toolhost_execute(
                                    &record,
                                    &cmd,
                                    &host,
                                    confirm.as_ref(),
                                    cancel,
                                    now,
                                    event_id,
                                )
                                .await;
                                if append_audit_jsonl(&audit_path_t, &outcome.audit).is_err() {
                                    let response = Response::error(
                                        &outcome.response.request_id,
                                        "audit_error",
                                        "audit write failed",
                                    );
                                    if let Ok(line) = response_line(&response) {
                                        sink_t.send_line(line);
                                    }
                                    return;
                                }
                                if let Ok(line) = response_line(&outcome.response) {
                                    sink_t.send_line(line);
                                }
                            });
                        } else {
                            // Sandbox init failed — deny fail-closed AND audit it
                            // (oracle MINOR-1: this path previously bypassed the
                            // audit row). Synthesize an audited error response.
                            let audit = crate::session::manual_audit(
                                event_id,
                                now,
                                Some(record.client_id.clone()),
                                "toolhost.execute",
                                fae_control_plane::AuditDecision::Error,
                                "sandbox_unavailable",
                            );
                            let _ = append_audit_jsonl(audit_path, &audit);
                            let response = Response::error(
                                &cmd.request_id,
                                "sandbox_error",
                                "toolhost sandbox unavailable",
                            );
                            sink.send_line(response_line(&response)?);
                        }
                        continue;
                    }
                    // F1: `conversation.delegate` — the native jailed agentic
                    // loop. SPAWNED like `agent.prompt`/`toolhost.execute`
                    // (BLOCKER-1): a delegation runs many turns and a dangerous
                    // tool may round-trip a `tool.confirm`, so it must not block
                    // the read loop (which routes the confirm reply). Tracked in
                    // `tool_tasks` so close cancels + drains it (the ephemeral
                    // ToolHost is rooted at the caller-supplied workspace, not the
                    // temp sandbox, so nothing here depends on `tool_root`).
                    if cmd.command == "conversation.delegate" {
                        let record = record.clone();
                        let engine = Arc::clone(&engine);
                        // Coerce the concrete confirmation Arc to a trait object so
                        // an orchestrator can share it across spawned children
                        // (unsized coercion applies on the plain `let` binding).
                        let confirm_concrete = Arc::clone(&confirm);
                        let confirm: Arc<dyn crate::toolhost::confirm::ToolConfirmation> =
                            confirm_concrete;
                        let store = Arc::clone(&conductor_store);
                        let home_dir = home_dir.clone();
                        let cancel = session_cancel.clone();
                        let audit_path_t = audit_path.to_path_buf();
                        let sink_t = Arc::clone(&sink);
                        tool_tasks.spawn(async move {
                            let outcome = run_authorized_delegate(
                                &record, &cmd, engine, confirm, store, home_dir, cancel, now,
                                event_id,
                            )
                            .await;
                            if append_audit_jsonl(&audit_path_t, &outcome.audit).is_err() {
                                let response = Response::error(
                                    &outcome.response.request_id,
                                    "audit_error",
                                    "audit write failed",
                                );
                                if let Ok(line) = response_line(&response) {
                                    sink_t.send_line(line);
                                }
                                return;
                            }
                            if let Ok(line) = response_line(&outcome.response) {
                                sink_t.send_line(line);
                            }
                        });
                        continue;
                    }
                    // A2.5: `skillhost.list` / `skillhost.activate` — read-only
                    // (discovery metadata + SKILL.md body). Handled inline (no
                    // confirm round-trip, so they cannot block the read loop).
                    if cmd.command == "skillhost.list" {
                        let outcome =
                            run_authorized_skillhost_list(record, &cmd, &skill_host, now, event_id);
                        if append_audit_jsonl(audit_path, &outcome.audit).is_err() {
                            let response = Response::error(
                                &outcome.response.request_id,
                                "audit_error",
                                "audit write failed",
                            );
                            sink.send_line(response_line(&response)?);
                            return Ok(());
                        }
                        sink.send_line(response_line(&outcome.response)?);
                        continue;
                    }
                    // Phase G3: `mcp.list` — read-only external MCP catalog + health.
                    // Handled inline (no confirm round-trip). Absent catalog =>
                    // an empty listing (MCP not configured), never an error.
                    if cmd.command == "mcp.list" {
                        let outcome = run_authorized_mcp_list(
                            record,
                            &cmd,
                            mcp_catalog.as_deref(),
                            now,
                            event_id,
                        );
                        if append_audit_jsonl(audit_path, &outcome.audit).is_err() {
                            let response = Response::error(
                                &outcome.response.request_id,
                                "audit_error",
                                "audit write failed",
                            );
                            sink.send_line(response_line(&response)?);
                            return Ok(());
                        }
                        sink.send_line(response_line(&outcome.response)?);
                        continue;
                    }
                    if cmd.command == "skillhost.activate" {
                        let outcome = run_authorized_skillhost_activate(
                            record,
                            &cmd,
                            &skill_host,
                            now,
                            event_id,
                        );
                        if append_audit_jsonl(audit_path, &outcome.audit).is_err() {
                            let response = Response::error(
                                &outcome.response.request_id,
                                "audit_error",
                                "audit write failed",
                            );
                            sink.send_line(response_line(&response)?);
                            return Ok(());
                        }
                        sink.send_line(response_line(&outcome.response)?);
                        continue;
                    }
                    // Phase G4: `skillhost.usage` — read-only per-skill run
                    // counters (zero-run skills included). Handled inline.
                    if cmd.command == "skillhost.usage" {
                        let outcome = run_authorized_skillhost_usage(
                            record,
                            &cmd,
                            &skill_host,
                            now,
                            event_id,
                        );
                        if append_audit_jsonl(audit_path, &outcome.audit).is_err() {
                            let response = Response::error(
                                &outcome.response.request_id,
                                "audit_error",
                                "audit write failed",
                            );
                            sink.send_line(response_line(&response)?);
                            return Ok(());
                        }
                        sink.send_line(response_line(&outcome.response)?);
                        continue;
                    }
                    // Phase G4: `skillhost.archive` — move an `auto-*` skill to
                    // skills-archived/ (fail-closed name check). Handled inline
                    // (a synchronous filesystem rename, no confirm round-trip).
                    if cmd.command == "skillhost.archive" {
                        let outcome = run_authorized_skillhost_archive(
                            record,
                            &cmd,
                            &skill_host,
                            now,
                            event_id,
                        );
                        if append_audit_jsonl(audit_path, &outcome.audit).is_err() {
                            let response = Response::error(
                                &outcome.response.request_id,
                                "audit_error",
                                "audit write failed",
                            );
                            sink.send_line(response_line(&response)?);
                            return Ok(());
                        }
                        sink.send_line(response_line(&outcome.response)?);
                        continue;
                    }
                    // A2.5: `skillhost.run` — build a `uv run --script …` command
                    // and route it through the SAME governed ToolHost bash path
                    // (`execute_governed`: dangerous scope + owner confirm).
                    // SPAWNED like `toolhost.execute` (BLOCKER-1). If a session
                    // ToolHost already exists it is reused; otherwise a skill run
                    // gets an ephemeral TEMP sandbox (scripts are referenced by
                    // absolute path, so the sandbox is just a cwd). To keep the
                    // root state machine consistent with `toolhost.execute`, the
                    // temp path is taken ONLY from `Unset` (transitioning to
                    // `InitializedTemp`); a pending/approved/inconsistent durable
                    // root denies fail-closed rather than shadow it with a temp
                    // sandbox.
                    if cmd.command == "skillhost.run" {
                        if toolhost.is_none() {
                            use crate::toolhost::root_confirm::ToolRootState;
                            // Atomically decide: only `Unset` may take the temp
                            // path (marking `InitializedTemp`); everything else
                            // denies with a stable reason.
                            let deny_reason: Option<&'static str> = {
                                let mut st = root_state.lock().await;
                                match &*st {
                                    ToolRootState::Unset => {
                                        *st = ToolRootState::InitializedTemp;
                                        None
                                    }
                                    ToolRootState::PendingRootConfirm => {
                                        Some("root_initialization_pending")
                                    }
                                    // A durable root was approved/initialized but
                                    // no host is bound yet: run a `toolhost.execute`
                                    // first (which binds it). Fail closed rather
                                    // than shadow the durable root with a temp one.
                                    _ => Some("toolhost_not_ready"),
                                }
                            };
                            if let Some(reason) = deny_reason {
                                let audit = crate::session::manual_audit(
                                    event_id,
                                    now,
                                    Some(record.client_id.clone()),
                                    "skillhost.run",
                                    fae_control_plane::AuditDecision::Error,
                                    reason,
                                );
                                let _ = append_audit_jsonl(audit_path, &audit);
                                let response =
                                    Response::error(&cmd.request_id, reason, "toolhost not ready");
                                sink.send_line(response_line(&response)?);
                                continue;
                            }
                            match tempfile::tempdir() {
                                Ok(dir) => {
                                    match ToolHost::new(
                                        dir.path().to_path_buf(),
                                        Limits::default(),
                                        Arc::clone(&conductor_store),
                                    )
                                    .await
                                    {
                                        Ok(h) => {
                                            toolhost = Some(Arc::new(h));
                                            tool_root = Some(dir);
                                        }
                                        Err(e) => {
                                            eprintln!(
                                                "fae-daemon: skillhost toolhost init failed: {e}"
                                            );
                                            // Revert so a later attempt can retry.
                                            let mut st = root_state.lock().await;
                                            *st = ToolRootState::Unset;
                                        }
                                    }
                                }
                                Err(e) => {
                                    eprintln!("fae-daemon: skillhost sandbox init failed: {e}");
                                    let mut st = root_state.lock().await;
                                    *st = ToolRootState::Unset;
                                }
                            }
                        }
                        if let Some(host) = toolhost.as_ref() {
                            let record = record.clone();
                            let host = Arc::clone(host);
                            let skill_host = Arc::clone(&skill_host);
                            let confirm = Arc::clone(&confirm);
                            let cancel = session_cancel.clone();
                            let audit_path_t = audit_path.to_path_buf();
                            let sink_t = Arc::clone(&sink);
                            tool_tasks.spawn(async move {
                                let outcome = run_authorized_skillhost_run(
                                    &record,
                                    &cmd,
                                    &skill_host,
                                    &host,
                                    confirm.as_ref(),
                                    cancel,
                                    now,
                                    event_id,
                                )
                                .await;
                                if append_audit_jsonl(&audit_path_t, &outcome.audit).is_err() {
                                    let response = Response::error(
                                        &outcome.response.request_id,
                                        "audit_error",
                                        "audit write failed",
                                    );
                                    if let Ok(line) = response_line(&response) {
                                        sink_t.send_line(line);
                                    }
                                    return;
                                }
                                if let Ok(line) = response_line(&outcome.response) {
                                    sink_t.send_line(line);
                                }
                            });
                        } else {
                            let audit = crate::session::manual_audit(
                                event_id,
                                now,
                                Some(record.client_id.clone()),
                                "skillhost.run",
                                fae_control_plane::AuditDecision::Error,
                                "sandbox_unavailable",
                            );
                            let _ = append_audit_jsonl(audit_path, &audit);
                            let response = Response::error(
                                &cmd.request_id,
                                "sandbox_error",
                                "skillhost sandbox unavailable",
                            );
                            sink.send_line(response_line(&response)?);
                        }
                        continue;
                    }
                }
            }

            let backends = SessionBackends {
                engine: engine.as_ref(),
                asr_fallback,
                tts,
                audio,
                events,
                playbacks,
                agents,
                conductor: Some(conductor.as_ref()),
                acp_runner: &crate::session::REAL_ACP_RUNNER,
                peer: peer_outbound,
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

    // A3 close-cancels (scope §5.1 / oracle MAJOR-2): cancel in-flight tool
    // tasks + drain them BEFORE the sandbox root (`tool_root`) drops, so a
    // spawned task never reads/writes a root that's been deleted under it. The
    // cancel propagates to each tool's `InvokeContext` (SIGTERM for shell); the
    // drain is bounded (a task ignoring cancel can't hang the close), and any
    // straggler is hard-aborted as a last resort.
    session_cancel.cancel();
    let _ = tokio::time::timeout(Duration::from_secs(5), async {
        while tool_tasks.join_next().await.is_some() {}
    })
    .await;
    tool_tasks.shutdown().await;

    // Drop every local that holds a strong `Arc<ConnSink>` reference BEFORE
    // `drop(sink)`, so the writer's `rx` actually closes and `writer.await`
    // returns (oracle MAJOR-2). `confirm` holds the requester → the sink;
    // `requester` holds the sink directly. If these outlive `drop(sink)`, the
    // writer channel never closes, `writer.await` hangs, and `tool_root` never
    // drops (temp dirs leak). Tasks already drained above dropped their clones.
    drop(toolhost);
    drop(confirm);
    drop(root_confirm);
    drop(requester);
    // Now the only remaining sink ref is `sink` itself.
    drop(sink);
    let _ = writer.await;
    // `tool_root` drops here (implicit, end of scope) — AFTER the tasks drained
    // and the toolhost dropped, so no read/write-after-delete race.
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
