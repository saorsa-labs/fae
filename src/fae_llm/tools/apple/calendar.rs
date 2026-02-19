//! Calendar tools for Fae's Apple ecosystem integration.
//!
//! Provides five LLM tools backed by a [`CalendarStore`] abstraction:
//!
//! - [`ListCalendarsTool`] — list all available calendars (read-only)
//! - [`ListEventsTool`] — list upcoming calendar events (read-only)
//! - [`CreateEventTool`] — create a new calendar event (write, Full mode)
//! - [`UpdateEventTool`] — update an existing event (write, Full mode)
//! - [`DeleteEventTool`] — delete a calendar event (write, Full mode)
//!
//! The store trait is implemented by:
//! - `FfiCalendarStore` in [`super::ffi_bridge`] for production (calls Swift/C bridge)
//! - `MockCalendarStore` in [`super::mock_stores`] for unit tests

use std::fmt;
use std::sync::Arc;

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;
use crate::fae_llm::tools::types::{Tool, ToolResult};
use crate::permissions::PermissionKind;

use super::trait_def::AppleEcosystemTool;

// ─── Domain types ─────────────────────────────────────────────────────────────

/// Metadata for a calendar in the user's CalDAV/EventKit store.
#[derive(Debug, Clone)]
pub struct CalendarInfo {
    /// EventKit calendar identifier.
    pub identifier: String,
    /// Calendar display title.
    pub title: String,
    /// Hex color string (e.g. `"#FF6347"`), if available.
    pub color: Option<String>,
    /// Whether the calendar allows event creation/modification.
    pub is_writable: bool,
}

impl CalendarInfo {
    /// One-line formatted string for LLM display.
    pub fn format_line(&self) -> String {
        let write_flag = if self.is_writable { "rw" } else { "ro" };
        let color_part = self
            .color
            .as_deref()
            .map(|c| format!(" color:{c}"))
            .unwrap_or_default();
        format!(
            "- [{id}] {title} ({write_flag}{color_part})",
            id = self.identifier,
            title = self.title
        )
    }
}

/// A single calendar event.
#[derive(Debug, Clone)]
pub struct CalendarEvent {
    /// EventKit event identifier.
    pub identifier: String,
    /// Parent calendar identifier.
    pub calendar_id: String,
    /// Event title.
    pub title: String,
    /// Start time in ISO-8601 format (e.g. `"2026-03-01T09:00:00"`).
    pub start: String,
    /// End time in ISO-8601 format.
    pub end: String,
    /// Location string, if set.
    pub location: Option<String>,
    /// Free-form notes.
    pub notes: Option<String>,
    /// Whether this is an all-day event.
    pub is_all_day: bool,
    /// Alarm offsets in minutes before the event (negative = before).
    pub alarms: Vec<i64>,
}

impl CalendarEvent {
    /// Format the event as a human-readable text block.
    pub fn format_summary(&self) -> String {
        let mut lines = Vec::new();

        let kind = if self.is_all_day { " (all-day)" } else { "" };
        lines.push(format!(
            "Event: {}{} [id: {}]",
            self.title, kind, self.identifier
        ));
        lines.push(format!("  Start:    {}", self.start));
        lines.push(format!("  End:      {}", self.end));
        lines.push(format!("  Calendar: {}", self.calendar_id));

        if let Some(ref loc) = self.location {
            lines.push(format!("  Location: {loc}"));
        }
        if let Some(ref notes) = self.notes {
            let snippet = if notes.len() > 80 {
                format!("{}…", &notes[..80])
            } else {
                notes.clone()
            };
            lines.push(format!("  Notes:    {snippet}"));
        }
        if !self.alarms.is_empty() {
            let alarm_strs: Vec<String> = self.alarms.iter().map(|m| format!("{m}min")).collect();
            lines.push(format!("  Reminders: {}", alarm_strs.join(", ")));
        }

        lines.join("\n")
    }
}

