//! Tool approval plumbing for interactive frontends (GUI/TUI).
//!
//! The agent tool harness can request high-risk operations (write/edit/bash/web).
//! When an approval sender is wired up, those tools are gated behind an explicit
//! user decision. If no approval handler is configured, tools run as-is.

use tokio::sync::oneshot;

/// UI response payload for interactive tool requests.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ToolApprovalResponse {
    /// Simple approve/deny response.
    Approved(bool),
    /// Text value response (used by select/input/editor dialogs).
    Value(String),
    /// Explicit cancel/no-response action.
    Cancelled,
}

impl ToolApprovalResponse {
    /// Return whether this response represents approval.
    pub fn is_approved(&self) -> bool {
        matches!(self, Self::Approved(true))
    }
}

/// A request for the UI to approve or deny a tool execution.
///
/// The UI can call:
/// - `respond(true|false)` for approve/deny.
/// - `respond_value(...)` for text responses.
/// - `cancel()` to abort.
pub struct ToolApprovalRequest {
    pub id: u64,
    pub name: String,
    pub input_json: String,
    respond_to: oneshot::Sender<ToolApprovalResponse>,
}

impl ToolApprovalRequest {
    pub fn new(
        id: u64,
        name: String,
        input_json: String,
        respond_to: oneshot::Sender<ToolApprovalResponse>,
    ) -> Self {
        Self {
            id,
            name,
            input_json,
            respond_to,
        }
    }

    /// Respond to the approval request.
    ///
    /// Returns `true` if the response was delivered to the waiting tool runner.
    pub fn respond(self, approved: bool) -> bool {
        self.respond_to
            .send(ToolApprovalResponse::Approved(approved))
            .is_ok()
    }

    /// Respond with a string value.
    ///
    /// Used by select/input/editor style dialogs.
    pub fn respond_value(self, value: impl Into<String>) -> bool {
        self.respond_to
            .send(ToolApprovalResponse::Value(value.into()))
            .is_ok()
    }

    /// Cancel the pending request.
    pub fn cancel(self) -> bool {
        self.respond_to
            .send(ToolApprovalResponse::Cancelled)
            .is_ok()
    }
}
