//! Message types for LLM conversations.
//!
//! Provides the [`Message`], [`Role`], and [`MessageContent`] types used
//! to represent conversation history sent to LLM providers.
//!
//! # Examples
//!
//! ```
//! use fae::fae_llm::providers::message::{Message, Role};
//!
//! let user_msg = Message::text(Role::User, "What is Rust?");
//! assert_eq!(user_msg.role, Role::User);
//!
//! let tool_result = Message::tool_result("call_123", "file contents here");
//! assert_eq!(tool_result.role, Role::Tool);
//! ```

use serde::{Deserialize, Serialize};

/// The role of a message in a conversation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Role {
    /// System instructions.
    System,
    /// User input.
    User,
    /// Assistant (model) output.
    Assistant,
    /// Tool execution result.
    Tool,
}

impl std::fmt::Display for Role {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::System => write!(f, "system"),
            Self::User => write!(f, "user"),
            Self::Assistant => write!(f, "assistant"),
            Self::Tool => write!(f, "tool"),
        }
    }
}

/// The content of a message.
///
/// Most messages contain plain text, but tool results include the
/// call ID for correlation with the tool call that produced them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum MessageContent {
    /// Plain text content.
    Text {
        /// The text content.
        text: String,
    },
    /// Tool execution result.
    ToolResult {
        /// The tool call ID this result corresponds to.
        call_id: String,
        /// The tool's output content.
        content: String,
    },
}

/// An assistant tool call included in an assistant message.
///
/// When the assistant decides to invoke a tool, the message carries
/// one or more of these alongside (or instead of) text content.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AssistantToolCall {
    /// Unique identifier for this tool call.
    pub call_id: String,
    /// The function name being called.
    pub function_name: String,
    /// JSON-encoded arguments string.
    pub arguments: String,
}

/// A message in an LLM conversation.
///
/// Messages form the conversation history sent to the provider.
/// Each message has a role and content, with optional tool calls
/// for assistant messages.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Message {
    /// Who sent this message.
    pub role: Role,
    /// The message content.
    pub content: MessageContent,
    /// Tool calls made by the assistant (only for Assistant role).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tool_calls: Vec<AssistantToolCall>,
}

impl Message {
    /// Create a text message with the given role.
    pub fn text(role: Role, text: impl Into<String>) -> Self {
        Self {
            role,
            content: MessageContent::Text { text: text.into() },
            tool_calls: Vec::new(),
        }
    }

    /// Create a system message.
    pub fn system(text: impl Into<String>) -> Self {
        Self::text(Role::System, text)
    }

    /// Create a user message.
    pub fn user(text: impl Into<String>) -> Self {
        Self::text(Role::User, text)
    }

    /// Create an assistant message.
    pub fn assistant(text: impl Into<String>) -> Self {
        Self::text(Role::Assistant, text)
    }

    /// Create an assistant message with tool calls and optional text.
    pub fn assistant_with_tool_calls(
        text: Option<String>,
        tool_calls: Vec<AssistantToolCall>,
    ) -> Self {
        Self {
            role: Role::Assistant,
            content: MessageContent::Text {
                text: text.unwrap_or_default(),
            },
            tool_calls,
        }
    }