/// Query parameters for listing events.
#[derive(Debug, Clone)]
pub struct EventQuery {
    /// Only include events from these calendar IDs (empty = all calendars).
    pub calendar_ids: Vec<String>,
    /// Include events that start at or after this ISO-8601 datetime.
    pub start_after: Option<String>,
    /// Include events that end at or before this ISO-8601 datetime.
    pub end_before: Option<String>,
    /// Maximum events to return.
    pub limit: usize,
}

/// Data for creating a new calendar event.
#[derive(Debug, Clone)]
pub struct NewCalendarEvent {
    /// Required: event title.
    pub title: String,
    /// Required: start time in ISO-8601 format.
    pub start: String,
    /// End time in ISO-8601 format.  If `None`, defaults to `start + 1 hour`.
    pub end: Option<String>,
    /// Target calendar identifier.  If `None`, uses the default calendar.
    pub calendar_id: Option<String>,
    /// Optional location.
    pub location: Option<String>,
    /// Optional notes.
    pub notes: Option<String>,
    /// Whether this is an all-day event.
    pub is_all_day: bool,
    /// Reminder offsets in minutes before the event.
    pub alarms: Vec<i64>,
}

/// Partial update for an existing event.  `None` fields are left unchanged.
/// `Some(None)` for `location`/`notes` clears the field.
#[derive(Debug, Clone)]
pub struct EventPatch {
    /// New title, if provided.
    pub title: Option<String>,
    /// New start time, if provided.
    pub start: Option<String>,
    /// New end time, if provided.
    pub end: Option<String>,
    /// New location (`Some(None)` clears it).
    pub location: Option<Option<String>>,
    /// New notes (`Some(None)` clears them).
    pub notes: Option<Option<String>>,
    /// New alarm offsets (replaces existing alarms).
    pub alarms: Option<Vec<i64>>,
}

/// Error type for calendar store operations.
#[derive(Debug, Clone)]
pub enum CalendarStoreError {
    /// macOS permission not granted or store not initialized.
    PermissionDenied(String),
    /// Event or calendar not found.
    NotFound,
    /// Invalid input supplied by the caller.
    InvalidInput(String),
    /// Unexpected error from the underlying store.
    Backend(String),
}

impl fmt::Display for CalendarStoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CalendarStoreError::PermissionDenied(msg) => write!(f, "permission denied: {msg}"),
            CalendarStoreError::NotFound => write!(f, "event not found"),
            CalendarStoreError::InvalidInput(msg) => write!(f, "invalid input: {msg}"),
            CalendarStoreError::Backend(msg) => write!(f, "store error: {msg}"),
        }
    }
}

impl std::error::Error for CalendarStoreError {}

impl From<CalendarStoreError> for FaeLlmError {
    fn from(e: CalendarStoreError) -> Self {
        FaeLlmError::ToolExecutionError(e.to_string())
    }
}

// ─── CalendarStore trait ──────────────────────────────────────────────────────

/// Abstraction over Apple's `EKEventStore` for testability.
///
/// The production implementation in [`super::ffi_bridge`] calls Swift/C bridge
/// functions.  Tests use [`super::mock_stores::MockCalendarStore`].
pub trait CalendarStore: Send + Sync {
    /// List all available calendars.
    fn list_calendars(&self) -> Result<Vec<CalendarInfo>, CalendarStoreError>;

    /// List events matching the query.
    fn list_events(&self, query: &EventQuery) -> Result<Vec<CalendarEvent>, CalendarStoreError>;

    /// Create a new calendar event.
    fn create_event(&self, event: &NewCalendarEvent) -> Result<CalendarEvent, CalendarStoreError>;

    /// Apply a partial update to an existing event.
    fn update_event(
        &self,
        id: &str,
        patch: &EventPatch,
    ) -> Result<CalendarEvent, CalendarStoreError>;

    /// Delete a calendar event by identifier.
    fn delete_event(&self, id: &str) -> Result<(), CalendarStoreError>;
}

