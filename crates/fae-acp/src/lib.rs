//! `fae-acp` — native Agent Client Protocol (ACP) client for the Fae daemon.
//!
//! Fae delegates coding tasks to external agents (codex / claude-code / pi /
//! gemini). Each agent ships an ACP **server** adapter; this crate is the ACP
//! **client** that spawns that server as a subprocess and drives it over
//! JSON-RPC — the native-Rust replacement for the macOS-only Swift
//! `ACPSessionManager` that shelled out to `acpx <agent> exec` one-shot.
//!
//! It builds on Zed's [`agent_client_protocol`] toolkit, which owns the wire
//! format, the `initialize → session/new → session/prompt` flow, streaming
//! `session/update` notifications, and the `session/request_permission`
//! round-trip. Stage 0 exposes a one-shot [`run_one_shot`]; persistent sessions,
//! live streaming, and a real permission UX land in later stages.
#![forbid(unsafe_code)]
#![cfg_attr(
    not(test),
    deny(clippy::unwrap_used, clippy::expect_used, clippy::panic)
)]
#![cfg_attr(test, allow(clippy::unwrap_used, clippy::expect_used, clippy::panic))]

use std::path::Path;
use std::str::FromStr;
use std::sync::{Arc, Mutex};

use agent_client_protocol::schema::{
    CancelNotification, ClientCapabilities, ContentBlock, FileSystemCapabilities,
    InitializeRequest, NewSessionRequest, PromptRequest, ProtocolVersion, ReadTextFileRequest,
    ReadTextFileResponse, RequestPermissionOutcome, RequestPermissionRequest,
    RequestPermissionResponse, SelectedPermissionOutcome, SessionNotification, SessionUpdate,
    StopReason, TextContent, WriteTextFileRequest, WriteTextFileResponse,
};
use agent_client_protocol::{AcpAgent, Agent, ConnectionTo};
use tokio::sync::{mpsc, oneshot, Notify};

/// Errors surfaced by the ACP client.
#[derive(Debug, thiserror::Error)]
pub enum AcpError {
    /// The agent name has no launch recipe in the registry.
    #[error("unknown agent '{0}' (no ACP launch recipe)")]
    UnknownAgent(String),
    /// Failed to build the agent launch command.
    #[error("invalid agent launch command: {0}")]
    Launch(String),
    /// An error inside the ACP protocol / transport.
    #[error("acp protocol error: {0}")]
    Protocol(String),
}

/// How the client answers the agent's `session/request_permission` calls before
/// a real approval UX exists (Stage 3 wires this to Fae's approval card).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ApprovalPolicy {
    /// Select the first offered option (approve).
    ApproveAll,
    /// Decline every permission request.
    DenyAll,
}

/// A tool call the agent reported during the turn.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcpToolCall {
    /// Stable id of the tool call within the session.
    pub id: String,
    /// Human-readable title (e.g. "Edit src/main.rs").
    pub title: String,
}

/// The collected result of one ACP prompt turn.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcpOutcome {
    /// Concatenated agent message text.
    pub text: String,
    /// Why the turn ended (`end_turn`, `max_tokens`, `refusal`, `cancelled`, …).
    pub stop_reason: String,
    /// Tool calls the agent initiated during the turn.
    pub tool_calls: Vec<AcpToolCall>,
}

/// Resolve a friendly agent name to a spawnable ACP server.
///
/// The recipes mirror what `acpx` launches; unknown names are rejected rather
/// than guessed. New harnesses are config, not code — this is the seam a config
/// table will override in a later stage.
pub fn resolve_agent(name: &str) -> Result<AcpAgent, AcpError> {
    let agent = match name.to_ascii_lowercase().as_str() {
        "claude" | "claude-code" => AcpAgent::zed_claude_code(),
        "codex" => AcpAgent::zed_codex(),
        "gemini" => AcpAgent::google_gemini(),
        "pi" => AcpAgent::from_str("npx -y pi-acp@latest").map_err(launch_err)?,
        "copilot" => AcpAgent::from_str("copilot --acp").map_err(launch_err)?,
        "opencode" => AcpAgent::from_str("npx -y opencode-ai acp").map_err(launch_err)?,
        // Deterministic A3 test fixture: only resolvable when
        // `FAE_ACP_MOCK_AGENT_BIN` points at the `mock_acp_agent` binary (dev/
        // test only — production never sets it, so `mock` stays unknown there).
        "mock" => {
            let bin = std::env::var("FAE_ACP_MOCK_AGENT_BIN").map_err(|_| {
                AcpError::UnknownAgent("mock (FAE_ACP_MOCK_AGENT_BIN unset)".to_owned())
            })?;
            AcpAgent::from_str(&bin).map_err(launch_err)?
        }
        other => return Err(AcpError::UnknownAgent(other.to_owned())),
    };
    Ok(agent)
}

