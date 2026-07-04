//! Authenticated fae-daemon Unix-socket NDJSON client.
//!
//! The daemon speaks one JSON [`fae_control_plane::Command`] per line and
//! answers with one [`fae_control_plane::Response`] per request (see
//! `fae-daemon/src/transport.rs`). A fresh connection is **unauthenticated**;
//! the first frame MUST be `session.authenticate` carrying `{ client_id, token }`
//! (see `fae-daemon/src/session.rs::AuthPayload`). Once authenticated, the
//! session accepts scoped commands — here, `conversation.delegate`, which runs
//! the daemon's native jailed agentic loop (Phase F1) and returns
//! `{ text, status, receipt_id, iterations, tokens }`.
//!
//! This is a thin, blocking-per-request client: each call writes one frame and
//! reads until the matching response. Unsolicited server-push `event` frames
//! (only delivered to subscribers, which this client never becomes) are skipped
//! defensively.

use std::path::{Path, PathBuf};

use fae_control_plane::{Command, Response};
use serde::Deserialize;
use serde_json::json;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};
use tokio::net::UnixStream;

/// The control-plane protocol envelope version the daemon speaks (ADR-002 v2).
/// Mirrors `fae_control_plane`'s internal `PROTOCOL_VERSION`; pinned here so a
/// bump surfaces as an explicit compile-site edit rather than silent drift.
const PROTOCOL_VERSION: u16 = 2;

/// A failure talking to the fae-daemon control socket. Every variant is
/// terminal for the current turn — the runner maps them to a runner error so
/// the orchestrator releases/retries rather than publishing a bogus handoff.
#[derive(Debug, thiserror::Error)]
pub enum DaemonError {
    /// The Unix socket could not be reached (daemon down / wrong path).
    #[error("connect to daemon socket {path} failed: {source}")]
    Connect {
        /// The socket path that failed to connect.
        path: PathBuf,
        /// The underlying OS error.
        source: std::io::Error,
    },
    /// A read/write on an established connection failed.
    #[error("daemon socket io error: {0}")]
    Io(#[from] std::io::Error),
    /// The daemon closed the connection before answering the request.
    #[error("daemon closed the connection before responding to {command}")]
    Closed {
        /// The command awaiting a response when the socket closed.
        command: String,
    },
    /// A response line could not be parsed as a control-plane [`Response`].
    #[error("malformed daemon response to {command}: {reason}")]
    Decode {
        /// The command whose response failed to decode.
        command: String,
        /// A human-readable decode reason.
        reason: String,
    },
    /// The daemon answered but denied/failed the command (`ok == false`).
    #[error("daemon rejected {command}: {code}: {message}")]
    Rejected {
        /// The rejected command name.
        command: String,
        /// The machine-readable error code from the daemon.
        code: String,
        /// The human-readable error message from the daemon.
        message: String,
    },
}

/// Hard budgets forwarded to `conversation.delegate`. The daemon re-clamps both
/// to its own ceilings (`MAX_ITERATIONS_CEILING` / `TOKEN_CEILING`), so these
/// are a request, never a guarantee.
#[derive(Debug, Clone, Copy)]
pub struct DelegationBudget {
    /// Requested iteration cap (one tool-executing turn per iteration).
    pub max_iterations: u32,
    /// Requested cumulative output-token cap.
    pub max_output_tokens: u32,
}

impl Default for DelegationBudget {
    fn default() -> Self {
        // Conservative defaults; the daemon clamps to its ceilings regardless.
        Self {
            max_iterations: 8,
            max_output_tokens: 8192,
        }
    }
}

/// The `conversation.delegate` result payload (Phase F1 shape).
#[derive(Debug, Clone, Deserialize)]
pub struct DelegationResponse {
    /// The worker's final (or last) visible text.
    #[serde(default)]
    pub text: String,
    /// Terminal status: `completed` | `budget_exhausted`.
    #[serde(default)]
    pub status: String,
    /// The persisted delegation-receipt id (`del-…`).
    #[serde(default)]
    pub receipt_id: String,
    /// Iterations consumed.
    #[serde(default)]
    pub iterations: u32,
    /// Approximate output tokens consumed.
    #[serde(default)]
    pub tokens: u32,
}

impl DelegationResponse {
    /// True when the delegation produced a final answer (no budget trip).
    #[must_use]
    pub fn is_completed(&self) -> bool {
        self.status == "completed"
    }
}

/// One authenticated connection to the daemon control socket.
pub struct DaemonClient {
    reader: BufReader<OwnedReadHalf>,
    writer: OwnedWriteHalf,
    next_id: u64,
}

impl DaemonClient {
    /// Open a fresh (unauthenticated) connection to the daemon Unix socket.
    ///
    /// # Errors
    /// Returns [`DaemonError::Connect`] if the socket cannot be reached.
    pub async fn connect(socket_path: &Path) -> Result<Self, DaemonError> {
        let stream =
            UnixStream::connect(socket_path)
                .await
                .map_err(|source| DaemonError::Connect {
                    path: socket_path.to_path_buf(),
                    source,
                })?;
        let (read_half, write_half) = stream.into_split();
        Ok(Self {
            reader: BufReader::new(read_half),
            writer: write_half,
            next_id: 0,
        })
    }

