//! Remote canvas session — WebSocket client for `canvas-server`.
//!
//! [`RemoteCanvasSession`] implements [`CanvasBackend`] by forwarding mutations
//! to a remote canvas-server over WebSocket and maintaining a local shadow copy
//! of the scene for reads.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use canvas_core::{Element, ElementDocument, ElementId, Scene};
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

use super::backend::{CanvasBackend, ConnectionStatus};
use super::session::MessageView;
use super::types::CanvasMessage;

// ---------------------------------------------------------------------------
// Protocol types (mirror the server's serde-tagged enums)
// ---------------------------------------------------------------------------

/// Messages sent from client to server.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
#[allow(dead_code)] // Protocol variants defined for completeness.
enum ClientMessage {
    Subscribe {
        session_id: String,
    },
    AddElement {
        element: ElementDocument,
        #[serde(skip_serializing_if = "Option::is_none")]
        message_id: Option<String>,
    },
    UpdateElement {
        id: String,
        changes: serde_json::Value,
        #[serde(skip_serializing_if = "Option::is_none")]
        message_id: Option<String>,
    },
    RemoveElement {
        id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        message_id: Option<String>,
    },
    Ping,
    GetScene,
}

/// Messages received from the server.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
#[allow(dead_code)] // Fields populated by deserialization only.
enum ServerMessage {
    Welcome {
        #[serde(default)]
        session_id: String,
    },
    SceneUpdate {
        scene: SceneDocument,
    },
    ElementAdded {
        element: ElementDocument,
    },
    ElementUpdated {
        element: ElementDocument,
        #[serde(default)]
        timestamp: u64,
    },
    ElementRemoved {
        id: String,
    },
    Ack {
        #[serde(default)]
        message_id: Option<String>,
        #[serde(default)]
        success: bool,
    },
    Error {
        #[serde(default)]
        message: String,
    },
    SyncResult {
        #[serde(default)]
        synced_count: usize,
        #[serde(default)]
        conflict_count: usize,
        #[serde(default)]
        timestamp: u64,
        #[serde(default)]
        failed_operations: Vec<serde_json::Value>,
    },
    Pong {},
}

/// Viewport metadata from the server scene.
#[derive(Debug, Clone, Copy, Deserialize)]
#[allow(dead_code)] // Fields populated by deserialization only.
struct ViewportInfo {
    #[serde(default)]
    width: f32,
    #[serde(default)]
    height: f32,
    #[serde(default = "default_zoom")]
    zoom: f32,
    #[serde(default)]
    pan_x: f32,
    #[serde(default)]
    pan_y: f32,
}

fn default_zoom() -> f32 {
    1.0
}

impl Default for ViewportInfo {
    fn default() -> Self {
        Self {
            width: 800.0,
            height: 600.0,
            zoom: 1.0,
            pan_x: 0.0,
            pan_y: 0.0,
        }
    }
}

/// Scene document matching canvas-server's `SceneDocument` schema.
#[derive(Debug, Clone, Deserialize)]
#[allow(dead_code)] // Fields populated by deserialization only.
struct SceneDocument {
    #[serde(default)]
    session_id: String,
    #[serde(default)]
    viewport: ViewportInfo,
    #[serde(default)]
    elements: Vec<ElementDocument>,
    #[serde(default)]
    timestamp: u64,
}

// ---------------------------------------------------------------------------
// Shared state between the session and the background WS task
// ---------------------------------------------------------------------------

/// Shared mutable state protected by a mutex.
struct SharedState {
    status: ConnectionStatus,
    /// Local shadow scene (rebuilt from server updates).
    scene: Scene,
    /// Messages pushed via the bridge.
    messages: Vec<MessageEntry>,
    next_y: f32,
    generation: u64,
}

/// Mirrors `CanvasSession::MessageEntry`.
struct MessageEntry {
    element_id: ElementId,
    role: super::types::MessageRole,
    timestamp_ms: u64,
    text: String,
    tool_name: Option<String>,
    tool_input: Option<String>,
    tool_result_text: Option<String>,
}

/// Vertical height allocated per message element (pixels).
const MESSAGE_HEIGHT: f32 = 40.0;
/// Vertical gap between consecutive messages (pixels).
const MESSAGE_PADDING: f32 = 8.0;
/// Horizontal margin on each side of messages (pixels).
const MESSAGE_MARGIN_X: f32 = 16.0;

// ---------------------------------------------------------------------------
// RemoteCanvasSession
// ---------------------------------------------------------------------------

