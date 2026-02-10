//! Canvas message types bridging fae's pipeline to canvas-core elements.

use canvas_core::{Element, ElementKind, Transform};

/// Roles for message attribution and styling.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageRole {
    User,
    Assistant,
    System,
    Tool,
}

impl MessageRole {
    /// CSS class name for this role (used in HTML rendering).
    pub fn css_class(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Assistant => "assistant",
            Self::System => "system",
            Self::Tool => "tool",
        }
    }

    /// Default text color (hex) for this role.
    pub fn color(self) -> &'static str {
        match self {
            Self::User => "#3B82F6",
            Self::Assistant => "#10B981",
            Self::System => "#6B7280",
            Self::Tool => "#F59E0B",
        }
    }
}

/// A pipeline event translated into a canvas-renderable message.
#[derive(Debug, Clone)]
pub struct CanvasMessage {
    pub role: MessageRole,
    pub text: String,
    pub timestamp_ms: u64,
    /// For tool messages: the tool name.
    pub tool_name: Option<String>,
    /// For tool messages: the JSON input to the tool call.
    pub tool_input: Option<String>,
    /// For tool messages: the result text from the tool execution.
    pub tool_result_text: Option<String>,
}

impl CanvasMessage {
    /// Create a new message.
    pub fn new(role: MessageRole, text: impl Into<String>, timestamp_ms: u64) -> Self {
        Self {
            role,
            text: text.into(),
            timestamp_ms,
            tool_name: None,
            tool_input: None,
            tool_result_text: None,
        }
    }

    /// Create a tool message with the tool name.
    pub fn tool(name: impl Into<String>, text: impl Into<String>, timestamp_ms: u64) -> Self {
        Self {
            role: MessageRole::Tool,
            text: text.into(),
            timestamp_ms,
            tool_name: Some(name.into()),
            tool_input: None,
            tool_result_text: None,
        }
    }

    /// Create a tool message with full details including input and result.
    pub fn tool_with_details(
        name: impl Into<String>,
        text: impl Into<String>,
        timestamp_ms: u64,
        tool_input: Option<String>,
        tool_result_text: Option<String>,
    ) -> Self {
        Self {
            role: MessageRole::Tool,
            text: text.into(),
            timestamp_ms,
            tool_name: Some(name.into()),
            tool_input,
            tool_result_text,
        }
    }

    /// Convert this message into a canvas-core `Element`.
    ///
    /// The element uses `ElementKind::Text` with role-based coloring.
    /// The caller is responsible for setting the transform (position/size).
    pub fn to_element(&self) -> Element {
        let content = match self.role {
            MessageRole::Tool => {
                let name = self.tool_name.as_deref().unwrap_or("tool");
                format!("[{name}] {}", self.text)
            }
            _ => self.text.clone(),
        };

        Element::new(ElementKind::Text {
            content,
            font_size: 14.0,
            color: self.role.color().to_string(),
        })
    }

    /// Convert this message into a positioned `Element` with the given transform.
    pub fn to_element_at(&self, transform: Transform) -> Element {
        self.to_element().with_transform(transform)
    }

