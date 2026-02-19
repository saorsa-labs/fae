//! Notes tools for Fae's Apple ecosystem integration.
//!
//! Provides four LLM tools backed by a [`NoteStore`] abstraction:
//!
//! - [`ListNotesTool`] — list notes, optionally filtered by folder or search term (read-only)
//! - [`GetNoteTool`] — read the full content of a note by identifier (read-only)
//! - [`CreateNoteTool`] — create a new note (write, Full mode)
//! - [`AppendToNoteTool`] — append content to an existing note (write, Full mode)
//!
//! The store trait is implemented by:
//! - `UnregisteredNoteStore` in [`super::ffi_bridge`] for production before the
//!   Swift bridge registers a real implementation
//! - `MockNoteStore` in [`super::mock_stores`] for unit tests
//!
//! Notes access requires [`PermissionKind::DesktopAutomation`] because the
//! production implementation uses AppleScript to bridge to Notes.app.

use std::fmt;
use std::sync::Arc;

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;
use crate::fae_llm::tools::types::{Tool, ToolResult};
use crate::permissions::PermissionKind;

use super::trait_def::AppleEcosystemTool;

// ─── Domain types ─────────────────────────────────────────────────────────────

/// A note from the user's Notes app.
#[derive(Debug, Clone)]
pub struct Note {
    /// Notes.app note identifier.
    pub identifier: String,
    /// Note title.
    pub title: String,
    /// Full note body text.
    pub body: String,
    /// Folder or account the note belongs to.
    pub folder: Option<String>,
    /// Creation date in ISO-8601 format, if available.
    pub created_at: Option<String>,
    /// Last-modified date in ISO-8601 format, if available.
    pub modified_at: Option<String>,
}

impl Note {
    /// Format the note as a brief summary (title + metadata + body snippet).
    pub fn format_summary(&self) -> String {
        let mut parts = vec![format!("Note: {} [id: {}]", self.title, self.identifier)];

        if let Some(ref folder) = self.folder {
            parts.push(format!("  Folder: {folder}"));
        }
        if let Some(ref modified) = self.modified_at {
            parts.push(format!("  Modified: {modified}"));
        }

        let snippet = if self.body.len() > 80 {
            format!("  Preview: {}…", &self.body[..80])
        } else if !self.body.is_empty() {
            format!("  Preview: {}", self.body)
        } else {
            "  (empty)".to_owned()
        };
        parts.push(snippet);

        parts.join("\n")
    }

    /// Format the full note content including complete body.
    pub fn format_full(&self) -> String {
        let mut parts = vec![format!("Note: {} [id: {}]", self.title, self.identifier)];

        if let Some(ref folder) = self.folder {
            parts.push(format!("Folder: {folder}"));
        }
        if let Some(ref created) = self.created_at {
            parts.push(format!("Created: {created}"));
        }
        if let Some(ref modified) = self.modified_at {
            parts.push(format!("Modified: {modified}"));
        }
        parts.push(String::new());
        parts.push(self.body.clone());

        parts.join("\n")
    }
}

/// Parameters for filtering notes in a list query.
#[derive(Debug, Clone)]
pub struct NoteQuery {
    /// Only return notes from this folder.
    pub folder: Option<String>,
    /// Substring search across title and body.
    pub search: Option<String>,
    /// Maximum notes to return.
    pub limit: usize,
}

/// Data for creating a new note.
#[derive(Debug, Clone)]
pub struct NewNote {
    /// Required: note title.
    pub title: String,
    /// Required: note body content.
    pub body: String,
    /// Optional: target folder name.
    pub folder: Option<String>,
}

/// Error type for note store operations.
#[derive(Debug, Clone)]
pub enum NoteStoreError {
    /// macOS permission not granted or store not initialized.
    PermissionDenied(String),
    /// Note with the given identifier was not found.
    NotFound,
    /// Invalid input supplied by the caller.
    InvalidInput(String),
    /// Unexpected error from the underlying store.
    Backend(String),
}

impl fmt::Display for NoteStoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            NoteStoreError::PermissionDenied(msg) => write!(f, "permission denied: {msg}"),
            NoteStoreError::NotFound => write!(f, "note not found"),
            NoteStoreError::InvalidInput(msg) => write!(f, "invalid input: {msg}"),
            NoteStoreError::Backend(msg) => write!(f, "store error: {msg}"),
        }
    }
}

