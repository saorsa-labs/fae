//! Mail tools for Fae's Apple ecosystem integration.
//!
//! Provides three LLM tools backed by a [`MailStore`] abstraction:
//!
//! - [`SearchMailTool`] — search inbox messages by query (read-only)
//! - [`GetMailTool`] — read a full email message by identifier (read-only)
//! - [`ComposeMailTool`] — compose and send a new email (write, Full mode)
//!
//! The store trait is implemented by:
//! - `UnregisteredMailStore` in [`super::ffi_bridge`] for production before the
//!   Swift bridge registers a real implementation
//! - `MockMailStore` in [`super::mock_stores`] for unit tests
//!
//! Mail access requires [`PermissionKind::Mail`] which gates all three tools.

use std::fmt;
use std::sync::Arc;

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;
use crate::fae_llm::tools::types::{Tool, ToolResult};
use crate::permissions::PermissionKind;

use super::trait_def::AppleEcosystemTool;

// ─── Domain types ─────────────────────────────────────────────────────────────

/// A mail message from the user's Mail app.
#[derive(Debug, Clone)]
pub struct Mail {
    /// Mail.app message identifier.
    pub identifier: String,
    /// Sender display name and/or email address.
    pub from: String,
    /// Recipient email addresses (comma-separated for multiple).
    pub to: String,
    /// Message subject line.
    pub subject: String,
    /// Full plain-text body of the message.
    pub body: String,
    /// Mailbox or account the message belongs to.
    pub mailbox: Option<String>,
    /// Whether the message has been read.
    pub is_read: bool,
    /// Date received in ISO-8601 format.
    pub date: Option<String>,
}

impl Mail {
    /// Format the message as a brief summary (sender, subject, date, snippet).
    pub fn format_summary(&self) -> String {
        let read_marker = if self.is_read { "" } else { "[unread] " };
        let mut parts = vec![format!(
            "{read_marker}From: {} — Subject: {} [id: {}]",
            self.from, self.subject, self.identifier
        )];
        if let Some(ref date) = self.date {
            parts.push(format!("  Date: {date}"));
        }
        if let Some(ref mailbox) = self.mailbox {
            parts.push(format!("  Mailbox: {mailbox}"));
        }
        let snippet = if self.body.len() > 80 {
            let preview: String = self.body.chars().take(80).collect();
            format!("  Preview: {preview}…")
        } else if !self.body.is_empty() {
            format!("  Preview: {}", self.body)
        } else {
            "  (no body)".to_owned()
        };
        parts.push(snippet);
        parts.join("\n")
    }

    /// Format the full message including complete body.
    pub fn format_full(&self) -> String {
        let read_marker = if self.is_read { "" } else { "[UNREAD] " };
        let mut parts = vec![
            format!("{read_marker}Subject: {}", self.subject),
            format!("From: {}", self.from),
            format!("To: {}", self.to),
        ];
        if let Some(ref date) = self.date {
            parts.push(format!("Date: {date}"));
        }
        if let Some(ref mailbox) = self.mailbox {
            parts.push(format!("Mailbox: {mailbox}"));
        }
        parts.push(format!("[id: {}]", self.identifier));
        parts.push(String::new());
        parts.push(self.body.clone());
        parts.join("\n")
    }
}

/// Parameters for a search query over mail messages.
#[derive(Debug, Clone)]
pub struct MailQuery {
    /// Search term matched against subject, sender, and body.
    pub search: Option<String>,
    /// Only return messages from this mailbox.
    pub mailbox: Option<String>,
    /// When `true`, include only unread messages.
    pub unread_only: bool,
    /// Maximum number of messages to return.
    pub limit: usize,
}

/// Data for composing a new email.
#[derive(Debug, Clone)]
pub struct NewMail {
    /// Required: recipient email address(es), comma-separated for multiple.
    pub to: String,
    /// Required: message subject.
    pub subject: String,
    /// Required: plain-text message body.
    pub body: String,
    /// Optional: CC recipients (comma-separated).
    pub cc: Option<String>,
}