// ─── ListCalendarsTool ────────────────────────────────────────────────────────

/// Read-only tool that lists all calendars available to the user.
///
/// # Arguments (JSON)
///
/// None required.
pub struct ListCalendarsTool {
    store: Arc<dyn CalendarStore>,
}

impl ListCalendarsTool {
    /// Create a new `ListCalendarsTool` backed by `store`.
    pub fn new(store: Arc<dyn CalendarStore>) -> Self {
        Self { store }
    }
}

impl Tool for ListCalendarsTool {
    fn name(&self) -> &str {
        "list_calendars"
    }

    fn description(&self) -> &str {
        "List all calendars available to the user, including their identifiers \
         and whether they are writable. Use the identifier with list_events or \
         create_calendar_event to target a specific calendar."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {}
        })
    }

    fn execute(&self, _args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let calendars = self.store.list_calendars().map_err(|e| {
            FaeLlmError::ToolExecutionError(format!("failed to list calendars: {e}"))
        })?;

        if calendars.is_empty() {
            return Ok(ToolResult::success(
                "No calendars found. The user may not have any calendars configured.".to_owned(),
            ));
        }

        let mut lines = vec![format!("Available calendars ({}):\n", calendars.len())];
        for cal in &calendars {
            lines.push(cal.format_line());
        }

        Ok(ToolResult::success(lines.join("\n")))
    }

    fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
        true // read-only
    }
}

impl AppleEcosystemTool for ListCalendarsTool {
    fn required_permission(&self) -> PermissionKind {
        PermissionKind::Calendar
    }
}

// ─── ListEventsTool ───────────────────────────────────────────────────────────

/// Read-only tool that lists upcoming calendar events.
///
/// # Arguments (JSON)
///
/// - `days_ahead` (integer, optional) — how many days ahead to look (default 7)
/// - `calendar_id` (string, optional) — filter to a specific calendar
/// - `limit` (integer, optional) — max events to return (default 20, max 100)
pub struct ListEventsTool {
    store: Arc<dyn CalendarStore>,
}

impl ListEventsTool {
    /// Create a new `ListEventsTool` backed by `store`.
    pub fn new(store: Arc<dyn CalendarStore>) -> Self {
        Self { store }
    }
}

impl Tool for ListEventsTool {
    fn name(&self) -> &str {
        "list_calendar_events"
    }

    fn description(&self) -> &str {
        "List upcoming calendar events. Defaults to events in the next 7 days. \
         Can filter by a specific calendar and limit the number of results."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "days_ahead": {
                    "type": "integer",
                    "description": "How many days ahead to search (default 7, max 365)",
                    "minimum": 1,
                    "maximum": 365
                },
                "calendar_id": {
                    "type": "string",
                    "description": "Filter to events from this calendar (use list_calendars to get IDs)"
                },
                "limit": {
                    "type": "integer",
                    "description": "Maximum number of events to return (default 20, max 100)",
                    "minimum": 1,
                    "maximum": 100
                }
            }
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let limit = args
            .get("limit")
            .and_then(|v| v.as_u64())
            .map(|n| n.min(100) as usize)
            .unwrap_or(20);

        let calendar_ids: Vec<String> = args
            .get("calendar_id")
            .and_then(|v| v.as_str())
            .filter(|s| !s.trim().is_empty())
            .map(|id| vec![id.to_owned()])
            .unwrap_or_default();

        let query = EventQuery {
            calendar_ids,
            start_after: None,
            end_before: None,
            limit,
        };

        let events = self
            .store
            .list_events(&query)
            .map_err(|e| FaeLlmError::ToolExecutionError(format!("failed to list events: {e}")))?;

        if events.is_empty() {
            return Ok(ToolResult::success(
                "No upcoming events found in the specified time range.".to_owned(),
            ));
        }

        let mut lines = vec![format!("Upcoming events ({} total):\n", events.len())];
        for event in &events {
            lines.push(event.format_summary());
            lines.push(String::new());
        }