impl std::error::Error for NoteStoreError {}

impl From<NoteStoreError> for FaeLlmError {
    fn from(e: NoteStoreError) -> Self {
        FaeLlmError::ToolExecutionError(e.to_string())
    }
}

// ─── NoteStore trait ──────────────────────────────────────────────────────────

/// Abstraction over Apple Notes for testability.
///
/// The production implementation in [`super::ffi_bridge`] bridges to Notes.app
/// via AppleScript.  Tests use [`super::mock_stores::MockNoteStore`].
pub trait NoteStore: Send + Sync {
    /// List notes matching the query.
    fn list_notes(&self, query: &NoteQuery) -> Result<Vec<Note>, NoteStoreError>;

    /// Get a single note by identifier.
    fn get_note(&self, identifier: &str) -> Result<Option<Note>, NoteStoreError>;

    /// Create a new note and return the stored record.
    fn create_note(&self, note: &NewNote) -> Result<Note, NoteStoreError>;

    /// Append content to an existing note and return the updated record.
    fn append_to_note(&self, identifier: &str, content: &str) -> Result<Note, NoteStoreError>;
}

// ─── ListNotesTool ────────────────────────────────────────────────────────────

/// Read-only tool that lists notes from the user's Notes app.
///
/// # Arguments (JSON)
///
/// - `folder` (string, optional) — only show notes from this folder
/// - `search` (string, optional) — search term matched against title and body
/// - `limit` (integer, optional) — max results (default 10, max 50)
pub struct ListNotesTool {
    store: Arc<dyn NoteStore>,
}

impl ListNotesTool {
    /// Create a new `ListNotesTool` backed by `store`.
    pub fn new(store: Arc<dyn NoteStore>) -> Self {
        Self { store }
    }
}

impl Tool for ListNotesTool {
    fn name(&self) -> &str {
        "list_notes"
    }

    fn description(&self) -> &str {
        "List notes from the user's Notes app. \
         Optionally filter by folder name or search for notes containing a specific term. \
         Use get_note to read the full content of a specific note."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "folder": {
                    "type": "string",
                    "description": "Only show notes from this folder"
                },
                "search": {
                    "type": "string",
                    "description": "Search term to match against note title and content"
                },
                "limit": {
                    "type": "integer",
                    "description": "Maximum number of notes to return (default 10, max 50)",
                    "minimum": 1,
                    "maximum": 50
                }
            }
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let folder = args
            .get("folder")
            .and_then(|v| v.as_str())
            .filter(|s| !s.trim().is_empty())
            .map(str::to_owned);
        let search = args
            .get("search")
            .and_then(|v| v.as_str())
            .filter(|s| !s.trim().is_empty())
            .map(str::to_owned);
        let limit = args
            .get("limit")
            .and_then(|v| v.as_u64())
            .map(|n| n.min(50) as usize)
            .unwrap_or(10);

        let query = NoteQuery {
            folder,
            search,
            limit,
        };

        let notes = self
            .store
            .list_notes(&query)
            .map_err(|e| FaeLlmError::ToolExecutionError(format!("failed to list notes: {e}")))?;

        if notes.is_empty() {
            return Ok(ToolResult::success("No notes found.".to_owned()));
        }

        let mut lines = vec![format!("Found {} note(s):\n", notes.len())];
        for note in &notes {
            lines.push(note.format_summary());
            lines.push(String::new());
        }

        Ok(ToolResult::success(lines.join("\n")))
    }

    fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
        true // read-only
    }
}

impl AppleEcosystemTool for ListNotesTool {
    fn required_permission(&self) -> PermissionKind {
        PermissionKind::DesktopAutomation
    }
}

// ─── GetNoteTool ──────────────────────────────────────────────────────────────

/// Read-only tool that fetches the full content of a note by identifier.
///
/// # Arguments (JSON)
///
/// - `identifier` (string, required) — the note's identifier from `list_notes`
pub struct GetNoteTool {
    store: Arc<dyn NoteStore>,
}

impl GetNoteTool {
    /// Create a new `GetNoteTool` backed by `store`.
    pub fn new(store: Arc<dyn NoteStore>) -> Self {
        Self { store }
    }
}

impl Tool for GetNoteTool {
    fn name(&self) -> &str {
        "get_note"
    }

