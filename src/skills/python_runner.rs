//! Process lifecycle management and JSON-RPC communication for Python skill subprocesses.
//!
//! Each Python skill runs as a child process spawned via `uv run`. This module
//! provides:
//!
//! - [`PythonProcessState`] / [`PythonSkillProcess`]: lifecycle state machine with
//!   guaranteed cleanup on drop.
//! - [`JsonRpcComm`]: sends JSON-RPC 2.0 requests over stdin and reads newline-
//!   delimited responses from stdout with timeout and output-size bounds.

use super::error::PythonSkillError;
use super::python_protocol::{
    HandshakeParams, HandshakeResult, HealthResult, JsonRpcRequest, METHOD_HANDSHAKE,
    METHOD_HEALTH, SkillMessage,
};
use std::fmt;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout};
use tokio::time::timeout;

/// Global monotonic request ID counter shared across all comm instances.
///
/// Using a global counter avoids id collisions if multiple `JsonRpcComm`
/// instances are alive simultaneously (e.g. during restarts).
static NEXT_REQUEST_ID: AtomicU64 = AtomicU64::new(1);

/// Returns the next unique request id, incrementing the global counter.
fn next_id() -> u64 {
    NEXT_REQUEST_ID.fetch_add(1, Ordering::Relaxed)
}

/// Maximum number of bytes accepted per response line (100 KB).
const MAX_LINE_BYTES: usize = 100 * 1024;

/// Process lifecycle states.
///
/// ```text
/// Pending → Starting → Running → Stopped
///               ↓          ↓
///             Failed     Failed
/// ```
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PythonProcessState {
    /// Process has not been spawned yet.
    Pending,
    /// Process is spawning / performing handshake.
    Starting,
    /// Process is running and ready to accept requests.
    Running,
    /// Process encountered a fatal error.
    Failed,
    /// Process has been intentionally stopped.
    Stopped,
}

impl PythonProcessState {
    /// Returns `true` if the process is in a terminal state.
    pub fn is_terminal(self) -> bool {
        matches!(self, Self::Failed | Self::Stopped)
    }

    /// Returns `true` if a transition from `self` to `target` is valid.
    pub fn can_transition_to(self, target: Self) -> bool {
        matches!(
            (self, target),
            (Self::Pending, Self::Starting)
                | (Self::Starting, Self::Running)
                | (Self::Starting, Self::Failed)
                | (Self::Running, Self::Stopped)
                | (Self::Running, Self::Failed)
                // Allow restart: Stopped/Failed → Pending
                | (Self::Failed, Self::Pending)
                | (Self::Stopped, Self::Pending)
        )
    }
}

impl fmt::Display for PythonProcessState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let label = match self {
            Self::Pending => "pending",
            Self::Starting => "starting",
            Self::Running => "running",
            Self::Failed => "failed",
            Self::Stopped => "stopped",
        };
        f.write_str(label)
    }
}

/// A managed Python skill child process.
///
/// Wraps a [`tokio::process::Child`] with lifecycle state tracking.
/// The child process is killed when this value is dropped.
pub struct PythonSkillProcess {
    /// Current lifecycle state.
    state: PythonProcessState,
    /// The underlying child process, if spawned.
    child: Option<Child>,
    /// Human-readable name for logging.
    skill_name: String,
}

impl PythonSkillProcess {
    /// Creates a new process handle in `Pending` state (no child yet).
    pub fn new(skill_name: &str) -> Self {
        Self {
            state: PythonProcessState::Pending,
            child: None,
            skill_name: skill_name.to_owned(),
        }
    }

    /// Returns the current process state.
    pub fn state(&self) -> PythonProcessState {
        self.state
    }

    /// Returns the skill name.
    pub fn skill_name(&self) -> &str {
        &self.skill_name
    }

    /// Returns `true` if the process is alive (has a child that hasn't exited).
    pub fn is_alive(&mut self) -> bool {
        let Some(child) = self.child.as_mut() else {
            return false;
        };
        // try_wait returns Ok(Some(status)) if exited, Ok(None) if still running
        match child.try_wait() {
            Ok(Some(_)) => false,
            Ok(None) => true,
            Err(_) => false,
        }
    }

    /// Transitions to a new state, returning an error if the transition is invalid.
    pub fn transition(&mut self, target: PythonProcessState) -> Result<(), PythonSkillError> {
        if !self.state.can_transition_to(target) {
            return Err(PythonSkillError::ProtocolError {
                message: format!(
                    "invalid state transition: {} → {} (skill: {})",
                    self.state, target, self.skill_name
                ),
            });
        }
        tracing::debug!(
            skill = %self.skill_name,
            from = %self.state,
            to = %target,
            "process state transition"
        );
        self.state = target;
        Ok(())
    }

    /// Attaches a spawned child process and transitions to `Starting`.
    pub fn attach(&mut self, child: Child) -> Result<(), PythonSkillError> {
        self.transition(PythonProcessState::Starting)?;
        self.child = Some(child);
        Ok(())
    }

    /// Takes ownership of the child process (if any).
    ///
    /// After calling this the process handle no longer tracks a child, so
    /// drop will not kill anything. The caller assumes responsibility.
    pub fn take_child(&mut self) -> Option<Child> {
        self.child.take()
    }

    /// Returns a mutable reference to the child, if one is attached.
    pub fn child_mut(&mut self) -> Option<&mut Child> {
        self.child.as_mut()
    }

    /// Kills the child process (if running) and transitions to `Stopped`.
    ///
    /// This is a best-effort operation — if kill fails the state still
    /// transitions to `Stopped` because we cannot meaningfully recover.
    pub async fn kill(&mut self) {
        if let Some(ref mut child) = self.child {
            let _ = child.kill().await;
            // Wait to reap the zombie
            let _ = child.wait().await;
        }
        self.child = None;
        // Force to Stopped regardless of current state
        self.state = PythonProcessState::Stopped;
    }
}

impl Drop for PythonSkillProcess {
    fn drop(&mut self) {
        if let Some(ref mut child) = self.child {
            // In Drop we cannot use async, so use start_kill() which sends
            // SIGKILL without waiting. The OS reaps the zombie eventually.
            let _ = child.start_kill();
            tracing::debug!(
                skill = %self.skill_name,
                "killed skill process on drop"
            );
        }
    }
}

impl fmt::Debug for PythonSkillProcess {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PythonSkillProcess")
            .field("skill_name", &self.skill_name)
            .field("state", &self.state)
            .field("has_child", &self.child.is_some())
            .finish()
    }
}

// ── JSON-RPC 2.0 communication layer ─────────────────────────────────────────

/// Result of a single [`JsonRpcComm::send_request`] call.
///
/// The skill may return a success response, an error response, or any number
/// of notifications before the final response arrives. Notifications are
/// collected and returned alongside the response.
#[derive(Debug)]
pub struct RpcOutcome {
    /// The skill's response (success or error).
    pub message: SkillMessage,
    /// Notifications received before the response, in arrival order.
    pub notifications: Vec<SkillMessage>,
}

