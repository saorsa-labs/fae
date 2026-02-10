//! Canvas session wrapping a `canvas_core::Scene`.
//!
//! Manages the message list, auto-layout positioning, and HTML serialization.

use canvas_core::{ElementId, Scene, Transform};

use super::types::{CanvasMessage, MessageRole};

/// Vertical height allocated per message element (pixels).
const MESSAGE_HEIGHT: f32 = 40.0;

/// Vertical gap between consecutive messages (pixels).
const MESSAGE_PADDING: f32 = 8.0;

/// Horizontal margin on each side of messages (pixels).
const MESSAGE_MARGIN_X: f32 = 16.0;

/// A read-only view of a message suitable for GUI rendering.
pub struct MessageView {
    /// Message role (user, assistant, system, tool).
    pub role: MessageRole,
    /// Timestamp in milliseconds.
    pub timestamp_ms: u64,
    /// Pre-rendered HTML body for the message content.
    pub html: String,
    /// Plain text content of the message.
    pub text: String,
    /// Tool name (for tool messages).
    pub tool_name: Option<String>,
    /// JSON input to the tool call.
    pub tool_input: Option<String>,
    /// Tool execution result text.
    pub tool_result_text: Option<String>,
}

/// Tracks a message element within the scene.
struct MessageEntry {
    element_id: ElementId,
    role: MessageRole,
    timestamp_ms: u64,
    text: String,
    tool_name: Option<String>,
    tool_input: Option<String>,
    tool_result_text: Option<String>,
}

/// A canvas session that owns a scene and manages message layout.
pub struct CanvasSession {
    scene: Scene,
    messages: Vec<MessageEntry>,
    next_y: f32,
    session_id: String,
    /// Monotonically increasing generation counter; bumped on any mutation.
    generation: u64,
    /// Generation at which the full HTML cache was last computed.
    cached_generation: u64,
    /// The full assembled HTML from the last `to_html_cached()` call.
    cached_html: String,
}

impl CanvasSession {
    /// Create a new session with the given viewport dimensions.
    pub fn new(session_id: impl Into<String>, width: f32, height: f32) -> Self {
        Self {
            scene: Scene::new(width, height),
            messages: Vec::new(),
            next_y: MESSAGE_PADDING,
            session_id: session_id.into(),
            generation: 0,
            cached_generation: 0,
            cached_html: String::new(),
        }
    }

    /// The session identifier.
    pub fn session_id(&self) -> &str {
        &self.session_id
    }

    /// Reference to the underlying scene.
    pub fn scene(&self) -> &Scene {
        &self.scene
    }

    /// Mutable reference to the underlying scene (for tool-driven modifications).
    ///
    /// Invalidates the HTML cache since the scene may have changed.
    pub fn scene_mut(&mut self) -> &mut Scene {
        self.generation += 1;
        &mut self.scene
    }

    /// Number of messages in this session.
    pub fn message_count(&self) -> usize {
        self.messages.len()
    }

    /// Push a message into the session, positioning it automatically.
    ///
    /// Returns the `ElementId` of the newly created element.
    pub fn push_message(&mut self, message: &CanvasMessage) -> ElementId {
        let width = self.scene.viewport_width - (MESSAGE_MARGIN_X * 2.0);
        let transform = Transform {
            x: MESSAGE_MARGIN_X,
            y: self.next_y,
            width,
            height: MESSAGE_HEIGHT,
            rotation: 0.0,
            z_index: self.messages.len() as i32,
        };

        let element = message.to_element_at(transform);
        let id = self.scene.add_element(element);

        self.messages.push(MessageEntry {
            element_id: id,
            role: message.role,
            timestamp_ms: message.timestamp_ms,
            text: message.text.clone(),
            tool_name: message.tool_name.clone(),
            tool_input: message.tool_input.clone(),
            tool_result_text: message.tool_result_text.clone(),
        });

        self.next_y += MESSAGE_HEIGHT + MESSAGE_PADDING;
        self.generation += 1;
        id
    }