/// A canvas backend that delegates to a remote canvas-server via WebSocket.
///
/// Mutations are sent as JSON messages over the WebSocket connection.
/// The local shadow scene is updated optimistically and corrected when the
/// server sends `SceneUpdate` messages.
pub struct RemoteCanvasSession {
    session_id: String,
    shared: Arc<Mutex<SharedState>>,
    /// Channel to send outbound WS messages to the background task.
    tx: mpsc::UnboundedSender<String>,
    /// Local HTML cache (owned by self so `to_html_cached` can return `&str`).
    cached_html: String,
    /// Generation at which the local HTML cache was last built.
    cached_generation: u64,
}

impl RemoteCanvasSession {
    /// Connect to a remote canvas-server.
    ///
    /// Spawns a background tokio task that manages the WebSocket connection
    /// with automatic reconnection.
    ///
    /// # Arguments
    /// * `server_url` — WebSocket URL, e.g. `ws://localhost:9473/ws/sync`
    /// * `session_id` — Canvas session to subscribe to.
    /// * `width` / `height` — Initial local viewport dimensions.
    pub fn connect(
        server_url: impl Into<String>,
        session_id: impl Into<String>,
        width: f32,
        height: f32,
    ) -> Self {
        let server_url = server_url.into();
        let session_id = session_id.into();

        let shared = Arc::new(Mutex::new(SharedState {
            status: ConnectionStatus::Connecting,
            scene: Scene::new(width, height),
            messages: Vec::new(),
            next_y: MESSAGE_PADDING,
            generation: 0,
        }));

        let (tx, rx) = mpsc::unbounded_channel();

        // Spawn background connection manager.
        let ws_shared = Arc::clone(&shared);
        let ws_session_id = session_id.clone();
        let ws_url = server_url;
        tokio::spawn(async move {
            connection_loop(ws_url, ws_session_id, ws_shared, rx).await;
        });

        Self {
            session_id,
            shared,
            tx,
            cached_html: String::new(),
            cached_generation: 0,
        }
    }

    /// Send a serialized JSON message to the background WebSocket task.
    fn send_msg(&self, msg: &ClientMessage) {
        if let Ok(json) = serde_json::to_string(msg) {
            // If the receiver is dropped the connection is dead — ignore error.
            let _ = self.tx.send(json);
        }
    }
}

impl CanvasBackend for RemoteCanvasSession {
    fn session_id(&self) -> &str {
        &self.session_id
    }

    fn push_message(&mut self, message: &CanvasMessage) -> ElementId {
        let mut state = match self.shared.lock() {
            Ok(s) => s,
            Err(p) => p.into_inner(),
        };

        let width = state.scene.viewport_width - (MESSAGE_MARGIN_X * 2.0);
        let transform = canvas_core::Transform {
            x: MESSAGE_MARGIN_X,
            y: state.next_y,
            width,
            height: MESSAGE_HEIGHT,
            rotation: 0.0,
            z_index: state.messages.len() as i32,
        };

        let element = message.to_element_at(transform);

        // Add locally.
        let doc = ElementDocument::from(&element);
        let id = state.scene.add_element(element);

        state.messages.push(MessageEntry {
            element_id: id,
            role: message.role,
            timestamp_ms: message.timestamp_ms,
            text: message.text.clone(),
            tool_name: message.tool_name.clone(),
            tool_input: message.tool_input.clone(),
            tool_result_text: message.tool_result_text.clone(),
        });

        state.next_y += MESSAGE_HEIGHT + MESSAGE_PADDING;
        state.generation += 1;

        drop(state);

        // Send to server.
        self.send_msg(&ClientMessage::AddElement {
            element: doc,
            message_id: None,
        });

        id
    }

    fn add_element(&mut self, element: Element) -> ElementId {
        let mut state = match self.shared.lock() {
            Ok(s) => s,
            Err(p) => p.into_inner(),
        };

        let doc = ElementDocument::from(&element);
        let id = state.scene.add_element(element);
        state.generation += 1;
        drop(state);

        self.send_msg(&ClientMessage::AddElement {
            element: doc,
            message_id: None,
        });

        id
    }

    fn remove_element(&mut self, id: &ElementId) -> Option<Element> {
        let mut state = match self.shared.lock() {
            Ok(s) => s,
            Err(p) => p.into_inner(),
        };

        let removed = state.scene.remove_element(id).ok();
        state.generation += 1;
        drop(state);

        self.send_msg(&ClientMessage::RemoveElement {
            id: id.to_string(),
            message_id: None,
        });

        removed
    }