/// Error type for mail store operations.
#[derive(Debug, Clone)]
pub enum MailStoreError {
    /// macOS permission not granted or store not initialized.
    PermissionDenied(String),
    /// Message with the given identifier was not found.
    NotFound,
    /// Invalid input supplied by the caller.
    InvalidInput(String),
    /// Unexpected error from the underlying store.
    Backend(String),
}

impl fmt::Display for MailStoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            MailStoreError::PermissionDenied(msg) => write!(f, "permission denied: {msg}"),
            MailStoreError::NotFound => write!(f, "mail message not found"),
            MailStoreError::InvalidInput(msg) => write!(f, "invalid input: {msg}"),
            MailStoreError::Backend(msg) => write!(f, "store error: {msg}"),
        }
    }
}

impl std::error::Error for MailStoreError {}

impl From<MailStoreError> for FaeLlmError {
    fn from(e: MailStoreError) -> Self {
        FaeLlmError::ToolExecutionError(e.to_string())
    }
}

// ─── MailStore trait ──────────────────────────────────────────────────────────

/// Abstraction over Apple Mail for testability.
///
/// The production implementation in [`super::ffi_bridge`] bridges to Mail.app
/// via AppleScript.  Tests use [`super::mock_stores::MockMailStore`].
pub trait MailStore: Send + Sync {
    /// List or search mail messages matching the query.
    fn list_messages(&self, query: &MailQuery) -> Result<Vec<Mail>, MailStoreError>;

    /// Get a single message by identifier.
    fn get_message(&self, identifier: &str) -> Result<Option<Mail>, MailStoreError>;

    /// Compose and send a new email.
    fn compose(&self, mail: &NewMail) -> Result<Mail, MailStoreError>;
}

// ─── SearchMailTool ───────────────────────────────────────────────────────────

/// Read-only tool that searches the user's inbox.
///
/// # Arguments (JSON)
///
/// - `search` (string, optional) — search term matched against subject, sender, body
/// - `mailbox` (string, optional) — only search this mailbox
/// - `unread_only` (boolean, optional) — when true, only return unread messages
/// - `limit` (integer, optional) — max results (default 10, max 50)
pub struct SearchMailTool {
    store: Arc<dyn MailStore>,
}

impl SearchMailTool {
    /// Create a new `SearchMailTool` backed by `store`.
    pub fn new(store: Arc<dyn MailStore>) -> Self {
        Self { store }
    }
}

impl Tool for SearchMailTool {
    fn name(&self) -> &str {
        "search_mail"
    }

    fn description(&self) -> &str {
        "Search the user's Mail inbox. Optionally filter by search term (matches subject, \
         sender, and body), mailbox name, or show only unread messages. \
         Returns message summaries including sender, subject, and a body preview. \
         Use get_mail to read the full content of a specific message."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "search": {
                    "type": "string",
                    "description": "Search term to match against subject, sender, and message body"
                },
                "mailbox": {
                    "type": "string",
                    "description": "Only search this mailbox (e.g. \"Inbox\", \"Sent\")"
                },
                "unread_only": {
                    "type": "boolean",
                    "description": "When true, only return unread messages (default false)"
                },
                "limit": {
                    "type": "integer",
                    "description": "Maximum number of messages to return (default 10, max 50)",
                    "minimum": 1,
                    "maximum": 50
                }
            }
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let search = args
            .get("search")
            .and_then(|v| v.as_str())
            .filter(|s| !s.trim().is_empty())
            .map(str::to_owned);
        let mailbox = args
            .get("mailbox")
            .and_then(|v| v.as_str())
            .filter(|s| !s.trim().is_empty())
            .map(str::to_owned);
        let unread_only = args
            .get("unread_only")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let limit = args
            .get("limit")
            .and_then(|v| v.as_u64())
            .map(|n| n.min(50) as usize)
            .unwrap_or(10);

        let query = MailQuery {
            search,
            mailbox,
            unread_only,
            limit,
        };

        let messages = self
            .store
            .list_messages(&query)
            .map_err(|e| FaeLlmError::ToolExecutionError(format!("failed to search mail: {e}")))?;

        if messages.is_empty() {
            return Ok(ToolResult::success("No messages found.".to_owned()));
        }

        let mut lines = vec![format!("Found {} message(s):\n", messages.len())];
        for msg in &messages {
            lines.push(msg.format_summary());
            lines.push(String::new());
        }

