//! Core types for session persistence.
//!
//! Provides [`Session`], [`SessionMeta`], and [`SessionResumeError`] for
//! persisting and resuming multi-turn conversations.
//!
//! # Examples
//!
//! ```
//! use fae::fae_llm::session::types::{Session, SessionMeta};
//!
//! let meta = SessionMeta::new("sess_001", None, None);
//! assert_eq!(meta.id, "sess_001");
//! assert_eq!(meta.schema_version, 1);
//! ```

use serde::{Deserialize, Serialize};

use crate::fae_llm::providers::message::Message;

/// Unique session identifier.
pub type SessionId = String;

/// Current schema version for session serialization.
pub const CURRENT_SCHEMA_VERSION: u32 = 1;

/// Metadata about a persisted session.
///
/// Contains bookkeeping data (creation time, turn count, token usage)
/// alongside optional context like the system prompt and model used.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionMeta {
    /// Unique identifier for this session.
    pub id: SessionId,
    /// Unix epoch seconds when the session was created.
    pub created_at: u64,
    /// Unix epoch seconds when the session was last updated.
    pub updated_at: u64,
    /// Number of user-assistant turn pairs completed.
    pub turn_count: usize,
    /// Total tokens consumed across all turns.
    pub total_tokens: u64,
    /// The system prompt used for this session, if any.
    pub system_prompt: Option<String>,
    /// Display string of the model used (e.g. "claude-opus-4").
    pub model: Option<String>,
    /// Schema version for forward compatibility.
    pub schema_version: u32,
}

impl SessionMeta {
    /// Create new session metadata with the given ID.
    ///
    /// Sets `created_at` and `updated_at` to the current Unix epoch,
    /// and `schema_version` to [`CURRENT_SCHEMA_VERSION`].
    pub fn new(
        id: impl Into<SessionId>,
        system_prompt: Option<String>,
        model: Option<String>,
    ) -> Self {
        let now = current_epoch_secs();
        Self {
            id: id.into(),
            created_at: now,
            updated_at: now,
            turn_count: 0,
            total_tokens: 0,
            system_prompt,
            model,
            schema_version: CURRENT_SCHEMA_VERSION,
        }
    }

    /// Update the `updated_at` timestamp to now.
    pub fn touch(&mut self) {
        self.updated_at = current_epoch_secs();
    }
}

/// A persisted session: metadata plus the full message history.
///
/// The `messages` field contains the complete conversation in the same
/// [`Message`] format used by the agent loop, making resume seamless.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Session {
    /// Session metadata (ID, timestamps, counts).
    pub meta: SessionMeta,
    /// The full message history (system, user, assistant, tool results).
    pub messages: Vec<Message>,
}

impl Session {
    /// Create a new empty session with the given ID.
    pub fn new(
        id: impl Into<SessionId>,
        system_prompt: Option<String>,
        model: Option<String>,
    ) -> Self {
        let meta = SessionMeta::new(id, system_prompt, model);
        Self {
            meta,
            messages: Vec::new(),
        }
    }

    /// Append a message to the conversation history and touch the timestamp.
    pub fn push_message(&mut self, message: Message) {
        self.messages.push(message);
        self.meta.touch();
    }

    /// Replace the entire message list and touch the timestamp.
    pub fn set_messages(&mut self, messages: Vec<Message>) {
        self.messages = messages;
        self.meta.touch();
    }
}

/// Typed errors for session resume failures.
///
/// Each variant carries enough context to produce a meaningful error message
/// and to allow programmatic handling without string parsing.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SessionResumeError {
    /// The requested session does not exist in the store.
    NotFound(SessionId),
    /// The session data is corrupted or unparseable.
    Corrupted {
        /// The session ID that was corrupted.
        id: SessionId,
        /// Human-readable description of the corruption.
        reason: String,
    },
    /// The session was created with a newer schema version.
    SchemaMismatch {
        /// The session ID.
        id: SessionId,
        /// The schema version found in the persisted data.
        found: u32,
        /// The schema version this code supports.
        expected: u32,
    },
}