        Ok(ToolResult::success(lines.join("\n")))
    }

    fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
        true // read-only
    }
}

impl AppleEcosystemTool for ListEventsTool {
    fn required_permission(&self) -> PermissionKind {
        PermissionKind::Calendar
    }
}

// ─── CreateEventTool ──────────────────────────────────────────────────────────

/// Write tool that creates a new calendar event.
///
/// Requires `ToolMode::Full` and the Calendar permission.
///
/// # Arguments (JSON)
///
/// - `title` (string, required)
/// - `start` (string, required) — ISO-8601 datetime
/// - `end` (string, optional) — ISO-8601 datetime; defaults to start + 1 hour
/// - `calendar_id` (string, optional) — target calendar
/// - `location` (string, optional)
/// - `notes` (string, optional)
/// - `all_day` (boolean, optional, default false)
/// - `reminders` (array of integers, optional) — minutes before event
pub struct CreateEventTool {
    store: Arc<dyn CalendarStore>,
}

impl CreateEventTool {
    /// Create a new `CreateEventTool` backed by `store`.
    pub fn new(store: Arc<dyn CalendarStore>) -> Self {
        Self { store }
    }
}

impl Tool for CreateEventTool {
    fn name(&self) -> &str {
        "create_calendar_event"
    }

    fn description(&self) -> &str {
        "Create a new event on the user's calendar. Requires a title and start time \
         in ISO-8601 format (e.g. '2026-03-15T10:00:00'). End time defaults to \
         1 hour after start if not specified."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["title", "start"],
            "properties": {
                "title": {
                    "type": "string",
                    "description": "Event title (required)"
                },
                "start": {
                    "type": "string",
                    "description": "Start time in ISO-8601 format (e.g. '2026-03-15T10:00:00')"
                },
                "end": {
                    "type": "string",
                    "description": "End time in ISO-8601 format. Defaults to start + 1 hour."
                },
                "calendar_id": {
                    "type": "string",
                    "description": "Target calendar identifier (from list_calendars). Uses default calendar if omitted."
                },
                "location": {
                    "type": "string",
                    "description": "Event location"
                },
                "notes": {
                    "type": "string",
                    "description": "Additional notes for the event"
                },
                "all_day": {
                    "type": "boolean",
                    "description": "Whether this is an all-day event (default false)"
                },
                "reminders": {
                    "type": "array",
                    "items": { "type": "integer" },
                    "description": "Reminder offsets in minutes before the event (e.g. [15, 60])"
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

        let start = match args.get("start").and_then(|v| v.as_str()) {
            Some(s) if !s.trim().is_empty() => s.trim().to_owned(),
            _ => {
                return Ok(ToolResult::failure(
                    "start is required (ISO-8601 datetime, e.g. '2026-03-15T10:00:00')".to_owned(),
                ));
            }
        };

        let alarms: Vec<i64> = args
            .get("reminders")
            .and_then(|v| v.as_array())
            .map(|arr| arr.iter().filter_map(|v| v.as_i64()).collect())
            .unwrap_or_default();

        let new_event = NewCalendarEvent {
            title,
            start,
            end: args
                .get("end")
                .and_then(|v| v.as_str())
                .filter(|s| !s.trim().is_empty())
                .map(str::to_owned),
            calendar_id: args
                .get("calendar_id")
                .and_then(|v| v.as_str())
                .filter(|s| !s.trim().is_empty())
                .map(str::to_owned),
            location: args
                .get("location")
                .and_then(|v| v.as_str())
                .filter(|s| !s.trim().is_empty())
                .map(str::to_owned),
            notes: args
                .get("notes")
                .and_then(|v| v.as_str())
                .filter(|s| !s.trim().is_empty())
                .map(str::to_owned),
            is_all_day: args
                .get("all_day")
                .and_then(|v| v.as_bool())
                .unwrap_or(false),
            alarms,
        };

        let created = self
            .store
            .create_event(&new_event)
            .map_err(|e| FaeLlmError::ToolExecutionError(format!("failed to create event: {e}")))?;

        Ok(ToolResult::success(format!(
            "Event created successfully.\n{}",
            created.format_summary()
        )))
    }

    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        matches!(mode, ToolMode::Full)
    }
}

impl AppleEcosystemTool for CreateEventTool {
    fn required_permission(&self) -> PermissionKind {
        PermissionKind::Calendar
    }
}

// ─── UpdateEventTool ──────────────────────────────────────────────────────────

/// Write tool that updates an existing calendar event.
///
/// Requires `ToolMode::Full` and the Calendar permission.
///
/// # Arguments (JSON)
///
/// - `identifier` (string, required) — event identifier from `list_calendar_events`
/// - `title`, `start`, `end`, `location`, `notes`, `reminders` — optional updates
pub struct UpdateEventTool {
    store: Arc<dyn CalendarStore>,
}

impl UpdateEventTool {
    /// Create a new `UpdateEventTool` backed by `store`.
    pub fn new(store: Arc<dyn CalendarStore>) -> Self {
        Self { store }
    }
}

impl Tool for UpdateEventTool {
    fn name(&self) -> &str {
        "update_calendar_event"
    }

