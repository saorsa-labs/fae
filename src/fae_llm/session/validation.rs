//! Session validation for safe resume.
//!
//! Validates that a persisted session is safe to resume by checking schema
//! version, message sequence integrity, and metadata consistency.
//!
//! # Examples
//!
//! ```
//! use fae::fae_llm::session::validation::validate_session;
//! use fae::fae_llm::session::types::Session;
//! use fae::fae_llm::providers::message::Message;
//!
//! let mut session = Session::new("test", None, None, None);
//! session.push_message(Message::user("hello"));
//! session.push_message(Message::assistant("hi"));
//! let result = validate_session(&session);
//! assert!(result.is_ok());
//! ```

use super::types::{CURRENT_SCHEMA_VERSION, Session, SessionResumeError};
use crate::fae_llm::providers::message::{Message, MessageContent, Role};

/// Validate a session is safe to resume.
///
/// Checks:
/// 1. Schema version is compatible (not from the future)
/// 2. Message history is not empty
/// 3. Message sequence is structurally valid
///
/// # Errors
///
/// Returns [`SessionResumeError`] if validation fails:
/// - [`SchemaMismatch`](SessionResumeError::SchemaMismatch) if schema version is unsupported
/// - [`Corrupted`](SessionResumeError::Corrupted) if messages are empty or sequence is invalid
pub fn validate_session(session: &Session) -> Result<(), SessionResumeError> {
    // Check schema version
    if session.meta.schema_version > CURRENT_SCHEMA_VERSION {
        return Err(SessionResumeError::SchemaMismatch {
            id: session.meta.id.clone(),
            found: session.meta.schema_version,
            expected: CURRENT_SCHEMA_VERSION,
        });
    }

    // Empty messages — nothing to resume
    if session.messages.is_empty() {
        return Err(SessionResumeError::Corrupted {
            id: session.meta.id.clone(),
            reason: "session has no messages".to_string(),
        });
    }

    // Validate message sequence
    if let Err(reason) = validate_message_sequence(&session.messages) {
        return Err(SessionResumeError::Corrupted {
            id: session.meta.id.clone(),
            reason,
        });
    }

    Ok(())
}

/// Validate provider switch during session resume.
///
/// Checks if the session was originally created with a different provider
/// than the one being used to resume it. Returns a warning message if a
/// switch is detected, or `Ok(())` if no switch or provider_id is unset.
///
/// This is informational only - provider switches are allowed, but callers
/// may want to log warnings for debugging.
///
/// # Errors
///
/// Returns a warning message if providers differ, `Ok(())` otherwise.
pub fn validate_provider_switch(
    session: &Session,
    current_provider_id: &str,
) -> Result<(), String> {
    match &session.meta.provider_id {
        None => Ok(()), // No provider recorded, allow
        Some(original_provider) if original_provider == current_provider_id => Ok(()), // Same provider
        Some(original_provider) => Err(format!(
            "session '{}' was created with provider '{}' but resuming with '{}'",
            session.meta.id, original_provider, current_provider_id
        )),
    }
}