    fn description(&self) -> &str {
        "Read the full content of a note by its identifier. \
         Returns the complete note body along with title, folder, and timestamps. \
         Use list_notes to find note identifiers."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["identifier"],
            "properties": {
                "identifier": {
                    "type": "string",
                    "description": "The note's identifier (from list_notes)"
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

        let note = self
            .store
            .get_note(&identifier)
            .map_err(|e| FaeLlmError::ToolExecutionError(format!("failed to get note: {e}")))?;

        match note {
            Some(n) => Ok(ToolResult::success(n.format_full())),
            None => Ok(ToolResult::success(format!(
                "No note found with identifier \"{identifier}\"."
            ))),
        }
    }

    fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
        true // read-only
    }
}

impl AppleEcosystemTool for GetNoteTool {
    fn required_permission(&self) -> PermissionKind {
        PermissionKind::DesktopAutomation
    }
}

// ─── CreateNoteTool ───────────────────────────────────────────────────────────

/// Write tool that creates a new note in the user's Notes app.
///
/// Requires `ToolMode::Full` and the DesktopAutomation permission.
///
/// # Arguments (JSON)
///
/// - `title` (string, required)
/// - `body` (string, required)
/// - `folder` (string, optional)
pub struct CreateNoteTool {
    store: Arc<dyn NoteStore>,
}

impl CreateNoteTool {
    /// Create a new `CreateNoteTool` backed by `store`.
    pub fn new(store: Arc<dyn NoteStore>) -> Self {
        Self { store }
    }
}

impl Tool for CreateNoteTool {
    fn name(&self) -> &str {
        "create_note"
    }

    fn description(&self) -> &str {
        "Create a new note in the user's Notes app. \
         Requires a title and body. Optionally specify a target folder. \
         Returns the created note's details including its new identifier."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["title", "body"],
            "properties": {
                "title": {
                    "type": "string",
                    "description": "Note title (required)"
                },
                "body": {
                    "type": "string",
                    "description": "Note body content (required)"
                },
                "folder": {
                    "type": "string",
                    "description": "Target folder name (defaults to Notes)"
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

        let body = match args.get("body").and_then(|v| v.as_str()) {
            Some(b) if !b.trim().is_empty() => b.trim().to_owned(),
            _ => {
                return Ok(ToolResult::failure(
                    "body is required and cannot be empty".to_owned(),
                ));
            }
        };

        let new_note = NewNote {
            title,
            body,
            folder: args
                .get("folder")
                .and_then(|v| v.as_str())
                .filter(|s| !s.trim().is_empty())
                .map(str::to_owned),
        };

        let created = self
            .store
            .create_note(&new_note)
            .map_err(|e| FaeLlmError::ToolExecutionError(format!("failed to create note: {e}")))?;

        Ok(ToolResult::success(format!(
            "Note created successfully.\n{}",
            created.format_summary()
        )))
    }

    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        matches!(mode, ToolMode::Full)
    }
}

impl AppleEcosystemTool for CreateNoteTool {
    fn required_permission(&self) -> PermissionKind {
        PermissionKind::DesktopAutomation
    }
}

// ─── AppendToNoteTool ─────────────────────────────────────────────────────────

/// Write tool that appends content to an existing note.
///
/// Requires `ToolMode::Full` and the DesktopAutomation permission.
///
/// # Arguments (JSON)
///
/// - `identifier` (string, required) — the note's identifier from `list_notes`
/// - `content` (string, required) — text to append
pub struct AppendToNoteTool {
    store: Arc<dyn NoteStore>,
}

impl AppendToNoteTool {
    /// Create a new `AppendToNoteTool` backed by `store`.
    pub fn new(store: Arc<dyn NoteStore>) -> Self {
        Self { store }
    }
}

impl Tool for AppendToNoteTool {
    fn name(&self) -> &str {
        "append_to_note"
    }

