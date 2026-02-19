//! Contacts tools for Fae's Apple ecosystem integration.
//!
//! Provides three LLM tools backed by a [`ContactStore`] abstraction:
//!
//! - [`SearchContactsTool`] — search contacts by name, email, or phone (read-only)
//! - [`GetContactTool`] — fetch full details for a contact by identifier (read-only)
//! - [`CreateContactTool`] — create a new contact (write, requires `ToolMode::Full`)
//!
//! The store trait is implemented by:
//! - `FfiContactStore` in [`super::ffi_bridge`] for production (calls Swift/C bridge)
//! - `MockContactStore` in [`super::mock_stores`] for unit tests

use std::fmt;
use std::sync::Arc;

use crate::fae_llm::config::types::ToolMode;
use crate::fae_llm::error::FaeLlmError;
use crate::fae_llm::tools::types::{Tool, ToolResult};
use crate::permissions::PermissionKind;

use super::trait_def::AppleEcosystemTool;

// ─── Domain types ─────────────────────────────────────────────────────────────

/// A contact record returned from `CNContactStore`.
#[derive(Debug, Clone)]
pub struct Contact {
    /// Unique Apple-assigned identifier (CNContact.identifier).
    pub identifier: String,
    /// First/given name.
    pub given_name: String,
    /// Last/family name.
    pub family_name: String,
    /// Email addresses.
    pub emails: Vec<String>,
    /// Phone numbers in E.164 or local format.
    pub phones: Vec<String>,
    /// Postal addresses (single-line formatted strings).
    pub addresses: Vec<String>,
    /// Birthday in ISO-8601 date format (`YYYY-MM-DD`), if set.
    pub birthday: Option<String>,
    /// Organization or company name.
    pub organization: Option<String>,
    /// Free-form note.
    pub note: Option<String>,
}

impl Contact {
    /// Format the contact as a human-readable text block for the LLM.
    pub fn format_summary(&self) -> String {
        let full_name = format!("{} {}", self.given_name, self.family_name)
            .trim()
            .to_owned();
        let name_line = if full_name.is_empty() {
            "(no name)".to_owned()
        } else {
            full_name
        };

        let mut lines = vec![format!("Contact: {name_line} [id: {}]", self.identifier)];

        if !self.emails.is_empty() {
            lines.push(format!("  Emails: {}", self.emails.join(", ")));
        }
        if !self.phones.is_empty() {
            lines.push(format!("  Phones: {}", self.phones.join(", ")));
        }
        if !self.addresses.is_empty() {
            lines.push(format!("  Addresses: {}", self.addresses.join(" | ")));
        }
        if let Some(ref org) = self.organization {
            lines.push(format!("  Organization: {org}"));
        }
        if let Some(ref bday) = self.birthday {
            lines.push(format!("  Birthday: {bday}"));
        }
        if let Some(ref note) = self.note {
            let snippet = if note.len() > 80 {
                format!("{}…", &note[..80])
            } else {
                note.clone()
            };
            lines.push(format!("  Note: {snippet}"));
        }

        lines.join("\n")
    }
}

/// Parameters for a contact search.
#[derive(Debug, Clone)]
pub struct ContactQuery {
    /// Substring search across name, email, and phone fields.
    pub query: Option<String>,
    /// Maximum results to return.
    pub limit: usize,
}

/// Data for creating a new contact.
#[derive(Debug, Clone)]
pub struct NewContact {
    /// Required: given (first) name.
    pub given_name: String,
    /// Optional: family (last) name.
    pub family_name: Option<String>,
    /// Optional: primary email address.
    pub email: Option<String>,
    /// Optional: primary phone number.
    pub phone: Option<String>,
    /// Optional: organization/company name.
    pub organization: Option<String>,
    /// Optional: free-form note.
    pub note: Option<String>,
}

/// Error type for contact store operations.
#[derive(Debug, Clone)]
pub enum ContactStoreError {
    /// macOS permission not granted or store not initialized.
    PermissionDenied(String),
    /// Contact with the given identifier was not found.
    NotFound,
    /// Invalid input supplied by the caller.
    InvalidInput(String),
    /// Unexpected error from the underlying store.
    Backend(String),
}