/// JSON-RPC 2.0 communication layer over a child process's stdin/stdout.
///
/// Holds buffered I/O handles split from a [`tokio::process::Child`] and
/// provides [`send_request`](JsonRpcComm::send_request) which writes a
/// newline-delimited JSON request and reads a matching response, with:
///
/// - A configurable timeout (returns [`PythonSkillError::Timeout`] on expiry).
/// - A 100 KB per-line output bound (returns [`PythonSkillError::OutputTruncated`]).
/// - Broken-pipe detection on write (returns [`PythonSkillError::ProcessExited`]).
/// - Notification collection: notifications received before the response are
///   bundled into [`RpcOutcome::notifications`].
pub struct JsonRpcComm {
    stdin: ChildStdin,
    stdout: BufReader<ChildStdout>,
    skill_name: String,
}

impl fmt::Debug for JsonRpcComm {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("JsonRpcComm")
            .field("skill_name", &self.skill_name)
            .finish()
    }
}

impl JsonRpcComm {
    /// Wraps a child's stdio handles.
    ///
    /// The `stdin` and `stdout` must have been taken from the child before
    /// calling this (e.g. via [`Child::stdin`] / [`Child::stdout`]).
    pub fn new(stdin: ChildStdin, stdout: ChildStdout, skill_name: &str) -> Self {
        Self {
            stdin,
            stdout: BufReader::new(stdout),
            skill_name: skill_name.to_owned(),
        }
    }

    /// Constructs a [`JsonRpcComm`] by taking stdio from a child process.
    ///
    /// Returns `None` if the child did not have stdin or stdout piped.
    pub fn from_child(child: &mut Child, skill_name: &str) -> Option<Self> {
        let stdin = child.stdin.take()?;
        let stdout = child.stdout.take()?;
        Some(Self::new(stdin, stdout, skill_name))
    }

    /// Sends a JSON-RPC 2.0 request and waits for the correlated response.
    ///
    /// Notifications that arrive before the response are collected and returned
    /// in [`RpcOutcome::notifications`].
    ///
    /// # Errors
    ///
    /// - [`PythonSkillError::Timeout`] — no response within `deadline`.
    /// - [`PythonSkillError::ProcessExited`] — stdin broken pipe on write.
    /// - [`PythonSkillError::OutputTruncated`] — a response line exceeded 100 KB.
    /// - [`PythonSkillError::ProtocolError`] — response id did not match request.
    pub async fn send_request(
        &mut self,
        request: &JsonRpcRequest,
        deadline: Duration,
    ) -> Result<RpcOutcome, PythonSkillError> {
        let line = request.to_line()?;

        tracing::debug!(
            skill = %self.skill_name,
            method = %request.method,
            id = request.id,
            "sending JSON-RPC request"
        );

        // Write request to child stdin.
        self.write_line(&line).await?;

        // Read response with deadline.
        timeout(deadline, self.read_response(request.id))
            .await
            .map_err(|_| PythonSkillError::Timeout {
                timeout_secs: deadline.as_secs(),
            })?
    }

    /// Reads the next [`SkillMessage`] from stdout without sending a request.
    ///
    /// Useful for draining notifications after a request.
    ///
    /// # Errors
    ///
    /// - [`PythonSkillError::Timeout`] — no message within `deadline`.
    /// - [`PythonSkillError::OutputTruncated`] — line exceeded 100 KB.
    /// - [`PythonSkillError::ProcessExited`] — stdout closed (EOF).
    pub async fn recv_message(
        &mut self,
        deadline: Duration,
    ) -> Result<SkillMessage, PythonSkillError> {
        timeout(deadline, self.read_one_message())
            .await
            .map_err(|_| PythonSkillError::Timeout {
                timeout_secs: deadline.as_secs(),
            })?
    }

    // ── Handshake & health ────────────────────────────────────────────────────

    /// Performs the initial handshake with the skill process.
    ///
    /// Sends a `skill.handshake` request with `expected_name` and `fae_version`.
    /// The skill must respond with its name (which must match `expected_name`) and
    /// a version string.
    ///
    /// # Errors
    ///
    /// - [`PythonSkillError::Timeout`] — no response within `deadline`.
    /// - [`PythonSkillError::HandshakeFailed`] — skill returned an error response,
    ///   or the reported name did not match `expected_name`.
    /// - Other `PythonSkillError` variants on I/O or protocol violations.
    pub async fn perform_handshake(
        &mut self,
        expected_name: &str,
        fae_version: &str,
        deadline: Duration,
    ) -> Result<HandshakeResult, PythonSkillError> {
        let params = HandshakeParams {
            expected_name: expected_name.to_owned(),
            fae_version: fae_version.to_owned(),
        };
        let params_value = serde_json::to_value(&params)?;
        let req = JsonRpcRequest::new(METHOD_HANDSHAKE, Some(params_value), next_id());

        tracing::debug!(
            skill = %self.skill_name,
            expected_name,
            fae_version,
            "performing handshake"
        );

        let outcome = self.send_request(&req, deadline).await?;

        match outcome.message {
            SkillMessage::Response(resp) => {
                let result: HandshakeResult = serde_json::from_value(resp.result).map_err(|e| {
                    PythonSkillError::HandshakeFailed {
                        reason: format!("cannot parse handshake result: {e}"),
                    }
                })?;

                if !result.name_matches(expected_name) {
                    return Err(PythonSkillError::HandshakeFailed {
                        reason: format!(
                            "skill name mismatch: expected \"{expected_name}\", got \"{}\"",
                            result.name
                        ),
                    });
                }

                tracing::info!(
                    skill = %self.skill_name,
                    version = %result.version,
                    "handshake successful"
                );
                Ok(result)
            }
            SkillMessage::Error(err) => Err(PythonSkillError::HandshakeFailed {
                reason: format!(
                    "skill returned error {}: {}",
                    err.error.code, err.error.message
                ),
            }),
            SkillMessage::Notification(_) => Err(PythonSkillError::HandshakeFailed {
                reason: "unexpected notification instead of handshake response".to_owned(),
            }),
        }
    }

    /// Sends a `skill.health` request and returns the skill's health status.
    ///
    /// # Errors
    ///
    /// - [`PythonSkillError::Timeout`] — no response within `deadline`.
    /// - [`PythonSkillError::ProtocolError`] — response could not be parsed.
    /// - Other `PythonSkillError` variants on I/O failures.
    pub async fn perform_health_check(
        &mut self,
        deadline: Duration,
    ) -> Result<HealthResult, PythonSkillError> {
        let req = JsonRpcRequest::new(METHOD_HEALTH, None, next_id());

        tracing::debug!(skill = %self.skill_name, "sending health check");

        let outcome = self.send_request(&req, deadline).await?;

        match outcome.message {
            SkillMessage::Response(resp) => {
                let result: HealthResult = serde_json::from_value(resp.result).map_err(|e| {
                    PythonSkillError::ProtocolError {
                        message: format!("cannot parse health result: {e}"),
                    }
                })?;

                tracing::debug!(
                    skill = %self.skill_name,
                    status = %result.status,
                    "health check response"
                );
                Ok(result)
            }
            SkillMessage::Error(err) => Err(PythonSkillError::ProtocolError {
                message: format!(
                    "skill health check error {}: {}",
                    err.error.code, err.error.message
                ),
            }),
            SkillMessage::Notification(_) => Err(PythonSkillError::ProtocolError {
                message: "unexpected notification instead of health check response".to_owned(),
            }),
        }
    }

    // ── private helpers ───────────────────────────────────────────────────────

