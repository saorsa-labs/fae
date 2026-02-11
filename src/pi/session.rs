//! Pi RPC session — spawns `pi` in RPC mode and communicates via JSON-over-stdin/stdout.
//!
//! Protocol reference: `pi-mono/packages/coding-agent/docs/rpc.md`.

use crate::error::{Result, SpeechError};
use serde::{Deserialize, Serialize};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use tokio::sync::mpsc;

// ---------------------------------------------------------------------------
// RPC requests (Fae → Pi stdin)
// ---------------------------------------------------------------------------

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum PiStreamingBehavior {
    Steer,
    #[serde(rename = "followUp")]
    FollowUp,
}

/// A request sent to Pi's stdin in RPC mode.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PiRpcRequest {
    /// Send a user prompt to the agent.
    Prompt {
        message: String,
        #[serde(rename = "streamingBehavior", skip_serializing_if = "Option::is_none")]
        streaming_behavior: Option<PiStreamingBehavior>,
    },
    /// Abort the current agent operation.
    Abort,
    /// Start a new session.
    NewSession {
        #[serde(rename = "parentSession", skip_serializing_if = "Option::is_none")]
        parent_session: Option<String>,
    },
    /// Respond to an extension UI request (RPC sub-protocol).
    ExtensionUiResponse {
        id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        value: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        confirmed: Option<bool>,
        #[serde(skip_serializing_if = "Option::is_none")]
        cancelled: Option<bool>,
    },
}

impl PiRpcRequest {
    pub fn prompt(message: impl Into<String>) -> Self {
        Self::Prompt {
            message: message.into(),
            streaming_behavior: None,
        }
    }

    pub fn abort() -> Self {
        Self::Abort
    }

    pub fn new_session() -> Self {
        Self::NewSession {
            parent_session: None,
        }
    }

    pub fn ui_confirm(id: impl Into<String>, confirmed: bool) -> Self {
        Self::ExtensionUiResponse {
            id: id.into(),
            value: None,
            confirmed: Some(confirmed),
            cancelled: None,
        }
    }

    pub fn ui_value(id: impl Into<String>, value: impl Into<String>) -> Self {
        Self::ExtensionUiResponse {
            id: id.into(),
            value: Some(value.into()),
            confirmed: None,
            cancelled: None,
        }
    }

    pub fn ui_cancel(id: impl Into<String>) -> Self {
        Self::ExtensionUiResponse {
            id: id.into(),
            value: None,
            confirmed: None,
            cancelled: Some(true),
        }
    }
}

// ---------------------------------------------------------------------------
// RPC outputs (Pi stdout → Fae)
// ---------------------------------------------------------------------------

/// A response to an RPC request.
#[derive(Debug, Clone, Deserialize)]
pub struct PiRpcResponse {
    #[serde(default)]
    pub id: Option<String>,
    pub command: String,
    pub success: bool,
    #[serde(default)]
    pub data: Option<serde_json::Value>,
    #[serde(default)]
    pub error: Option<String>,
}

/// Extension UI request emitted in RPC mode.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "method", rename_all = "snake_case")]
pub enum PiExtensionUiRequest {
    Select {
        id: String,
        title: String,
        options: Vec<String>,
        #[serde(default)]
        timeout: Option<u64>,
    },
    Confirm {
        id: String,
        title: String,
        message: String,
        #[serde(default)]
        timeout: Option<u64>,
    },
    Input {
        id: String,
        title: String,
        #[serde(default)]
        placeholder: Option<String>,
        #[serde(default)]
        timeout: Option<u64>,
    },
    Editor {
        id: String,
        title: String,
        #[serde(default)]
        prefill: Option<String>,
    },
    Notify {
        id: String,
        message: String,
        #[serde(rename = "notifyType", default)]
        notify_type: Option<String>,
    },
    SetStatus {
        id: String,
        #[serde(rename = "statusKey")]
        status_key: String,
        #[serde(rename = "statusText", default)]
        status_text: Option<String>,
    },
    SetWidget {
        id: String,
        #[serde(rename = "widgetKey")]
        widget_key: String,
        #[serde(rename = "widgetLines", default)]
        widget_lines: Option<Vec<String>>,
        #[serde(rename = "widgetPlacement", default)]
        widget_placement: Option<String>,
    },
    SetTitle {
        id: String,
        title: String,
    },
    SetEditorText {
        id: String,
        text: String,
    },
}