/// Drive a single prompt turn against `agent` in `cwd` and collect the result.
///
/// Spawns the agent's ACP server, runs the `initialize → session/new →
/// session/prompt` flow, accumulates streamed `agent_message_chunk` text and
/// `tool_call`s, answers permission requests per `policy`, and tears the agent
/// down when the turn completes.
pub async fn run_one_shot(
    agent: &str,
    cwd: &Path,
    prompt: &str,
    policy: ApprovalPolicy,
) -> Result<AcpOutcome, AcpError> {
    let server = resolve_agent(agent)?;
    let collector: Arc<Mutex<Collector>> = Arc::new(Mutex::new(Collector::default()));
    let cwd = cwd.to_path_buf();
    let prompt = prompt.to_owned();

    let notify_sink = Arc::clone(&collector);

    let stop_reason = agent_client_protocol::Client
        .builder()
        .on_receive_notification(
            move |notification: SessionNotification, _cx| {
                let sink = Arc::clone(&notify_sink);
                async move {
                    if let Ok(mut c) = sink.lock() {
                        c.absorb(notification.update);
                    }
                    Ok(())
                }
            },
            agent_client_protocol::on_receive_notification!(),
        )
        .on_receive_request(
            async move |request: RequestPermissionRequest, responder, _connection| {
                let outcome = match policy {
                    ApprovalPolicy::ApproveAll => request
                        .options
                        .first()
                        .map(|opt| {
                            RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(
                                opt.option_id.clone(),
                            ))
                        })
                        .unwrap_or(RequestPermissionOutcome::Cancelled),
                    ApprovalPolicy::DenyAll => RequestPermissionOutcome::Cancelled,
                };
                responder.respond(RequestPermissionResponse::new(outcome))
            },
            agent_client_protocol::on_receive_request!(),
        )
        .connect_with(server, move |connection: ConnectionTo<Agent>| async move {
            connection
                .send_request(InitializeRequest::new(ProtocolVersion::V1))
                .block_task()
                .await?;
            let session = connection
                .send_request(NewSessionRequest::new(cwd))
                .block_task()
                .await?;
            let response = connection
                .send_request(PromptRequest::new(
                    session.session_id,
                    vec![ContentBlock::Text(TextContent::new(prompt))],
                ))
                .block_task()
                .await?;
            Ok(response.stop_reason)
        })
        .await
        .map_err(|error| AcpError::Protocol(error.to_string()))?;

    let collected = match Arc::try_unwrap(collector) {
        Ok(mutex) => mutex.into_inner().unwrap_or_default(),
        Err(shared) => shared.lock().map(|c| c.clone()).unwrap_or_default(),
    };

    Ok(AcpOutcome {
        text: collected.text,
        stop_reason: stop_reason_str(&stop_reason).to_owned(),
        tool_calls: collected.tool_calls,
    })
}

/// A streamed update emitted during an [`AcpSession`] prompt turn. The daemon
/// republishes these on the V2 event bus (`agent.output` / `agent.tool_call`)
/// so the orb can narrate the agent live.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AcpUpdate {
    /// A chunk of agent message text.
    Text(String),
    /// A tool call the agent initiated.
    ToolCall {
        /// Stable id of the tool call within the session.
        id: String,
        /// Human-readable title.
        title: String,
    },
}

/// One option the agent offered for a permission request (gap A3).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcpPermissionOption {
    /// Stable option id to echo back when selected.
    pub id: String,
    /// Human-readable label (e.g. "Allow", "Allow once", "Reject").
    pub name: String,
    /// Hint about the option (`allow_once`, `allow_always`, `reject_once`, …).
    pub kind: String,
}