impl fmt::Display for ContactStoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ContactStoreError::PermissionDenied(msg) => write!(f, "permission denied: {msg}"),
            ContactStoreError::NotFound => write!(f, "contact not found"),
            ContactStoreError::InvalidInput(msg) => write!(f, "invalid input: {msg}"),
            ContactStoreError::Backend(msg) => write!(f, "store error: {msg}"),
        }
    }
}

impl std::error::Error for ContactStoreError {}

impl From<ContactStoreError> for FaeLlmError {
    fn from(e: ContactStoreError) -> Self {
        FaeLlmError::ToolExecutionError(e.to_string())
    }
}

// ─── ContactStore trait ───────────────────────────────────────────────────────

/// Abstraction over Apple's `CNContactStore` for testability.
///
/// The production implementation in [`super::ffi_bridge`] calls Swift/C bridge
/// functions.  Tests use [`super::mock_stores::MockContactStore`].
pub trait ContactStore: Send + Sync {
    /// Search for contacts matching the query.
    fn search(&self, query: &ContactQuery) -> Result<Vec<Contact>, ContactStoreError>;

    /// Fetch a single contact by its Apple-assigned identifier.
    fn get(&self, identifier: &str) -> Result<Option<Contact>, ContactStoreError>;

    /// Create a new contact and return the stored record (with assigned identifier).
    fn create(&self, contact: &NewContact) -> Result<Contact, ContactStoreError>;
}

// ─── SearchContactsTool ───────────────────────────────────────────────────────

/// Read-only tool that searches contacts by name, email, or phone.
///
/// # Arguments (JSON)
///
/// - `query` (string, optional) — search term matched against name, email, phone
/// - `limit` (integer, optional) — max results (default 10, max 50)
pub struct SearchContactsTool {
    store: Arc<dyn ContactStore>,
}

impl SearchContactsTool {
    /// Create a new `SearchContactsTool` backed by `store`.
    pub fn new(store: Arc<dyn ContactStore>) -> Self {
        Self { store }
    }
}

impl Tool for SearchContactsTool {
    fn name(&self) -> &str {
        "search_contacts"
    }

    fn description(&self) -> &str {
        "Search your contacts by name, email address, or phone number. \
         Returns a list of matching contacts with their key details. \
         Use get_contact to fetch full details for a specific contact."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "Search term to match against contact name, email, or phone number"
                },
                "limit": {
                    "type": "integer",
                    "description": "Maximum number of contacts to return (default 10, max 50)",
                    "minimum": 1,
                    "maximum": 50
                }
            }
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let query_str = args
            .get("query")
            .and_then(|v| v.as_str())
            .map(str::to_owned);
        let limit = args
            .get("limit")
            .and_then(|v| v.as_u64())
            .map(|n| n.min(50) as usize)
            .unwrap_or(10);

        let query = ContactQuery {
            query: query_str.clone(),
            limit,
        };

        let contacts = self
            .store
            .search(&query)
            .map_err(|e| FaeLlmError::ToolExecutionError(format!("contact search failed: {e}")))?;

        if contacts.is_empty() {
            let msg = match query_str {
                Some(q) => format!("No contacts found matching \"{q}\"."),
                None => "No contacts found.".to_owned(),
            };
            return Ok(ToolResult::success(msg));
        }

        let mut lines = vec![format!("Found {} contact(s):\n", contacts.len())];
        for contact in &contacts {
            lines.push(contact.format_summary());
            lines.push(String::new()); // blank line separator
        }

        Ok(ToolResult::success(lines.join("\n")))
    }

    fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
        true // read-only
    }
}

impl AppleEcosystemTool for SearchContactsTool {
    fn required_permission(&self) -> PermissionKind {
        PermissionKind::Contacts
    }
}

// ─── GetContactTool ───────────────────────────────────────────────────────────

/// Read-only tool that fetches full contact details by identifier.
///
/// # Arguments (JSON)
///
/// - `identifier` (string, required) — the contact's Apple-assigned identifier
pub struct GetContactTool {
    store: Arc<dyn ContactStore>,
}

