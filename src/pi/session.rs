//! Pi RPC session — spawns Pi in RPC mode and communicates via JSON-over-stdin/stdout.
//!
//! The RPC protocol uses newline-delimited JSON:
//! - **Requests**: sent to Pi's stdin (one JSON object per line)
//! - **Events**: received from Pi's stdout (streaming JSON lines)
//!
//! See: <https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/rpc.md>

use crate::error::{Result, SpeechError};
use serde::{Deserialize, Serialize};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use tokio::sync::mpsc;

// ---------------------------------------------------------------------------
// RPC request types (Fae → Pi stdin)
// ---------------------------------------------------------------------------

/// A request sent to Pi's stdin in RPC mode.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PiRpcRequest {
    /// Send a user prompt to Pi.
    Prompt {
        /// The task or message for Pi.
        message: String,
    },
    /// Abort the current operation.
    Abort,
    /// Get the current session state.
    GetState,
    /// Start a new session.
    NewSession,
}

// ---------------------------------------------------------------------------
// RPC event types (Pi stdout → Fae)
// ---------------------------------------------------------------------------

/// An event received from Pi's stdout in RPC mode.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PiRpcEvent {
    /// Agent has started processing.
    AgentStart,
    /// Agent has finished processing.
    AgentEnd,
    /// A reasoning turn has started.
    TurnStart,
    /// A reasoning turn has ended.
    TurnEnd,
    /// A message has started.
    MessageStart,
    /// Streaming text delta.
    MessageUpdate {
        /// The text content of this delta.
        #[serde(default)]
        text: String,
    },
    /// A message has ended.
    MessageEnd,
    /// A tool execution has started.
    ToolExecutionStart {
        /// Name of the tool being executed.
        #[serde(default)]
        name: String,
    },
    /// A tool execution update (streaming output).
    ToolExecutionUpdate {
        /// Incremental output text.
        #[serde(default)]
        text: String,
    },
    /// A tool execution has ended.
    ToolExecutionEnd {
        /// Name of the tool.
        #[serde(default)]
        name: String,
        /// Whether the tool execution succeeded.
        #[serde(default)]
        success: bool,
    },
    /// Automatic compaction started.
    AutoCompactionStart,
    /// Automatic compaction ended.
    AutoCompactionEnd,
    /// An RPC response to a command.
    Response {
        /// Whether the command succeeded.
        #[serde(default)]
        success: bool,
    },
}

/// Parsed event or an unrecognized JSON line from Pi.
#[derive(Debug, Clone)]
pub enum PiEvent {
    /// A recognized RPC event.
    Rpc(PiRpcEvent),
    /// An unrecognized JSON line (logged but not processed).
    Unknown(String),
    /// Pi process has exited.
    ProcessExited,
}

// ---------------------------------------------------------------------------
// PiSession
// ---------------------------------------------------------------------------

/// A running Pi RPC session.
///
/// Manages the Pi child process, sends requests via stdin, and receives
/// events via a background reader thread.
pub struct PiSession {
    /// Path to the Pi binary.
    pi_path: PathBuf,
    /// Provider name (e.g. "fae-local", "anthropic").
    provider: String,
    /// Model ID (e.g. "fae-qwen3", "claude-3-haiku").
    model: String,
    /// The Pi child process (if spawned).
    child: Option<Child>,
    /// Stdin writer for sending JSON commands.
    stdin: Option<std::io::BufWriter<std::process::ChildStdin>>,
    /// Channel for receiving parsed events from the stdout reader thread.
    event_rx: Option<mpsc::UnboundedReceiver<PiEvent>>,
}

impl PiSession {
    /// Create a new `PiSession` (not yet spawned).
    ///
    /// Call [`spawn()`](Self::spawn) to start the Pi process.
    pub fn new(pi_path: PathBuf, provider: String, model: String) -> Self {
        Self {
            pi_path,
            provider,
            model,
            child: None,
            stdin: None,
            event_rx: None,
        }
    }

    /// Returns `true` if the Pi process is currently running.
    pub fn is_running(&self) -> bool {
        self.child.is_some()
    }

