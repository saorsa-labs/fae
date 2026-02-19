//! Reminders tools for Fae's Apple ecosystem integration.
//!
//! Provides four LLM tools backed by a [`ReminderStore`] abstraction:
//!
//! - [`ListReminderListsTool`] — list all reminder lists (read-only)
//! - [`ListRemindersTool`] — list reminders, optionally filtered by list (read-only)
//! - [`CreateReminderTool`] — create a new reminder (write, Full mode)
//! - [`SetReminderCompletedTool`] — complete or uncomplete a reminder (write, Full mode)
//!
//! The store trait is implemented by:
//! - `UnregisteredReminderStore` in [`super::ffi_bridge`] for production before the
//!   Swift bridge registers a real implementation
//! - `MockReminderStore` in [`super::mock_stores`] for unit tests

use std::fmt;
use std::sync::Arc;

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;
use crate::fae_llm::tools::types::{Tool, ToolResult};
use crate::permissions::PermissionKind;

use super::trait_def::AppleEcosystemTool;

// ─── Domain types ─────────────────────────────────────────────────────────────

/// Metadata for a single reminder list in the user's Reminders app.
#[derive(Debug, Clone)]
pub struct ReminderList {
    /// EventKit reminder list identifier.
    pub identifier: String,
    /// Display title of the list.
    pub title: String,
    /// Number of incomplete reminders in this list.
    pub item_count: usize,
}

/// A single reminder item.
#[derive(Debug, Clone)]
pub struct Reminder {
    /// EventKit reminder identifier.
    pub identifier: String,
    /// Parent list identifier.
    pub list_id: String,
    /// Reminder title.
    pub title: String,
    /// Optional free-form notes.
    pub notes: Option<String>,
    /// Due date in ISO-8601 format (`YYYY-MM-DDTHH:MM:SS`), if set.
    pub due_date: Option<String>,
    /// Priority 0 (none) through 9 (highest).
    pub priority: u8,
    /// Whether the reminder is marked complete.
    pub is_completed: bool,
    /// Completion date in ISO-8601 format, if completed.
    pub completion_date: Option<String>,
}

impl Reminder {
    /// Format the reminder as a human-readable text block for the LLM.
    pub fn format_summary(&self) -> String {
        let status = if self.is_completed { "[x]" } else { "[ ]" };
        let mut parts = vec![format!(
            "{status} {title} [id: {id}]",
            title = self.title,
            id = self.identifier
        )];

        if let Some(ref due) = self.due_date {
            parts.push(format!("  Due: {due}"));
        }
        if self.priority > 0 {
            let priority_label = match self.priority {
                1..=3 => "high",
                4..=6 => "medium",
                7..=9 => "low",
                _ => "none",
            };
            parts.push(format!("  Priority: {priority_label} ({})", self.priority));
        }
        if let Some(ref notes) = self.notes {
            let snippet = if notes.len() > 80 {
                format!("{}…", &notes[..80])
            } else {
                notes.clone()
            };
            parts.push(format!("  Notes: {snippet}"));
        }
        if self.is_completed
            && let Some(ref date) = self.completion_date
        {
            parts.push(format!("  Completed: {date}"));
        }
        parts.join("\n")
    }
}

/// Parameters for a query filter on reminder items.
#[derive(Debug, Clone)]
pub struct ReminderQuery {
    /// If `Some`, only include reminders from this list.
    pub list_id: Option<String>,
    /// Whether to include already-completed reminders.
    pub include_completed: bool,
    /// Maximum reminders to return.
    pub limit: usize,
}

/// Data for creating a new reminder.
#[derive(Debug, Clone)]
pub struct NewReminder {
    /// Required: reminder title.
    pub title: String,
    /// Optional: target list identifier (defaults to the user's default list).
    pub list_id: Option<String>,
    /// Optional: free-form notes.
    pub notes: Option<String>,
    /// Optional: due date in ISO-8601 format.
    pub due_date: Option<String>,
    /// Optional: priority 0-9 (0 = none).
    pub priority: Option<u8>,
}