        Ok(ToolResult::success(lines.join("\n")))
    }

    fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
        true // read-only
    }
}

impl AppleEcosystemTool for SearchMailTool {
    fn required_permission(&self) -> PermissionKind {
        PermissionKind::Mail
    }
}

// ─── GetMailTool ──────────────────────────────────────────────────────────────

/// Read-only tool that fetches the full content of an email by identifier.
///
/// # Arguments (JSON)
///
/// - `identifier` (string, required) — the message's identifier from `search_mail`
pub struct GetMailTool {
    store: Arc<dyn MailStore>,
}

impl GetMailTool {
    /// Create a new `GetMailTool` backed by `store`.
    pub fn new(store: Arc<dyn MailStore>) -> Self {
        Self { store }
    }
}

impl Tool for GetMailTool {
    fn name(&self) -> &str {
        "get_mail"
    }

    fn description(&self) -> &str {
        "Read the full content of an email message by its identifier. \
         Returns the complete message body along with all headers (subject, sender, \
         recipients, date). Use search_mail to find message identifiers."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["identifier"],
            "properties": {
                "identifier": {
                    "type": "string",
                    "description": "The message's identifier (from search_mail)"
                }
            }
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let identifier = match args.get("identifier").and_then(|v| v.as_str()) {
            Some(id) if !id.trim().is_empty() => id.trim().to_owned(),
            _ => {
                return Ok(ToolResult::failure(
                    "identifier is required and cannot be empty".to_owned(),
                ));
            }
        };

        let message = self.store.get_message(&identifier).map_err(|e| {
            FaeLlmError::ToolExecutionError(format!("failed to get mail message: {e}"))
        })?;

        match message {
            Some(m) => Ok(ToolResult::success(m.format_full())),
            None => Ok(ToolResult::success(format!(
                "No message found with identifier \"{identifier}\"."
            ))),
        }
    }

    fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
        true // read-only
    }
}

impl AppleEcosystemTool for GetMailTool {
    fn required_permission(&self) -> PermissionKind {
        PermissionKind::Mail
    }
}

// ─── ComposeMailTool ──────────────────────────────────────────────────────────

/// Write tool that composes and sends an email via the user's Mail app.
///
/// Requires `ToolMode::Full` and the Mail permission.
///
/// # Arguments (JSON)
///
/// - `to` (string, required) — recipient address(es), comma-separated
/// - `subject` (string, required) — message subject
/// - `body` (string, required) — plain-text message body
/// - `cc` (string, optional) — CC recipients, comma-separated
pub struct ComposeMailTool {
    store: Arc<dyn MailStore>,
}

impl ComposeMailTool {
    /// Create a new `ComposeMailTool` backed by `store`.
    pub fn new(store: Arc<dyn MailStore>) -> Self {
        Self { store }
    }
}

impl Tool for ComposeMailTool {
    fn name(&self) -> &str {
        "compose_mail"
    }

    fn description(&self) -> &str {
        "Compose and send an email via the user's Mail app. \
         Requires recipient address, subject, and body. \
         Optionally add CC recipients. \
         Returns a confirmation with the sent message details."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["to", "subject", "body"],
            "properties": {
                "to": {
                    "type": "string",
                    "description": "Recipient email address(es), comma-separated for multiple"
                },
                "subject": {
                    "type": "string",
                    "description": "Email subject line (required)"
                },
                "body": {
                    "type": "string",
                    "description": "Plain-text message body (required)"
                },
                "cc": {
                    "type": "string",
                    "description": "CC recipients, comma-separated (optional)"
                }
            }
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let to = match args.get("to").and_then(|v| v.as_str()) {
            Some(t) if !t.trim().is_empty() => t.trim().to_owned(),
            _ => {
                return Ok(ToolResult::failure(
                    "to is required and cannot be empty".to_owned(),
                ));
            }
        };

        let subject = match args.get("subject").and_then(|v| v.as_str()) {
            Some(s) if !s.trim().is_empty() => s.trim().to_owned(),
            _ => {
                return Ok(ToolResult::failure(
                    "subject is required and cannot be empty".to_owned(),
                ));
            }
        };

        let body = match args.get("body").and_then(|v| v.as_str()) {
            Some(b) if !b.trim().is_empty() => b.trim().to_owned(),
            _ => {
                return Ok(ToolResult::failure(
                    "body is required and cannot be empty".to_owned(),
                ));
            }
        };

        let cc = args
            .get("cc")
            .and_then(|v| v.as_str())
            .filter(|s| !s.trim().is_empty())
            .map(str::to_owned);

        let new_mail = NewMail {
            to,
            subject,
            body,
            cc,
        };

        let sent = self
            .store
            .compose(&new_mail)
            .map_err(|e| FaeLlmError::ToolExecutionError(format!("failed to send email: {e}")))?;

        Ok(ToolResult::success(format!(
            "Email sent successfully.\n{}",
            sent.format_summary()
        )))
    }

    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        matches!(mode, ToolMode::Full)
    }
}