    /// Spawn the Pi process in RPC mode.
    ///
    /// # Errors
    ///
    /// Returns an error if the process cannot be started.
    pub fn spawn(&mut self) -> Result<()> {
        if self.is_running() {
            return Ok(());
        }

        let mut child = Command::new(&self.pi_path)
            .args([
                "--mode",
                "rpc",
                "--no-session",
                "--provider",
                &self.provider,
                "--model",
                &self.model,
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| {
                SpeechError::Pi(format!(
                    "failed to spawn Pi at {}: {e}",
                    self.pi_path.display()
                ))
            })?;

        let child_stdin = child.stdin.take().ok_or_else(|| {
            SpeechError::Pi("failed to capture Pi stdin".to_owned())
        })?;
        let child_stdout = child.stdout.take().ok_or_else(|| {
            SpeechError::Pi("failed to capture Pi stdout".to_owned())
        })?;

        let stdin_writer = std::io::BufWriter::new(child_stdin);

        // Spawn background thread to read stdout lines and parse events.
        let (tx, rx) = mpsc::unbounded_channel();
        std::thread::spawn(move || {
            read_events(child_stdout, tx);
        });

        self.child = Some(child);
        self.stdin = Some(stdin_writer);
        self.event_rx = Some(rx);

        tracing::info!("Pi RPC session spawned: {}", self.pi_path.display());
        Ok(())
    }

    /// Send a request to Pi's stdin.
    ///
    /// # Errors
    ///
    /// Returns an error if the process is not running or the write fails.
    pub fn send(&mut self, request: &PiRpcRequest) -> Result<()> {
        let stdin = self.stdin.as_mut().ok_or_else(|| {
            SpeechError::Pi("Pi process not running".to_owned())
        })?;

        let json = serde_json::to_string(request)
            .map_err(|e| SpeechError::Pi(format!("failed to serialize request: {e}")))?;

        stdin
            .write_all(json.as_bytes())
            .map_err(|e| SpeechError::Pi(format!("failed to write to Pi stdin: {e}")))?;
        stdin
            .write_all(b"\n")
            .map_err(|e| SpeechError::Pi(format!("failed to write newline to Pi stdin: {e}")))?;
        stdin
            .flush()
            .map_err(|e| SpeechError::Pi(format!("failed to flush Pi stdin: {e}")))?;

        Ok(())
    }

    /// Send a prompt (coding task) to Pi.
    ///
    /// # Errors
    ///
    /// Returns an error if the process is not running or the write fails.
    pub fn send_prompt(&mut self, message: &str) -> Result<()> {
        self.send(&PiRpcRequest::Prompt {
            message: message.to_owned(),
        })
    }

    /// Send an abort signal to Pi.
    ///
    /// # Errors
    ///
    /// Returns an error if the process is not running or the write fails.
    pub fn send_abort(&mut self) -> Result<()> {
        self.send(&PiRpcRequest::Abort)
    }

    /// Try to receive the next event without blocking.
    ///
    /// Returns `None` if no events are available or the session is not running.
    pub fn try_recv(&mut self) -> Option<PiEvent> {
        self.event_rx.as_mut()?.try_recv().ok()
    }

    /// Receive the next event, blocking until one is available.
    ///
    /// Returns `None` if the channel is closed (Pi process exited).
    pub async fn recv(&mut self) -> Option<PiEvent> {
        self.event_rx.as_mut()?.recv().await
    }

    /// Run a coding task and collect the full response text.
    ///
    /// Spawns the session if not already running, sends the prompt, then
    /// collects `MessageUpdate` events until `AgentEnd`.
    ///
    /// # Errors
    ///
    /// Returns an error if spawning or communication fails.
    pub async fn run_task<F>(&mut self, prompt: &str, mut on_event: F) -> Result<String>
    where
        F: FnMut(&PiEvent),
    {
        if !self.is_running() {
            self.spawn()?;
        }

        self.send_prompt(prompt)?;

        let mut accumulated_text = String::new();

        loop {
            let event = match self.recv().await {
                Some(ev) => ev,
                None => {
                    return Err(SpeechError::Pi(
                        "Pi process exited unexpectedly".to_owned(),
                    ));
                }
            };

            on_event(&event);

            match &event {
                PiEvent::Rpc(PiRpcEvent::MessageUpdate { text }) => {
                    accumulated_text.push_str(text);
                }
                PiEvent::Rpc(PiRpcEvent::AgentEnd) => {
                    break;
                }
                PiEvent::ProcessExited => {
                    return Err(SpeechError::Pi(
                        "Pi process exited during task".to_owned(),
                    ));
                }
                _ => {}
            }
        }

        Ok(accumulated_text)
    }

    /// Shut down the Pi process gracefully.
    pub fn shutdown(&mut self) {
        // Drop stdin to signal EOF.
        self.stdin.take();

        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }

        self.event_rx.take();
        tracing::info!("Pi RPC session shut down");
    }

    /// Returns the Pi binary path.
    pub fn pi_path(&self) -> &Path {
        &self.pi_path
    }
}

impl Drop for PiSession {
    fn drop(&mut self) {
        self.shutdown();
    }
}

// ---------------------------------------------------------------------------
// Background stdout reader
// ---------------------------------------------------------------------------