/// The client's answer to a permission request (gap A3).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AcpPermissionDecision {
    /// Approve by selecting the option with this id.
    Selected(String),
    /// Decline / cancel the request.
    Cancelled,
}

/// A decision the agent needs from the client mid-turn (gap A3). The daemon
/// drives these to Fae (the approval card, the path/damage policy) and feeds the
/// answer back into the agent's turn.
pub enum AcpServerRequest {
    /// The agent asked permission for a tool call (`session/request_permission`).
    Permission {
        /// Best-effort title of the tool call needing permission.
        title: String,
        /// The options the agent offered.
        options: Vec<AcpPermissionOption>,
        /// Channel for the client's decision.
        reply: oneshot::Sender<AcpPermissionDecision>,
    },
    /// The agent asked the client to read a text file (`fs/read_text_file`,
    /// gap A3b). The client mediates via its path/damage policy. Reply is the
    /// file contents, or an error message (refused / unreadable).
    ReadFile {
        /// Absolute path the agent wants to read.
        path: String,
        /// Channel for the file contents or a refusal reason.
        reply: oneshot::Sender<Result<String, String>>,
    },
    /// The agent asked the client to write a text file (`fs/write_text_file`,
    /// gap A3b), mediated by the client's path/damage policy. Reply is `Ok` on a
    /// successful write, or an error message (refused / unwritable).
    WriteFile {
        /// Absolute path the agent wants to write.
        path: String,
        /// Full new contents.
        content: String,
        /// Channel for the write result or a refusal reason.
        reply: oneshot::Sender<Result<(), String>>,
    },
}

/// In-flight handle for one prompt turn: a live stream of updates, a stream of
/// mid-turn server requests (permission/fs), plus the final outcome. The daemon
/// drains `updates` (publishing events) and `requests` (driving them to Fae)
/// while awaiting `reply`. When the turn ends, the session drops the senders,
/// closing both streams.
pub struct PromptHandle {
    /// Live updates for this turn (closed when the turn completes).
    pub updates: mpsc::UnboundedReceiver<AcpUpdate>,
    /// Mid-turn server requests the agent raised (permission, fs).
    pub requests: mpsc::UnboundedReceiver<AcpServerRequest>,
    /// The final turn outcome.
    pub reply: oneshot::Receiver<Result<AcpOutcome, AcpError>>,
}

/// Mutable per-turn accumulation, shared between the streaming notification
/// handler and the session command loop.
#[derive(Default)]
struct TurnState {
    text: String,
    tool_calls: Vec<AcpToolCall>,
    /// Live sink for the active turn; `None` between turns.
    live: Option<mpsc::UnboundedSender<AcpUpdate>>,
    /// Sink for mid-turn server requests (permission/fs) of the active turn;
    /// `None` between turns (the permission handler then uses the static policy).
    requests: Option<mpsc::UnboundedSender<AcpServerRequest>>,
}

impl TurnState {
    /// Start a fresh turn: clear the accumulators and install the live sinks.
    fn begin(
        &mut self,
        live: mpsc::UnboundedSender<AcpUpdate>,
        requests: mpsc::UnboundedSender<AcpServerRequest>,
    ) {
        self.text.clear();
        self.tool_calls.clear();
        self.live = Some(live);
        self.requests = Some(requests);
    }

    /// Fold one streamed `session/update` into the turn, forwarding it live.
    fn absorb(&mut self, update: SessionUpdate) {
        match update {
            SessionUpdate::AgentMessageChunk(chunk) => {
                if let ContentBlock::Text(text) = chunk.content {
                    self.text.push_str(&text.text);
                    if let Some(sink) = &self.live {
                        let _ = sink.send(AcpUpdate::Text(text.text));
                    }
                }
            }
            SessionUpdate::ToolCall(call) => {
                let id = call.tool_call_id.to_string();
                if let Some(sink) = &self.live {
                    let _ = sink.send(AcpUpdate::ToolCall {
                        id: id.clone(),
                        title: call.title.clone(),
                    });
                }
                self.tool_calls.push(AcpToolCall {
                    id,
                    title: call.title,
                });
            }
            _ => {}
        }
    }