/// Error type for reminder store operations.
#[derive(Debug, Clone)]
pub enum ReminderStoreError {
    /// macOS permission not granted or store not initialized.
    PermissionDenied(String),
    /// Reminder with the given identifier was not found.
    NotFound,
    /// Invalid input supplied by the caller.
    InvalidInput(String),
    /// Unexpected error from the underlying store.
    Backend(String),
}

impl fmt::Display for ReminderStoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ReminderStoreError::PermissionDenied(msg) => write!(f, "permission denied: {msg}"),
            ReminderStoreError::NotFound => write!(f, "reminder not found"),
            ReminderStoreError::InvalidInput(msg) => write!(f, "invalid input: {msg}"),
            ReminderStoreError::Backend(msg) => write!(f, "store error: {msg}"),
        }
    }
}

impl std::error::Error for ReminderStoreError {}

impl From<ReminderStoreError> for FaeLlmError {
    fn from(e: ReminderStoreError) -> Self {
        FaeLlmError::ToolExecutionError(e.to_string())
    }
}

// ─── ReminderStore trait ──────────────────────────────────────────────────────

/// Abstraction over Apple's EventKit reminder store for testability.
///
/// The production implementation in [`super::ffi_bridge`] calls Swift/C bridge
/// functions.  Tests use [`super::mock_stores::MockReminderStore`].
pub trait ReminderStore: Send + Sync {
    /// List all reminder lists.
    fn list_reminder_lists(&self) -> Result<Vec<ReminderList>, ReminderStoreError>;

    /// List reminders matching the query.
    fn list_reminders(&self, query: &ReminderQuery) -> Result<Vec<Reminder>, ReminderStoreError>;

    /// Get a single reminder by identifier.
    fn get_reminder(&self, identifier: &str) -> Result<Option<Reminder>, ReminderStoreError>;

    /// Create a new reminder and return the stored record.
    fn create_reminder(&self, reminder: &NewReminder) -> Result<Reminder, ReminderStoreError>;

    /// Mark a reminder as completed or uncompleted.
    fn set_completed(
        &self,
        identifier: &str,
        completed: bool,
    ) -> Result<Reminder, ReminderStoreError>;
}

// ─── ListReminderListsTool ────────────────────────────────────────────────────

/// Read-only tool that lists all reminder lists in the Reminders app.
///
/// No arguments required. Returns a formatted list of all reminder lists with
/// their item counts.
pub struct ListReminderListsTool {
    store: Arc<dyn ReminderStore>,
}

impl ListReminderListsTool {
    /// Create a new `ListReminderListsTool` backed by `store`.
    pub fn new(store: Arc<dyn ReminderStore>) -> Self {
        Self { store }
    }
}

impl Tool for ListReminderListsTool {
    fn name(&self) -> &str {
        "list_reminder_lists"
    }

    fn description(&self) -> &str {
        "List all reminder lists in the user's Reminders app. \
         Returns the name and identifier of each list, along with \
         the number of incomplete reminders. Use list_reminders to \
         see the actual reminder items."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {}
        })
    }

    fn execute(&self, _args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let lists = self.store.list_reminder_lists().map_err(|e| {
            FaeLlmError::ToolExecutionError(format!("failed to list reminder lists: {e}"))
        })?;

        if lists.is_empty() {
            return Ok(ToolResult::success("No reminder lists found.".to_owned()));
        }

        let mut lines = vec![format!("Found {} reminder list(s):\n", lists.len())];
        for list in &lists {
            lines.push(format!(
                "- [{id}] {title} ({count} item{plural})",
                id = list.identifier,
                title = list.title,
                count = list.item_count,
                plural = if list.item_count == 1 { "" } else { "s" },
            ));
        }

        Ok(ToolResult::success(lines.join("\n")))
    }

    fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
        true // read-only
    }
}

impl AppleEcosystemTool for ListReminderListsTool {
    fn required_permission(&self) -> PermissionKind {
        PermissionKind::Reminders
    }
}

// ─── ListRemindersTool ────────────────────────────────────────────────────────