    fn clear(&mut self) {
        let mut state = match self.shared.lock() {
            Ok(s) => s,
            Err(p) => p.into_inner(),
        };

        state.scene.clear();
        state.messages.clear();
        state.next_y = MESSAGE_PADDING;
        state.generation += 1;
    }

    fn message_count(&self) -> usize {
        match self.shared.lock() {
            Ok(s) => s.messages.len(),
            Err(p) => p.into_inner().messages.len(),
        }
    }

    fn element_count(&self) -> usize {
        match self.shared.lock() {
            Ok(s) => s.scene.element_count(),
            Err(p) => p.into_inner().scene.element_count(),
        }
    }

    fn message_views(&self) -> Vec<MessageView> {
        use super::render::render_element_html;

        let state = match self.shared.lock() {
            Ok(s) => s,
            Err(p) => p.into_inner(),
        };

        state
            .messages
            .iter()
            .map(|entry| {
                let html = state
                    .scene
                    .get_element(entry.element_id)
                    .map(|el| render_element_html(el, entry.role.css_class()))
                    .unwrap_or_default();

                MessageView {
                    role: entry.role,
                    timestamp_ms: entry.timestamp_ms,
                    html,
                    text: entry.text.clone(),
                    tool_name: entry.tool_name.clone(),
                    tool_input: entry.tool_input.clone(),
                    tool_result_text: entry.tool_result_text.clone(),
                }
            })
            .collect()
    }

    fn tool_elements_html(&self) -> String {
        use super::render::render_element_html;
        use std::collections::HashSet;

        let state = match self.shared.lock() {
            Ok(s) => s,
            Err(p) => p.into_inner(),
        };

        let message_ids: HashSet<ElementId> = state.messages.iter().map(|e| e.element_id).collect();

        let tool_elements: Vec<_> = state
            .scene
            .elements()
            .filter(|el| !message_ids.contains(&el.id))
            .collect();

        if tool_elements.is_empty() {
            return String::new();
        }

        let mut html = String::from("<div class=\"canvas-tools\">\n");
        for el in tool_elements {
            html.push_str("  ");
            html.push_str(&render_element_html(el, "tool-content"));
            html.push('\n');
        }
        html.push_str("</div>\n");
        html
    }

    fn to_html(&self) -> String {
        use super::render::render_element_html;
        use std::collections::HashSet;

        let state = match self.shared.lock() {
            Ok(s) => s,
            Err(p) => p.into_inner(),
        };

        let mut html = String::from("<div class=\"canvas-messages\">\n");
        let mut message_ids: HashSet<ElementId> = HashSet::new();

        for entry in &state.messages {
            message_ids.insert(entry.element_id);
            if let Some(el) = state.scene.get_element(entry.element_id) {
                let role_class = entry.role.css_class();
                html.push_str("  ");
                html.push_str(&render_element_html(el, role_class));
                html.push('\n');
            }
        }
        html.push_str("</div>\n");

        let tool_elements: Vec<_> = state
            .scene
            .elements()
            .filter(|el| !message_ids.contains(&el.id))
            .collect();

        if !tool_elements.is_empty() {
            html.push_str("<div class=\"canvas-tools\">\n");
            for el in tool_elements {
                html.push_str("  ");
                html.push_str(&render_element_html(el, "tool-content"));
                html.push('\n');
            }
            html.push_str("</div>\n");
        }

        html
    }

    fn to_html_cached(&mut self) -> &str {
        // Rebuild if the shared state has changed since last cache.
        let state = match self.shared.lock() {
            Ok(s) => s,
            Err(p) => p.into_inner(),
        };

        let generation = state.generation;
        if generation != self.cached_generation {
            self.cached_html = build_html(&state);
            self.cached_generation = generation;
        }

        drop(state);
        &self.cached_html
    }

    fn resize_viewport(&mut self, width: f32, height: f32) {
        let mut state = match self.shared.lock() {
            Ok(s) => s,
            Err(p) => p.into_inner(),
        };

        state.scene.set_viewport(width, height);
        let msg_width = width - (MESSAGE_MARGIN_X * 2.0);

        // Collect element IDs to avoid borrowing messages and scene simultaneously.
        let ids: Vec<ElementId> = state.messages.iter().map(|e| e.element_id).collect();
        let mut y = MESSAGE_PADDING;
        for id in ids {
            if let Some(el) = state.scene.get_element_mut(id) {
                el.transform.x = MESSAGE_MARGIN_X;
                el.transform.y = y;
                el.transform.width = msg_width;
            }
            y += MESSAGE_HEIGHT + MESSAGE_PADDING;
        }
        state.next_y = y;
        state.generation += 1;
    }