    fn description(&self) -> &str {
        "Update an existing calendar event. Only the fields you provide will be changed. \
         Requires the event identifier from list_calendar_events."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["identifier"],
            "properties": {
                "identifier": {
                    "type": "string",
                    "description": "Event identifier from list_calendar_events (required)"
                },
                "title": {
                    "type": "string",
                    "description": "New event title"
                },
                "start": {
                    "type": "string",
                    "description": "New start time in ISO-8601 format"
                },
                "end": {
                    "type": "string",
                    "description": "New end time in ISO-8601 format"
                },
                "location": {
                    "type": "string",
                    "description": "New location (empty string to clear)"
                },
                "notes": {
                    "type": "string",
                    "description": "New notes (empty string to clear)"
                },
                "reminders": {
                    "type": "array",
                    "items": { "type": "integer" },
                    "description": "New reminder offsets in minutes (replaces existing reminders)"
                }
            }
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let identifier = match args.get("identifier").and_then(|v| v.as_str()) {
            Some(id) if !id.trim().is_empty() => id.trim().to_owned(),
            _ => {
                return Ok(ToolResult::failure("identifier is required".to_owned()));
            }
        };

        // Build patch — only set fields that were provided
        let location = args.get("location").and_then(|v| v.as_str()).map(|s| {
            if s.trim().is_empty() {
                None
            } else {
                Some(s.to_owned())
            }
        });

        let notes = args.get("notes").and_then(|v| v.as_str()).map(|s| {
            if s.trim().is_empty() {
                None
            } else {
                Some(s.to_owned())
            }
        });

        let alarms = args
            .get("reminders")
            .and_then(|v| v.as_array())
            .map(|arr| arr.iter().filter_map(|v| v.as_i64()).collect::<Vec<_>>());

        let patch = EventPatch {
            title: args
                .get("title")
                .and_then(|v| v.as_str())
                .filter(|s| !s.trim().is_empty())
                .map(str::to_owned),
            start: args
                .get("start")
                .and_then(|v| v.as_str())
                .filter(|s| !s.trim().is_empty())
                .map(str::to_owned),
            end: args
                .get("end")
                .and_then(|v| v.as_str())
                .filter(|s| !s.trim().is_empty())
                .map(str::to_owned),
            location,
            notes,
            alarms,
        };

        let updated = self
            .store
            .update_event(&identifier, &patch)
            .map_err(|e| match e {
                CalendarStoreError::NotFound => FaeLlmError::ToolExecutionError(format!(
                    "no event found with identifier \"{identifier}\""
                )),
                other => {
                    FaeLlmError::ToolExecutionError(format!("failed to update event: {other}"))
                }
            })?;

        Ok(ToolResult::success(format!(
            "Event updated successfully.\n{}",
            updated.format_summary()
        )))
    }

    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        matches!(mode, ToolMode::Full)
    }
}