    /// End the turn: drop the live sink and build the outcome from the accumulated
    /// text/tool calls + the prompt's stop reason.
    fn finish(
        &mut self,
        result: Result<StopReason, agent_client_protocol::Error>,
    ) -> Result<AcpOutcome, AcpError> {
        self.live = None;
        self.requests = None;
        let text = std::mem::take(&mut self.text);
        let tool_calls = std::mem::take(&mut self.tool_calls);
        match result {
            Ok(stop) => Ok(AcpOutcome {
                text,
                stop_reason: stop_reason_str(&stop).to_owned(),
                tool_calls,
            }),
            Err(error) => Err(AcpError::Protocol(error.to_string())),
        }
    }
}

/// Command sent from an [`AcpSession`] handle to its driver task.
enum SessionCommand {
    Prompt {
        text: String,
        updates: mpsc::UnboundedSender<AcpUpdate>,
        requests: mpsc::UnboundedSender<AcpServerRequest>,
        reply: oneshot::Sender<Result<AcpOutcome, AcpError>>,
    },
    Close,
}

/// A persistent ACP session: the agent's ACP server is spawned once
/// (`initialize → session/new`) and the connection is kept alive across many
/// `prompt` turns, the native-Rust replacement for the acpx one-shot-per-prompt
/// transcript replay. `cancel` interrupts the in-flight turn (`session/cancel`);
/// `close` tears the session down.
pub struct AcpSession {
    cmd_tx: mpsc::UnboundedSender<SessionCommand>,
    cancel: Arc<Notify>,
}

