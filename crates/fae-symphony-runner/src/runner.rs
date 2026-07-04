//! [`FaeRunner`] — an x0x-symphony [`Runner`] backed by the fae-daemon socket.
//!
//! The orchestrator drives every claimed issue through this trait:
//! `start_session` → `run_turn` → `stop_session`. `FaeRunner` maps that lifecycle
//! onto the daemon's `conversation.delegate` command:
//!
//! * `start_session` — verify the daemon is reachable and the token is accepted
//!   (fail fast on a dead/misconfigured daemon), and stash the workspace path in
//!   the returned [`SessionHandle`]. A live socket is intentionally NOT held in
//!   the handle: [`SessionHandle`] is a plain serialisable value, and a
//!   delegation is one blocking round-trip, so `run_turn` opens a fresh
//!   authenticated connection per turn.
//! * `run_turn` — open a connection, authenticate, and delegate the issue
//!   description into the daemon's native jailed agentic loop, rooted at the
//!   session's `workspace_path`. The daemon does the ToolHost jailing, budget
//!   enforcement, and mutation receipts; the runner just carries the request and
//!   classifies the terminal status.
//! * `stream_events` — `stream::empty` for v1. Delegation is a single blocking
//!   round-trip with no incremental event surface yet; structured event
//!   fidelity is a documented fast-follow (see README).
//! * `stop_session` — no daemon-side session to tear down (each turn is
//!   self-contained), so an empty [`UsageReport`].

use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use async_trait::async_trait;
use futures_util::stream;
use x0x_symphony_core::{
    EventStream, Prompt, Result as CoreResult, Runner, RunnerCapabilities, SessionContext,
    SessionHandle, SessionId, SymphonyError, TurnOutcome, TurnStatus, UsageReport,
};

use crate::daemon_client::{DaemonClient, DaemonError, DelegationBudget};

/// The conservative default toolset a delegated leaf worker is permitted to
/// call. Anything the model names outside this set is rejected by the daemon
/// without executing.
pub const DEFAULT_TOOLSET: [&str; 6] = ["read", "write", "edit", "bash", "glob", "grep"];

/// Runner kind advertised to the orchestrator (recorded in proof manifests).
const RUNNER_KIND: &str = "fae-daemon";

/// A [`Runner`] that executes claimed work by delegating to a local fae-daemon.
pub struct FaeRunner {
    socket_path: PathBuf,
    client_id: String,
    token: String,
    toolset: Vec<String>,
    budget: DelegationBudget,
    capabilities: RunnerCapabilities,
}

impl FaeRunner {
    /// Build a runner bound to a daemon control socket and its auth token.
    ///
    /// `toolset` is the leaf worker's tool allowlist; pass [`DEFAULT_TOOLSET`]
    /// for the standard read/write/edit/bash/glob/grep set.
    #[must_use]
    pub fn new(
        socket_path: PathBuf,
        client_id: impl Into<String>,
        token: impl Into<String>,
        toolset: Vec<String>,
        budget: DelegationBudget,
    ) -> Self {
        let capabilities = RunnerCapabilities::new(RUNNER_KIND)
            .with_command_line(RUNNER_KIND, ["conversation.delegate"]);
        Self {
            socket_path,
            client_id: client_id.into(),
            token: token.into(),
            toolset,
            budget,
            capabilities,
        }
    }

    /// Convenience constructor using [`DEFAULT_TOOLSET`] and the default budget.
    #[must_use]
    pub fn with_defaults(
        socket_path: PathBuf,
        client_id: impl Into<String>,
        token: impl Into<String>,
    ) -> Self {
        Self::new(
            socket_path,
            client_id,
            token,
            DEFAULT_TOOLSET.iter().map(|t| (*t).to_owned()).collect(),
            DelegationBudget::default(),
        )
    }

    /// Open and authenticate a fresh daemon connection.
    async fn connect_authenticated(&self) -> Result<DaemonClient, DaemonError> {
        let mut client = DaemonClient::connect(&self.socket_path).await?;
        client.authenticate(&self.client_id, &self.token).await?;
        Ok(client)
    }
}

/// Map any daemon error into a symphony runner error so the orchestrator treats
/// it as a failed turn (release + retry) rather than a handoff.
fn runner_error(error: DaemonError) -> SymphonyError {
    SymphonyError::Runner(error.to_string())
}

fn now_millis_string() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis().to_string())
        .unwrap_or_else(|_| "0".to_owned())
}

#[async_trait]
impl Runner for FaeRunner {
    fn name(&self) -> &'static str {
        RUNNER_KIND
    }

    fn capabilities(&self) -> &RunnerCapabilities {
        &self.capabilities
    }

    async fn start_session(&self, ctx: SessionContext) -> CoreResult<SessionHandle> {
        // Fail fast: prove the daemon is reachable and the token is accepted
        // before the orchestrator commits the turn. The connection is dropped
        // immediately; run_turn opens its own.
        let _client = self.connect_authenticated().await.map_err(runner_error)?;
        let session_id = SessionId::new(format!("fae-{}", ctx.issue.id.as_str()));
        Ok(SessionHandle::new(
            session_id,
            ctx.workspace_path,
            now_millis_string(),
        ))
    }

    async fn run_turn(&self, sess: &mut SessionHandle, prompt: Prompt) -> CoreResult<TurnOutcome> {
        let started = SystemTime::now();
        let mut client = self.connect_authenticated().await.map_err(runner_error)?;
        let response = client
            .delegate(
                prompt.as_str(),
                &self.toolset,
                &sess.workspace_path,
                self.budget,
            )
            .await
            .map_err(runner_error)?;

        let status = if response.is_completed() {
            TurnStatus::Succeeded
        } else {
            // budget_exhausted (or any non-completed terminal) is a failed turn:
            // the retry loop decides whether to re-run or block.
            TurnStatus::Failed
        };

        let mut usage = UsageReport::new();
        usage.output_tokens = Some(u64::from(response.tokens));
        usage.total_tokens = Some(u64::from(response.tokens));
        usage.duration_ms = started
            .elapsed()
            .ok()
            .and_then(|d| u64::try_from(d.as_millis()).ok());

        // Carry the worker's answer as the turn summary. The orchestrator
        // derives `files_changed` from `git diff` in the workspace (not from
        // this text) and scrapes optional `follow_up:` lines from it.
        Ok(TurnOutcome::new(status, usage).with_summary(response.text))
    }

    fn stream_events(&self, _sess: &SessionHandle) -> EventStream {
        // v1: no incremental event surface. A single blocking delegation
        // round-trip has no streaming yet; event mapping is a fast-follow.
        Box::pin(stream::empty())
    }

    async fn stop_session(&self, _sess: SessionHandle) -> CoreResult<UsageReport> {
        // Each turn is a self-contained connection; nothing to tear down.
        Ok(UsageReport::new())
    }
}
