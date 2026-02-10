//! Canvas backend trait — unifies local and remote canvas sessions.
//!
//! [`CanvasBackend`] is the abstraction that lets bridge, tools, and the GUI
//! work identically against a local [`CanvasSession`](super::session::CanvasSession)
//! or a [`RemoteCanvasSession`](super::remote::RemoteCanvasSession).

use canvas_core::{Element, ElementId};

use super::session::MessageView;
use super::types::CanvasMessage;

/// Connection status for canvas backends.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionStatus {
    /// Using a local canvas — no network involved.
    Local,
    /// Not connected to the remote server.
    Disconnected,
    /// Establishing initial connection.
    Connecting,
    /// Connected and synced with the remote server.
    Connected,
    /// Reconnecting after a disconnect.
    Reconnecting {
        /// Number of attempts so far.
        attempt: u32,
    },
    /// Unrecoverable connection error.
    Failed(String),
}

impl std::fmt::Display for ConnectionStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Local => write!(f, "Local"),
            Self::Disconnected => write!(f, "Disconnected"),
            Self::Connecting => write!(f, "Connecting"),
            Self::Connected => write!(f, "Connected"),
            Self::Reconnecting { attempt } => write!(f, "Reconnecting (attempt {attempt})"),
            Self::Failed(msg) => write!(f, "Failed: {msg}"),
        }
    }
}

/// Unified interface for local and remote canvas sessions.
///
/// Both [`CanvasSession`](super::session::CanvasSession) and
/// [`RemoteCanvasSession`](super::remote::RemoteCanvasSession) implement this
/// trait, allowing bridge, tools, and the GUI to be backend-agnostic.
pub trait CanvasBackend: Send {
    /// The session identifier.
    fn session_id(&self) -> &str;

    /// Push a conversation message to the canvas, returning its element ID.
    fn push_message(&mut self, message: &CanvasMessage) -> ElementId;

    /// Add a raw element (used by MCP tools), returning its element ID.
    fn add_element(&mut self, element: Element) -> ElementId;

    /// Remove an element by ID. Returns the removed element, or `None`.
    fn remove_element(&mut self, id: &ElementId) -> Option<Element>;

    /// Clear all elements and reset the session.
    fn clear(&mut self);

    /// Number of conversation messages.
    fn message_count(&self) -> usize;

    /// Total element count in the scene.
    fn element_count(&self) -> usize;

    /// Get per-message rendering data for the GUI.
    fn message_views(&self) -> Vec<MessageView>;

    /// Render tool-pushed elements as HTML.
    fn tool_elements_html(&self) -> String;

    /// Full HTML serialization of the session.
    fn to_html(&self) -> String;

    /// Cached HTML serialization. Re-renders only when the session has changed.
    fn to_html_cached(&mut self) -> &str;

    /// Update viewport dimensions and re-layout messages.
    fn resize_viewport(&mut self, width: f32, height: f32);

    /// Current connection status.
    fn connection_status(&self) -> ConnectionStatus;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn connection_status_display() {
        assert_eq!(ConnectionStatus::Local.to_string(), "Local");
        assert_eq!(ConnectionStatus::Connected.to_string(), "Connected");
        assert_eq!(
            ConnectionStatus::Reconnecting { attempt: 3 }.to_string(),
            "Reconnecting (attempt 3)"
        );
        assert_eq!(
            ConnectionStatus::Failed("timeout".into()).to_string(),
            "Failed: timeout"
        );
    }

    #[test]
    fn connection_status_eq() {
        assert_eq!(ConnectionStatus::Local, ConnectionStatus::Local);
        assert_ne!(ConnectionStatus::Local, ConnectionStatus::Connected);
    }
}