impl GetContactTool {
    /// Create a new `GetContactTool` backed by `store`.
    pub fn new(store: Arc<dyn ContactStore>) -> Self {
        Self { store }
    }
}

impl Tool for GetContactTool {
    fn name(&self) -> &str {
        "get_contact"
    }

    fn description(&self) -> &str {
        "Get the full details of a contact by their identifier. \
         Returns name, email addresses, phone numbers, postal addresses, \
         birthday, organization, and notes. Use search_contacts to find identifiers."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["identifier"],
            "properties": {
                "identifier": {
                    "type": "string",
                    "description": "The contact's Apple-assigned identifier from search_contacts"
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

        let contact = self
            .store
            .get(&identifier)
            .map_err(|e| FaeLlmError::ToolExecutionError(format!("failed to get contact: {e}")))?;

        match contact {
            Some(c) => Ok(ToolResult::success(c.format_summary())),
            None => Ok(ToolResult::success(format!(
                "No contact found with identifier \"{identifier}\"."
            ))),
        }
    }

    fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
        true // read-only
    }
}

impl AppleEcosystemTool for GetContactTool {
    fn required_permission(&self) -> PermissionKind {
        PermissionKind::Contacts
    }
}

// ─── CreateContactTool ────────────────────────────────────────────────────────

/// Write tool that creates a new contact in the user's address book.
///
/// Requires `ToolMode::Full` and the Contacts permission.
///
/// # Arguments (JSON)
///
/// - `given_name` (string, required)
/// - `family_name` (string, optional)
/// - `email` (string, optional)
/// - `phone` (string, optional)
/// - `organization` (string, optional)
/// - `note` (string, optional)
pub struct CreateContactTool {
    store: Arc<dyn ContactStore>,
}

impl CreateContactTool {
    /// Create a new `CreateContactTool` backed by `store`.
    pub fn new(store: Arc<dyn ContactStore>) -> Self {
        Self { store }
    }
}

impl Tool for CreateContactTool {
    fn name(&self) -> &str {
        "create_contact"
    }

    fn description(&self) -> &str {
        "Create a new contact in the user's address book. \
         Requires at least a given name. Returns the created contact's details \
         including the newly assigned identifier."
    }

    fn schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "required": ["given_name"],
            "properties": {
                "given_name": {
                    "type": "string",
                    "description": "Contact's first/given name (required)"
                },
                "family_name": {
                    "type": "string",
                    "description": "Contact's last/family name"
                },
                "email": {
                    "type": "string",
                    "description": "Primary email address"
                },
                "phone": {
                    "type": "string",
                    "description": "Primary phone number"
                },
                "organization": {
                    "type": "string",
                    "description": "Organization or company name"
                },
                "note": {
                    "type": "string",
                    "description": "Free-form note"
                }
            }
        })
    }

    fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
        let given_name = match args.get("given_name").and_then(|v| v.as_str()) {
            Some(name) if !name.trim().is_empty() => name.trim().to_owned(),
            _ => {
                return Ok(ToolResult::failure(
                    "given_name is required and cannot be empty".to_owned(),
                ));
            }
        };

        let new_contact = NewContact {
            given_name,
            family_name: args
                .get("family_name")
                .and_then(|v| v.as_str())
                .filter(|s| !s.trim().is_empty())
                .map(str::to_owned),
            email: args
                .get("email")
                .and_then(|v| v.as_str())
                .filter(|s| !s.trim().is_empty())
                .map(str::to_owned),
            phone: args
                .get("phone")
                .and_then(|v| v.as_str())
                .filter(|s| !s.trim().is_empty())
                .map(str::to_owned),
            organization: args
                .get("organization")
                .and_then(|v| v.as_str())
                .filter(|s| !s.trim().is_empty())
                .map(str::to_owned),
            note: args
                .get("note")
                .and_then(|v| v.as_str())
                .filter(|s| !s.trim().is_empty())
                .map(str::to_owned),
        };

        let created = self.store.create(&new_contact).map_err(|e| {
            FaeLlmError::ToolExecutionError(format!("failed to create contact: {e}"))
        })?;

        Ok(ToolResult::success(format!(
            "Contact created successfully.\n{}",
            created.format_summary()
        )))
    }

    fn allowed_in_mode(&self, mode: ToolMode) -> bool {
        matches!(mode, ToolMode::Full)
    }
}