    fn connection_status(&self) -> ConnectionStatus {
        match self.shared.lock() {
            Ok(s) => s.status.clone(),
            Err(p) => p.into_inner().status.clone(),
        }
    }

    fn scene_snapshot(&self) -> canvas_core::Scene {
        match self.shared.lock() {
            Ok(s) => s.scene.clone(),
            Err(p) => p.into_inner().scene.clone(),
        }
    }
}

/// Build full HTML from shared state (helper for cache).
fn build_html(state: &SharedState) -> String {
    use super::render::render_element_html;
    use std::collections::HashSet;

    let mut html = String::from("<div class=\"canvas-messages\">\n");
    let mut message_ids: HashSet<ElementId> = HashSet::new();

    for entry in &state.messages {
        message_ids.insert(entry.element_id);
        if let Some(el) = state.scene.get_element(entry.element_id) {
            let role_class = entry.role.css_class();
            html.push_str("  ");
            html.push_str(&render_element_html(el, role_class));
            html.push('\n');
        }
    }
    html.push_str("</div>\n");

    let tool_elements: Vec<_> = state
        .scene
        .elements()
        .filter(|el| !message_ids.contains(&el.id))
        .collect();

    if !tool_elements.is_empty() {
        html.push_str("<div class=\"canvas-tools\">\n");
        for el in tool_elements {
            html.push_str("  ");
            html.push_str(&render_element_html(el, "tool-content"));
            html.push('\n');
        }
        html.push_str("</div>\n");
    }

    html
}

// ---------------------------------------------------------------------------
// Background WebSocket connection loop
// ---------------------------------------------------------------------------

/// Maximum reconnect delay.
const MAX_RECONNECT_DELAY: Duration = Duration::from_secs(30);
/// Base reconnect delay.
const BASE_RECONNECT_DELAY: Duration = Duration::from_secs(1);
/// Ping interval.
const PING_INTERVAL: Duration = Duration::from_secs(30);

/// Run the WebSocket connection loop with automatic reconnection.
async fn connection_loop(
    url: String,
    session_id: String,
    shared: Arc<Mutex<SharedState>>,
    mut outbound_rx: mpsc::UnboundedReceiver<String>,
) {
    let mut attempt: u32 = 0;

    loop {
        // Update status.
        if let Ok(mut s) = shared.lock() {
            s.status = if attempt == 0 {
                ConnectionStatus::Connecting
            } else {
                ConnectionStatus::Reconnecting { attempt }
            };
        }

        match try_connect(&url, &session_id, &shared, &mut outbound_rx).await {
            Ok(()) => {
                // Clean disconnect.
                if let Ok(mut s) = shared.lock() {
                    s.status = ConnectionStatus::Disconnected;
                }
                break;
            }
            Err(e) => {
                tracing::warn!("WebSocket connection failed (attempt {attempt}): {e}");
                attempt += 1;

                let delay = BASE_RECONNECT_DELAY
                    .saturating_mul(2u32.saturating_pow(attempt.min(5)))
                    .min(MAX_RECONNECT_DELAY);

                if let Ok(mut s) = shared.lock() {
                    s.status = ConnectionStatus::Reconnecting { attempt };
                }

                tokio::time::sleep(delay).await;
            }
        }
    }
}