/// Validate message sequence integrity.
///
/// Ensures:
/// - Tool result messages are preceded by an assistant message with a matching tool call
/// - System messages only appear at the beginning
///
/// Returns `Ok(())` if valid, or an error string describing the problem.
pub fn validate_message_sequence(messages: &[Message]) -> Result<(), String> {
    if messages.is_empty() {
        return Err("message sequence is empty".to_string());
    }

    let mut seen_non_system = false;
    let mut pending_tool_call_ids: Vec<String> = Vec::new();

    for (i, message) in messages.iter().enumerate() {
        match message.role {
            Role::System => {
                if seen_non_system {
                    return Err(format!(
                        "system message at index {i} appears after non-system messages"
                    ));
                }
            }
            Role::User => {
                seen_non_system = true;
                // User messages are always valid
            }
            Role::Assistant => {
                seen_non_system = true;
                // Track tool call IDs if present
                pending_tool_call_ids.clear();
                for tc in &message.tool_calls {
                    pending_tool_call_ids.push(tc.call_id.clone());
                }
            }
            Role::Tool => {
                seen_non_system = true;
                // Tool result must match a pending tool call
                let call_id = match &message.content {
                    MessageContent::ToolResult { call_id, .. } => call_id.clone(),
                    MessageContent::Text { .. } => {
                        return Err(format!(
                            "tool message at index {i} has text content instead of tool result"
                        ));
                    }
                };

                if let Some(pos) = pending_tool_call_ids.iter().position(|id| *id == call_id) {
                    pending_tool_call_ids.remove(pos);
                } else {
                    return Err(format!(
                        "tool result at index {i} references call_id '{call_id}' with no matching tool call"
                    ));
                }
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fae_llm::providers::message::{AssistantToolCall, Message};
    use crate::fae_llm::session::types::Session;

    // ── validate_session ───────────────────────────────────

    #[test]
    fn validate_empty_session_fails() {
        let session = Session::new("empty", None, None, None);
        let result = validate_session(&session);
        assert!(result.is_err());
        match result {
            Err(SessionResumeError::Corrupted { id, reason }) => {
                assert_eq!(id, "empty");
                assert!(reason.contains("no messages"));
            }
            _ => unreachable!("expected Corrupted error"),
        }
    }

    #[test]
    fn validate_valid_session_passes() {
        let mut session = Session::new("valid", None, None, None);
        session.push_message(Message::user("hello"));
        session.push_message(Message::assistant("hi there"));
        let result = validate_session(&session);
        assert!(result.is_ok());
    }

    #[test]
    fn validate_session_with_system_prompt() {
        let mut session = Session::new("sys", Some("Be helpful.".into()), None, None);
        session.push_message(Message::system("Be helpful."));
        session.push_message(Message::user("hello"));
        let result = validate_session(&session);
        assert!(result.is_ok());
    }

    #[test]
    fn validate_schema_mismatch_fails() {
        let mut session = Session::new("future", None, None, None);
        session.meta.schema_version = 999;
        session.push_message(Message::user("hello"));
        let result = validate_session(&session);
        assert!(result.is_err());
        match result {
            Err(SessionResumeError::SchemaMismatch {
                id,
                found,
                expected,
            }) => {
                assert_eq!(id, "future");
                assert_eq!(found, 999);
                assert_eq!(expected, CURRENT_SCHEMA_VERSION);
            }
            _ => unreachable!("expected SchemaMismatch"),
        }
    }

    #[test]
    fn validate_current_schema_passes() {
        let mut session = Session::new("current", None, None, None);
        session.meta.schema_version = CURRENT_SCHEMA_VERSION;
        session.push_message(Message::user("hello"));
        let result = validate_session(&session);
        assert!(result.is_ok());
    }

    #[test]
    fn validate_older_schema_passes() {
        // Schema version 0 (hypothetically older) should still be valid
        let mut session = Session::new("old", None, None, None);
        session.meta.schema_version = 0;
        session.push_message(Message::user("hello"));
        let result = validate_session(&session);
        assert!(result.is_ok());
    }

    // ── validate_message_sequence ──────────────────────────

    #[test]
    fn validate_empty_messages_fails() {
        let result = validate_message_sequence(&[]);
        assert!(result.is_err());
        let err = match result {
            Err(e) => e,
            Ok(()) => unreachable!("expected error"),
        };
        assert!(err.contains("empty"));
    }

    #[test]
    fn validate_user_only_passes() {
        let messages = vec![Message::user("hello")];
        let result = validate_message_sequence(&messages);
        assert!(result.is_ok());
    }

    #[test]
    fn validate_system_then_user_passes() {
        let messages = vec![Message::system("be helpful"), Message::user("hello")];
        let result = validate_message_sequence(&messages);
        assert!(result.is_ok());
    }

    #[test]
    fn validate_system_after_user_fails() {
        let messages = vec![Message::user("hello"), Message::system("too late")];
        let result = validate_message_sequence(&messages);
        assert!(result.is_err());
        let err = match result {
            Err(e) => e,
            Ok(()) => unreachable!("expected error"),
        };
        assert!(err.contains("system message"));
        assert!(err.contains("after non-system"));
    }

    #[test]
    fn validate_valid_tool_sequence_passes() {
        let tool_calls = vec![AssistantToolCall {
            call_id: "call_1".into(),
            function_name: "read".into(),
            arguments: "{}".into(),
        }];
        let messages = vec![
            Message::user("read file"),
            Message::assistant_with_tool_calls(Some("reading...".into()), tool_calls),
            Message::tool_result("call_1", "file content"),
            Message::assistant("here's the file"),
        ];
        let result = validate_message_sequence(&messages);
        assert!(result.is_ok());
    }

    #[test]
    fn validate_orphan_tool_result_fails() {
        let messages = vec![
            Message::user("hello"),
            Message::tool_result("orphan_call", "some result"),
        ];
        let result = validate_message_sequence(&messages);
        assert!(result.is_err());
        let err = match result {
            Err(e) => e,
            Ok(()) => unreachable!("expected error"),
        };
        assert!(err.contains("orphan_call"));
        assert!(err.contains("no matching tool call"));
    }

    #[test]
    fn validate_tool_result_wrong_id_fails() {
        let tool_calls = vec![AssistantToolCall {
            call_id: "call_1".into(),
            function_name: "read".into(),
            arguments: "{}".into(),
        }];
        let messages = vec![
            Message::user("read file"),
            Message::assistant_with_tool_calls(None, tool_calls),
            Message::tool_result("wrong_id", "result"),
        ];
        let result = validate_message_sequence(&messages);
        assert!(result.is_err());
        let err = match result {
            Err(e) => e,
            Ok(()) => unreachable!("expected error"),
        };
        assert!(err.contains("wrong_id"));
    }

    #[test]
    fn validate_multiple_tool_calls_passes() {
        let tool_calls = vec![
            AssistantToolCall {
                call_id: "call_a".into(),
                function_name: "read".into(),
                arguments: "{}".into(),
            },
            AssistantToolCall {
                call_id: "call_b".into(),
                function_name: "bash".into(),
                arguments: "{}".into(),
            },
        ];
        let messages = vec![
            Message::user("do stuff"),
            Message::assistant_with_tool_calls(None, tool_calls),
            Message::tool_result("call_a", "file content"),
            Message::tool_result("call_b", "command output"),
            Message::assistant("done"),
        ];
        let result = validate_message_sequence(&messages);
        assert!(result.is_ok());
    }

    #[test]
    fn validate_multi_turn_with_tools_passes() {
        let tc1 = vec![AssistantToolCall {
            call_id: "c1".into(),
            function_name: "read".into(),
            arguments: "{}".into(),
        }];
        let tc2 = vec![AssistantToolCall {
            call_id: "c2".into(),
            function_name: "bash".into(),
            arguments: "{}".into(),
        }];
        let messages = vec![
            Message::system("be helpful"),
            Message::user("read file"),
            Message::assistant_with_tool_calls(None, tc1),
            Message::tool_result("c1", "content"),
            Message::assistant("here it is"),
            Message::user("now run command"),
            Message::assistant_with_tool_calls(None, tc2),
            Message::tool_result("c2", "output"),
            Message::assistant("done"),
        ];
        let result = validate_message_sequence(&messages);
        assert!(result.is_ok());
    }

    #[test]
    fn validate_text_only_conversation_passes() {
        let messages = vec![
            Message::user("hello"),
            Message::assistant("hi"),
            Message::user("how are you?"),
            Message::assistant("fine thanks"),
        ];
        let result = validate_message_sequence(&messages);
        assert!(result.is_ok());
    }

    // ── validate_provider_switch ───────────────────────────

    #[test]
    fn provider_switch_no_original_provider() {
        let mut session = Session::new("test", None, None, None);
        session.push_message(Message::user("hello"));
        let result = validate_provider_switch(&session, "openai");
        assert!(result.is_ok());
    }

    #[test]
    fn provider_switch_same_provider() {
        let mut session = Session::new("test", None, None, Some("openai".into()));
        session.push_message(Message::user("hello"));
        let result = validate_provider_switch(&session, "openai");
        assert!(result.is_ok());
    }

    #[test]
    fn provider_switch_different_provider() {
        let mut session = Session::new("test", None, None, Some("openai".into()));
        session.push_message(Message::user("hello"));
        let result = validate_provider_switch(&session, "anthropic");
        assert!(result.is_err());
        let err = match result {
            Err(e) => e,
            Ok(()) => unreachable!("expected error"),
        };
        assert!(err.contains("openai"));
        assert!(err.contains("anthropic"));
        assert!(err.contains("test"));
    }

    #[test]
    fn provider_switch_returns_descriptive_message() {
        let mut session = Session::new("sess_123", None, None, Some("provider_a".into()));
        session.push_message(Message::user("hello"));
        let result = validate_provider_switch(&session, "provider_b");
        assert!(result.is_err());
        let err = match result {
            Err(e) => e,
            Ok(()) => unreachable!("expected error"),
        };
        assert!(err.contains("sess_123"));
        assert!(err.contains("provider_a"));
        assert!(err.contains("provider_b"));
        assert!(err.contains("created with"));
        assert!(err.contains("resuming with"));
    }
}