impl PiExtensionUiRequest {
    pub fn id(&self) -> &str {
        match self {
            Self::Select { id, .. }
            | Self::Confirm { id, .. }
            | Self::Input { id, .. }
            | Self::Editor { id, .. }
            | Self::Notify { id, .. }
            | Self::SetStatus { id, .. }
            | Self::SetWidget { id, .. }
            | Self::SetTitle { id, .. }
            | Self::SetEditorText { id, .. } => id,
        }
    }
}

/// Agent/session events emitted by Pi.
///
/// This is a superset of `AgentEvent` (pi-agent-core) in RPC mode, including
/// session-level events such as auto-compaction and auto-retry.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum PiAgentEvent {
    AgentStart,
    AgentEnd {
        #[serde(default)]
        messages: Vec<serde_json::Value>,
    },

    TurnStart,
    TurnEnd {
        message: serde_json::Value,
        #[serde(rename = "toolResults", default)]
        tool_results: Vec<serde_json::Value>,
    },

    MessageStart {
        message: serde_json::Value,
    },
    MessageUpdate {
        message: serde_json::Value,
        #[serde(rename = "assistantMessageEvent")]
        assistant_message_event: serde_json::Value,
    },
    MessageEnd {
        message: serde_json::Value,
    },

    ToolExecutionStart {
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
        #[serde(rename = "toolName")]
        tool_name: String,
        args: serde_json::Value,
    },
    ToolExecutionUpdate {
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
        #[serde(rename = "toolName")]
        tool_name: String,
        args: serde_json::Value,
        #[serde(rename = "partialResult")]
        partial_result: serde_json::Value,
    },
    ToolExecutionEnd {
        #[serde(rename = "toolCallId")]
        tool_call_id: String,
        #[serde(rename = "toolName")]
        tool_name: String,
        result: serde_json::Value,
        #[serde(rename = "isError")]
        is_error: bool,
    },

    AutoCompactionStart {
        reason: String,
    },
    AutoCompactionEnd {
        #[serde(default)]
        result: Option<serde_json::Value>,
        #[serde(default)]
        aborted: bool,
        #[serde(rename = "willRetry", default)]
        will_retry: bool,
        #[serde(rename = "errorMessage", default)]
        error_message: Option<String>,
    },

    AutoRetryStart {
        attempt: u32,
        #[serde(rename = "maxAttempts")]
        max_attempts: u32,
        #[serde(rename = "delayMs")]
        delay_ms: u64,
        #[serde(rename = "errorMessage")]
        error_message: String,
    },
    AutoRetryEnd {
        success: bool,
        attempt: u32,
        #[serde(rename = "finalError", default)]
        final_error: Option<String>,
    },

    ExtensionError {
        #[serde(rename = "extensionPath")]
        extension_path: String,
        event: String,
        error: String,
    },
}

/// Parsed line from Pi stdout.
#[derive(Debug, Clone)]
pub enum PiOutput {
    Response(PiRpcResponse),
    ExtensionUiRequest(PiExtensionUiRequest),
    Event(PiAgentEvent),
    Unknown(String),
    ProcessExited,
}

// ---------------------------------------------------------------------------
// PiSession
// ---------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub enum PiToolsConfig {
    /// Do not pass any tool flags; Pi chooses its defaults.
    Default,
    /// Disable all built-in tools (`--no-tools`).
    None,
    /// Enable only these built-in tools (`--tools ...`).
    Allowlist(Vec<String>),
}

/// A running Pi RPC session (subprocess + event stream).
pub struct PiSession {
    pi_path: PathBuf,
    provider: String,
    model: String,
    tools: PiToolsConfig,
    no_session: bool,
    append_system_prompt: Option<String>,
    extensions: Vec<PathBuf>,
    cwd: Option<PathBuf>,

    child: Option<Child>,
    stdin: Option<std::io::BufWriter<std::process::ChildStdin>>,
    event_rx: Option<mpsc::UnboundedReceiver<PiOutput>>,
}