    /// Create a tool result message.
    pub fn tool_result(call_id: impl Into<String>, content: impl Into<String>) -> Self {
        Self {
            role: Role::Tool,
            content: MessageContent::ToolResult {
                call_id: call_id.into(),
                content: content.into(),
            },
            tool_calls: Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── Role ──────────────────────────────────────────────────

    #[test]
    fn role_display() {
        assert_eq!(Role::System.to_string(), "system");
        assert_eq!(Role::User.to_string(), "user");
        assert_eq!(Role::Assistant.to_string(), "assistant");
        assert_eq!(Role::Tool.to_string(), "tool");
    }

    #[test]
    fn role_serde_round_trip() {
        for role in &[Role::System, Role::User, Role::Assistant, Role::Tool] {
            let json = serde_json::to_string(role).unwrap_or_default();
            let parsed: Result<Role, _> = serde_json::from_str(&json);
            assert!(parsed.is_ok());
            match parsed {
                Ok(r) => assert_eq!(r, *role),
                Err(_) => unreachable!("deserialization succeeded"),
            }
        }
    }

    #[test]
    fn role_equality() {
        assert_eq!(Role::User, Role::User);
        assert_ne!(Role::User, Role::System);
    }

    // ── MessageContent ────────────────────────────────────────

    #[test]
    fn message_content_text() {
        let content = MessageContent::Text {
            text: "hello".into(),
        };
        match &content {
            MessageContent::Text { text } => assert_eq!(text, "hello"),
            _ => unreachable!("expected Text"),
        }
    }

    #[test]
    fn message_content_tool_result() {
        let content = MessageContent::ToolResult {
            call_id: "call_1".into(),
            content: "output".into(),
        };
        match &content {
            MessageContent::ToolResult { call_id, content } => {
                assert_eq!(call_id, "call_1");
                assert_eq!(content, "output");
            }
            _ => unreachable!("expected ToolResult"),
        }
    }

    #[test]
    fn message_content_serde_round_trip() {
        let original = MessageContent::ToolResult {
            call_id: "tc_1".into(),
            content: "result data".into(),
        };
        let json = serde_json::to_string(&original).unwrap_or_default();
        let parsed: Result<MessageContent, _> = serde_json::from_str(&json);
        assert!(parsed.is_ok());
        match parsed {
            Ok(p) => assert_eq!(p, original),
            Err(_) => unreachable!("deserialization succeeded"),
        }
    }

    // ── Message construction ──────────────────────────────────

    #[test]
    fn message_text() {
        let msg = Message::text(Role::User, "What is Rust?");
        assert_eq!(msg.role, Role::User);
        match &msg.content {
            MessageContent::Text { text } => assert_eq!(text, "What is Rust?"),
            _ => unreachable!("expected Text"),
        }
        assert!(msg.tool_calls.is_empty());
    }

    #[test]
    fn message_system() {
        let msg = Message::system("You are helpful.");
        assert_eq!(msg.role, Role::System);
    }

    #[test]
    fn message_user() {
        let msg = Message::user("Hello");
        assert_eq!(msg.role, Role::User);
    }

    #[test]
    fn message_assistant() {
        let msg = Message::assistant("Hi there!");
        assert_eq!(msg.role, Role::Assistant);
    }

    #[test]
    fn message_assistant_with_tool_calls() {
        let tool_calls = vec![AssistantToolCall {
            call_id: "call_1".into(),
            function_name: "read".into(),
            arguments: r#"{"path":"main.rs"}"#.into(),
        }];
        let msg = Message::assistant_with_tool_calls(Some("Let me read that.".into()), tool_calls);
        assert_eq!(msg.role, Role::Assistant);
        assert_eq!(msg.tool_calls.len(), 1);
        assert_eq!(msg.tool_calls[0].function_name, "read");
    }

    #[test]
    fn message_tool_result() {
        let msg = Message::tool_result("call_1", "file contents");
        assert_eq!(msg.role, Role::Tool);
        match &msg.content {
            MessageContent::ToolResult { call_id, content } => {
                assert_eq!(call_id, "call_1");
                assert_eq!(content, "file contents");
            }
            _ => unreachable!("expected ToolResult"),
        }
    }

    #[test]
    fn message_serde_round_trip() {
        let original = Message::user("test message");
        let json = serde_json::to_string(&original).unwrap_or_default();
        let parsed: Result<Message, _> = serde_json::from_str(&json);
        assert!(parsed.is_ok());
        match parsed {
            Ok(p) => assert_eq!(p, original),
            Err(_) => unreachable!("deserialization succeeded"),
        }
    }

    #[test]
    fn message_with_tool_calls_serde_round_trip() {
        let tool_calls = vec![AssistantToolCall {
            call_id: "call_abc".into(),
            function_name: "bash".into(),
            arguments: r#"{"command":"ls"}"#.into(),
        }];
        let original = Message::assistant_with_tool_calls(None, tool_calls);
        let json = serde_json::to_string(&original).unwrap_or_default();
        let parsed: Result<Message, _> = serde_json::from_str(&json);
        assert!(parsed.is_ok());
        match parsed {
            Ok(p) => {
                assert_eq!(p.tool_calls.len(), 1);
                assert_eq!(p.tool_calls[0].call_id, "call_abc");
            }
            Err(_) => unreachable!("deserialization succeeded"),
        }
    }

    #[test]
    fn message_clone() {
        let msg = Message::user("test");
        let cloned = msg.clone();
        assert_eq!(msg, cloned);
    }

    #[test]
    fn assistant_tool_call_debug() {
        let tc = AssistantToolCall {
            call_id: "call_1".into(),
            function_name: "read".into(),
            arguments: "{}".into(),
        };
        let debug = format!("{tc:?}");
        assert!(debug.contains("call_1"));
        assert!(debug.contains("read"));
    }
}