impl AppleEcosystemTool for CreateContactTool {
    fn required_permission(&self) -> PermissionKind {
        PermissionKind::Contacts
    }
}

// ─── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;
    use crate::fae_llm::config::types::ToolMode;
    use crate::fae_llm::tools::apple::mock_stores::MockContactStore;
    use crate::permissions::PermissionStore;

    fn sample_contacts() -> Vec<Contact> {
        vec![
            Contact {
                identifier: "abc-001".to_owned(),
                given_name: "Alice".to_owned(),
                family_name: "Smith".to_owned(),
                emails: vec!["alice@example.com".to_owned()],
                phones: vec!["+1-555-0101".to_owned()],
                addresses: vec!["123 Main St, Springfield".to_owned()],
                birthday: Some("1985-06-15".to_owned()),
                organization: Some("Acme Corp".to_owned()),
                note: Some("Colleague".to_owned()),
            },
            Contact {
                identifier: "abc-002".to_owned(),
                given_name: "Bob".to_owned(),
                family_name: "Jones".to_owned(),
                emails: vec!["bob@corp.com".to_owned(), "b.jones@personal.com".to_owned()],
                phones: vec!["+1-555-0202".to_owned()],
                addresses: vec![],
                birthday: None,
                organization: None,
                note: None,
            },
            Contact {
                identifier: "abc-003".to_owned(),
                given_name: "Carol".to_owned(),
                family_name: "White".to_owned(),
                emails: vec!["carol@example.org".to_owned()],
                phones: vec!["+1-555-0303".to_owned()],
                addresses: vec!["456 Oak Ave".to_owned()],
                birthday: Some("1990-03-22".to_owned()),
                organization: Some("TechCo".to_owned()),
                note: None,
            },
        ]
    }

    fn make_search_tool() -> SearchContactsTool {
        let store = Arc::new(MockContactStore::new(sample_contacts()));
        SearchContactsTool::new(store)
    }

    fn make_get_tool() -> GetContactTool {
        let store = Arc::new(MockContactStore::new(sample_contacts()));
        GetContactTool::new(store)
    }

    fn make_create_tool() -> CreateContactTool {
        let store = Arc::new(MockContactStore::new(vec![]));
        CreateContactTool::new(store)
    }

    // ── SearchContactsTool ───────────────────────────────────────────────────

    #[test]
    fn search_schema_is_valid_json_object() {
        let tool = make_search_tool();
        let schema = tool.schema();
        assert!(schema.is_object());
        assert!(schema.get("properties").is_some());
    }

    #[test]
    fn search_allowed_in_all_modes() {
        let tool = make_search_tool();
        assert!(tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn search_by_name_returns_match() {
        let tool = make_search_tool();
        let result = tool.execute(serde_json::json!({"query": "Alice"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("search should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Alice"));
        assert!(result.content.contains("abc-001"));
    }

    #[test]
    fn search_by_email_returns_match() {
        let tool = make_search_tool();
        let result = tool.execute(serde_json::json!({"query": "bob@corp.com"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("search should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Bob"));
    }

    #[test]
    fn search_by_phone_returns_match() {
        let tool = make_search_tool();
        let result = tool.execute(serde_json::json!({"query": "0303"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("search should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Carol"));
    }

    #[test]
    fn search_no_results_returns_helpful_message() {
        let tool = make_search_tool();
        let result = tool.execute(serde_json::json!({"query": "zzz_nonexistent"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("search should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("No contacts found"));
    }

    #[test]
    fn search_no_query_returns_all_up_to_limit() {
        let tool = make_search_tool();
        let result = tool.execute(serde_json::json!({"limit": 2}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("search should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Found 2 contact"));
    }

    #[test]
    fn search_requires_contacts_permission() {
        let tool = make_search_tool();
        let mut store = PermissionStore::default();
        assert!(!tool.is_available(&store));
        store.grant(PermissionKind::Contacts);
        assert!(tool.is_available(&store));
    }

    // ── GetContactTool ───────────────────────────────────────────────────────

    #[test]
    fn get_schema_requires_identifier() {
        let tool = make_get_tool();
        let schema = tool.schema();
        let required = schema.get("required").and_then(|v| v.as_array());
        assert!(required.is_some_and(|r| r.iter().any(|v| v.as_str() == Some("identifier"))));
    }

    #[test]
    fn get_existing_contact_returns_all_fields() {
        let tool = make_get_tool();
        let result = tool.execute(serde_json::json!({"identifier": "abc-001"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("get should succeed"),
        };
        assert!(result.success);
        let content = &result.content;
        assert!(content.contains("Alice"));
        assert!(content.contains("abc-001"));
        assert!(content.contains("alice@example.com"));
        assert!(content.contains("+1-555-0101"));
        assert!(content.contains("Acme Corp"));
        assert!(content.contains("1985-06-15"));
        assert!(content.contains("Colleague"));
    }

    #[test]
    fn get_missing_contact_returns_not_found_message() {
        let tool = make_get_tool();
        let result = tool.execute(serde_json::json!({"identifier": "nonexistent-id"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("get should succeed with not-found message"),
        };
        assert!(result.success);
        assert!(result.content.contains("No contact found"));
    }

    #[test]
    fn get_missing_identifier_returns_failure() {
        let tool = make_get_tool();
        let result = tool.execute(serde_json::json!({}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("get should succeed (return failure result, not error)"),
        };
        assert!(!result.success);
        assert!(result.error.as_deref().unwrap_or("").contains("identifier"));
    }

    #[test]
    fn get_allowed_in_all_modes() {
        let tool = make_get_tool();
        assert!(tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    // ── CreateContactTool ────────────────────────────────────────────────────

    #[test]
    fn create_schema_requires_given_name() {
        let tool = make_create_tool();
        let schema = tool.schema();
        let required = schema.get("required").and_then(|v| v.as_array());
        assert!(required.is_some_and(|r| r.iter().any(|v| v.as_str() == Some("given_name"))));
    }

    #[test]
    fn create_only_full_mode() {
        let tool = make_create_tool();
        assert!(!tool.allowed_in_mode(ToolMode::ReadOnly));
        assert!(tool.allowed_in_mode(ToolMode::Full));
    }

    #[test]
    fn create_minimal_succeeds() {
        let tool = make_create_tool();
        let result = tool.execute(serde_json::json!({"given_name": "Dave"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("create should succeed"),
        };
        assert!(result.success, "content: {}", result.content);
        assert!(result.content.contains("Dave"));
        assert!(result.content.contains("created successfully"));
    }

    #[test]
    fn create_all_fields_populates_correctly() {
        let tool = make_create_tool();
        let result = tool.execute(serde_json::json!({
            "given_name": "Eve",
            "family_name": "Turner",
            "email": "eve@example.com",
            "phone": "+1-555-0999",
            "organization": "StartupCo",
            "note": "Important client"
        }));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("create should succeed"),
        };
        assert!(result.success);
        assert!(result.content.contains("Eve"));
        assert!(result.content.contains("Turner"));
        assert!(result.content.contains("eve@example.com"));
        assert!(result.content.contains("+1-555-0999"));
        assert!(result.content.contains("StartupCo"));
        assert!(result.content.contains("Important client"));
    }

    #[test]
    fn create_missing_given_name_returns_failure() {
        let tool = make_create_tool();
        let result = tool.execute(serde_json::json!({"family_name": "NoFirst"}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return failure result"),
        };
        assert!(!result.success);
        assert!(result.error.as_deref().unwrap_or("").contains("given_name"));
    }

    #[test]
    fn create_empty_given_name_returns_failure() {
        let tool = make_create_tool();
        let result = tool.execute(serde_json::json!({"given_name": "   "}));
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("should return failure result"),
        };
        assert!(!result.success);
    }
}