/// Attempt a single WebSocket connection. Returns `Ok(())` on clean close,
/// `Err` on connection failure or unexpected disconnect.
async fn try_connect(
    url: &str,
    session_id: &str,
    shared: &Arc<Mutex<SharedState>>,
    outbound_rx: &mut mpsc::UnboundedReceiver<String>,
) -> Result<(), String> {
    use futures_util::{SinkExt, StreamExt};
    use tokio_tungstenite::{connect_async, tungstenite::Message};

    let (ws_stream, _) = connect_async(url)
        .await
        .map_err(|e| format!("connect: {e}"))?;

    let (mut write, mut read) = ws_stream.split();

    // Subscribe to session.
    let subscribe = ClientMessage::Subscribe {
        session_id: session_id.to_owned(),
    };
    if let Ok(json) = serde_json::to_string(&subscribe) {
        write
            .send(Message::Text(json))
            .await
            .map_err(|e| format!("send subscribe: {e}"))?;
    }

    // Mark connected.
    if let Ok(mut s) = shared.lock() {
        s.status = ConnectionStatus::Connected;
    }

    let mut ping_interval = tokio::time::interval(PING_INTERVAL);
    // Skip the first immediate tick.
    ping_interval.tick().await;

    loop {
        tokio::select! {
            // Inbound from server.
            msg = read.next() => {
                match msg {
                    Some(Ok(Message::Text(text))) => {
                        handle_server_message(&text, shared);
                    }
                    Some(Ok(Message::Close(_))) | None => {
                        // Server closed connection.
                        return Err("connection closed by server".into());
                    }
                    Some(Err(e)) => {
                        return Err(format!("read error: {e}"));
                    }
                    _ => {} // Binary, Ping/Pong frames handled by tungstenite.
                }
            }
            // Outbound from fae.
            Some(json) = outbound_rx.recv() => {
                if let Err(e) = write.send(Message::Text(json)).await {
                    return Err(format!("send error: {e}"));
                }
            }
            // Periodic ping.
            _ = ping_interval.tick() => {
                if let Ok(json) = serde_json::to_string(&ClientMessage::Ping)
                    && let Err(e) = write.send(Message::Text(json)).await
                {
                    return Err(format!("ping error: {e}"));
                }
            }
        }
    }
}