impl AcpSession {
    /// Spawn the agent's ACP server, run `initialize → session/new`, and return
    /// once the session is ready for prompts. The driver task owns the live
    /// connection until [`close`](Self::close) (or the handle is dropped).
    pub async fn start(
        agent: &str,
        cwd: &Path,
        policy: ApprovalPolicy,
    ) -> Result<AcpSession, AcpError> {
        let server = resolve_agent(agent)?;
        let cwd = cwd.to_path_buf();
        let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel::<SessionCommand>();
        let cancel = Arc::new(Notify::new());
        let cancel_task = Arc::clone(&cancel);
        let turn_state = Arc::new(Mutex::new(TurnState::default()));
        let handler_state = Arc::clone(&turn_state);
        let handler_state_perm = Arc::clone(&turn_state);
        let handler_state_read = Arc::clone(&turn_state);
        let handler_state_write = Arc::clone(&turn_state);
        let (ready_tx, ready_rx) = oneshot::channel::<Result<(), AcpError>>();

        tokio::spawn(async move {
            let driver = agent_client_protocol::Client
                .builder()
                .on_receive_notification(
                    move |notification: SessionNotification, _cx| {
                        let state = Arc::clone(&handler_state);
                        async move {
                            if let Ok(mut turn) = state.lock() {
                                turn.absorb(notification.update);
                            }
                            Ok(())
                        }
                    },
                    agent_client_protocol::on_receive_notification!(),
                )
                .on_receive_request(
                    async move |request: RequestPermissionRequest, responder, cx| {
                        // A3: route to the active turn's request sink so Fae's
                        // approval card decides; fall back to the static policy
                        // when no turn is routing (A1/A2 one-shot behavior).
                        // Run on a spawned task: the routed decision awaits a
                        // reverse round-trip, which would deadlock the dispatch
                        // loop if awaited inline (see `concepts::ordering`).
                        let sink =
                            handler_state_perm.lock().ok().and_then(|turn| turn.requests.clone());
                        cx.clone().spawn(async move {
                            let outcome = match sink {
                                Some(sink) => Self::request_permission(&sink, &request).await,
                                None => Self::fallback_permission(policy, &request),
                            };
                            let _ = responder.respond(RequestPermissionResponse::new(outcome));
                            Ok(())
                        })?;
                        Ok(())
                    },
                    agent_client_protocol::on_receive_request!(),
                )
                .on_receive_request(
                    async move |request: ReadTextFileRequest, responder, cx| {
                        // A3b: delegate fs reads to the client (path/damage policy).
                        let sink =
                            handler_state_read.lock().ok().and_then(|turn| turn.requests.clone());
                        let path = request.path.to_string_lossy().into_owned();
                        cx.clone().spawn(async move {
                            match Self::request_read_file(sink, path).await {
                                Ok(content) => {
                                    let _ = responder.respond(ReadTextFileResponse::new(content));
                                }
                                Err(reason) => {
                                    let _ = responder.respond_with_internal_error(reason);
                                }
                            }
                            Ok(())
                        })?;
                        Ok(())
                    },
                    agent_client_protocol::on_receive_request!(),
                )
                .on_receive_request(
                    async move |request: WriteTextFileRequest, responder, cx| {
                        // A3b: delegate fs writes to the client (path/damage policy).
                        let sink =
                            handler_state_write.lock().ok().and_then(|turn| turn.requests.clone());
                        let path = request.path.to_string_lossy().into_owned();
                        let content = request.content;
                        cx.clone().spawn(async move {
                            match Self::request_write_file(sink, path, content).await {
                                Ok(()) => {
                                    let _ = responder.respond(WriteTextFileResponse::new());
                                }
                                Err(reason) => {
                                    let _ = responder.respond_with_internal_error(reason);
                                }
                            }
                            Ok(())
                        })?;
                        Ok(())
                    },
                    agent_client_protocol::on_receive_request!(),
                )
                .connect_with(server, move |connection: ConnectionTo<Agent>| async move {
                    // initialize → session/new; signal readiness (or the failure).
                    let session_id = match Self::handshake(&connection, cwd).await {
                        Ok(id) => {
                            let _ = ready_tx.send(Ok(()));
                            id
                        }
                        Err(error) => {
                            let _ = ready_tx.send(Err(error));
                            return Ok(());
                        }
                    };

                    while let Some(command) = cmd_rx.recv().await {
                        match command {
                            SessionCommand::Prompt {
                                text,
                                updates,
                                requests,
                                reply,
                            } => {
                                if let Ok(mut turn) = turn_state.lock() {
                                    turn.begin(updates, requests);
                                }
                                let prompt_fut = connection
                                    .send_request(PromptRequest::new(
                                        session_id.clone(),
                                        vec![ContentBlock::Text(TextContent::new(text))],
                                    ))
                                    .block_task();
                                tokio::pin!(prompt_fut);
                                let mut cancelled = false;
                                let stop = loop {
                                    tokio::select! {
                                        result = &mut prompt_fut => break result.map(|r| r.stop_reason),
                                        _ = cancel_task.notified(), if !cancelled => {
                                            cancelled = true;
                                            let _ = connection.send_notification(
                                                CancelNotification::new(session_id.clone()));
                                        }
                                    }
                                };
                                let outcome = match turn_state.lock() {
                                    Ok(mut turn) => turn.finish(stop),
                                    Err(_) => Err(AcpError::Protocol(
                                        "session turn state poisoned".to_owned(),
                                    )),
                                };
                                let _ = reply.send(outcome);
                            }
                            SessionCommand::Close => break,
                        }
                    }
                    Ok::<(), agent_client_protocol::Error>(())
                })
                .await;
            if let Err(error) = driver {
                eprintln!("fae-acp: session driver ended with error: {error}");
            }
        });

        match ready_rx.await {
            Ok(Ok(())) => Ok(AcpSession { cmd_tx, cancel }),
            Ok(Err(error)) => Err(error),
            Err(_) => Err(AcpError::Protocol(
                "session driver ended before it became ready".to_owned(),
            )),
        }
    }

    /// `initialize → session/new`, returning the ACP session id.
    async fn handshake(
        connection: &ConnectionTo<Agent>,
        cwd: std::path::PathBuf,
    ) -> Result<agent_client_protocol::schema::SessionId, AcpError> {
        // Advertise client-side fs so the agent delegates reads/writes to us,
        // where the path/damage policy mediates them (gap A3b).
        let capabilities = ClientCapabilities::default().fs(FileSystemCapabilities::default()
            .read_text_file(true)
            .write_text_file(true));
        connection
            .send_request(
                InitializeRequest::new(ProtocolVersion::V1).client_capabilities(capabilities),
            )
            .block_task()
            .await
            .map_err(|error| AcpError::Protocol(error.to_string()))?;
        let session = connection
            .send_request(NewSessionRequest::new(cwd))
            .block_task()
            .await
            .map_err(|error| AcpError::Protocol(error.to_string()))?;
        Ok(session.session_id)
    }