impl AppleEcosystemTool for ComposeMailTool {
    fn required_permission(&self) -> PermissionKind {
        PermissionKind::Mail
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use crate::fae_llm::config::types::ToolMode;
    use crate::fae_llm::tools::apple::mock_stores::MockMailStore;
    use crate::permissions::PermissionStore;

    fn sample_messages() -> Vec<Mail> {
        vec![
            Mail {
                identifier: "mail-001".to_owned(),
                from: "alice@example.com".to_owned(),
                to: "me@example.com".to_owned(),
                subject: "Project update".to_owned(),
                body: "Hi, just wanted to let you know the project is on track.".to_owned(),
                mailbox: Some("Inbox".to_owned()),
                is_read: true,
                date: Some("2026-02-15T09:00:00".to_owned()),
            },
            Mail {
                identifier: "mail-002".to_owned(),
                from: "bob@example.com".to_owned(),
                to: "me@example.com".to_owned(),
                subject: "Meeting tomorrow".to_owned(),
                body: "Are you available for a quick sync tomorrow at 10am?".to_owned(),
                mailbox: Some("Inbox".to_owned()),
                is_read: false,
                date: Some("2026-02-16T14:30:00".to_owned()),
            },
            Mail {
                identifier: "mail-003".to_owned(),
                from: "newsletter@example.com".to_owned(),
                to: "me@example.com".to_owned(),
                subject: "Weekly digest".to_owned(),
                body: "Here is your weekly digest of news and updates.".to_owned(),
                mailbox: Some("Newsletters".to_owned()),
                is_read: false,
                date: Some("2026-02-17T07:00:00".to_owned()),
            },
        ]
    }

    fn make_search_tool() -> SearchMailTool {
        let store = Arc::new(MockMailStore::new(sample_messages()));
        SearchMailTool::new(store)
    }

    fn make_get_tool() -> GetMailTool {
        let store = Arc::new(MockMailStore::new(sample_messages()));
        GetMailTool::new(store)
    }

    fn make_compose_tool() -> ComposeMailTool {
        let store = Arc::new(MockMailStore::new(vec![]));
        ComposeMailTool::new(store)
    }

    // ── SearchMailTool ────────────────────────────────────────────────────────

    #[test]
    fn search_mail_returns_all_up_to_limit() {
        let tool = make_search_tool();
        let result = tool.execute(serde_json::json!({}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("search_mail should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Project update"));
        assert!(result.content.contains("Meeting tomorrow"));
        assert!(result.content.contains("Weekly digest"));
    }

    #[test]
    fn search_mail_filter_by_search_term() {
        let tool = make_search_tool();
        let result = tool.execute(serde_json::json!({"search": "sync tomorrow"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Meeting tomorrow"));
        assert!(!result.content.contains("Project update"));
        assert!(!result.content.contains("Weekly digest"));
    }

    #[test]
    fn search_mail_filter_by_mailbox() {
        let tool = make_search_tool();
        let result = tool.execute(serde_json::json!({"mailbox": "Newsletters"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Weekly digest"));
        assert!(!result.content.contains("Project update"));
        assert!(!result.content.contains("Meeting tomorrow"));
    }

    #[test]
    fn search_mail_unread_only() {
        let tool = make_search_tool();
        let result = tool.execute(serde_json::json!({"unread_only": true}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Meeting tomorrow"));
        assert!(result.content.contains("Weekly digest"));
        assert!(!result.content.contains("Project update")); // mail-001 is_read = true
    }

    #[test]
    fn search_mail_limit_respected() {
        let tool = make_search_tool();
        let result = tool.execute(serde_json::json!({"limit": 1}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Found 1 message"));
    }

    #[test]
    fn search_mail_allowed_in_all_modes() {
        let tool = make_search_tool();
        assert!(tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn search_mail_requires_mail_permission() {
        let tool = make_search_tool();
        let mut store = PermissionStore::default();
        assert!(!tool.is_available(&store));
        store.grant(PermissionKind::Mail);
        assert!(tool.is_available(&store));
    }

    // ── GetMailTool ───────────────────────────────────────────────────────────

    #[test]
    fn get_mail_returns_full_content() {
        let tool = make_get_tool();
        let result = tool.execute(serde_json::json!({"identifier": "mail-001"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("get_mail should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Project update"));
        assert!(result.content.contains("alice@example.com"));
        assert!(result.content.contains("on track"));
        assert!(result.content.contains("mail-001"));
    }

    #[test]
    fn get_mail_missing_returns_not_found_message() {
        let tool = make_get_tool();
        let result = tool.execute(serde_json::json!({"identifier": "nonexistent-id"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should succeed with not-found message"),
        };
        assert!(result.success);
        assert!(result.content.contains("No message found"));
    }

    #[test]
    fn get_mail_missing_identifier_returns_failure() {
        let tool = make_get_tool();
        let result = tool.execute(serde_json::json!({}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return failure result"),
        };
        assert!(!result.success);
        assert!(result.error.as_deref().unwrap_or("").contains("identifier"));
    }

    #[test]
    fn get_mail_allowed_in_all_modes() {
        let tool = make_get_tool();
        assert!(tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn get_mail_requires_mail_permission() {
        let tool = make_get_tool();
        let mut store = PermissionStore::default();
        assert!(!tool.is_available(&store));
        store.grant(PermissionKind::Mail);
        assert!(tool.is_available(&store));
    }

    // ── ComposeMailTool ───────────────────────────────────────────────────────

    #[test]
    fn compose_mail_minimal_succeeds() {
        let tool = make_compose_tool();
        let result = tool.execute(serde_json::json!({
            "to": "alice@example.com",
            "subject": "Hello",
            "body": "Hope you are well!"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("compose should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("sent successfully"));
        assert!(result.content.contains("Hello"));
    }

    #[test]
    fn compose_mail_with_cc_succeeds() {
        let tool = make_compose_tool();
        let result = tool.execute(serde_json::json!({
            "to": "alice@example.com",
            "subject": "Team update",
            "body": "Please see the attached.",
            "cc": "bob@example.com,carol@example.com"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("compose with cc should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Team update"));
    }

    #[test]
    fn compose_mail_empty_to_returns_failure() {
        let tool = make_compose_tool();
        let result = tool.execute(serde_json::json!({
            "to": "  ",
            "subject": "Hello",
            "body": "body"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return failure result"),
        };
        assert!(!result.success);
        assert!(result.error.as_deref().unwrap_or("").contains("to"));
    }

    #[test]
    fn compose_mail_empty_subject_returns_failure() {
        let tool = make_compose_tool();
        let result = tool.execute(serde_json::json!({
            "to": "alice@example.com",
            "subject": "",
            "body": "body"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return failure result"),
        };
        assert!(!result.success);
        assert!(result.error.as_deref().unwrap_or("").contains("subject"));
    }

    #[test]
    fn compose_mail_empty_body_returns_failure() {
        let tool = make_compose_tool();
        let result = tool.execute(serde_json::json!({
            "to": "alice@example.com",
            "subject": "Hello",
            "body": ""
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return failure result"),
        };
        assert!(!result.success);
        assert!(result.error.as_deref().unwrap_or("").contains("body"));
    }

    #[test]
    fn compose_mail_only_full_mode() {
        let tool = make_compose_tool();
        assert!(!tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn compose_mail_requires_mail_permission() {
        let tool = make_compose_tool();
        let mut store = PermissionStore::default();
        assert!(!tool.is_available(&store));
        store.grant(PermissionKind::Mail);
        assert!(tool.is_available(&store));
    }
}