    /// Writes a newline-terminated line to stdin, treating broken pipe as
    /// `ProcessExited`.
    async fn write_line(&mut self, line: &str) -> Result<(), PythonSkillError> {
        self.stdin
            .write_all(line.as_bytes())
            .await
            .map_err(|e| map_write_error(e, self.skill_name.as_str()))?;
        self.stdin
            .flush()
            .await
            .map_err(|e| map_write_error(e, self.skill_name.as_str()))
    }

    /// Reads messages until it finds one whose id matches `expected_id`.
    /// All notifications received along the way are accumulated.
    async fn read_response(&mut self, expected_id: u64) -> Result<RpcOutcome, PythonSkillError> {
        let mut notifications = Vec::new();

        loop {
            let message = self.read_one_message().await?;

            match &message {
                SkillMessage::Notification(_) => {
                    tracing::debug!(
                        skill = %self.skill_name,
                        "received notification while waiting for response"
                    );
                    notifications.push(message);
                }
                SkillMessage::Response(resp) => {
                    if resp.id != expected_id {
                        return Err(PythonSkillError::ProtocolError {
                            message: format!(
                                "response id mismatch: expected {expected_id}, got {}",
                                resp.id
                            ),
                        });
                    }
                    tracing::debug!(
                        skill = %self.skill_name,
                        id = resp.id,
                        "received JSON-RPC response"
                    );
                    return Ok(RpcOutcome {
                        message,
                        notifications,
                    });
                }
                SkillMessage::Error(err) => {
                    if err.id != expected_id {
                        return Err(PythonSkillError::ProtocolError {
                            message: format!(
                                "error response id mismatch: expected {expected_id}, got {}",
                                err.id
                            ),
                        });
                    }
                    tracing::debug!(
                        skill = %self.skill_name,
                        id = err.id,
                        code = err.error.code,
                        "received JSON-RPC error response"
                    );
                    return Ok(RpcOutcome {
                        message,
                        notifications,
                    });
                }
            }
        }
    }

    /// Reads exactly one newline-delimited message from stdout.
    ///
    /// Returns [`PythonSkillError::ProcessExited`] on EOF, and
    /// [`PythonSkillError::OutputTruncated`] if the line exceeds `MAX_LINE_BYTES`.
    async fn read_one_message(&mut self) -> Result<SkillMessage, PythonSkillError> {
        let mut line = String::new();
        let n = self.stdout.read_line(&mut line).await.map_err(|e| {
            PythonSkillError::ProtocolError {
                message: format!("stdout read error: {e}"),
            }
        })?;

        if n == 0 {
            // EOF — process closed stdout
            return Err(PythonSkillError::ProcessExited { exit_code: None });
        }

        if line.len() > MAX_LINE_BYTES {
            return Err(PythonSkillError::OutputTruncated {
                max_bytes: MAX_LINE_BYTES,
            });
        }

        SkillMessage::parse(&line)
    }
}

/// Maps a stdin write error to `ProcessExited` (broken pipe) or `ProtocolError`.
fn map_write_error(e: std::io::Error, skill_name: &str) -> PythonSkillError {
    if e.kind() == std::io::ErrorKind::BrokenPipe {
        tracing::warn!(skill = %skill_name, "stdin broken pipe — skill process exited");
        PythonSkillError::ProcessExited { exit_code: None }
    } else {
        PythonSkillError::ProtocolError {
            message: format!("stdin write error: {e}"),
        }
    }
}

// ── Daemon / one-shot mode ────────────────────────────────────────────────────

/// How a [`PythonSkillRunner`] manages the subprocess lifetime.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RunMode {
    /// The subprocess is spawned once on first use and kept alive between
    /// requests. On process exit the runner attempts to restart it, subject
    /// to the configured backoff and restart cap.
    Daemon,
    /// A fresh subprocess is spawned for every request and killed immediately
    /// after the response is received. No restart logic applies.
    OneShot,
}

impl fmt::Display for RunMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Daemon => f.write_str("daemon"),
            Self::OneShot => f.write_str("one-shot"),
        }
    }
}

/// Backoff delays used between restart attempts: 1 s, 2 s, 4 s, … capped at 60 s.
const BACKOFF_INITIAL_SECS: u64 = 1;
const BACKOFF_MAX_SECS: u64 = 60;

/// Returns the backoff duration for `attempt` (0-indexed), doubling up to the max.
///
/// - attempt 0 → 1 s
/// - attempt 1 → 2 s
/// - attempt 2 → 4 s
/// - attempt 3 → 8 s
/// - …
/// - attempt ≥ 6 → 60 s (capped)
pub fn backoff_for_attempt(attempt: u32) -> Duration {
    // Saturating left-shift: double the initial delay for each attempt.
    let secs = BACKOFF_INITIAL_SECS
        .checked_shl(attempt)
        .unwrap_or(BACKOFF_MAX_SECS)
        .min(BACKOFF_MAX_SECS);
    Duration::from_secs(secs)
}

/// Configuration for a Python skill subprocess.
#[derive(Debug, Clone)]
pub struct SkillProcessConfig {
    /// The skill name (used for logging and handshake verification).
    pub skill_name: String,
    /// Path to the Python entry-point script.
    pub script_path: std::path::PathBuf,
    /// Working directory for the subprocess.
    pub work_dir: std::path::PathBuf,
    /// Absolute path to the `uv` binary used to spawn the subprocess.
    pub uv_path: std::path::PathBuf,
    /// Run mode: daemon or one-shot.
    pub mode: RunMode,
    /// Maximum number of restart attempts before giving up (daemon mode only).
    pub max_restarts: u32,
    /// Timeout for the initial handshake.
    pub handshake_timeout: Duration,
    /// Timeout for individual JSON-RPC requests.
    pub request_timeout: Duration,
    /// Fae version string sent in the handshake.
    pub fae_version: String,
    /// Additional environment variables injected into the subprocess.
    ///
    /// These are merged with the inherited environment after all other
    /// configuration is applied. Credential values from [`CredentialCollection`]
    /// are injected here via [`CredentialCollection::inject_into`].
    ///
    /// # Security
    ///
    /// Values in this map are passed directly as environment variables to the
    /// Python subprocess. They must not be logged. Never populate this map
    /// with raw Keychain data — use the credential mediation layer instead.
    ///
    /// [`CredentialCollection`]: super::credential_mediation::CredentialCollection
    pub env_overrides: std::collections::HashMap<String, String>,
}

impl SkillProcessConfig {
    /// Creates a config with sensible defaults.
    ///
    /// `uv_path` defaults to `"uv"` (PATH lookup). Use
    /// [`with_uv_path`](Self::with_uv_path) to override with a discovered
    /// binary path.
    pub fn new(skill_name: &str, script_path: std::path::PathBuf) -> Self {
        Self {
            skill_name: skill_name.to_owned(),
            script_path: script_path.clone(),
            work_dir: script_path
                .parent()
                .unwrap_or_else(|| std::path::Path::new("."))
                .to_path_buf(),
            uv_path: std::path::PathBuf::from("uv"),
            mode: RunMode::Daemon,
            max_restarts: 5,
            handshake_timeout: Duration::from_secs(10),
            request_timeout: Duration::from_secs(30),
            fae_version: env!("CARGO_PKG_VERSION").to_owned(),
            env_overrides: std::collections::HashMap::new(),
        }
    }