    /// Submit a prompt to the live session, returning a streaming handle. The
    /// caller drains `updates` (republishing events) and awaits `reply` for the
    /// final outcome.
    pub fn prompt(&self, text: String) -> Result<PromptHandle, AcpError> {
        let (updates_tx, updates_rx) = mpsc::unbounded_channel();
        let (requests_tx, requests_rx) = mpsc::unbounded_channel();
        let (reply_tx, reply_rx) = oneshot::channel();
        self.cmd_tx
            .send(SessionCommand::Prompt {
                text,
                updates: updates_tx,
                requests: requests_tx,
                reply: reply_tx,
            })
            .map_err(|_| AcpError::Protocol("session is closed".to_owned()))?;
        Ok(PromptHandle {
            updates: updates_rx,
            requests: requests_rx,
            reply: reply_rx,
        })
    }

    /// Drive one permission request to the client (via the turn's request sink)
    /// and map its decision back to an ACP outcome. A closed sink or cancelled
    /// decision declines the request (fail-safe).
    async fn request_permission(
        sink: &mpsc::UnboundedSender<AcpServerRequest>,
        request: &RequestPermissionRequest,
    ) -> RequestPermissionOutcome {
        let options: Vec<AcpPermissionOption> = request
            .options
            .iter()
            .map(|opt| AcpPermissionOption {
                id: opt.option_id.to_string(),
                name: opt.name.clone(),
                kind: format!("{:?}", opt.kind),
            })
            .collect();
        let title = serde_json::to_value(&request.tool_call)
            .ok()
            .and_then(|value| {
                value
                    .get("title")
                    .and_then(serde_json::Value::as_str)
                    .map(str::to_owned)
            })
            .unwrap_or_default();
        let (reply_tx, reply_rx) = oneshot::channel();
        if sink
            .send(AcpServerRequest::Permission {
                title,
                options,
                reply: reply_tx,
            })
            .is_err()
        {
            return RequestPermissionOutcome::Cancelled;
        }
        match reply_rx.await {
            Ok(AcpPermissionDecision::Selected(option_id)) => request
                .options
                .iter()
                .find(|opt| opt.option_id.to_string() == option_id)
                .map(|opt| {
                    RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(
                        opt.option_id.clone(),
                    ))
                })
                .unwrap_or(RequestPermissionOutcome::Cancelled),
            _ => RequestPermissionOutcome::Cancelled,
        }
    }

    /// Drive one `fs/read_text_file` to the client (gap A3b) and return the
    /// contents or a refusal reason. No turn routing (e.g. one-shot) refuses.
    async fn request_read_file(
        sink: Option<mpsc::UnboundedSender<AcpServerRequest>>,
        path: String,
    ) -> Result<String, String> {
        let Some(sink) = sink else {
            return Err("filesystem mediation unavailable".to_owned());
        };
        let (reply_tx, reply_rx) = oneshot::channel();
        if sink
            .send(AcpServerRequest::ReadFile {
                path,
                reply: reply_tx,
            })
            .is_err()
        {
            return Err("filesystem channel closed".to_owned());
        }
        match reply_rx.await {
            Ok(result) => result,
            Err(_) => Err("no filesystem response".to_owned()),
        }
    }

    /// Drive one `fs/write_text_file` to the client (gap A3b) and return `Ok` or
    /// a refusal reason. No turn routing (e.g. one-shot) refuses.
    async fn request_write_file(
        sink: Option<mpsc::UnboundedSender<AcpServerRequest>>,
        path: String,
        content: String,
    ) -> Result<(), String> {
        let Some(sink) = sink else {
            return Err("filesystem mediation unavailable".to_owned());
        };
        let (reply_tx, reply_rx) = oneshot::channel();
        if sink
            .send(AcpServerRequest::WriteFile {
                path,
                content,
                reply: reply_tx,
            })
            .is_err()
        {
            return Err("filesystem channel closed".to_owned());
        }
        match reply_rx.await {
            Ok(result) => result,
            Err(_) => Err("no filesystem response".to_owned()),
        }
    }

    /// The A1/A2 fallback: approve the first option or decline, per the static
    /// policy. Used when no turn is routing permissions (e.g. `run_one_shot`).
    fn fallback_permission(
        policy: ApprovalPolicy,
        request: &RequestPermissionRequest,
    ) -> RequestPermissionOutcome {
        match policy {
            ApprovalPolicy::ApproveAll => request
                .options
                .first()
                .map(|opt| {
                    RequestPermissionOutcome::Selected(SelectedPermissionOutcome::new(
                        opt.option_id.clone(),
                    ))
                })
                .unwrap_or(RequestPermissionOutcome::Cancelled),
            ApprovalPolicy::DenyAll => RequestPermissionOutcome::Cancelled,
        }
    }

    /// Cancel the in-flight turn (`session/cancel`). A no-op if no turn is
    /// running; the cancelled turn resolves with stop reason `cancelled`.
    pub fn cancel(&self) {
        self.cancel.notify_waiters();
    }

    /// Tear the session down: the driver task ends and the agent server exits.
    pub fn close(&self) {
        let _ = self.cmd_tx.send(SessionCommand::Close);
    }
}