    fn next_request_id(&mut self) -> String {
        self.next_id = self.next_id.wrapping_add(1);
        format!("runner-{}", self.next_id)
    }

    /// Send one command and await its matching response payload. Server-push
    /// `event` frames (never solicited by this client) are skipped.
    async fn request(
        &mut self,
        command: &str,
        payload: serde_json::Value,
    ) -> Result<serde_json::Value, DaemonError> {
        let request_id = self.next_request_id();
        let cmd = Command {
            v: PROTOCOL_VERSION,
            request_id: request_id.clone(),
            command: command.to_owned(),
            payload,
        };
        let mut line = serde_json::to_string(&cmd).map_err(|source| DaemonError::Decode {
            command: command.to_owned(),
            reason: format!("failed to encode request: {source}"),
        })?;
        line.push('\n');
        self.writer.write_all(line.as_bytes()).await?;
        self.writer.flush().await?;

        loop {
            let mut buf = String::new();
            let read = self.reader.read_line(&mut buf).await?;
            if read == 0 {
                return Err(DaemonError::Closed {
                    command: command.to_owned(),
                });
            }
            let trimmed = buf.trim();
            if trimmed.is_empty() {
                continue;
            }
            // Classify the frame before decoding it as a command response.
            if let Ok(value) = serde_json::from_str::<serde_json::Value>(trimmed) {
                // Server-push event frame (has `event`, no `request_id`): skip.
                if value.get("event").is_some() && value.get("request_id").is_none() {
                    continue;
                }
                // Server-INITIATED request (`{server_request_id, method, params}`).
                // During `conversation.delegate` the daemon round-trips a
                // `tool.confirm` before running a dangerous (write/edit/bash) tool
                // in the jailed loop. An autonomous symphony worker PRE-AUTHORIZES
                // its own delegation and answers it — see `answer_server_request`.
                if let (Some(sr_id), Some(method)) = (
                    value.get("server_request_id").and_then(|v| v.as_str()),
                    value.get("method").and_then(|v| v.as_str()),
                ) {
                    self.answer_server_request(sr_id, method).await?;
                    continue;
                }
            }
            let response: Response =
                serde_json::from_str(trimmed).map_err(|source| DaemonError::Decode {
                    command: command.to_owned(),
                    reason: format!("failed to decode response: {source}"),
                })?;
            if response.request_id != request_id {
                // A response for another request should not happen on a
                // single-flight client; skip it rather than mis-attribute.
                continue;
            }
            if !response.ok {
                let (code, message) = response.error.map_or_else(
                    || ("unknown".to_owned(), "daemon returned ok=false".to_owned()),
                    |error| (error.code, error.message),
                );
                return Err(DaemonError::Rejected {
                    command: command.to_owned(),
                    code,
                    message,
                });
            }
            return Ok(response.result.unwrap_or(serde_json::Value::Null));
        }
    }