    /// Sets the path to the `uv` binary, consuming and returning `self`
    /// for builder-style chaining.
    pub fn with_uv_path(mut self, uv_path: std::path::PathBuf) -> Self {
        self.uv_path = uv_path;
        self
    }
}

/// High-level Python skill subprocess manager.
///
/// Wraps [`PythonSkillProcess`] + [`JsonRpcComm`] with automatic restart in
/// daemon mode and per-request spawning in one-shot mode.
///
/// # Daemon mode
///
/// The subprocess is started on first [`send`](PythonSkillRunner::send) call
/// (or explicitly via [`start`](PythonSkillRunner::start)). If the process
/// exits unexpectedly the runner restarts it with exponential backoff (1 s →
/// 2 s → 4 s → … → 60 s), up to [`SkillProcessConfig::max_restarts`].
///
/// # One-shot mode
///
/// A fresh subprocess is spawned for every `send` call and killed after the
/// response is received.
pub struct PythonSkillRunner {
    config: SkillProcessConfig,
    /// Live process handle in daemon mode; always `None` in one-shot mode.
    process: Option<PythonSkillProcess>,
    /// Live comm handle; always `None` in one-shot mode (rebuilt per request).
    comm: Option<JsonRpcComm>,
    /// Number of restarts attempted so far (daemon mode only).
    restart_count: u32,
}

impl fmt::Debug for PythonSkillRunner {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PythonSkillRunner")
            .field("skill_name", &self.config.skill_name)
            .field("mode", &self.config.mode)
            .field("restart_count", &self.restart_count)
            .field("has_process", &self.process.is_some())
            .finish()
    }
}

impl PythonSkillRunner {
    /// Creates a new runner. The subprocess is not started yet.
    pub fn new(config: SkillProcessConfig) -> Self {
        Self {
            config,
            process: None,
            comm: None,
            restart_count: 0,
        }
    }

    /// Returns the configured run mode.
    pub fn mode(&self) -> RunMode {
        self.config.mode
    }

    /// Returns the number of restarts attempted (daemon mode only).
    pub fn restart_count(&self) -> u32 {
        self.restart_count
    }

    /// Returns `true` if the daemon subprocess is currently alive.
    pub fn is_running(&mut self) -> bool {
        self.process
            .as_mut()
            .is_some_and(|p| p.state() == PythonProcessState::Running && p.is_alive())
    }

    /// Starts the subprocess and performs the handshake.
    ///
    /// In daemon mode this must be called before [`send`](PythonSkillRunner::send).
    /// Calling `start` when already running is a no-op.
    ///
    /// # Errors
    ///
    /// Returns an error if spawning or handshake fails.
    pub async fn start(&mut self) -> Result<(), PythonSkillError> {
        if self.is_running() {
            return Ok(());
        }
        self.spawn_and_handshake().await
    }

    /// Stops the daemon subprocess gracefully.
    pub async fn stop(&mut self) {
        if let Some(mut proc) = self.process.take() {
            proc.kill().await;
        }
        self.comm = None;
    }

    /// Sends a JSON-RPC request and returns the response.
    ///
    /// - **Daemon mode**: reuses the live process. If the process has exited,
    ///   attempts to restart (up to `max_restarts`) before giving up.
    /// - **One-shot mode**: spawns a fresh process, performs handshake, sends
    ///   the request, kills the process, returns the response.
    ///
    /// # Errors
    ///
    /// [`PythonSkillError::MaxRestartsExceeded`] if daemon restart limit is hit.
    /// Other variants on spawn, handshake, or I/O failures.
    pub async fn send(
        &mut self,
        method: &str,
        params: Option<serde_json::Value>,
    ) -> Result<serde_json::Value, PythonSkillError> {
        match self.config.mode {
            RunMode::Daemon => self.send_daemon(method, params).await,
            RunMode::OneShot => self.send_one_shot(method, params).await,
        }
    }

    // ── private ───────────────────────────────────────────────────────────────

    /// Daemon-mode send: ensure the process is running, then send.
    async fn send_daemon(
        &mut self,
        method: &str,
        params: Option<serde_json::Value>,
    ) -> Result<serde_json::Value, PythonSkillError> {
        // Ensure we have a live process.
        if !self.is_running() {
            self.ensure_alive().await?;
        }

        let req = JsonRpcRequest::new(method, params, next_id());
        let comm = self
            .comm
            .as_mut()
            .ok_or_else(|| PythonSkillError::ProtocolError {
                message: "comm handle missing in daemon mode".to_owned(),
            })?;

        match comm.send_request(&req, self.config.request_timeout).await {
            Ok(outcome) => extract_result(outcome.message),
            Err(e) => {
                // Mark process as failed so next call restarts.
                if let Some(proc) = self.process.as_mut() {
                    let _ = proc.transition(PythonProcessState::Failed);
                }
                Err(e)
            }
        }
    }

    /// One-shot send: spawn → handshake → request → kill.
    async fn send_one_shot(
        &mut self,
        method: &str,
        params: Option<serde_json::Value>,
    ) -> Result<serde_json::Value, PythonSkillError> {
        let (mut proc, mut comm) = self.spawn_child().await?;

        match comm
            .perform_handshake(
                &self.config.skill_name,
                &self.config.fae_version,
                self.config.handshake_timeout,
            )
            .await
        {
            Ok(_) => {}
            Err(e) => {
                proc.kill().await;
                return Err(e);
            }
        }

        proc.transition(PythonProcessState::Running)?;

        let req = JsonRpcRequest::new(method, params, next_id());
        let outcome = comm.send_request(&req, self.config.request_timeout).await;

        proc.kill().await;

        extract_result(outcome?.message)
    }

    /// Ensures the daemon process is running, restarting if needed.
    async fn ensure_alive(&mut self) -> Result<(), PythonSkillError> {
        if self.is_running() {
            return Ok(());
        }

        if self.restart_count >= self.config.max_restarts {
            return Err(PythonSkillError::MaxRestartsExceeded {
                count: self.restart_count,
            });
        }

        // Apply backoff (skip on first start: restart_count == 0 only if we
        // have previously had a process).
        if self.process.is_some() || self.restart_count > 0 {
            let delay = backoff_for_attempt(self.restart_count);
            tracing::warn!(
                skill = %self.config.skill_name,
                attempt = self.restart_count,
                delay_secs = delay.as_secs(),
                "restarting skill process with backoff"
            );
            tokio::time::sleep(delay).await;
            self.restart_count += 1;
        }

        // Clean up old handles.
        if let Some(mut old_proc) = self.process.take() {
            old_proc.kill().await;
        }
        self.comm = None;

        self.spawn_and_handshake().await
    }

    /// Spawns the child and performs the handshake, storing both handles.
    async fn spawn_and_handshake(&mut self) -> Result<(), PythonSkillError> {
        let (mut proc, mut comm) = self.spawn_child().await?;

        let result = comm
            .perform_handshake(
                &self.config.skill_name,
                &self.config.fae_version,
                self.config.handshake_timeout,
            )
            .await;

        match result {
            Ok(_) => {
                proc.transition(PythonProcessState::Running)?;
                self.process = Some(proc);
                self.comm = Some(comm);
                Ok(())
            }
            Err(e) => {
                proc.kill().await;
                Err(e)
            }
        }
    }

