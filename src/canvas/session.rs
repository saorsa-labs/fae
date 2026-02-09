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

/// Tracks a message element within the scene.
struct MessageEntry {
    element_id: ElementId,
    role: MessageRole,
    #[allow(dead_code)]
    timestamp_ms: u64,
}

/// A canvas session that owns a scene and manages message layout.
pub struct CanvasSession {
    scene: Scene,
    messages: Vec<MessageEntry>,
    next_y: f32,
    session_id: String,
}

impl CanvasSession {
    /// Create a new session with the given viewport dimensions.
    pub fn new(session_id: impl Into<String>, width: f32, height: f32) -> Self {
        Self {
            scene: Scene::new(width, height),
            messages: Vec::new(),
            next_y: MESSAGE_PADDING,
            session_id: session_id.into(),
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
    pub fn scene_mut(&mut self) -> &mut Scene {
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
        });

        self.next_y += MESSAGE_HEIGHT + MESSAGE_PADDING;
        id
    }

    /// Serialize the session's messages as styled HTML.
    ///
    /// Each message becomes a `<div>` with a role-based CSS class. The outer
    /// wrapper has class `canvas-messages`.
    pub fn to_html(&self) -> String {
        let mut html = String::from("<div class=\"canvas-messages\">\n");
        for entry in &self.messages {
            if let Some(el) = self.scene.get_element(entry.element_id)
                && let canvas_core::ElementKind::Text { content, color, .. } = &el.kind
            {
                let role_class = entry.role.css_class();
                html.push_str(&format!(
                    "  <div class=\"message {role_class}\" style=\"color: {};\">{}</div>\n",
                    html_escape(color),
                    html_escape(content),
                ));
            }
        }
        html.push_str("</div>");
        html
    }
}

/// Escape HTML special characters.
fn html_escape(s: &str) -> String {
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
        assert_eq!(html, "<div class=\"canvas-messages\">\n</div>");
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
}