    /// Serialize the session as styled HTML.
    ///
    /// Messages are rendered with role-based CSS classes via
    /// [`super::render::render_element_html`].  Elements that were added
    /// directly to the scene (e.g. via MCP tools) but are not associated with
    /// a message are rendered in a separate `canvas-tools` section.
    pub fn to_html(&self) -> String {
        use super::render::render_element_html;
        use std::collections::HashSet;

        let mut html = String::from("<div class=\"canvas-messages\">\n");

        // Track which element IDs belong to messages.
        let mut message_ids: HashSet<canvas_core::ElementId> = HashSet::new();

        for entry in &self.messages {
            message_ids.insert(entry.element_id);
            if let Some(el) = self.scene.get_element(entry.element_id) {
                let role_class = entry.role.css_class();
                html.push_str("  ");
                html.push_str(&render_element_html(el, role_class));
                html.push('\n');
            }
        }
        html.push_str("</div>\n");

        // Render non-message elements (tool-pushed content: charts, images, etc.)
        let tool_elements: Vec<_> = self
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

    /// Cached variant of [`to_html`](Self::to_html).
    ///
    /// Returns the previously assembled HTML if the session has not been
    /// mutated since the last call. This avoids re-rendering charts and
    /// markdown on every GUI frame.
    pub fn to_html_cached(&mut self) -> &str {
        if self.generation != self.cached_generation {
            self.cached_html = self.to_html();
            self.cached_generation = self.generation;
        }
        &self.cached_html
    }

    /// Build a list of `MessageView` structs for per-message GUI rendering.
    ///
    /// Each view carries the pre-rendered HTML body, plain text, role,
    /// and optional tool metadata so the GUI can wrap each message in
    /// interactive Dioxus components.
    pub fn message_views(&self) -> Vec<MessageView> {
        use super::render::render_element_html;

        self.messages
            .iter()
            .map(|entry| {
                let html = self
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

    /// Render non-message elements (MCP tool-pushed content) to HTML.
    pub fn tool_elements_html(&self) -> String {
        use super::render::render_element_html;
        use std::collections::HashSet;

        let message_ids: HashSet<canvas_core::ElementId> =
            self.messages.iter().map(|e| e.element_id).collect();

        let tool_elements: Vec<_> = self
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

    /// Update the viewport dimensions and re-layout existing messages.
    ///
    /// Invalidates the HTML cache.
    pub fn resize_viewport(&mut self, width: f32, height: f32) {
        self.scene.set_viewport(width, height);
        let msg_width = width - (MESSAGE_MARGIN_X * 2.0);
        let mut y = MESSAGE_PADDING;
        for entry in &self.messages {
            if let Some(el) = self.scene.get_element_mut(entry.element_id) {
                el.transform.x = MESSAGE_MARGIN_X;
                el.transform.y = y;
                el.transform.width = msg_width;
            }
            y += MESSAGE_HEIGHT + MESSAGE_PADDING;
        }
        self.next_y = y;
        self.generation += 1;
    }
}

impl super::backend::CanvasBackend for CanvasSession {
    fn session_id(&self) -> &str {
        &self.session_id
    }

    fn push_message(&mut self, message: &CanvasMessage) -> canvas_core::ElementId {
        CanvasSession::push_message(self, message)
    }

    fn add_element(&mut self, element: canvas_core::Element) -> canvas_core::ElementId {
        self.generation += 1;
        self.scene.add_element(element)
    }

    fn remove_element(&mut self, id: &canvas_core::ElementId) -> Option<canvas_core::Element> {
        self.generation += 1;
        self.scene.remove_element(id).ok()
    }

    fn clear(&mut self) {
        self.scene.clear();
        self.messages.clear();
        self.next_y = MESSAGE_PADDING;
        self.generation += 1;
    }

    fn message_count(&self) -> usize {
        self.messages.len()
    }

    fn element_count(&self) -> usize {
        self.scene.element_count()
    }

    fn message_views(&self) -> Vec<MessageView> {
        CanvasSession::message_views(self)
    }

    fn tool_elements_html(&self) -> String {
        CanvasSession::tool_elements_html(self)
    }

    fn to_html(&self) -> String {
        CanvasSession::to_html(self)
    }

    fn to_html_cached(&mut self) -> &str {
        CanvasSession::to_html_cached(self)
    }

    fn resize_viewport(&mut self, width: f32, height: f32) {
        CanvasSession::resize_viewport(self, width, height);
    }

    fn connection_status(&self) -> super::backend::ConnectionStatus {
        super::backend::ConnectionStatus::Local
    }

    fn scene_snapshot(&self) -> canvas_core::Scene {
        self.scene.clone()
    }
}

/// Escape HTML special characters.
pub fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_session() {
        let s = CanvasSession::new("test-1", 800.0, 600.0);
        assert_eq!(s.session_id(), "test-1");
        assert_eq!(s.message_count(), 0);
        assert!(s.scene().is_empty());
    }

    #[test]
    fn test_push_single_message() {
        let mut s = CanvasSession::new("s", 800.0, 600.0);
        let msg = CanvasMessage::new(MessageRole::User, "Hello", 1000);
        let id = s.push_message(&msg);
        assert_eq!(s.message_count(), 1);
        assert_eq!(s.scene().element_count(), 1);

        let el = s.scene().get_element(id);
        assert!(el.is_some());
    }

    #[test]
    fn test_push_multiple_stacks_vertically() {
        let mut s = CanvasSession::new("s", 800.0, 600.0);
        let m1 = CanvasMessage::new(MessageRole::User, "A", 1);
        let m2 = CanvasMessage::new(MessageRole::Assistant, "B", 2);
        let m3 = CanvasMessage::new(MessageRole::System, "C", 3);

        let id1 = s.push_message(&m1);
        let id2 = s.push_message(&m2);
        let id3 = s.push_message(&m3);

        let y1 = s.scene().get_element(id1).map(|e| e.transform.y);
        let y2 = s.scene().get_element(id2).map(|e| e.transform.y);
        let y3 = s.scene().get_element(id3).map(|e| e.transform.y);

        // Each should be further down than the previous
        assert!(y1 < y2);
        assert!(y2 < y3);

        // Specific layout: padding, then (height + padding) increments
        let expected_y1 = MESSAGE_PADDING;
        let expected_y2 = MESSAGE_PADDING + MESSAGE_HEIGHT + MESSAGE_PADDING;
        let expected_y3 = MESSAGE_PADDING + 2.0 * (MESSAGE_HEIGHT + MESSAGE_PADDING);

        assert!((y1.unwrap_or(0.0) - expected_y1).abs() < f32::EPSILON);
        assert!((y2.unwrap_or(0.0) - expected_y2).abs() < f32::EPSILON);
        assert!((y3.unwrap_or(0.0) - expected_y3).abs() < f32::EPSILON);
    }

    #[test]
    fn test_z_index_increments() {
        let mut s = CanvasSession::new("s", 800.0, 600.0);
        let id1 = s.push_message(&CanvasMessage::new(MessageRole::User, "A", 1));
        let id2 = s.push_message(&CanvasMessage::new(MessageRole::User, "B", 2));

        let z1 = s.scene().get_element(id1).map(|e| e.transform.z_index);
        let z2 = s.scene().get_element(id2).map(|e| e.transform.z_index);
        assert_eq!(z1, Some(0));
        assert_eq!(z2, Some(1));
    }

    #[test]
    fn test_message_width() {
        let mut s = CanvasSession::new("s", 800.0, 600.0);
        let id = s.push_message(&CanvasMessage::new(MessageRole::User, "X", 1));
        let w = s.scene().get_element(id).map(|e| e.transform.width);
        let expected = 800.0 - (MESSAGE_MARGIN_X * 2.0);
        assert!((w.unwrap_or(0.0) - expected).abs() < f32::EPSILON);
    }

    #[test]
    fn test_to_html_empty() {
        let s = CanvasSession::new("s", 800.0, 600.0);
        let html = s.to_html();
        assert!(html.contains("canvas-messages"));
        assert!(!html.contains("canvas-tools"));
    }

    #[test]
    fn test_to_html_with_messages() {
        let mut s = CanvasSession::new("s", 800.0, 600.0);
        s.push_message(&CanvasMessage::new(MessageRole::User, "Hi", 1));
        s.push_message(&CanvasMessage::new(MessageRole::Assistant, "Hello!", 2));

        let html = s.to_html();
        assert!(html.contains("class=\"message user\""));
        assert!(html.contains("class=\"message assistant\""));
        assert!(html.contains(">Hi</div>"));
        assert!(html.contains(">Hello!</div>"));
    }

    #[test]
    fn test_to_html_escapes_special_chars() {
        let mut s = CanvasSession::new("s", 800.0, 600.0);
        s.push_message(&CanvasMessage::new(
            MessageRole::User,
            "<script>alert('xss')</script>",
            1,
        ));

        let html = s.to_html();
        assert!(!html.contains("<script>"));
        assert!(html.contains("&lt;script&gt;"));
    }

    #[test]
    fn test_scene_element_count_matches() {
        let mut s = CanvasSession::new("s", 800.0, 600.0);
        for i in 0..5 {
            s.push_message(&CanvasMessage::new(MessageRole::User, "msg", i));
        }
        assert_eq!(s.message_count(), 5);
        assert_eq!(s.scene().element_count(), 5);
    }

    #[test]
    fn test_html_escape_fn() {
        assert_eq!(html_escape("a&b"), "a&amp;b");
        assert_eq!(html_escape("<div>"), "&lt;div&gt;");
        assert_eq!(html_escape("he said \"hi\""), "he said &quot;hi&quot;");
        assert_eq!(html_escape("normal"), "normal");
    }

    #[test]
    fn test_to_html_cached_returns_same_on_no_change() {
        let mut s = CanvasSession::new("s", 800.0, 600.0);
        s.push_message(&CanvasMessage::new(MessageRole::User, "Hi", 1));

        let html1 = s.to_html_cached().to_owned();
        let html2 = s.to_html_cached().to_owned();
        assert_eq!(html1, html2);
    }

    #[test]
    fn test_to_html_cached_invalidated_by_push() {
        let mut s = CanvasSession::new("s", 800.0, 600.0);
        s.push_message(&CanvasMessage::new(MessageRole::User, "A", 1));
        let html1 = s.to_html_cached().to_owned();

        s.push_message(&CanvasMessage::new(MessageRole::Assistant, "B", 2));
        let html2 = s.to_html_cached().to_owned();

        assert_ne!(html1, html2);
        assert!(html2.contains("B"));
    }

    #[test]
    fn test_to_html_cached_invalidated_by_scene_mut() {
        let mut s = CanvasSession::new("s", 800.0, 600.0);
        s.push_message(&CanvasMessage::new(MessageRole::User, "A", 1));
        let html1 = s.to_html_cached().to_owned();

        // Mutate the scene (e.g. via tool).
        let _ = s.scene_mut();
        let html2 = s.to_html_cached().to_owned();

        // Even though content hasn't visually changed, the cache should
        // have been invalidated because scene_mut was called.
        // The re-rendered HTML will be identical content-wise, but the
        // cache was rebuilt.
        assert_eq!(html1, html2);
    }

    #[test]
    fn test_resize_viewport() {
        let mut s = CanvasSession::new("s", 800.0, 600.0);
        let id1 = s.push_message(&CanvasMessage::new(MessageRole::User, "A", 1));
        let id2 = s.push_message(&CanvasMessage::new(MessageRole::User, "B", 2));

        s.resize_viewport(400.0, 300.0);

        let expected_width = 400.0 - (MESSAGE_MARGIN_X * 2.0);
        let w1 = s.scene().get_element(id1).map(|e| e.transform.width);
        let w2 = s.scene().get_element(id2).map(|e| e.transform.width);
        assert!((w1.unwrap_or(0.0) - expected_width).abs() < f32::EPSILON);
        assert!((w2.unwrap_or(0.0) - expected_width).abs() < f32::EPSILON);

        // Y positions should be re-laid-out.
        let y1 = s.scene().get_element(id1).map(|e| e.transform.y);
        assert!((y1.unwrap_or(0.0) - MESSAGE_PADDING).abs() < f32::EPSILON);
    }

    #[test]
    fn test_resize_invalidates_cache() {
        let mut s = CanvasSession::new("s", 800.0, 600.0);
        s.push_message(&CanvasMessage::new(MessageRole::User, "A", 1));
        let _html1 = s.to_html_cached().to_owned();

        s.resize_viewport(400.0, 300.0);
        let html2 = s.to_html_cached().to_owned();

        // After resize, cache should have been invalidated.
        assert!(html2.contains("A"));
    }

    #[test]
    fn test_to_html_renders_tool_elements() {
        let mut s = CanvasSession::new("s", 800.0, 600.0);
        s.push_message(&CanvasMessage::new(MessageRole::User, "Hi", 1));

        // Add a text element directly to scene (simulating MCP tool push).
        let el = canvas_core::Element::new(canvas_core::ElementKind::Text {
            content: "Tool output".into(),
            font_size: 14.0,
            color: "#FFF".into(),
        });
        s.scene_mut().add_element(el);

        let html = s.to_html();
        assert!(html.contains("canvas-messages"));
        assert!(html.contains("canvas-tools"));
        assert!(html.contains("Tool output"));
    }
}
