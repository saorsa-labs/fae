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

use std::path::Path;
use std::str::FromStr;
use std::sync::{Arc, Mutex};

use agent_client_protocol::schema::{
    ContentBlock, InitializeRequest, NewSessionRequest, PromptRequest, ProtocolVersion,
    RequestPermissionOutcome, RequestPermissionRequest, RequestPermissionResponse,
    SelectedPermissionOutcome, SessionNotification, SessionUpdate, StopReason, TextContent,
};
use agent_client_protocol::{AcpAgent, Agent, ConnectionTo};

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
}