/// Read-only tool that lists reminders, optionally filtered by list.
///
/// # Arguments (JSON)
///
/// - `list_id` (string, optional) — only show reminders from this list
/// - `include_completed` (bool, optional) — whether to include completed reminders (default false)
/// - `limit` (integer, optional) — max results (default 20, max 100)
pub struct ListRemindersTool {
    store: Arc<dyn ReminderStore>,
}

impl ListRemindersTool {
    /// Create a new `ListRemindersTool` backed by `store`.
    pub fn new(store: Arc<dyn ReminderStore>) -> Self {
        Self { store }
    }
}

impl Tool for ListRemindersTool {
    fn name(&self) -> &str {
        "list_reminders"
    }

    fn description(&self) -> &str {
        "List reminders from the user's Reminders app. \
         Optionally filter by a specific list or include completed reminders. \
         Use list_reminder_lists to get list identifiers."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "list_id": {
                    "type": "string",
                    "description": "Only show reminders from this list (identifier from list_reminder_lists)"
                },
                "include_completed": {
                    "type": "boolean",
                    "description": "Whether to include already-completed reminders (default false)"
                },
                "limit": {
                    "type": "integer",
                    "description": "Maximum number of reminders to return (default 20, max 100)",
                    "minimum": 1,
                    "maximum": 100
                }
            }
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let list_id = args
            .get("list_id")
            .and_then(|v| v.as_str())
            .filter(|s| !s.trim().is_empty())
            .map(str::to_owned);
        let include_completed = args
            .get("include_completed")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        let limit = args
            .get("limit")
            .and_then(|v| v.as_u64())
            .map(|n| n.min(100) as usize)
            .unwrap_or(20);

        let query = ReminderQuery {
            list_id,
            include_completed,
            limit,
        };

        let reminders = self.store.list_reminders(&query).map_err(|e| {
            FaeLlmError::ToolExecutionError(format!("failed to list reminders: {e}"))
        })?;

        if reminders.is_empty() {
            return Ok(ToolResult::success("No reminders found.".to_owned()));
        }

        let mut lines = vec![format!("Found {} reminder(s):\n", reminders.len())];
        for reminder in &reminders {
            lines.push(reminder.format_summary());
            lines.push(String::new());
        }

        Ok(ToolResult::success(lines.join("\n")))
    }

    fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
        true // read-only
    }
}

impl AppleEcosystemTool for ListRemindersTool {
    fn required_permission(&self) -> PermissionKind {
        PermissionKind::Reminders
    }
}

// ─── CreateReminderTool ───────────────────────────────────────────────────────

/// Write tool that creates a new reminder in the user's Reminders app.
///
/// Requires `ToolMode::Full` and the Reminders permission.
///
/// # Arguments (JSON)
///
/// - `title` (string, required)
/// - `list_id` (string, optional)
/// - `notes` (string, optional)
/// - `due_date` (string, optional) — ISO-8601 date/time
/// - `priority` (integer, optional) — 0-9 (0 = none, 1 = highest)
pub struct CreateReminderTool {
    store: Arc<dyn ReminderStore>,
}

impl CreateReminderTool {
    /// Create a new `CreateReminderTool` backed by `store`.
    pub fn new(store: Arc<dyn ReminderStore>) -> Self {
        Self { store }
    }
}

impl Tool for CreateReminderTool {
    fn name(&self) -> &str {
        "create_reminder"
    }