/// Process a server message and update shared state.
fn handle_server_message(text: &str, shared: &Arc<Mutex<SharedState>>) {
    let msg: ServerMessage = match serde_json::from_str(text) {
        Ok(m) => m,
        Err(e) => {
            tracing::debug!("Ignoring unparseable server message: {e}");
            return;
        }
    };

    match msg {
        ServerMessage::Welcome { session_id } => {
            tracing::info!("Connected to canvas session: {session_id}");
        }
        ServerMessage::SceneUpdate { scene: doc } => {
            if let Ok(mut s) = shared.lock() {
                // Rebuild scene from server document.
                s.scene.clear();
                // Apply viewport if the server provided dimensions.
                if doc.viewport.width > 0.0 && doc.viewport.height > 0.0 {
                    s.scene
                        .set_viewport(doc.viewport.width, doc.viewport.height);
                }
                for elem_doc in &doc.elements {
                    let element = Element::new(elem_doc.kind.clone())
                        .with_transform(elem_doc.transform)
                        .with_interactive(elem_doc.interactive);
                    s.scene.add_element(element);
                }
                s.generation += 1;
            }
        }
        ServerMessage::ElementAdded { element: doc, .. } => {
            if let Ok(mut s) = shared.lock() {
                let element = Element::new(doc.kind.clone())
                    .with_transform(doc.transform)
                    .with_interactive(doc.interactive);
                s.scene.add_element(element);
                s.generation += 1;
            }
        }
        ServerMessage::ElementUpdated { element: doc, .. } => {
            if let Ok(mut s) = shared.lock() {
                // Replace element in scene — remove old, add updated.
                if let Ok(eid) = ElementId::parse(&doc.id) {
                    let _ = s.scene.remove_element(&eid);
                }
                let element = Element::new(doc.kind.clone())
                    .with_transform(doc.transform)
                    .with_interactive(doc.interactive);
                s.scene.add_element(element);
                s.generation += 1;
            }
        }
        ServerMessage::ElementRemoved { id, .. } => {
            if let Ok(mut s) = shared.lock()
                && let Ok(eid) = ElementId::parse(&id)
            {
                let _ = s.scene.remove_element(&eid);
                s.generation += 1;
            }
        }
        ServerMessage::Ack { .. }
        | ServerMessage::Error { .. }
        | ServerMessage::SyncResult { .. }
        | ServerMessage::Pong { .. } => {
            // Logged at trace level if needed.
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn client_message_serialize_subscribe() {
        let msg = ClientMessage::Subscribe {
            session_id: "default".into(),
        };
        let json = serde_json::to_string(&msg).unwrap_or_default();
        assert!(json.contains("\"type\":\"subscribe\""));
        assert!(json.contains("\"session_id\":\"default\""));
    }

    #[test]
    fn client_message_serialize_ping() {
        let msg = ClientMessage::Ping;
        let json = serde_json::to_string(&msg).unwrap_or_default();
        assert!(json.contains("\"type\":\"ping\""));
    }

    #[test]
    fn client_message_serialize_remove() {
        let msg = ClientMessage::RemoveElement {
            id: "abc-123".into(),
            message_id: Some("msg-1".into()),
        };
        let json = serde_json::to_string(&msg).unwrap_or_default();
        assert!(json.contains("\"type\":\"remove_element\""));
        assert!(json.contains("\"id\":\"abc-123\""));
        assert!(json.contains("\"message_id\":\"msg-1\""));
    }

    #[test]
    fn client_message_serialize_get_scene() {
        let msg = ClientMessage::GetScene;
        let json = serde_json::to_string(&msg).unwrap_or_default();
        assert!(json.contains("\"type\":\"get_scene\""));
    }

    #[test]
    fn server_message_deserialize_welcome() {
        let json = r#"{"type":"welcome","session_id":"s1","version":"0.1.4","timestamp":123}"#;
        let msg: ServerMessage = serde_json::from_str(json).unwrap_or_else(|e| {
            panic!("parse failed: {e}");
        });
        match msg {
            ServerMessage::Welcome { session_id } => assert_eq!(session_id, "s1"),
            _ => unreachable!("expected Welcome"),
        }
    }

    #[test]
    fn server_message_deserialize_pong() {
        let json = r#"{"type":"pong","timestamp":999}"#;
        let msg: ServerMessage = serde_json::from_str(json).unwrap_or_else(|e| {
            panic!("parse failed: {e}");
        });
        assert!(matches!(msg, ServerMessage::Pong { .. }));
    }

    #[test]
    fn server_message_deserialize_error() {
        let json = r#"{"type":"error","code":"bad_request","message":"oops"}"#;
        let msg: ServerMessage = serde_json::from_str(json).unwrap_or_else(|e| {
            panic!("parse failed: {e}");
        });
        match msg {
            ServerMessage::Error { message, .. } => assert_eq!(message, "oops"),
            _ => unreachable!("expected Error"),
        }
    }

    #[test]
    fn server_message_deserialize_ack() {
        let json = r#"{"type":"ack","message_id":"m1","success":true}"#;
        let msg: ServerMessage = serde_json::from_str(json).unwrap_or_else(|e| {
            panic!("parse failed: {e}");
        });
        match msg {
            ServerMessage::Ack {
                message_id,
                success,
            } => {
                assert_eq!(message_id, Some("m1".into()));
                assert!(success);
            }
            _ => unreachable!("expected Ack"),
        }
    }

    #[test]
    fn server_message_deserialize_scene_update() {
        let json = r#"{
            "type": "scene_update",
            "scene": {
                "session_id": "test",
                "elements": []
            }
        }"#;
        let msg: ServerMessage = serde_json::from_str(json).unwrap_or_else(|e| {
            panic!("parse failed: {e}");
        });
        match msg {
            ServerMessage::SceneUpdate { scene } => {
                assert_eq!(scene.session_id, "test");
                assert!(scene.elements.is_empty());
            }
            _ => unreachable!("expected SceneUpdate"),
        }
    }

    #[test]
    fn server_message_deserialize_element_removed() {
        let json = r#"{"type":"element_removed","id":"el-1","timestamp":100}"#;
        let msg: ServerMessage = serde_json::from_str(json).unwrap_or_else(|e| {
            panic!("parse failed: {e}");
        });
        match msg {
            ServerMessage::ElementRemoved { id, .. } => assert_eq!(id, "el-1"),
            _ => unreachable!("expected ElementRemoved"),
        }
    }

    #[test]
    fn handle_server_message_ignores_garbage() {
        let shared = Arc::new(Mutex::new(SharedState {
            status: ConnectionStatus::Connected,
            scene: Scene::new(800.0, 600.0),
            messages: Vec::new(),
            next_y: MESSAGE_PADDING,
            generation: 0,
        }));

        // Should not panic.
        handle_server_message("not json at all", &shared);
        handle_server_message("{}", &shared);
        handle_server_message(r#"{"type":"unknown_thing"}"#, &shared);

        let state = shared.lock().unwrap_or_else(|p| p.into_inner());
        assert_eq!(state.generation, 0); // No change.
    }

    #[test]
    fn handle_server_message_scene_update_replaces_scene() {
        let shared = Arc::new(Mutex::new(SharedState {
            status: ConnectionStatus::Connected,
            scene: Scene::new(800.0, 600.0),
            messages: Vec::new(),
            next_y: MESSAGE_PADDING,
            generation: 0,
        }));

        let json = r##"{
            "type": "scene_update",
            "scene": {
                "session_id": "test",
                "elements": [
                    {
                        "id": "00000000-0000-0000-0000-000000000001",
                        "kind": { "type": "Text", "data": { "content": "hello", "font_size": 14.0, "color": "#FFF" } },
                        "transform": { "x": 0, "y": 0, "width": 100, "height": 30, "rotation": 0, "z_index": 0 },
                        "interactive": false,
                        "selected": false
                    }
                ]
            }
        }"##;

        handle_server_message(json, &shared);

        let state = shared.lock().unwrap_or_else(|p| p.into_inner());
        assert_eq!(state.scene.element_count(), 1);
        assert_eq!(state.generation, 1);
    }

    #[test]
    fn handle_server_message_element_removed() {
        let shared = Arc::new(Mutex::new(SharedState {
            status: ConnectionStatus::Connected,
            scene: Scene::new(800.0, 600.0),
            messages: Vec::new(),
            next_y: MESSAGE_PADDING,
            generation: 0,
        }));

        // Add an element first.
        {
            let mut state = shared.lock().unwrap_or_else(|p| p.into_inner());
            let el = Element::new(canvas_core::ElementKind::Text {
                content: "test".into(),
                font_size: 14.0,
                color: "#FFF".into(),
            });
            let id = state.scene.add_element(el);
            // Use the actual ID for removal.
            let json = format!(
                r#"{{"type":"element_removed","id":"{}","timestamp":100}}"#,
                id
            );
            drop(state);
            handle_server_message(&json, &shared);
        }

        let state = shared.lock().unwrap_or_else(|p| p.into_inner());
        assert_eq!(state.scene.element_count(), 0);
    }

    #[test]
    fn reconnect_delay_capped() {
        // Verify the exponential backoff math stays within bounds.
        for attempt in 0u32..20 {
            let delay = BASE_RECONNECT_DELAY
                .saturating_mul(2u32.saturating_pow(attempt.min(5)))
                .min(MAX_RECONNECT_DELAY);
            assert!(delay <= MAX_RECONNECT_DELAY);
        }
    }

    // --- Task 1: SceneDocument with viewport ---

    #[test]
    fn scene_document_deserialization_with_viewport() {
        let json = r##"{
            "type": "scene_update",
            "scene": {
                "session_id": "v-test",
                "viewport": {
                    "width": 1920.0,
                    "height": 1080.0,
                    "zoom": 2.0,
                    "pan_x": 10.0,
                    "pan_y": 20.0
                },
                "elements": [],
                "timestamp": 42
            }
        }"##;
        let msg: ServerMessage = serde_json::from_str(json).unwrap_or_else(|e| {
            panic!("parse failed: {e}");
        });
        match msg {
            ServerMessage::SceneUpdate { scene } => {
                assert_eq!(scene.session_id, "v-test");
                assert!((scene.viewport.width - 1920.0).abs() < f32::EPSILON);
                assert!((scene.viewport.height - 1080.0).abs() < f32::EPSILON);
                assert!((scene.viewport.zoom - 2.0).abs() < f32::EPSILON);
                assert!((scene.viewport.pan_x - 10.0).abs() < f32::EPSILON);
                assert!((scene.viewport.pan_y - 20.0).abs() < f32::EPSILON);
                assert_eq!(scene.timestamp, 42);
            }
            _ => unreachable!("expected SceneUpdate"),
        }
    }

    #[test]
    fn scene_document_defaults_for_missing_viewport() {
        // Backward compat: no viewport field should use defaults.
        let json = r#"{
            "type": "scene_update",
            "scene": {
                "session_id": "old",
                "elements": []
            }
        }"#;
        let msg: ServerMessage = serde_json::from_str(json).unwrap_or_else(|e| {
            panic!("parse failed: {e}");
        });
        match msg {
            ServerMessage::SceneUpdate { scene } => {
                assert_eq!(scene.session_id, "old");
                // Default viewport values
                assert!((scene.viewport.zoom - 1.0).abs() < f32::EPSILON);
                assert_eq!(scene.timestamp, 0);
            }
            _ => unreachable!("expected SceneUpdate"),
        }
    }

    #[test]
    fn handle_scene_update_applies_viewport() {
        let shared = Arc::new(Mutex::new(SharedState {
            status: ConnectionStatus::Connected,
            scene: Scene::new(800.0, 600.0),
            messages: Vec::new(),
            next_y: MESSAGE_PADDING,
            generation: 0,
        }));

        let json = r##"{
            "type": "scene_update",
            "scene": {
                "session_id": "vp",
                "viewport": { "width": 1024.0, "height": 768.0, "zoom": 1.0, "pan_x": 0.0, "pan_y": 0.0 },
                "elements": [],
                "timestamp": 1
            }
        }"##;
        handle_server_message(json, &shared);

        let state = shared.lock().unwrap_or_else(|p| p.into_inner());
        assert!((state.scene.viewport_width - 1024.0).abs() < f32::EPSILON);
        assert!((state.scene.viewport_height - 768.0).abs() < f32::EPSILON);
        assert_eq!(state.generation, 1);
    }

    // --- Task 2: ElementUpdated and SyncResult ---

    #[test]
    fn server_message_deserialize_element_updated() {
        let json = r##"{
            "type": "element_updated",
            "element": {
                "id": "00000000-0000-0000-0000-000000000002",
                "kind": { "type": "Text", "data": { "content": "updated", "font_size": 16.0, "color": "#000" } },
                "transform": { "x": 10, "y": 20, "width": 200, "height": 40, "rotation": 0, "z_index": 1 },
                "interactive": true,
                "selected": false
            },
            "timestamp": 999
        }"##;
        let msg: ServerMessage = serde_json::from_str(json).unwrap_or_else(|e| {
            panic!("parse failed: {e}");
        });
        match msg {
            ServerMessage::ElementUpdated {
                element, timestamp, ..
            } => {
                assert_eq!(element.id, "00000000-0000-0000-0000-000000000002");
                assert!(element.interactive);
                assert_eq!(timestamp, 999);
            }
            _ => unreachable!("expected ElementUpdated"),
        }
    }

    #[test]
    fn server_message_deserialize_sync_result() {
        let json = r#"{
            "type": "sync_result",
            "synced_count": 3,
            "conflict_count": 1,
            "timestamp": 500,
            "failed_operations": [{"op": "add", "reason": "conflict"}]
        }"#;
        let msg: ServerMessage = serde_json::from_str(json).unwrap_or_else(|e| {
            panic!("parse failed: {e}");
        });
        match msg {
            ServerMessage::SyncResult {
                synced_count,
                conflict_count,
                ..
            } => {
                assert_eq!(synced_count, 3);
                assert_eq!(conflict_count, 1);
            }
            _ => unreachable!("expected SyncResult"),
        }
    }

    #[test]
    fn handle_element_updated_replaces_in_scene() {
        let shared = Arc::new(Mutex::new(SharedState {
            status: ConnectionStatus::Connected,
            scene: Scene::new(800.0, 600.0),
            messages: Vec::new(),
            next_y: MESSAGE_PADDING,
            generation: 0,
        }));

        // Add an element first.
        let id = {
            let mut state = shared.lock().unwrap_or_else(|p| p.into_inner());
            let el = Element::new(canvas_core::ElementKind::Text {
                content: "original".into(),
                font_size: 14.0,
                color: "#FFF".into(),
            });
            state.scene.add_element(el)
        };

        // Send an update for that element.
        let json = format!(
            r##"{{
                "type": "element_updated",
                "element": {{
                    "id": "{id}",
                    "kind": {{ "type": "Text", "data": {{ "content": "changed", "font_size": 14.0, "color": "#FFF" }} }},
                    "transform": {{ "x": 0, "y": 0, "width": 100, "height": 30, "rotation": 0, "z_index": 0 }},
                    "interactive": false,
                    "selected": false
                }},
                "timestamp": 1
            }}"##
        );
        handle_server_message(&json, &shared);

        let state = shared.lock().unwrap_or_else(|p| p.into_inner());
        // Still 1 element (replaced, not duplicated).
        assert_eq!(state.scene.element_count(), 1);
        assert_eq!(state.generation, 1);
    }

    // --- Task 3: UpdateElement client message ---

    #[test]
    fn client_message_serialize_update_element() {
        let msg = ClientMessage::UpdateElement {
            id: "el-1".into(),
            changes: serde_json::json!({"transform": {"x": 50}}),
            message_id: Some("msg-1".into()),
        };
        let json = serde_json::to_string(&msg).unwrap_or_default();
        assert!(json.contains("\"type\":\"update_element\""));
        assert!(json.contains("\"id\":\"el-1\""));
        assert!(json.contains("\"changes\""));
        assert!(json.contains("\"message_id\":\"msg-1\""));
    }
}