    /// Spawns the raw child process and returns a `(PythonSkillProcess, JsonRpcComm)` pair.
    async fn spawn_child(&self) -> Result<(PythonSkillProcess, JsonRpcComm), PythonSkillError> {
        let mut cmd = tokio::process::Command::new(&self.config.uv_path);
        cmd.arg("run")
            .arg(&self.config.script_path)
            .current_dir(&self.config.work_dir)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true);

        // Inject credential env vars. Each entry overwrites any inherited
        // value with the same name, ensuring skills always receive the
        // current Keychain-backed secret.
        for (key, value) in &self.config.env_overrides {
            cmd.env(key, value);
        }

        let mut child = cmd.spawn().map_err(PythonSkillError::SpawnFailed)?;

        let comm =
            JsonRpcComm::from_child(&mut child, &self.config.skill_name).ok_or_else(|| {
                PythonSkillError::ProtocolError {
                    message: "child process missing piped stdin/stdout".to_owned(),
                }
            })?;

        let mut proc = PythonSkillProcess::new(&self.config.skill_name);
        proc.attach(child)?;

        Ok((proc, comm))
    }
}

/// Extracts the `result` value from a `SkillMessage::Response`, or maps
/// `SkillMessage::Error` to `PythonSkillError::ProtocolError`.
fn extract_result(message: SkillMessage) -> Result<serde_json::Value, PythonSkillError> {
    match message {
        SkillMessage::Response(resp) => Ok(resp.result),
        SkillMessage::Error(err) => Err(PythonSkillError::ProtocolError {
            message: format!("skill error {}: {}", err.error.code, err.error.message),
        }),
        SkillMessage::Notification(_) => Err(PythonSkillError::ProtocolError {
            message: "unexpected notification where response was expected".to_owned(),
        }),
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use crate::skills::python_protocol::JsonRpcRequest;

    // ── State machine transition tests ──

    #[test]
    fn valid_happy_path_transitions() {
        let s = PythonProcessState::Pending;
        assert!(s.can_transition_to(PythonProcessState::Starting));

        let s = PythonProcessState::Starting;
        assert!(s.can_transition_to(PythonProcessState::Running));

        let s = PythonProcessState::Running;
        assert!(s.can_transition_to(PythonProcessState::Stopped));
    }

    #[test]
    fn valid_failure_transitions() {
        assert!(PythonProcessState::Starting.can_transition_to(PythonProcessState::Failed));
        assert!(PythonProcessState::Running.can_transition_to(PythonProcessState::Failed));
    }

    #[test]
    fn valid_restart_transitions() {
        assert!(PythonProcessState::Failed.can_transition_to(PythonProcessState::Pending));
        assert!(PythonProcessState::Stopped.can_transition_to(PythonProcessState::Pending));
    }

    #[test]
    fn invalid_transitions_rejected() {
        // Cannot skip Pending → Running
        assert!(!PythonProcessState::Pending.can_transition_to(PythonProcessState::Running));
        // Cannot go backward Running → Starting
        assert!(!PythonProcessState::Running.can_transition_to(PythonProcessState::Starting));
        // Cannot go from Pending directly to Stopped
        assert!(!PythonProcessState::Pending.can_transition_to(PythonProcessState::Stopped));
        // Self-transitions are invalid
        assert!(!PythonProcessState::Running.can_transition_to(PythonProcessState::Running));
        assert!(!PythonProcessState::Pending.can_transition_to(PythonProcessState::Pending));
    }

    #[test]
    fn terminal_states() {
        assert!(PythonProcessState::Failed.is_terminal());
        assert!(PythonProcessState::Stopped.is_terminal());
        assert!(!PythonProcessState::Pending.is_terminal());
        assert!(!PythonProcessState::Starting.is_terminal());
        assert!(!PythonProcessState::Running.is_terminal());
    }

    #[test]
    fn display_labels() {
        assert_eq!(PythonProcessState::Pending.to_string(), "pending");
        assert_eq!(PythonProcessState::Starting.to_string(), "starting");
        assert_eq!(PythonProcessState::Running.to_string(), "running");
        assert_eq!(PythonProcessState::Failed.to_string(), "failed");
        assert_eq!(PythonProcessState::Stopped.to_string(), "stopped");
    }

    // ── PythonSkillProcess unit tests ──

    #[test]
    fn new_process_starts_pending() {
        let proc = PythonSkillProcess::new("test-skill");
        assert_eq!(proc.state(), PythonProcessState::Pending);
        assert_eq!(proc.skill_name(), "test-skill");
    }

    #[test]
    fn transition_valid_succeeds() {
        let mut proc = PythonSkillProcess::new("test");
        assert!(proc.transition(PythonProcessState::Starting).is_ok());
        assert_eq!(proc.state(), PythonProcessState::Starting);
    }

    #[test]
    fn transition_invalid_fails() {
        let mut proc = PythonSkillProcess::new("test");
        let result = proc.transition(PythonProcessState::Running);
        assert!(result.is_err());
        // State should not have changed
        assert_eq!(proc.state(), PythonProcessState::Pending);
    }

    #[test]
    fn is_alive_without_child_returns_false() {
        let mut proc = PythonSkillProcess::new("test");
        assert!(!proc.is_alive());
    }

    #[test]
    fn debug_format() {
        let proc = PythonSkillProcess::new("my-skill");
        let dbg = format!("{proc:?}");
        assert!(dbg.contains("my-skill"));
        assert!(dbg.contains("Pending"));
        assert!(dbg.contains("has_child"));
    }

    #[test]
    fn take_child_returns_none_when_no_child() {
        let mut proc = PythonSkillProcess::new("test");
        assert!(proc.take_child().is_none());
    }

    #[test]
    fn child_mut_returns_none_when_no_child() {
        let mut proc = PythonSkillProcess::new("test");
        assert!(proc.child_mut().is_none());
    }

    // ── Integration tests with real processes ──

    #[tokio::test]
    async fn attach_real_process() {
        let child = tokio::process::Command::new("sleep")
            .arg("60")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn sleep");

        let mut proc = PythonSkillProcess::new("attach-test");
        assert!(proc.attach(child).is_ok());
        assert_eq!(proc.state(), PythonProcessState::Starting);
        assert!(proc.child_mut().is_some());
        assert!(proc.is_alive());

        // Cleanup
        proc.kill().await;
        assert_eq!(proc.state(), PythonProcessState::Stopped);
        assert!(!proc.is_alive());
    }

    #[tokio::test]
    async fn kill_transitions_to_stopped() {
        let child = tokio::process::Command::new("sleep")
            .arg("60")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn sleep");

        let mut proc = PythonSkillProcess::new("kill-test");
        proc.attach(child).unwrap();
        proc.transition(PythonProcessState::Running).unwrap();

        proc.kill().await;
        assert_eq!(proc.state(), PythonProcessState::Stopped);
        assert!(proc.child_mut().is_none());
    }

    #[tokio::test]
    async fn drop_kills_child_process() {
        let child = tokio::process::Command::new("sleep")
            .arg("60")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn sleep");

        let pid = child.id().expect("get pid");

        {
            let mut proc = PythonSkillProcess::new("drop-test");
            proc.attach(child).unwrap();
            // proc dropped here
        }

        // Give the OS a moment to reap
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;

        // Verify the process is no longer running by checking /proc or kill(0)
        // On macOS/Unix, kill(pid, 0) returns error if process doesn't exist
        #[cfg(unix)]
        {
            let alive = unsafe { libc::kill(pid as i32, 0) };
            assert_ne!(alive, 0, "process should be dead after drop");
        }
    }

    #[tokio::test]
    async fn attach_fails_from_wrong_state() {
        let child = tokio::process::Command::new("echo")
            .arg("test")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn echo");

        let mut proc = PythonSkillProcess::new("wrong-state");
        // Force to Running (bypassing normal flow for test)
        proc.state = PythonProcessState::Starting;
        proc.state = PythonProcessState::Running;

        // Attach requires Pending → Starting, but we're in Running
        let result = proc.attach(child);
        assert!(result.is_err());
    }

    #[tokio::test]
    async fn is_alive_detects_exited_process() {
        let child = tokio::process::Command::new("true")
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn true");

        let mut proc = PythonSkillProcess::new("exited-test");
        proc.attach(child).unwrap();

        // Wait for `true` to exit naturally
        tokio::time::sleep(std::time::Duration::from_millis(100)).await;

        assert!(!proc.is_alive());
    }

    #[test]
    fn full_lifecycle_transitions() {
        let mut proc = PythonSkillProcess::new("lifecycle");
        // Pending → Starting
        proc.transition(PythonProcessState::Starting).unwrap();
        // Starting → Running
        proc.transition(PythonProcessState::Running).unwrap();
        // Running → Stopped
        proc.transition(PythonProcessState::Stopped).unwrap();
        // Stopped → Pending (restart)
        proc.transition(PythonProcessState::Pending).unwrap();
        // Pending → Starting
        proc.transition(PythonProcessState::Starting).unwrap();
        // Starting → Failed
        proc.transition(PythonProcessState::Failed).unwrap();
        // Failed → Pending (restart)
        proc.transition(PythonProcessState::Pending).unwrap();
    }

    #[test]
    fn state_and_process_are_send() {
        fn assert_send<T: Send>() {}
        assert_send::<PythonProcessState>();
        assert_send::<PythonSkillProcess>();
    }

    // ── JsonRpcComm tests ──

    /// Spawn a shell echo server: reads one JSON line, echoes it back with
    /// "result": "ok" and the same id.
    fn spawn_echo_skill() -> Child {
        // Shell script: read one line from stdin, parse id with sed, echo response.
        tokio::process::Command::new("sh")
            .arg("-c")
            .arg(
                r#"
while IFS= read -r line; do
    id=$(echo "$line" | sed 's/.*"id":\([0-9]*\).*/\1/')
    printf '{"jsonrpc":"2.0","result":"ok","id":%s}\n' "$id"
done
"#,
            )
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn echo skill")
    }

    /// Spawn a skill that emits a notification then the response.
    fn spawn_notification_then_response_skill() -> Child {
        tokio::process::Command::new("sh")
            .arg("-c")
            .arg(
                r#"
while IFS= read -r line; do
    id=$(echo "$line" | sed 's/.*"id":\([0-9]*\).*/\1/')
    printf '{"jsonrpc":"2.0","method":"skill.ping","params":{"msg":"hello"}}\n'
    printf '{"jsonrpc":"2.0","result":"done","id":%s}\n' "$id"
done
"#,
            )
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn notification skill")
    }

    /// Spawn a skill that immediately exits without responding.
    fn spawn_exit_immediately() -> Child {
        tokio::process::Command::new("sh")
            .arg("-c")
            .arg("exit 0")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn exit skill")
    }

    #[tokio::test]
    async fn rpc_round_trip_success() {
        let mut child = spawn_echo_skill();
        let mut comm = JsonRpcComm::from_child(&mut child, "echo-skill").expect("from_child");

        let req = JsonRpcRequest::new("test.method", None, 42);
        let outcome = comm
            .send_request(&req, Duration::from_secs(5))
            .await
            .expect("send_request");

        match outcome.message {
            SkillMessage::Response(resp) => {
                assert_eq!(resp.id, 42);
                assert_eq!(resp.result, "ok");
            }
            other => panic!("expected Response, got {other:?}"),
        }
        assert!(outcome.notifications.is_empty());

        let _ = child.kill().await;
    }

    #[tokio::test]
    async fn rpc_receives_notification_before_response() {
        let mut child = spawn_notification_then_response_skill();
        let mut comm = JsonRpcComm::from_child(&mut child, "notif-skill").expect("from_child");

        let req = JsonRpcRequest::new("skill.run", None, 7);
        let outcome = comm
            .send_request(&req, Duration::from_secs(5))
            .await
            .expect("send_request");

        assert_eq!(outcome.notifications.len(), 1);
        match &outcome.notifications[0] {
            SkillMessage::Notification(n) => assert_eq!(n.method, "skill.ping"),
            other => panic!("expected Notification, got {other:?}"),
        }
        match outcome.message {
            SkillMessage::Response(resp) => assert_eq!(resp.id, 7),
            other => panic!("expected Response, got {other:?}"),
        }

        let _ = child.kill().await;
    }

    #[tokio::test]
    async fn rpc_timeout_fires() {
        // Use `sleep` — never writes anything to stdout, blocks forever on stdin.
        let mut child = tokio::process::Command::new("sleep")
            .arg("60")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn sleep");

        let mut comm = JsonRpcComm::from_child(&mut child, "cat-skill").expect("from_child");

        let req = JsonRpcRequest::new("method", None, 1);
        let result = comm.send_request(&req, Duration::from_millis(100)).await;

        assert!(result.is_err());
        match result.unwrap_err() {
            PythonSkillError::Timeout { .. } => {}
            other => panic!("expected Timeout, got {other:?}"),
        }

        let _ = child.kill().await;
    }

    #[tokio::test]
    async fn rpc_process_exited_on_eof() {
        let mut child = spawn_exit_immediately();
        let mut comm = JsonRpcComm::from_child(&mut child, "exit-skill").expect("from_child");

        // Give the process a moment to exit and close its stdout
        tokio::time::sleep(Duration::from_millis(50)).await;

        let req = JsonRpcRequest::new("test", None, 1);
        let result = comm.send_request(&req, Duration::from_secs(2)).await;

        // We may get either ProcessExited (broken pipe on write or EOF on read)
        // or Timeout — both are valid depending on timing.
        assert!(result.is_err(), "expected an error when process has exited");
    }

    #[tokio::test]
    async fn recv_message_returns_notification() {
        // Skill writes a notification immediately without waiting for a request.
        let mut child = tokio::process::Command::new("sh")
            .arg("-c")
            .arg(r#"printf '{"jsonrpc":"2.0","method":"startup.ready"}\n'"#)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn");

        let mut comm = JsonRpcComm::from_child(&mut child, "startup-skill").expect("from_child");

        let msg = comm
            .recv_message(Duration::from_secs(2))
            .await
            .expect("recv_message");
        match msg {
            SkillMessage::Notification(n) => assert_eq!(n.method, "startup.ready"),
            other => panic!("expected Notification, got {other:?}"),
        }

        let _ = child.kill().await;
    }

    #[tokio::test]
    async fn multiple_sequential_requests() {
        let mut child = spawn_echo_skill();
        let mut comm = JsonRpcComm::from_child(&mut child, "seq-skill").expect("from_child");

        for id in 1_u64..=5 {
            let req = JsonRpcRequest::new("ping", None, id);
            let outcome = comm
                .send_request(&req, Duration::from_secs(5))
                .await
                .unwrap_or_else(|e| panic!("request {id} failed: {e}"));
            match outcome.message {
                SkillMessage::Response(resp) => assert_eq!(resp.id, id),
                other => panic!("expected Response for id={id}, got {other:?}"),
            }
        }

        let _ = child.kill().await;
    }

    #[tokio::test]
    async fn comm_is_send() {
        fn assert_send<T: Send>() {}
        assert_send::<JsonRpcComm>();
        assert_send::<RpcOutcome>();
    }

    // ── Handshake & health check tests ──

    /// Spawn a skill that handles skill.handshake correctly.
    fn spawn_handshake_skill(name: &str) -> Child {
        let name = name.to_owned();
        tokio::process::Command::new("sh")
            .arg("-c")
            .arg(format!(
                r#"IFS= read -r line; id=$(echo "$line" | sed 's/.*"id":\([0-9]*\).*/\1/'); printf '{{"jsonrpc":"2.0","result":{{"name":"{name}","version":"1.0.0"}},"id":%s}}\n' "$id""#
            ))
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn handshake skill")
    }

    /// Spawn a skill that echoes requests back, supporting both handshake and health.
    fn spawn_full_protocol_skill() -> Child {
        // Reads lines, for handshake returns name+version, for health returns ok.
        tokio::process::Command::new("sh")
            .arg("-c")
            .arg(
                r#"
while IFS= read -r line; do
    id=$(echo "$line" | sed 's/.*"id":\([0-9]*\).*/\1/')
    if echo "$line" | grep -q '"skill.handshake"'; then
        printf '{"jsonrpc":"2.0","result":{"name":"test-skill","version":"2.0.0"},"id":%s}\n' "$id"
    elif echo "$line" | grep -q '"skill.health"'; then
        printf '{"jsonrpc":"2.0","result":{"status":"ok"},"id":%s}\n' "$id"
    else
        printf '{"jsonrpc":"2.0","result":"ok","id":%s}\n' "$id"
    fi
done
"#,
            )
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn full protocol skill")
    }

    #[tokio::test]
    async fn handshake_succeeds_with_matching_name() {
        let mut child = spawn_handshake_skill("my-skill");
        let mut comm = JsonRpcComm::from_child(&mut child, "my-skill").expect("from_child");

        let result = comm
            .perform_handshake("my-skill", "0.8.1", Duration::from_secs(5))
            .await
            .expect("handshake");

        assert_eq!(result.name, "my-skill");
        assert_eq!(result.version, "1.0.0");

        let _ = child.kill().await;
    }

    #[tokio::test]
    async fn handshake_fails_name_mismatch() {
        let mut child = spawn_handshake_skill("wrong-name");
        let mut comm = JsonRpcComm::from_child(&mut child, "expected-name").expect("from_child");

        let result = comm
            .perform_handshake("expected-name", "0.8.1", Duration::from_secs(5))
            .await;

        assert!(result.is_err());
        match result.unwrap_err() {
            PythonSkillError::HandshakeFailed { reason } => {
                assert!(reason.contains("name mismatch"), "reason: {reason}");
            }
            other => panic!("expected HandshakeFailed, got {other:?}"),
        }

        let _ = child.kill().await;
    }

    #[tokio::test]
    async fn handshake_timeout() {
        let mut child = tokio::process::Command::new("sleep")
            .arg("60")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn sleep");

        let mut comm = JsonRpcComm::from_child(&mut child, "slow-skill").expect("from_child");

        let result = comm
            .perform_handshake("slow-skill", "0.8.1", Duration::from_millis(100))
            .await;

        assert!(result.is_err());
        match result.unwrap_err() {
            PythonSkillError::Timeout { .. } => {}
            other => panic!("expected Timeout, got {other:?}"),
        }

        let _ = child.kill().await;
    }

    #[tokio::test]
    async fn handshake_error_response() {
        // Skill returns an error response instead of a result.
        let mut child = tokio::process::Command::new("sh")
            .arg("-c")
            .arg(
                r#"IFS= read -r line; id=$(echo "$line" | sed 's/.*"id":\([0-9]*\).*/\1/'); printf '{"jsonrpc":"2.0","error":{"code":-1,"message":"not supported"},"id":%s}\n' "$id""#,
            )
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn error skill");

        let mut comm = JsonRpcComm::from_child(&mut child, "error-skill").expect("from_child");

        let result = comm
            .perform_handshake("error-skill", "0.8.1", Duration::from_secs(5))
            .await;

        assert!(result.is_err());
        match result.unwrap_err() {
            PythonSkillError::HandshakeFailed { reason } => {
                assert!(reason.contains("not supported"), "reason: {reason}");
            }
            other => panic!("expected HandshakeFailed, got {other:?}"),
        }

        let _ = child.kill().await;
    }

    #[tokio::test]
    async fn health_check_ok() {
        let mut child = spawn_full_protocol_skill();
        let mut comm = JsonRpcComm::from_child(&mut child, "test-skill").expect("from_child");

        // First do handshake to consume the first read
        comm.perform_handshake("test-skill", "0.8.1", Duration::from_secs(5))
            .await
            .expect("handshake");

        let health = comm
            .perform_health_check(Duration::from_secs(5))
            .await
            .expect("health check");

        assert!(health.is_ok());
        assert_eq!(health.status, "ok");

        let _ = child.kill().await;
    }

    #[tokio::test]
    async fn health_check_timeout() {
        let mut child = tokio::process::Command::new("sleep")
            .arg("60")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn sleep");

        let mut comm = JsonRpcComm::from_child(&mut child, "slow-skill").expect("from_child");

        let result = comm.perform_health_check(Duration::from_millis(100)).await;

        assert!(result.is_err());
        match result.unwrap_err() {
            PythonSkillError::Timeout { .. } => {}
            other => panic!("expected Timeout, got {other:?}"),
        }

        let _ = child.kill().await;
    }

    #[tokio::test]
    async fn next_id_is_monotonically_increasing() {
        let a = next_id();
        let b = next_id();
        let c = next_id();
        assert!(a < b);
        assert!(b < c);
    }

    // ── RunMode / backoff / config tests ──

    #[test]
    fn run_mode_display() {
        assert_eq!(RunMode::Daemon.to_string(), "daemon");
        assert_eq!(RunMode::OneShot.to_string(), "one-shot");
    }

    #[test]
    fn backoff_for_attempt_values() {
        assert_eq!(backoff_for_attempt(0), Duration::from_secs(1));
        assert_eq!(backoff_for_attempt(1), Duration::from_secs(2));
        assert_eq!(backoff_for_attempt(2), Duration::from_secs(4));
        assert_eq!(backoff_for_attempt(3), Duration::from_secs(8));
        assert_eq!(backoff_for_attempt(4), Duration::from_secs(16));
        assert_eq!(backoff_for_attempt(5), Duration::from_secs(32));
        assert_eq!(backoff_for_attempt(6), Duration::from_secs(60)); // capped
        assert_eq!(backoff_for_attempt(10), Duration::from_secs(60)); // still capped
        assert_eq!(backoff_for_attempt(63), Duration::from_secs(60)); // overflow safe
    }

    #[test]
    fn skill_process_config_defaults() {
        let cfg = SkillProcessConfig::new("my-skill", std::path::PathBuf::from("/tmp/skill.py"));
        assert_eq!(cfg.skill_name, "my-skill");
        assert_eq!(cfg.uv_path, std::path::PathBuf::from("uv"));
        assert_eq!(cfg.mode, RunMode::Daemon);
        assert_eq!(cfg.max_restarts, 5);
        assert_eq!(cfg.handshake_timeout, Duration::from_secs(10));
        assert_eq!(cfg.request_timeout, Duration::from_secs(30));
        // env_overrides defaults to empty.
        assert!(cfg.env_overrides.is_empty());
    }

    #[test]
    fn env_overrides_can_be_set_on_config() {
        let mut cfg =
            SkillProcessConfig::new("discord-bot", std::path::PathBuf::from("/tmp/skill.py"));
        cfg.env_overrides
            .insert("DISCORD_BOT_TOKEN".to_owned(), "xoxb-secret".to_owned());
        cfg.env_overrides
            .insert("DISCORD_GUILD_ID".to_owned(), "12345".to_owned());

        assert_eq!(cfg.env_overrides.len(), 2);
        assert_eq!(
            cfg.env_overrides
                .get("DISCORD_BOT_TOKEN")
                .map(String::as_str),
            Some("xoxb-secret")
        );
        assert_eq!(
            cfg.env_overrides
                .get("DISCORD_GUILD_ID")
                .map(String::as_str),
            Some("12345")
        );
    }

    #[test]
    fn env_overrides_default_empty_and_can_inject() {
        let cfg = SkillProcessConfig::new("skill", std::path::PathBuf::from("/tmp/skill.py"));
        // env_overrides starts empty — no credentials injected by default.
        assert!(cfg.env_overrides.is_empty());
    }

    #[test]
    fn skill_process_config_with_uv_path() {
        let cfg = SkillProcessConfig::new("test", std::path::PathBuf::from("/tmp/t.py"))
            .with_uv_path(std::path::PathBuf::from("/opt/uv/bin/uv"));
        assert_eq!(cfg.uv_path, std::path::PathBuf::from("/opt/uv/bin/uv"));
        // Other defaults should be preserved.
        assert_eq!(cfg.skill_name, "test");
        assert_eq!(cfg.mode, RunMode::Daemon);
    }

    #[test]
    fn python_skill_runner_new() {
        let cfg = SkillProcessConfig::new("test", std::path::PathBuf::from("/tmp/t.py"));
        let runner = PythonSkillRunner::new(cfg);
        assert_eq!(runner.mode(), RunMode::Daemon);
        assert_eq!(runner.restart_count(), 0);
    }

    #[test]
    fn python_skill_runner_is_send() {
        fn assert_send<T: Send>() {}
        assert_send::<PythonSkillRunner>();
        assert_send::<RunMode>();
        assert_send::<SkillProcessConfig>();
    }

    #[test]
    fn extract_result_response() {
        use crate::skills::python_protocol::JsonRpcResponse;
        let msg = SkillMessage::Response(JsonRpcResponse {
            jsonrpc: "2.0".to_owned(),
            result: serde_json::json!({"answer": 42}),
            id: 1,
        });
        let val = extract_result(msg).unwrap();
        assert_eq!(val["answer"], 42);
    }

    #[test]
    fn extract_result_error_maps_to_protocol_error() {
        use crate::skills::python_protocol::{JsonRpcError, JsonRpcErrorResponse};
        let msg = SkillMessage::Error(JsonRpcErrorResponse {
            jsonrpc: "2.0".to_owned(),
            error: JsonRpcError {
                code: -1,
                message: "oops".to_owned(),
                data: None,
            },
            id: 1,
        });
        let err = extract_result(msg).unwrap_err();
        match err {
            PythonSkillError::ProtocolError { message } => {
                assert!(message.contains("oops"));
            }
            other => panic!("expected ProtocolError, got {other:?}"),
        }
    }

    /// Spawn a one-shot skill using `sh` instead of `uv run` for testing.
    ///
    /// We bypass PythonSkillRunner.send() and directly exercise the spawn+
    /// handshake+request cycle with shell processes.
    #[tokio::test]
    async fn one_shot_send_round_trip() {
        // Manually exercise the one-shot pattern without going through uv.
        let mut child = tokio::process::Command::new("sh")
            .arg("-c")
            .arg(
                r#"
while IFS= read -r line; do
    id=$(echo "$line" | sed 's/.*"id":\([0-9]*\).*/\1/')
    if echo "$line" | grep -q '"skill.handshake"'; then
        printf '{"jsonrpc":"2.0","result":{"name":"echo","version":"1.0"},"id":%s}\n' "$id"
    else
        printf '{"jsonrpc":"2.0","result":{"reply":"pong"},"id":%s}\n' "$id"
    fi
done
"#,
            )
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn");

        let mut proc = PythonSkillProcess::new("echo");
        let mut comm = JsonRpcComm::from_child(&mut child, "echo").expect("from_child");

        proc.attach(child).unwrap();

        comm.perform_handshake("echo", "0.8.1", Duration::from_secs(5))
            .await
            .expect("handshake");
        proc.transition(PythonProcessState::Running).unwrap();

        let req = JsonRpcRequest::new("ping", None, next_id());
        let outcome = comm
            .send_request(&req, Duration::from_secs(5))
            .await
            .expect("send_request");

        match outcome.message {
            SkillMessage::Response(resp) => assert_eq!(resp.result["reply"], "pong"),
            other => panic!("expected Response, got {other:?}"),
        }

        proc.kill().await;
        assert_eq!(proc.state(), PythonProcessState::Stopped);
    }

    #[tokio::test]
    async fn daemon_mode_reuses_process() {
        // Verify that in daemon mode a process handle is kept across requests.
        // We simulate daemon behaviour manually (PythonSkillRunner.send requires uv).
        let mut child = tokio::process::Command::new("sh")
            .arg("-c")
            .arg(
                r#"
while IFS= read -r line; do
    id=$(echo "$line" | sed 's/.*"id":\([0-9]*\).*/\1/')
    if echo "$line" | grep -q '"skill.handshake"'; then
        printf '{"jsonrpc":"2.0","result":{"name":"daemon","version":"1.0"},"id":%s}\n' "$id"
    else
        printf '{"jsonrpc":"2.0","result":"ok","id":%s}\n' "$id"
    fi
done
"#,
            )
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .expect("spawn daemon");

        let mut proc = PythonSkillProcess::new("daemon");
        let mut comm = JsonRpcComm::from_child(&mut child, "daemon").expect("from_child");
        proc.attach(child).unwrap();

        comm.perform_handshake("daemon", "0.8.1", Duration::from_secs(5))
            .await
            .expect("handshake");
        proc.transition(PythonProcessState::Running).unwrap();
        assert!(proc.is_alive());

        // Send multiple requests through the same process.
        for i in 1_u64..=3 {
            let req = JsonRpcRequest::new("work", None, i + 1000);
            comm.send_request(&req, Duration::from_secs(5))
                .await
                .unwrap_or_else(|e| panic!("request {i} failed: {e}"));
            assert!(proc.is_alive(), "process died after request {i}");
        }

        proc.kill().await;
    }
}