impl AppleEcosystemTool for UpdateEventTool {
    fn required_permission(&self) -> PermissionKind {
        PermissionKind::Calendar
    }
}

// ─── DeleteEventTool ──────────────────────────────────────────────────────────

/// Write tool that deletes a calendar event.
///
/// Requires `ToolMode::Full`, Calendar permission, and `confirm: true` to
/// prevent accidental deletion.
///
/// # Arguments (JSON)
///
/// - `identifier` (string, required)
/// - `confirm` (boolean, required) — must be `true`
pub struct DeleteEventTool {
    store: Arc<dyn CalendarStore>,
}

impl DeleteEventTool {
    /// Create a new `DeleteEventTool` backed by `store`.
    pub fn new(store: Arc<dyn CalendarStore>) -> Self {
        Self { store }
    }
}

impl Tool for DeleteEventTool {
    fn name(&self) -> &str {
        "delete_calendar_event"
    }

    fn description(&self) -> &str {
        "Delete a calendar event permanently. Requires the event identifier and \
         confirm: true to prevent accidental deletion. This action cannot be undone."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["identifier", "confirm"],
            "properties": {
                "identifier": {
                    "type": "string",
                    "description": "Event identifier from list_calendar_events (required)"
                },
                "confirm": {
                    "type": "boolean",
                    "description": "Must be true to confirm deletion (required)"
                }
            }
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let identifier = match args.get("identifier").and_then(|v| v.as_str()) {
            Some(id) if !id.trim().is_empty() => id.trim().to_owned(),
            _ => {
                return Ok(ToolResult::failure("identifier is required".to_owned()));
            }
        };

        let confirmed = args
            .get("confirm")
            .and_then(|v| v.as_bool())
            .unwrap_or(false);
        if !confirmed {
            return Ok(ToolResult::failure(
                "confirm must be true to delete an event. \
                 Please confirm with the user before deleting."
                    .to_owned(),
            ));
        }

        self.store.delete_event(&identifier).map_err(|e| match e {
            CalendarStoreError::NotFound => FaeLlmError::ToolExecutionError(format!(
                "no event found with identifier \"{identifier}\""
            )),
            other => FaeLlmError::ToolExecutionError(format!("failed to delete event: {other}")),
        })?;

        Ok(ToolResult::success(format!(
            "Event \"{identifier}\" deleted successfully."
        )))
    }

    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        matches!(mode, ToolMode::Full)
    }
}