    fn description(&self) -> &str {
        "Create a new reminder in the user's Reminders app. \
         Requires at least a title. Due dates use ISO-8601 format \
         (e.g. '2026-03-01T09:00:00'). Priority ranges from 1 (highest) to 9 (lowest); \
         0 means no priority."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["title"],
            "properties": {
                "title": {
                    "type": "string",
                    "description": "Reminder title (required)"
                },
                "list_id": {
                    "type": "string",
                    "description": "Target reminder list identifier (from list_reminder_lists)"
                },
                "notes": {
                    "type": "string",
                    "description": "Optional free-form notes for the reminder"
                },
                "due_date": {
                    "type": "string",
                    "description": "Due date/time in ISO-8601 format (e.g. '2026-03-01T09:00:00')"
                },
                "priority": {
                    "type": "integer",
                    "description": "Priority level 0-9 (0=none, 1=highest, 9=lowest)",
                    "minimum": 0,
                    "maximum": 9
                }
            }
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let title = match args.get("title").and_then(|v| v.as_str()) {
            Some(t) if !t.trim().is_empty() => t.trim().to_owned(),
            _ => {
                return Ok(ToolResult::failure(
                    "title is required and cannot be empty".to_owned(),
                ));
            }
        };

        let new_reminder = NewReminder {
            title,
            list_id: args
                .get("list_id")
                .and_then(|v| v.as_str())
                .filter(|s| !s.trim().is_empty())
                .map(str::to_owned),
            notes: args
                .get("notes")
                .and_then(|v| v.as_str())
                .filter(|s| !s.trim().is_empty())
                .map(str::to_owned),
            due_date: args
                .get("due_date")
                .and_then(|v| v.as_str())
                .filter(|s| !s.trim().is_empty())
                .map(str::to_owned),
            priority: args
                .get("priority")
                .and_then(|v| v.as_u64())
                .map(|n| n.min(9) as u8),
        };

        let created = self.store.create_reminder(&new_reminder).map_err(|e| {
            FaeLlmError::ToolExecutionError(format!("failed to create reminder: {e}"))
        })?;

        Ok(ToolResult::success(format!(
            "Reminder created successfully.\n{}",
            created.format_summary()
        )))
    }

    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        matches!(mode, ToolMode::Full)
    }
}

impl AppleEcosystemTool for CreateReminderTool {
    fn required_permission(&self) -> PermissionKind {
        PermissionKind::Reminders
    }
}

// ─── SetReminderCompletedTool ─────────────────────────────────────────────────

/// Write tool that marks a reminder as completed or uncompleted.
///
/// Requires `ToolMode::Full` and the Reminders permission.
///
/// # Arguments (JSON)
///
/// - `identifier` (string, required) — the reminder's identifier
/// - `completed` (bool, required) — `true` to complete, `false` to uncomplete
pub struct SetReminderCompletedTool {
    store: Arc<dyn ReminderStore>,
}

impl SetReminderCompletedTool {
    /// Create a new `SetReminderCompletedTool` backed by `store`.
    pub fn new(store: Arc<dyn ReminderStore>) -> Self {
        Self { store }
    }
}

impl Tool for SetReminderCompletedTool {
    fn name(&self) -> &str {
        "set_reminder_completed"
    }

