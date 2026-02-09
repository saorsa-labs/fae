//! Tool approval plumbing for interactive frontends (GUI/TUI).
//!
//! The agent tool harness can request high-risk operations (write/edit/bash/web).
//! When an approval sender is wired up, those tools are gated behind an explicit
//! user decision. If no approval handler is configured, tools run as-is.

use tokio::sync::oneshot;

/// A request for the UI to approve or deny a tool execution.
///
/// The UI should call `respond(true)` to approve or `respond(false)` to deny.
pub struct ToolApprovalRequest {
    pub id: u64,
    pub name: String,
    pub input_json: String,
    respond_to: oneshot::Sender<bool>,
}

impl ToolApprovalRequest {
    pub fn new(
        id: u64,
        name: String,
        input_json: String,
        respond_to: oneshot::Sender<bool>,
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
        self.respond_to.send(approved).is_ok()
    }
}