impl AppleEcosystemTool for DeleteEventTool {
    fn required_permission(&self) -> PermissionKind {
        PermissionKind::Calendar
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use crate::fae_llm::config::types::ToolMode;
    use crate::fae_llm::tools::apple::mock_stores::MockCalendarStore;
    use crate::permissions::PermissionStore;

    fn sample_calendars() -> Vec<CalendarInfo> {
        vec![
            CalendarInfo {
                identifier: "cal-work".to_owned(),
                title: "Work".to_owned(),
                color: Some("#0080FF".to_owned()),
                is_writable: true,
            },
            CalendarInfo {
                identifier: "cal-personal".to_owned(),
                title: "Personal".to_owned(),
                color: Some("#FF6347".to_owned()),
                is_writable: true,
            },
            CalendarInfo {
                identifier: "cal-holidays".to_owned(),
                title: "Holidays".to_owned(),
                color: None,
                is_writable: false,
            },
        ]
    }

    fn sample_events() -> Vec<CalendarEvent> {
        vec![
            CalendarEvent {
                identifier: "evt-001".to_owned(),
                calendar_id: "cal-work".to_owned(),
                title: "Team Standup".to_owned(),
                start: "2026-03-01T09:00:00".to_owned(),
                end: "2026-03-01T09:30:00".to_owned(),
                location: None,
                notes: None,
                is_all_day: false,
                alarms: vec![15],
            },
            CalendarEvent {
                identifier: "evt-002".to_owned(),
                calendar_id: "cal-personal".to_owned(),
                title: "Dentist Appointment".to_owned(),
                start: "2026-03-03T14:00:00".to_owned(),
                end: "2026-03-03T15:00:00".to_owned(),
                location: Some("123 Dental St".to_owned()),
                notes: Some("Remember to floss".to_owned()),
                is_all_day: false,
                alarms: vec![60, 1440],
            },
        ]
    }

    fn make_list_calendars_tool() -> ListCalendarsTool {
        let store = Arc::new(MockCalendarStore::new(sample_calendars(), sample_events()));
        ListCalendarsTool::new(store)
    }

    fn make_list_events_tool() -> ListEventsTool {
        let store = Arc::new(MockCalendarStore::new(sample_calendars(), sample_events()));
        ListEventsTool::new(store)
    }

    fn make_create_tool() -> CreateEventTool {
        let store = Arc::new(MockCalendarStore::new(sample_calendars(), vec![]));
        CreateEventTool::new(store)
    }

    fn make_update_tool() -> UpdateEventTool {
        let store = Arc::new(MockCalendarStore::new(sample_calendars(), sample_events()));
        UpdateEventTool::new(store)
    }

    fn make_delete_tool() -> DeleteEventTool {
        let store = Arc::new(MockCalendarStore::new(sample_calendars(), sample_events()));
        DeleteEventTool::new(store)
    }

    // ── ListCalendarsTool ────────────────────────────────────────────────────

    #[test]
    fn list_calendars_schema_valid() {
        let tool = make_list_calendars_tool();
        assert!(tool.schema().is_object());
    }

    #[test]
    fn list_calendars_allowed_all_modes() {
        let tool = make_list_calendars_tool();
        assert!(tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn list_calendars_returns_all() {
        let tool = make_list_calendars_tool();
        let result = tool.execute(serde_json::json!({}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("list_calendars should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Work"));
        assert!(result.content.contains("Personal"));
        assert!(result.content.contains("Holidays"));
        assert!(result.content.contains("cal-work"));
    }

    #[test]
    fn list_calendars_empty_helpful_message() {
        let store = Arc::new(MockCalendarStore::new(vec![], vec![]));
        let tool = ListCalendarsTool::new(store);
        let result = tool.execute(serde_json::json!({}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("list_calendars should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("No calendars found"));
    }

    #[test]
    fn list_calendars_requires_calendar_permission() {
        let tool = make_list_calendars_tool();
        let mut store = PermissionStore::default();
        assert!(!tool.is_available(&store));
        store.grant(PermissionKind::Calendar);
        assert!(tool.is_available(&store));
    }

    // ── ListEventsTool ───────────────────────────────────────────────────────

    #[test]
    fn list_events_schema_valid() {
        let tool = make_list_events_tool();
        assert!(tool.schema().is_object());
    }

    #[test]
    fn list_events_allowed_all_modes() {
        let tool = make_list_events_tool();
        assert!(tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn list_events_returns_events() {
        let tool = make_list_events_tool();
        let result = tool.execute(serde_json::json!({}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("list_events should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Team Standup"));
        assert!(result.content.contains("Dentist Appointment"));
    }

    #[test]
    fn list_events_empty_helpful_message() {
        let store = Arc::new(MockCalendarStore::new(sample_calendars(), vec![]));
        let tool = ListEventsTool::new(store);
        let result = tool.execute(serde_json::json!({}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("list_events should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("No upcoming events"));
    }

    // ── CreateEventTool ──────────────────────────────────────────────────────

    #[test]
    fn create_event_schema_requires_title_and_start() {
        let tool = make_create_tool();
        let schema = tool.schema();
        let required = schema.get("required").and_then(|v| v.as_array());
        assert!(required.is_some_and(|r| {
            r.iter().any(|v| v.as_str() == Some("title"))
                && r.iter().any(|v| v.as_str() == Some("start"))
        }));
    }

    #[test]
    fn create_event_only_full_mode() {
        let tool = make_create_tool();
        assert!(!tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn create_event_minimal_succeeds() {
        let tool = make_create_tool();
        let result = tool.execute(serde_json::json!({
            "title": "Quick Meeting",
            "start": "2026-03-10T15:00:00"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("create should succeed"),
        };
        assert!(result.success, "content: {}", result.content);
        assert!(result.content.contains("Quick Meeting"));
        assert!(result.content.contains("created successfully"));
    }

    #[test]
    fn create_event_all_fields() {
        let tool = make_create_tool();
        let result = tool.execute(serde_json::json!({
            "title": "Product Launch",
            "start": "2026-04-01T10:00:00",
            "end": "2026-04-01T12:00:00",
            "calendar_id": "cal-work",
            "location": "Conference Room A",
            "notes": "Bring slides",
            "all_day": false,
            "reminders": [15, 60]
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("create should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Product Launch"));
        assert!(result.content.contains("Conference Room A"));
        assert!(result.content.contains("Bring slides"));
        assert!(result.content.contains("15min"));
    }

    #[test]
    fn create_event_missing_title_returns_failure() {
        let tool = make_create_tool();
        let result = tool.execute(serde_json::json!({"start": "2026-03-10T10:00:00"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return failure result"),
        };
        assert!(!result.success);
        assert!(result.error.as_deref().unwrap_or("").contains("title"));
    }

    #[test]
    fn create_event_missing_start_returns_failure() {
        let tool = make_create_tool();
        let result = tool.execute(serde_json::json!({"title": "No Start"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return failure result"),
        };
        assert!(!result.success);
        assert!(result.error.as_deref().unwrap_or("").contains("start"));
    }

    // ── UpdateEventTool ──────────────────────────────────────────────────────

    #[test]
    fn update_event_only_full_mode() {
        let tool = make_update_tool();
        assert!(!tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn update_event_title_only() {
        let tool = make_update_tool();
        let result = tool.execute(serde_json::json!({
            "identifier": "evt-001",
            "title": "Updated Standup"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("update should succeed"),
        };
        assert!(result.success, "content: {}", result.content);
        assert!(result.content.contains("Updated Standup"));
        assert!(result.content.contains("updated successfully"));
    }

    #[test]
    fn update_missing_identifier_returns_failure() {
        let tool = make_update_tool();
        let result = tool.execute(serde_json::json!({"title": "new title"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return failure result"),
        };
        assert!(!result.success);
        assert!(result.error.as_deref().unwrap_or("").contains("identifier"));
    }

    // ── DeleteEventTool ──────────────────────────────────────────────────────

    #[test]
    fn delete_event_only_full_mode() {
        let tool = make_delete_tool();
        assert!(!tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn delete_without_confirm_returns_failure() {
        let tool = make_delete_tool();
        let result = tool.execute(serde_json::json!({
            "identifier": "evt-001",
            "confirm": false
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return failure result"),
        };
        assert!(!result.success);
        assert!(
            result
                .error
                .as_deref()
                .unwrap_or("")
                .contains("confirm must be true")
        );
    }

    #[test]
    fn delete_confirmed_succeeds() {
        let tool = make_delete_tool();
        let result = tool.execute(serde_json::json!({
            "identifier": "evt-001",
            "confirm": true
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("delete should succeed"),
        };
        assert!(result.success, "content: {}", result.content);
        assert!(result.content.contains("deleted successfully"));
    }

    #[test]
    fn delete_missing_identifier_returns_failure() {
        let tool = make_delete_tool();
        let result = tool.execute(serde_json::json!({"confirm": true}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return failure result"),
        };
        assert!(!result.success);
        assert!(result.error.as_deref().unwrap_or("").contains("identifier"));
    }
}