    /// Answer a daemon-initiated `{server_request_id, method, params}` request.
    ///
    /// The only such request a `conversation.delegate` turn raises is
    /// `tool.confirm`: the jailed loop is about to run a dangerous (write / edit /
    /// bash) tool and the daemon asks the client to approve it. An autonomous
    /// symphony worker **pre-authorizes its own delegation** — it already pinned a
    /// conservative leaf toolset in the request, and the daemon confines every
    /// mutation to the issue workspace via the OS jail (a write outside the root
    /// is denied WITHOUT any prompt). The jail, not an interactive owner card, is
    /// the boundary here, so the runner replies `{approved: true}`.
    ///
    /// Any OTHER method is answered `{approved: false}` so an unexpected
    /// round-trip fails closed rather than hanging the turn.
    async fn answer_server_request(
        &mut self,
        server_request_id: &str,
        method: &str,
    ) -> Result<(), DaemonError> {
        let approved = method == "tool.confirm";
        if approved {
            tracing::debug!(
                server_request_id,
                method,
                "runner auto-approving delegated tool confirm"
            );
        } else {
            tracing::warn!(
                server_request_id,
                method,
                "runner denying unexpected server request"
            );
        }
        let reply = json!({
            "v": PROTOCOL_VERSION,
            "server_request_id": server_request_id,
            "result": { "approved": approved },
        });
        let mut line = serde_json::to_string(&reply).map_err(|source| DaemonError::Decode {
            command: method.to_owned(),
            reason: format!("failed to encode server-request reply: {source}"),
        })?;
        line.push('\n');
        self.writer.write_all(line.as_bytes()).await?;
        self.writer.flush().await?;
        Ok(())
    }

    /// Establish the session: send `session.authenticate` with `client_id` +
    /// `token`. Must be the first frame on a fresh connection.
    ///
    /// # Errors
    /// Returns [`DaemonError::Rejected`] if the token/client id is not accepted.
    pub async fn authenticate(&mut self, client_id: &str, token: &str) -> Result<(), DaemonError> {
        self.request(
            "session.authenticate",
            json!({ "client_id": client_id, "token": token }),
        )
        .await
        .map(|_| ())
    }

    /// Run one delegation via `conversation.delegate` (Phase F1: single
    /// delegation, `role` defaults to leaf daemon-side, `depth` 0). The
    /// `workspace_root` is passed verbatim to the daemon, which validates it
    /// (absolute/exists/dir/not-protected) before rooting the ephemeral jailed
    /// ToolHost there.
    ///
    /// `role` is intentionally omitted from the payload: the daemon's
    /// `DelegationRequest.role` is `#[serde(default)]` and defaults to `Leaf`,
    /// which is the F3 contract (a leaf worker that does not fan out). Sending
    /// no `role` guarantees the correct default is carried into the receipt.
    ///
    /// # Errors
    /// Propagates any [`DaemonError`]; a non-`completed` status is returned in
    /// the [`DelegationResponse`] (not an error) so the caller can classify it.
    pub async fn delegate(
        &mut self,
        prompt: &str,
        toolset: &[String],
        workspace_root: &Path,
        budget: DelegationBudget,
    ) -> Result<DelegationResponse, DaemonError> {
        let payload = json!({
            "prompt": prompt,
            "toolset": toolset,
            "workspace_root": workspace_root,
            "max_iterations": budget.max_iterations,
            "max_output_tokens": budget.max_output_tokens,
            "depth": 0,
        });
        let result = self.request("conversation.delegate", payload).await?;
        serde_json::from_value(result).map_err(|source| DaemonError::Decode {
            command: "conversation.delegate".to_owned(),
            reason: format!("failed to decode delegation response: {source}"),
        })
    }
}