    fn description(&self) -> &str {
        "Mark a reminder as completed or uncompleted. \
         Use list_reminders to find reminder identifiers. \
         Set completed to false to reopen a completed reminder."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["identifier", "completed"],
            "properties": {
                "identifier": {
                    "type": "string",
                    "description": "The reminder's identifier (from list_reminders)"
                },
                "completed": {
                    "type": "boolean",
                    "description": "true to mark as completed, false to reopen"
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

        let completed = match args.get("completed").and_then(|v| v.as_bool()) {
            Some(c) => c,
            None => {
                return Ok(ToolResult::failure(
                    "completed (boolean) is required".to_owned(),
                ));
            }
        };

        let updated = self
            .store
            .set_completed(&identifier, completed)
            .map_err(|e| {
                FaeLlmError::ToolExecutionError(format!("failed to update reminder: {e}"))
            })?;

        let status_msg = if completed {
            "Reminder marked as completed."
        } else {
            "Reminder reopened."
        };

        Ok(ToolResult::success(format!(
            "{status_msg}\n{}",
            updated.format_summary()
        )))
    }

    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        matches!(mode, ToolMode::Full)
    }
}

impl AppleEcosystemTool for SetReminderCompletedTool {
    fn required_permission(&self) -> PermissionKind {
        PermissionKind::Reminders
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use crate::fae_llm::config::types::ToolMode;
    use crate::fae_llm::tools::apple::mock_stores::MockReminderStore;
    use crate::permissions::PermissionStore;

    fn sample_lists() -> Vec<ReminderList> {
        vec![
            ReminderList {
                identifier: "list-001".to_owned(),
                title: "Personal".to_owned(),
                item_count: 3,
            },
            ReminderList {
                identifier: "list-002".to_owned(),
                title: "Work".to_owned(),
                item_count: 1,
            },
        ]
    }

    fn sample_reminders() -> Vec<Reminder> {
        vec![
            Reminder {
                identifier: "rem-001".to_owned(),
                list_id: "list-001".to_owned(),
                title: "Buy groceries".to_owned(),
                notes: Some("Milk, eggs, bread".to_owned()),
                due_date: Some("2026-03-01T09:00:00".to_owned()),
                priority: 3,
                is_completed: false,
                completion_date: None,
            },
            Reminder {
                identifier: "rem-002".to_owned(),
                list_id: "list-001".to_owned(),
                title: "Call dentist".to_owned(),
                notes: None,
                due_date: None,
                priority: 0,
                is_completed: true,
                completion_date: Some("2026-02-15T14:00:00".to_owned()),
            },
            Reminder {
                identifier: "rem-003".to_owned(),
                list_id: "list-002".to_owned(),
                title: "Prepare slides".to_owned(),
                notes: Some("Q1 review".to_owned()),
                due_date: Some("2026-03-10T10:00:00".to_owned()),
                priority: 1,
                is_completed: false,
                completion_date: None,
            },
        ]
    }

    fn make_list_lists_tool() -> ListReminderListsTool {
        let store = Arc::new(MockReminderStore::new(sample_lists(), sample_reminders()));
        ListReminderListsTool::new(store)
    }

    fn make_list_tool() -> ListRemindersTool {
        let store = Arc::new(MockReminderStore::new(sample_lists(), sample_reminders()));
        ListRemindersTool::new(store)
    }

    fn make_create_tool() -> CreateReminderTool {
        let store = Arc::new(MockReminderStore::new(sample_lists(), vec![]));
        CreateReminderTool::new(store)
    }

    fn make_set_completed_tool() -> SetReminderCompletedTool {
        let store = Arc::new(MockReminderStore::new(sample_lists(), sample_reminders()));
        SetReminderCompletedTool::new(store)
    }

    // ── ListReminderListsTool ─────────────────────────────────────────────────

    #[test]
    fn list_reminder_lists_returns_all_lists() {
        let tool = make_list_lists_tool();
        let result = tool.execute(serde_json::json!({}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("list_reminder_lists should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Personal"));
        assert!(result.content.contains("Work"));
        assert!(result.content.contains("list-001"));
        assert!(result.content.contains("list-002"));
    }

    #[test]
    fn list_reminder_lists_shows_item_count() {
        let tool = make_list_lists_tool();
        let result = tool.execute(serde_json::json!({}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should succeed"),
        };
        assert!(result.content.contains("3 items"));
        assert!(result.content.contains("1 item"));
    }

    #[test]
    fn list_reminder_lists_allowed_in_all_modes() {
        let tool = make_list_lists_tool();
        assert!(tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn list_reminder_lists_requires_reminders_permission() {
        let tool = make_list_lists_tool();
        let mut store = PermissionStore::default();
        assert!(!tool.is_available(&store));
        store.grant(PermissionKind::Reminders);
        assert!(tool.is_available(&store));
    }

    // ── ListRemindersTool ─────────────────────────────────────────────────────

    #[test]
    fn list_reminders_no_filter_excludes_completed_by_default() {
        let tool = make_list_tool();
        let result = tool.execute(serde_json::json!({}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("list_reminders should succeed"),
        };
        assert!(result.success);
        // rem-001 and rem-003 are incomplete
        assert!(result.content.contains("Buy groceries"));
        assert!(result.content.contains("Prepare slides"));
        // rem-002 is completed and should not appear
        assert!(!result.content.contains("Call dentist"));
    }

    #[test]
    fn list_reminders_includes_completed_when_requested() {
        let tool = make_list_tool();
        let result = tool.execute(serde_json::json!({"include_completed": true}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Call dentist"));
    }

    #[test]
    fn list_reminders_filter_by_list_id() {
        let tool = make_list_tool();
        let result =
            tool.execute(serde_json::json!({"list_id": "list-002", "include_completed": true}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Prepare slides"));
        assert!(!result.content.contains("Buy groceries"));
        assert!(!result.content.contains("Call dentist"));
    }

    #[test]
    fn list_reminders_respects_limit() {
        let tool = make_list_tool();
        let result = tool.execute(serde_json::json!({"include_completed": true, "limit": 1}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Found 1 reminder"));
    }

    #[test]
    fn list_reminders_allowed_in_all_modes() {
        let tool = make_list_tool();
        assert!(tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn list_reminders_requires_reminders_permission() {
        let tool = make_list_tool();
        let mut store = PermissionStore::default();
        assert!(!tool.is_available(&store));
        store.grant(PermissionKind::Reminders);
        assert!(tool.is_available(&store));
    }

    // ── CreateReminderTool ────────────────────────────────────────────────────

    #[test]
    fn create_reminder_minimal_succeeds() {
        let tool = make_create_tool();
        let result = tool.execute(serde_json::json!({"title": "Pick up package"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("create should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Pick up package"));
        assert!(result.content.contains("created successfully"));
    }

    #[test]
    fn create_reminder_all_fields_populates_correctly() {
        let tool = make_create_tool();
        let result = tool.execute(serde_json::json!({
            "title": "Submit report",
            "list_id": "list-002",
            "notes": "Include Q4 data",
            "due_date": "2026-03-15T17:00:00",
            "priority": 1
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("create should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Submit report"));
        assert!(result.content.contains("2026-03-15T17:00:00"));
        assert!(result.content.contains("Include Q4 data"));
    }

    #[test]
    fn create_reminder_empty_title_returns_failure() {
        let tool = make_create_tool();
        let result = tool.execute(serde_json::json!({"title": "  "}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return failure result"),
        };
        assert!(!result.success);
        assert!(result.error.as_deref().unwrap_or("").contains("title"));
    }

    #[test]
    fn create_reminder_missing_title_returns_failure() {
        let tool = make_create_tool();
        let result = tool.execute(serde_json::json!({"notes": "no title"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return failure result"),
        };
        assert!(!result.success);
    }

    #[test]
    fn create_reminder_only_full_mode() {
        let tool = make_create_tool();
        assert!(!tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn create_reminder_requires_reminders_permission() {
        let tool = make_create_tool();
        let mut store = PermissionStore::default();
        assert!(!tool.is_available(&store));
        store.grant(PermissionKind::Reminders);
        assert!(tool.is_available(&store));
    }

    // ── SetReminderCompletedTool ──────────────────────────────────────────────

    #[test]
    fn set_completed_marks_reminder_done() {
        let tool = make_set_completed_tool();
        let result = tool.execute(serde_json::json!({
            "identifier": "rem-001",
            "completed": true
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("set_completed should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("completed"));
        assert!(result.content.contains("[x]"));
    }

    #[test]
    fn set_completed_can_uncomplete() {
        let tool = make_set_completed_tool();
        let result = tool.execute(serde_json::json!({
            "identifier": "rem-002",
            "completed": false
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("set_completed should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("reopened"));
        assert!(result.content.contains("[ ]"));
    }

    #[test]
    fn set_completed_missing_identifier_returns_failure() {
        let tool = make_set_completed_tool();
        let result = tool.execute(serde_json::json!({"completed": true}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return failure result"),
        };
        assert!(!result.success);
        assert!(result.error.as_deref().unwrap_or("").contains("identifier"));
    }

    #[test]
    fn set_completed_missing_completed_field_returns_failure() {
        let tool = make_set_completed_tool();
        let result = tool.execute(serde_json::json!({"identifier": "rem-001"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return failure result"),
        };
        assert!(!result.success);
        assert!(result.error.as_deref().unwrap_or("").contains("completed"));
    }

    #[test]
    fn set_completed_only_full_mode() {
        let tool = make_set_completed_tool();
        assert!(!tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn set_completed_requires_reminders_permission() {
        let tool = make_set_completed_tool();
        let mut store = PermissionStore::default();
        assert!(!tool.is_available(&store));
        store.grant(PermissionKind::Reminders);
        assert!(tool.is_available(&store));
    }
}