fn launch_err(error: impl std::fmt::Display) -> AcpError {
    AcpError::Launch(error.to_string())
}

fn stop_reason_str(reason: &StopReason) -> &'static str {
    match reason {
        StopReason::EndTurn => "end_turn",
        StopReason::MaxTokens => "max_tokens",
        StopReason::MaxTurnRequests => "max_turn_requests",
        StopReason::Refusal => "refusal",
        StopReason::Cancelled => "cancelled",
        _ => "unknown",
    }
}

/// Accumulates streamed `session/update` events into a final outcome.
#[derive(Debug, Default, Clone)]
struct Collector {
    text: String,
    tool_calls: Vec<AcpToolCall>,
}

impl Collector {
    fn absorb(&mut self, update: SessionUpdate) {
        match update {
            SessionUpdate::AgentMessageChunk(chunk) => {
                if let ContentBlock::Text(text) = chunk.content {
                    self.text.push_str(&text.text);
                }
            }
            SessionUpdate::ToolCall(call) => self.tool_calls.push(AcpToolCall {
                id: call.tool_call_id.to_string(),
                title: call.title,
            }),
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unknown_agent_is_rejected() {
        assert!(matches!(
            resolve_agent("definitely-not-an-agent"),
            Err(AcpError::UnknownAgent(_))
        ));
    }

    #[test]
    fn known_agents_resolve() {
        for name in ["claude", "codex", "gemini", "pi", "copilot"] {
            assert!(resolve_agent(name).is_ok(), "agent {name} should resolve");
        }
    }

    #[test]
    fn stop_reasons_map_to_wire_strings() {
        assert_eq!(stop_reason_str(&StopReason::EndTurn), "end_turn");
        assert_eq!(stop_reason_str(&StopReason::Cancelled), "cancelled");
    }

    #[tokio::test]
    async fn session_start_rejects_unknown_agent() {
        let result = AcpSession::start(
            "definitely-not-an-agent",
            Path::new("/tmp"),
            ApprovalPolicy::DenyAll,
        )
        .await;
        assert!(matches!(result, Err(AcpError::UnknownAgent(_))));
    }

    #[test]
    fn turn_state_streams_and_accumulates() {
        // The streaming sink and the final accumulation see the same text/tool
        // calls — the orb narration and the tool's final result stay in sync.
        let (tx, mut rx) = mpsc::unbounded_channel();
        let (req_tx, _req_rx) = mpsc::unbounded_channel();
        let mut turn = TurnState::default();
        turn.begin(tx, req_tx);
        turn.absorb(SessionUpdate::AgentMessageChunk(
            agent_client_protocol::schema::ContentChunk::new(ContentBlock::Text(TextContent::new(
                "hello ".to_owned(),
            ))),
        ));
        turn.absorb(SessionUpdate::AgentMessageChunk(
            agent_client_protocol::schema::ContentChunk::new(ContentBlock::Text(TextContent::new(
                "world".to_owned(),
            ))),
        ));
        let outcome = turn.finish(Ok(StopReason::EndTurn)).expect("outcome built");
        assert_eq!(outcome.text, "hello world");
        assert_eq!(outcome.stop_reason, "end_turn");
        assert_eq!(rx.try_recv(), Ok(AcpUpdate::Text("hello ".to_owned())));
        assert_eq!(rx.try_recv(), Ok(AcpUpdate::Text("world".to_owned())));
        // Finishing dropped the live sink, so the stream is closed.
        assert!(rx.try_recv().is_err());
    }
}