impl PiSession {
    /// Create a new `PiSession` (not yet spawned).
    pub fn new(pi_path: PathBuf, provider: String, model: String) -> Self {
        Self {
            pi_path,
            provider,
            model,
            tools: PiToolsConfig::Default,
            no_session: true,
            append_system_prompt: None,
            extensions: Vec::new(),
            cwd: None,
            child: None,
            stdin: None,
            event_rx: None,
        }
    }

    pub fn set_tools(&mut self, tools: PiToolsConfig) {
        self.tools = tools;
    }

    /// Switch provider/model for future prompts.
    ///
    /// If a process is currently running, it is shut down so the next spawn
    /// starts Pi with the new provider/model.
    pub fn set_provider_model(&mut self, provider: String, model: String) {
        if self.provider == provider && self.model == model {
            return;
        }
        self.shutdown();
        self.provider = provider;
        self.model = model;
    }

    /// Current provider id passed to Pi (`--provider`).
    pub fn provider(&self) -> &str {
        &self.provider
    }

    /// Current model id passed to Pi (`--model`).
    pub fn model(&self) -> &str {
        &self.model
    }

    pub fn set_no_session(&mut self, no_session: bool) {
        self.no_session = no_session;
    }

    pub fn set_append_system_prompt(&mut self, text: Option<String>) {
        self.append_system_prompt = text;
    }

    pub fn add_extension(&mut self, path: PathBuf) {
        self.extensions.push(path);
    }

    pub fn set_cwd(&mut self, cwd: Option<PathBuf>) {
        self.cwd = cwd;
    }

    pub fn is_running(&self) -> bool {
        self.child.is_some()
    }

    /// Spawn the Pi process in RPC mode.
    pub fn spawn(&mut self) -> Result<()> {
        if self.is_running() {
            return Ok(());
        }

        let mut cmd = Command::new(&self.pi_path);
        cmd.args(["--mode", "rpc"]);

        if self.no_session {
            cmd.arg("--no-session");
        }

        cmd.args(["--provider", &self.provider, "--model", &self.model]);

        match &self.tools {
            PiToolsConfig::Default => {}
            PiToolsConfig::None => {
                cmd.arg("--no-tools");
            }
            PiToolsConfig::Allowlist(list) => {
                if list.is_empty() {
                    cmd.arg("--no-tools");
                } else {
                    cmd.arg("--tools");
                    cmd.arg(list.join(","));
                }
            }
        }

        if let Some(text) = &self.append_system_prompt
            && !text.trim().is_empty()
        {
            cmd.arg("--append-system-prompt");
            cmd.arg(text);
        }

        for ext in &self.extensions {
            cmd.arg("--extension");
            cmd.arg(ext);
        }

        if let Some(cwd) = &self.cwd {
            cmd.current_dir(cwd);
        }

        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| {
                SpeechError::Pi(format!(
                    "failed to spawn Pi at {}: {e}",
                    self.pi_path.display()
                ))
            })?;

        let child_stdin = child
            .stdin
            .take()
            .ok_or_else(|| SpeechError::Pi("failed to capture Pi stdin".to_owned()))?;
        let child_stdout = child
            .stdout
            .take()
            .ok_or_else(|| SpeechError::Pi("failed to capture Pi stdout".to_owned()))?;
        let child_stderr = child
            .stderr
            .take()
            .ok_or_else(|| SpeechError::Pi("failed to capture Pi stderr".to_owned()))?;

        let stdin_writer = std::io::BufWriter::new(child_stdin);

        let (tx, rx) = mpsc::unbounded_channel();
        std::thread::spawn(move || {
            read_stdout_events(child_stdout, tx);
        });

        std::thread::spawn(move || {
            read_stderr_lines(child_stderr);
        });

        self.child = Some(child);
        self.stdin = Some(stdin_writer);
        self.event_rx = Some(rx);