impl std::fmt::Display for SessionResumeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotFound(id) => write!(f, "session not found: {id}"),
            Self::Corrupted { id, reason } => {
                write!(f, "session {id} is corrupted: {reason}")
            }
            Self::SchemaMismatch {
                id,
                found,
                expected,
            } => {
                write!(
                    f,
                    "session {id} has schema version {found}, expected {expected}"
                )
            }
        }
    }
}

impl std::error::Error for SessionResumeError {}

/// Returns the current Unix epoch in seconds.
fn current_epoch_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fae_llm::providers::message::Message;

    #[test]
    fn session_meta_new_sets_defaults() {
        let meta = SessionMeta::new("sess_001", None, None);
        assert_eq!(meta.id, "sess_001");
        assert_eq!(meta.turn_count, 0);
        assert_eq!(meta.total_tokens, 0);
        assert!(meta.system_prompt.is_none());
        assert!(meta.model.is_none());
        assert_eq!(meta.schema_version, CURRENT_SCHEMA_VERSION);
        assert!(meta.created_at > 0);
        assert_eq!(meta.created_at, meta.updated_at);
    }

    #[test]
    fn session_meta_with_system_prompt_and_model() {
        let meta = SessionMeta::new(
            "sess_002",
            Some("Be helpful.".into()),
            Some("claude-opus-4".into()),
        );
        assert_eq!(meta.system_prompt.as_deref(), Some("Be helpful."));
        assert_eq!(meta.model.as_deref(), Some("claude-opus-4"));
    }

    #[test]
    fn session_meta_touch_updates_timestamp() {
        let mut meta = SessionMeta::new("sess_003", None, None);
        let original = meta.updated_at;
        // Touch should set updated_at to now (>= original)
        meta.touch();
        assert!(meta.updated_at >= original);
    }

    #[test]
    fn session_meta_serde_round_trip() {
        let original = SessionMeta::new("sess_rt", Some("system".into()), Some("gpt-4".into()));
        let json = serde_json::to_string(&original).unwrap_or_default();
        assert!(!json.is_empty());
        let parsed: Result<SessionMeta, _> = serde_json::from_str(&json);
        assert!(parsed.is_ok());
        let parsed = match parsed {
            Ok(m) => m,
            Err(_) => unreachable!("deserialization succeeded"),
        };
        assert_eq!(parsed.id, "sess_rt");
        assert_eq!(parsed.schema_version, CURRENT_SCHEMA_VERSION);
        assert_eq!(parsed.system_prompt.as_deref(), Some("system"));
    }

    #[test]
    fn session_new_creates_empty() {
        let session = Session::new("sess_010", None, None);
        assert_eq!(session.meta.id, "sess_010");
        assert!(session.messages.is_empty());
    }

    #[test]
    fn session_push_message() {
        let mut session = Session::new("sess_011", None, None);
        session.push_message(Message::user("Hello"));
        assert_eq!(session.messages.len(), 1);
    }

    #[test]
    fn session_set_messages() {
        let mut session = Session::new("sess_012", None, None);
        session.push_message(Message::user("first"));
        let new_msgs = vec![Message::user("replaced")];
        session.set_messages(new_msgs);
        assert_eq!(session.messages.len(), 1);
        // Verify the first message was replaced
        match &session.messages[0].content {
            crate::fae_llm::providers::message::MessageContent::Text { text } => {
                assert_eq!(text, "replaced");
            }
            _ => unreachable!("expected text content"),
        }
    }

    #[test]
    fn session_serde_round_trip() {
        let mut session = Session::new("sess_rt2", Some("system".into()), None);
        session.push_message(Message::system("system"));
        session.push_message(Message::user("hello"));
        session.push_message(Message::assistant("hi there"));

        let json = serde_json::to_string(&session).unwrap_or_default();
        assert!(!json.is_empty());
        let parsed: Result<Session, _> = serde_json::from_str(&json);
        assert!(parsed.is_ok());
        let parsed = match parsed {
            Ok(s) => s,
            Err(_) => unreachable!("deserialization succeeded"),
        };
        assert_eq!(parsed.meta.id, "sess_rt2");
        assert_eq!(parsed.messages.len(), 3);
    }

    #[test]
    fn session_serde_with_tool_calls() {
        let mut session = Session::new("sess_tc", None, None);
        let tool_calls = vec![crate::fae_llm::providers::message::AssistantToolCall {
            call_id: "call_1".into(),
            function_name: "read".into(),
            arguments: r#"{"path":"main.rs"}"#.into(),
        }];
        session.push_message(Message::assistant_with_tool_calls(
            Some("Let me read.".into()),
            tool_calls,
        ));
        session.push_message(Message::tool_result("call_1", "fn main() {}"));

        let json = serde_json::to_string(&session).unwrap_or_default();
        let parsed: Result<Session, _> = serde_json::from_str(&json);
        assert!(parsed.is_ok());
        let parsed = match parsed {
            Ok(s) => s,
            Err(_) => unreachable!("deserialization succeeded"),
        };
        assert_eq!(parsed.messages.len(), 2);
        assert_eq!(parsed.messages[0].tool_calls.len(), 1);
    }

    // ── SessionResumeError ──────────────────────────────────

    #[test]
    fn resume_error_not_found_display() {
        let err = SessionResumeError::NotFound("sess_missing".into());
        let display = format!("{err}");
        assert!(display.contains("sess_missing"));
        assert!(display.contains("not found"));
    }

    #[test]
    fn resume_error_corrupted_display() {
        let err = SessionResumeError::Corrupted {
            id: "sess_bad".into(),
            reason: "invalid JSON".into(),
        };
        let display = format!("{err}");
        assert!(display.contains("sess_bad"));
        assert!(display.contains("corrupted"));
        assert!(display.contains("invalid JSON"));
    }

    #[test]
    fn resume_error_schema_mismatch_display() {
        let err = SessionResumeError::SchemaMismatch {
            id: "sess_old".into(),
            found: 99,
            expected: 1,
        };
        let display = format!("{err}");
        assert!(display.contains("sess_old"));
        assert!(display.contains("99"));
        assert!(display.contains("1"));
    }

    #[test]
    fn resume_error_equality() {
        let a = SessionResumeError::NotFound("a".into());
        let b = SessionResumeError::NotFound("a".into());
        let c = SessionResumeError::NotFound("b".into());
        assert_eq!(a, b);
        assert_ne!(a, c);
    }

    #[test]
    fn resume_error_clone() {
        let err = SessionResumeError::Corrupted {
            id: "sess_c".into(),
            reason: "bad".into(),
        };
        let cloned = err.clone();
        assert_eq!(err, cloned);
    }

    #[test]
    fn resume_error_debug() {
        let err = SessionResumeError::NotFound("sess_d".into());
        let debug = format!("{err:?}");
        assert!(debug.contains("NotFound"));
    }

    #[test]
    fn resume_error_is_std_error() {
        let err = SessionResumeError::NotFound("x".into());
        let _: &dyn std::error::Error = &err;
    }

    // ── Send + Sync ─────────────────────────────────────────

    #[test]
    fn all_session_types_are_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<SessionMeta>();
        assert_send_sync::<Session>();
        assert_send_sync::<SessionResumeError>();
    }

    // ── current_epoch_secs ─────────────────────────────────

    #[test]
    fn current_epoch_secs_returns_positive() {
        let now = current_epoch_secs();
        // Should be well past 2020 (1577836800)
        assert!(now > 1_577_836_800);
    }
}