    /// Format the timestamp as `"HH:MM"` (UTC).
    ///
    /// The timestamp is treated as milliseconds since an arbitrary epoch
    /// (typically session start). For display, only hours and minutes matter.
    pub fn formatted_time(&self) -> String {
        let total_secs = self.timestamp_ms / 1000;
        let hours = (total_secs / 3600) % 24;
        let minutes = (total_secs / 60) % 60;
        format!("{hours:02}:{minutes:02}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_message_new() {
        let msg = CanvasMessage::new(MessageRole::User, "Hello", 1000);
        assert_eq!(msg.role, MessageRole::User);
        assert_eq!(msg.text, "Hello");
        assert_eq!(msg.timestamp_ms, 1000);
        assert!(msg.tool_name.is_none());
    }

    #[test]
    fn test_message_tool() {
        let msg = CanvasMessage::tool("search", "found 3 results", 2000);
        assert_eq!(msg.role, MessageRole::Tool);
        assert_eq!(msg.text, "found 3 results");
        assert_eq!(msg.tool_name.as_deref(), Some("search"));
    }

    #[test]
    fn test_css_class() {
        assert_eq!(MessageRole::User.css_class(), "user");
        assert_eq!(MessageRole::Assistant.css_class(), "assistant");
        assert_eq!(MessageRole::System.css_class(), "system");
        assert_eq!(MessageRole::Tool.css_class(), "tool");
    }

    #[test]
    fn test_role_colors() {
        assert_eq!(MessageRole::User.color(), "#3B82F6");
        assert_eq!(MessageRole::Assistant.color(), "#10B981");
        assert_eq!(MessageRole::System.color(), "#6B7280");
        assert_eq!(MessageRole::Tool.color(), "#F59E0B");
    }

    #[test]
    fn test_to_element_user() {
        let msg = CanvasMessage::new(MessageRole::User, "Hi there", 1000);
        let el = msg.to_element();
        match &el.kind {
            ElementKind::Text {
                content,
                font_size,
                color,
            } => {
                assert_eq!(content, "Hi there");
                assert!((font_size - 14.0).abs() < f32::EPSILON);
                assert_eq!(color, "#3B82F6");
            }
            other => unreachable!("expected Text, got {other:?}"),
        }
    }

    #[test]
    fn test_to_element_assistant() {
        let msg = CanvasMessage::new(MessageRole::Assistant, "Hello!", 1000);
        let el = msg.to_element();
        match &el.kind {
            ElementKind::Text { color, .. } => assert_eq!(color, "#10B981"),
            other => unreachable!("expected Text, got {other:?}"),
        }
    }

    #[test]
    fn test_to_element_tool_formats_name() {
        let msg = CanvasMessage::tool("search", "3 results", 1000);
        let el = msg.to_element();
        match &el.kind {
            ElementKind::Text { content, .. } => assert_eq!(content, "[search] 3 results"),
            other => unreachable!("expected Text, got {other:?}"),
        }
    }

    #[test]
    fn test_to_element_tool_no_name_fallback() {
        let msg = CanvasMessage {
            role: MessageRole::Tool,
            text: "done".into(),
            timestamp_ms: 1000,
            tool_name: None,
            tool_input: None,
            tool_result_text: None,
        };
        let el = msg.to_element();
        match &el.kind {
            ElementKind::Text { content, .. } => assert_eq!(content, "[tool] done"),
            other => unreachable!("expected Text, got {other:?}"),
        }
    }

    #[test]
    fn test_to_element_at_sets_transform() {
        let msg = CanvasMessage::new(MessageRole::User, "test", 1000);
        let t = Transform {
            x: 10.0,
            y: 20.0,
            width: 300.0,
            height: 40.0,
            rotation: 0.0,
            z_index: 5,
        };
        let el = msg.to_element_at(t);
        assert!((el.transform.x - 10.0).abs() < f32::EPSILON);
        assert!((el.transform.y - 20.0).abs() < f32::EPSILON);
        assert_eq!(el.transform.z_index, 5);
    }

    #[test]
    fn test_formatted_time() {
        // 0 ms → 00:00
        let msg = CanvasMessage::new(MessageRole::User, "x", 0);
        assert_eq!(msg.formatted_time(), "00:00");

        // 3661000 ms = 1h 1m 1s → 01:01
        let msg = CanvasMessage::new(MessageRole::User, "x", 3_661_000);
        assert_eq!(msg.formatted_time(), "01:01");

        // 86400000 ms = 24h → wraps to 00:00
        let msg = CanvasMessage::new(MessageRole::User, "x", 86_400_000);
        assert_eq!(msg.formatted_time(), "00:00");
    }
}