        tracing::info!("Pi RPC session spawned: {}", self.pi_path.display());
        Ok(())
    }

    pub fn send(&mut self, request: &PiRpcRequest) -> Result<()> {
        let stdin = self
            .stdin
            .as_mut()
            .ok_or_else(|| SpeechError::Pi("Pi process not running".to_owned()))?;

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

    pub fn send_prompt(&mut self, message: &str) -> Result<()> {
        self.send(&PiRpcRequest::prompt(message))
    }

    pub fn send_abort(&mut self) -> Result<()> {
        self.send(&PiRpcRequest::abort())
    }

    pub fn send_new_session(&mut self) -> Result<()> {
        self.send(&PiRpcRequest::new_session())
    }

    pub fn send_ui_confirm(&mut self, id: &str, confirmed: bool) -> Result<()> {
        self.send(&PiRpcRequest::ui_confirm(id, confirmed))
    }

    pub fn send_ui_value(&mut self, id: &str, value: impl Into<String>) -> Result<()> {
        self.send(&PiRpcRequest::ui_value(id, value))
    }

    pub fn send_ui_cancel(&mut self, id: &str) -> Result<()> {
        self.send(&PiRpcRequest::ui_cancel(id))
    }

    pub fn try_recv(&mut self) -> Option<PiOutput> {
        self.event_rx.as_mut()?.try_recv().ok()
    }

    pub async fn recv(&mut self) -> Option<PiOutput> {
        self.event_rx.as_mut()?.recv().await
    }

    pub fn shutdown(&mut self) {
        self.stdin.take();
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        self.event_rx.take();
        tracing::info!("Pi RPC session shut down");
    }

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
// Background readers
// ---------------------------------------------------------------------------

fn read_stdout_events(stdout: std::process::ChildStdout, tx: mpsc::UnboundedSender<PiOutput>) {
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

        let parsed = parse_output_line(&line);
        if tx.send(parsed).is_err() {
            break;
        }
    }

    let _ = tx.send(PiOutput::ProcessExited);
}

fn read_stderr_lines(stderr: std::process::ChildStderr) {
    use std::io::BufRead;
    let reader = std::io::BufReader::new(stderr);
    for line in reader.lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };
        if line.trim().is_empty() {
            continue;
        }
        tracing::warn!("pi stderr: {line}");
    }
}

fn parse_output_line(line: &str) -> PiOutput {
    let value: serde_json::Value = match serde_json::from_str(line) {
        Ok(v) => v,
        Err(_) => return PiOutput::Unknown(line.to_owned()),
    };

    let Some(tp) = value.get("type").and_then(|v| v.as_str()) else {
        return PiOutput::Unknown(line.to_owned());
    };

    match tp {
        "response" => match serde_json::from_value::<PiRpcResponse>(value) {
            Ok(r) => PiOutput::Response(r),
            Err(_) => PiOutput::Unknown(line.to_owned()),
        },
        "extension_ui_request" => match serde_json::from_value::<PiExtensionUiRequest>(value) {
            Ok(req) => PiOutput::ExtensionUiRequest(req),
            Err(_) => PiOutput::Unknown(line.to_owned()),
        },
        _ => match serde_json::from_value::<PiAgentEvent>(value) {
            Ok(ev) => PiOutput::Event(ev),
            Err(_) => PiOutput::Unknown(line.to_owned()),
        },
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;

    #[test]
    fn prompt_serializes_with_expected_keys() {
        let req = PiRpcRequest::prompt("hello");
        let json = serde_json::to_string(&req).unwrap();
        assert!(json.contains("\"type\":\"prompt\""));
        assert!(json.contains("\"message\":\"hello\""));
    }

    #[test]
    fn parse_tool_execution_start() {
        let line = r#"{"type":"tool_execution_start","toolCallId":"call_1","toolName":"bash","args":{"command":"ls"}} "#;
        let out = parse_output_line(line);
        match out {
            PiOutput::Event(PiAgentEvent::ToolExecutionStart {
                tool_call_id,
                tool_name,
                args,
            }) => {
                assert_eq!(tool_call_id, "call_1");
                assert_eq!(tool_name, "bash");
                assert_eq!(args["command"].as_str(), Some("ls"));
            }
            other => panic!("unexpected: {other:?}"),
        }
    }

    #[test]
    fn parse_extension_ui_confirm() {
        let line = r#"{"type":"extension_ui_request","id":"uuid-1","method":"confirm","title":"OK?","message":"Proceed?"}"#;
        let out = parse_output_line(line);
        match out {
            PiOutput::ExtensionUiRequest(PiExtensionUiRequest::Confirm {
                id,
                title,
                message,
                ..
            }) => {
                assert_eq!(id, "uuid-1");
                assert_eq!(title, "OK?");
                assert_eq!(message, "Proceed?");
            }
            other => panic!("unexpected: {other:?}"),
        }
    }
}
