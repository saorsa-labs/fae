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
use super::python_protocol::{JsonRpcRequest, SkillMessage};
use std::fmt;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout};
use tokio::time::timeout;

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
        let n = self
            .stdout
            .read_line(&mut line)
            .await
            .map_err(|e| PythonSkillError::ProtocolError {
                message: format!("stdout read error: {e}"),
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
        let mut comm =
            JsonRpcComm::from_child(&mut child, "notif-skill").expect("from_child");

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
        let result = comm
            .send_request(&req, Duration::from_millis(100))
            .await;

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
        let result = comm
            .send_request(&req, Duration::from_secs(2))
            .await;

        // We may get either ProcessExited (broken pipe on write or EOF on read)
        // or Timeout — both are valid depending on timing.
        assert!(
            result.is_err(),
            "expected an error when process has exited"
        );
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
}