/// Read JSON lines from Pi's stdout and send parsed events to the channel.
fn read_events(stdout: std::process::ChildStdout, tx: mpsc::UnboundedSender<PiEvent>) {
    use std::io::BufRead;
    let reader = std::io::BufReader::new(stdout);

    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };

        if line.trim().is_empty() {
            continue;
        }

        let event = match serde_json::from_str::<PiRpcEvent>(&line) {
            Ok(rpc_event) => PiEvent::Rpc(rpc_event),
            Err(_) => PiEvent::Unknown(line),
        };

        if tx.send(event).is_err() {
            break; // Receiver dropped.
        }
    }

    // Signal that the process has exited.
    let _ = tx.send(PiEvent::ProcessExited);
}

// ---------------------------------------------------------------------------
// Parse helper for events from raw JSON
// ---------------------------------------------------------------------------

/// Parse a single JSON line into a `PiEvent`.
pub fn parse_event(json_line: &str) -> PiEvent {
    match serde_json::from_str::<PiRpcEvent>(json_line) {
        Ok(rpc_event) => PiEvent::Rpc(rpc_event),
        Err(_) => PiEvent::Unknown(json_line.to_owned()),
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;

    #[test]
    fn prompt_request_serializes_correctly() {
        let req = PiRpcRequest::Prompt {
            message: "fix the bug".to_owned(),
        };
        let json = serde_json::to_string(&req).unwrap();
        assert!(json.contains("\"type\":\"prompt\""));
        assert!(json.contains("\"message\":\"fix the bug\""));
    }

    #[test]
    fn abort_request_serializes_correctly() {
        let req = PiRpcRequest::Abort;
        let json = serde_json::to_string(&req).unwrap();
        assert!(json.contains("\"type\":\"abort\""));
    }

    #[test]
    fn get_state_request_serializes_correctly() {
        let req = PiRpcRequest::GetState;
        let json = serde_json::to_string(&req).unwrap();
        assert!(json.contains("\"type\":\"get_state\""));
    }

    #[test]
    fn new_session_request_serializes_correctly() {
        let req = PiRpcRequest::NewSession;
        let json = serde_json::to_string(&req).unwrap();
        assert!(json.contains("\"type\":\"new_session\""));
    }

    #[test]
    fn message_update_event_deserializes() {
        let json = r#"{"type":"message_update","text":"Hello world"}"#;
        let event: PiRpcEvent = serde_json::from_str(json).unwrap();
        assert!(matches!(event, PiRpcEvent::MessageUpdate { text } if text == "Hello world"));
    }

    #[test]
    fn agent_start_event_deserializes() {
        let json = r#"{"type":"agent_start"}"#;
        let event: PiRpcEvent = serde_json::from_str(json).unwrap();
        assert!(matches!(event, PiRpcEvent::AgentStart));
    }

    #[test]
    fn agent_end_event_deserializes() {
        let json = r#"{"type":"agent_end"}"#;
        let event: PiRpcEvent = serde_json::from_str(json).unwrap();
        assert!(matches!(event, PiRpcEvent::AgentEnd));
    }

    #[test]
    fn tool_execution_start_deserializes() {
        let json = r#"{"type":"tool_execution_start","name":"bash"}"#;
        let event: PiRpcEvent = serde_json::from_str(json).unwrap();
        assert!(matches!(event, PiRpcEvent::ToolExecutionStart { name } if name == "bash"));
    }

    #[test]
    fn tool_execution_end_deserializes() {
        let json = r#"{"type":"tool_execution_end","name":"edit","success":true}"#;
        let event: PiRpcEvent = serde_json::from_str(json).unwrap();
        assert!(
            matches!(event, PiRpcEvent::ToolExecutionEnd { name, success } if name == "edit" && success)
        );
    }

    #[test]
    fn response_event_deserializes() {
        let json = r#"{"type":"response","success":true}"#;
        let event: PiRpcEvent = serde_json::from_str(json).unwrap();
        assert!(matches!(event, PiRpcEvent::Response { success } if success));
    }

    #[test]
    fn parse_event_unknown_type() {
        let json = r#"{"type":"future_event_type","data":123}"#;
        let event = parse_event(json);
        assert!(matches!(event, PiEvent::Unknown(_)));
    }

    #[test]
    fn parse_event_invalid_json() {
        let event = parse_event("not json at all");
        assert!(matches!(event, PiEvent::Unknown(_)));
    }

    #[test]
    fn pi_session_new_is_not_running() {
        let session = PiSession::new(
            PathBuf::from("/usr/local/bin/pi"),
            "fae-local".to_owned(),
            "fae-qwen3".to_owned(),
        );
        assert!(!session.is_running());
        assert_eq!(session.pi_path(), Path::new("/usr/local/bin/pi"));
    }

    #[test]
    fn message_update_event_default_text() {
        // When "text" field is missing, default to empty string.
        let json = r#"{"type":"message_update"}"#;
        let event: PiRpcEvent = serde_json::from_str(json).unwrap();
        assert!(matches!(event, PiRpcEvent::MessageUpdate { text } if text.is_empty()));
    }
}