    fn description(&self) -> &str {
        "Append content to an existing note in the user's Notes app. \
         Use list_notes to find the note's identifier. \
         The content is added on a new line at the end of the note."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["identifier", "content"],
            "properties": {
                "identifier": {
                    "type": "string",
                    "description": "The note's identifier (from list_notes)"
                },
                "content": {
                    "type": "string",
                    "description": "Text to append to the note"
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

        let content = match args.get("content").and_then(|v| v.as_str()) {
            Some(c) if !c.trim().is_empty() => c.to_owned(),
            _ => {
                return Ok(ToolResult::failure(
                    "content is required and cannot be empty".to_owned(),
                ));
            }
        };

        let updated = self
            .store
            .append_to_note(&identifier, &content)
            .map_err(|e| {
                FaeLlmError::ToolExecutionError(format!("failed to append to note: {e}"))
            })?;

        Ok(ToolResult::success(format!(
            "Content appended to note successfully.\n{}",
            updated.format_summary()
        )))
    }

    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        matches!(mode, ToolMode::Full)
    }
}

impl AppleEcosystemTool for AppendToNoteTool {
    fn required_permission(&self) -> PermissionKind {
        PermissionKind::DesktopAutomation
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use crate::fae_llm::config::types::ToolMode;
    use crate::fae_llm::tools::apple::mock_stores::MockNoteStore;
    use crate::permissions::PermissionStore;

    fn sample_notes() -> Vec<Note> {
        vec![
            Note {
                identifier: "note-001".to_owned(),
                title: "Meeting notes".to_owned(),
                body: "Discussed project timeline and milestones.".to_owned(),
                folder: Some("Work".to_owned()),
                created_at: Some("2026-02-01T09:00:00".to_owned()),
                modified_at: Some("2026-02-15T10:30:00".to_owned()),
            },
            Note {
                identifier: "note-002".to_owned(),
                title: "Recipe ideas".to_owned(),
                body: "Pasta carbonara, risotto, tiramisu.".to_owned(),
                folder: Some("Personal".to_owned()),
                created_at: Some("2026-01-20T18:00:00".to_owned()),
                modified_at: Some("2026-01-20T18:00:00".to_owned()),
            },
            Note {
                identifier: "note-003".to_owned(),
                title: "Shopping list".to_owned(),
                body: "Milk, eggs, coffee, olive oil.".to_owned(),
                folder: Some("Personal".to_owned()),
                created_at: Some("2026-02-10T08:00:00".to_owned()),
                modified_at: Some("2026-02-18T07:00:00".to_owned()),
            },
        ]
    }

    fn make_list_tool() -> ListNotesTool {
        let store = Arc::new(MockNoteStore::new(sample_notes()));
        ListNotesTool::new(store)
    }

    fn make_get_tool() -> GetNoteTool {
        let store = Arc::new(MockNoteStore::new(sample_notes()));
        GetNoteTool::new(store)
    }

    fn make_create_tool() -> CreateNoteTool {
        let store = Arc::new(MockNoteStore::new(vec![]));
        CreateNoteTool::new(store)
    }

    fn make_append_tool() -> AppendToNoteTool {
        let store = Arc::new(MockNoteStore::new(sample_notes()));
        AppendToNoteTool::new(store)
    }

    // ── ListNotesTool ─────────────────────────────────────────────────────────

    #[test]
    fn list_notes_returns_all_up_to_limit() {
        let tool = make_list_tool();
        let result = tool.execute(serde_json::json!({}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("list_notes should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Meeting notes"));
        assert!(result.content.contains("Recipe ideas"));
        assert!(result.content.contains("Shopping list"));
    }

    #[test]
    fn list_notes_filter_by_folder() {
        let tool = make_list_tool();
        let result = tool.execute(serde_json::json!({"folder": "Work"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Meeting notes"));
        assert!(!result.content.contains("Recipe ideas"));
        assert!(!result.content.contains("Shopping list"));
    }

    #[test]
    fn list_notes_search_term_matches_title_and_body() {
        let tool = make_list_tool();
        let result = tool.execute(serde_json::json!({"search": "pasta"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Recipe ideas"));
        assert!(!result.content.contains("Meeting notes"));
    }

    #[test]
    fn list_notes_limit_respected() {
        let tool = make_list_tool();
        let result = tool.execute(serde_json::json!({"limit": 1}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Found 1 note"));
    }

    #[test]
    fn list_notes_allowed_in_all_modes() {
        let tool = make_list_tool();
        assert!(tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn list_notes_requires_desktop_automation_permission() {
        let tool = make_list_tool();
        let mut store = PermissionStore::default();
        assert!(!tool.is_available(&store));
        store.grant(PermissionKind::DesktopAutomation);
        assert!(tool.is_available(&store));
    }

    // ── GetNoteTool ───────────────────────────────────────────────────────────

    #[test]
    fn get_note_returns_full_content() {
        let tool = make_get_tool();
        let result = tool.execute(serde_json::json!({"identifier": "note-001"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("get_note should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Meeting notes"));
        assert!(result.content.contains("Discussed project timeline"));
        assert!(result.content.contains("Work"));
        assert!(result.content.contains("note-001"));
    }

    #[test]
    fn get_note_missing_returns_not_found_message() {
        let tool = make_get_tool();
        let result = tool.execute(serde_json::json!({"identifier": "nonexistent-id"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should succeed with not-found message"),
        };
        assert!(result.success);
        assert!(result.content.contains("No note found"));
    }

    #[test]
    fn get_note_missing_identifier_returns_failure() {
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
    fn get_note_allowed_in_all_modes() {
        let tool = make_get_tool();
        assert!(tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn get_note_requires_desktop_automation_permission() {
        let tool = make_get_tool();
        let mut store = PermissionStore::default();
        assert!(!tool.is_available(&store));
        store.grant(PermissionKind::DesktopAutomation);
        assert!(tool.is_available(&store));
    }

    // ── CreateNoteTool ────────────────────────────────────────────────────────

    #[test]
    fn create_note_minimal_succeeds() {
        let tool = make_create_tool();
        let result = tool.execute(serde_json::json!({
            "title": "Quick idea",
            "body": "Some important thought."
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("create should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Quick idea"));
        assert!(result.content.contains("created successfully"));
    }

    #[test]
    fn create_note_with_folder_populates() {
        let tool = make_create_tool();
        let result = tool.execute(serde_json::json!({
            "title": "Architecture decision",
            "body": "We chose Rust for safety.",
            "folder": "Tech"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("create should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Architecture decision"));
        assert!(result.content.contains("Tech"));
    }

    #[test]
    fn create_note_empty_title_returns_failure() {
        let tool = make_create_tool();
        let result = tool.execute(serde_json::json!({"title": "  ", "body": "content"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return failure result"),
        };
        assert!(!result.success);
        assert!(result.error.as_deref().unwrap_or("").contains("title"));
    }

    #[test]
    fn create_note_empty_body_returns_failure() {
        let tool = make_create_tool();
        let result = tool.execute(serde_json::json!({"title": "My note", "body": ""}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return failure result"),
        };
        assert!(!result.success);
        assert!(result.error.as_deref().unwrap_or("").contains("body"));
    }

    #[test]
    fn create_note_only_full_mode() {
        let tool = make_create_tool();
        assert!(!tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn create_note_requires_desktop_automation_permission() {
        let tool = make_create_tool();
        let mut store = PermissionStore::default();
        assert!(!tool.is_available(&store));
        store.grant(PermissionKind::DesktopAutomation);
        assert!(tool.is_available(&store));
    }

    // ── AppendToNoteTool ──────────────────────────────────────────────────────

    #[test]
    fn append_to_note_adds_content() {
        let tool = make_append_tool();
        let result = tool.execute(serde_json::json!({
            "identifier": "note-001",
            "content": "Action item: schedule follow-up."
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("append should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("appended"));
        assert!(result.content.contains("Meeting notes"));
    }

    #[test]
    fn append_to_note_missing_identifier_returns_failure() {
        let tool = make_append_tool();
        let result = tool.execute(serde_json::json!({"content": "some text"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return failure result"),
        };
        assert!(!result.success);
        assert!(result.error.as_deref().unwrap_or("").contains("identifier"));
    }

    #[test]
    fn append_to_note_empty_content_returns_failure() {
        let tool = make_append_tool();
        let result = tool.execute(serde_json::json!({
            "identifier": "note-001",
            "content": "  "
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return failure result"),
        };
        assert!(!result.success);
        assert!(result.error.as_deref().unwrap_or("").contains("content"));
    }

    #[test]
    fn append_to_note_only_full_mode() {
        let tool = make_append_tool();
        assert!(!tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn append_to_note_requires_desktop_automation_permission() {
        let tool = make_append_tool();
        let mut store = PermissionStore::default();
        assert!(!tool.is_available(&store));
        store.grant(PermissionKind::DesktopAutomation);
        assert!(tool.is_available(&store));
    }
}
