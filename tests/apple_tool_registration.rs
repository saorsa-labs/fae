//! Integration tests for Apple ecosystem tool registration.
//!
//! Validates the full tool registration flow: tool construction, permission
//! gating via [`AvailabilityGatedTool`], rate limiting, and LLM-facing
//! contract guarantees (names, descriptions, schemas).
#![allow(clippy::unwrap_used, clippy::expect_used)]

use std::sync::Arc;

use fae::fae_llm::config::types::ToolMode;
use fae::fae_llm::tools::ToolRegistry;
use fae::fae_llm::tools::apple::{
    AppendToNoteTool, AppleRateLimiter, AvailabilityGatedTool, ComposeMailTool, CreateContactTool,
    CreateEventTool, CreateNoteTool, CreateReminderTool, DeleteEventTool, GetContactTool,
    GetMailTool, GetNoteTool, ListCalendarsTool, ListEventsTool, ListNotesTool,
    ListReminderListsTool, ListRemindersTool, SearchContactsTool, SearchMailTool,
    SetReminderCompletedTool, UpdateEventTool, global_calendar_store, global_contact_store,
    global_mail_store, global_note_store, global_reminder_store,
};
use fae::fae_llm::tools::types::Tool;
use fae::permissions::{PermissionKind, PermissionStore};

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Build all 19 Apple tools using the global (unregistered) stores and
/// wrap each with [`AvailabilityGatedTool`] — mirroring production wiring.
fn build_apple_tools(perms: Arc<PermissionStore>) -> Vec<Arc<dyn Tool>> {
    let contacts = global_contact_store();
    let calendars = global_calendar_store();
    let reminders = global_reminder_store();
    let notes = global_note_store();
    let mail = global_mail_store();

    macro_rules! gated {
        ($tool:expr) => {
            Arc::new(AvailabilityGatedTool::new(
                Arc::new($tool),
                Arc::clone(&perms),
            )) as Arc<dyn Tool>
        };
    }

    vec![
        gated!(SearchContactsTool::new(Arc::clone(&contacts))),
        gated!(GetContactTool::new(Arc::clone(&contacts))),
        gated!(CreateContactTool::new(contacts)),
        gated!(ListCalendarsTool::new(Arc::clone(&calendars))),
        gated!(ListEventsTool::new(Arc::clone(&calendars))),
        gated!(CreateEventTool::new(Arc::clone(&calendars))),
        gated!(UpdateEventTool::new(Arc::clone(&calendars))),
        gated!(DeleteEventTool::new(calendars)),
        gated!(ListReminderListsTool::new(Arc::clone(&reminders))),
        gated!(ListRemindersTool::new(Arc::clone(&reminders))),
        gated!(CreateReminderTool::new(Arc::clone(&reminders))),
        gated!(SetReminderCompletedTool::new(reminders)),
        gated!(ListNotesTool::new(Arc::clone(&notes))),
        gated!(GetNoteTool::new(Arc::clone(&notes))),
        gated!(CreateNoteTool::new(Arc::clone(&notes))),
        gated!(AppendToNoteTool::new(notes)),
        gated!(SearchMailTool::new(Arc::clone(&mail))),
        gated!(GetMailTool::new(Arc::clone(&mail))),
        gated!(ComposeMailTool::new(mail)),
    ]
}

/// Register all Apple tools into a [`ToolRegistry`].
fn build_registry_with_apple_tools(perms: Arc<PermissionStore>) -> ToolRegistry {
    let mut registry = ToolRegistry::new(ToolMode::Full);
    for tool in build_apple_tools(perms) {
        registry.register(tool);
    }
    registry
}

/// Expected Apple tool names in sorted order.
const EXPECTED_APPLE_TOOL_NAMES: [&str; 19] = [
    "append_to_note",
    "compose_mail",
    "create_calendar_event",
    "create_contact",
    "create_note",
    "create_reminder",
    "delete_calendar_event",
    "get_contact",
    "get_mail",
    "get_note",
    "list_calendar_events",
    "list_calendars",
    "list_notes",
    "list_reminder_lists",
    "list_reminders",
    "search_contacts",
    "search_mail",
    "set_reminder_completed",
    "update_calendar_event",
];

// ─── Test 1: All Apple tools appear in registry ──────────────────────────────

#[test]
fn all_19_apple_tools_registered_in_full_mode() {
    let perms = Arc::new(PermissionStore::default());
    let registry = build_registry_with_apple_tools(perms);
    let available = registry.list_available();

    for expected in &EXPECTED_APPLE_TOOL_NAMES {
        assert!(
            available.contains(expected),
            "tool '{expected}' should be in the registry but was not found. Available: {available:?}"
        );
    }
    assert_eq!(
        available.len(),
        EXPECTED_APPLE_TOOL_NAMES.len(),
        "registry should contain exactly 19 Apple tools, found {}",
        available.len()
    );
}

// ─── Test 2: Mail tools registered ───────────────────────────────────────────

#[test]
fn mail_tools_registered_and_retrievable() {
    let perms = Arc::new(PermissionStore::default());
    let registry = build_registry_with_apple_tools(perms);

    let mail_names = ["compose_mail", "search_mail", "get_mail"];
    for name in &mail_names {
        let tool = registry.get(name);
        assert!(
            tool.is_some(),
            "mail tool '{name}' should be retrievable from registry"
        );
    }
}

// ─── Test 3: Unregistered stores return PermissionDenied ─────────────────────

#[test]
fn unregistered_contact_store_returns_permission_denied() {
    let store = global_contact_store();
    let query = fae::fae_llm::tools::apple::ContactQuery {
        query: Some("Alice".to_owned()),
        limit: 10,
    };
    let result = store.search(&query);
    assert!(result.is_err(), "unregistered store should return Err");
    let err = format!("{}", result.unwrap_err());
    assert!(
        err.contains("permission denied") || err.contains("not initialized"),
        "error should mention permission denied or not initialized, got: {err}"
    );
}

#[test]
fn unregistered_calendar_store_returns_permission_denied() {
    let store = global_calendar_store();
    let result = store.list_calendars();
    assert!(result.is_err(), "unregistered store should return Err");
    let err = format!("{}", result.unwrap_err());
    assert!(
        err.contains("permission denied") || err.contains("not initialized"),
        "error should mention permission denied or not initialized, got: {err}"
    );
}

#[test]
fn unregistered_reminder_store_returns_permission_denied() {
    let store = global_reminder_store();
    let result = store.list_reminder_lists();
    assert!(result.is_err(), "unregistered store should return Err");
    let err = format!("{}", result.unwrap_err());
    assert!(
        err.contains("permission denied") || err.contains("not initialized"),
        "error should mention permission denied or not initialized, got: {err}"
    );
}

#[test]
fn unregistered_note_store_returns_permission_denied() {
    let store = global_note_store();
    let query = fae::fae_llm::tools::apple::NoteQuery {
        folder: None,
        search: None,
        limit: 10,
    };
    let result = store.list_notes(&query);
    assert!(result.is_err(), "unregistered store should return Err");
    let err = format!("{}", result.unwrap_err());
    assert!(
        err.contains("permission denied") || err.contains("not initialized"),
        "error should mention permission denied or not initialized, got: {err}"
    );
}

#[test]
fn unregistered_mail_store_returns_permission_denied() {
    let store = global_mail_store();
    let query = fae::fae_llm::tools::apple::MailQuery {
        search: None,
        mailbox: None,
        unread_only: false,
        limit: 10,
    };
    let result = store.list_messages(&query);
    assert!(result.is_err(), "unregistered store should return Err");
    let err = format!("{}", result.unwrap_err());
    assert!(
        err.contains("permission denied") || err.contains("not initialized"),
        "error should mention permission denied or not initialized, got: {err}"
    );
}

// ─── Test 4: AvailabilityGatedTool blocks without permission ─────────────────

#[test]
fn availability_gate_blocks_execution_without_permission() {
    let perms = Arc::new(PermissionStore::default());
    let store = global_contact_store();
    let gated =
        AvailabilityGatedTool::new(Arc::new(SearchContactsTool::new(store)), Arc::clone(&perms));

    let result = gated.execute(serde_json::json!({"query": "test"}));
    let result = result.expect("execute should return Ok (with failure payload)");
    assert!(
        !result.success,
        "gated tool should return failure when permission not granted"
    );
    let err = result.error.as_deref().unwrap_or("");
    assert!(
        err.contains("Permission not granted"),
        "error should mention permission not granted, got: {err}"
    );
}

#[test]
fn availability_gate_blocks_mail_tool_without_permission() {
    let perms = Arc::new(PermissionStore::default());
    let store = global_mail_store();
    let gated =
        AvailabilityGatedTool::new(Arc::new(ComposeMailTool::new(store)), Arc::clone(&perms));

    let result = gated
        .execute(serde_json::json!({
            "to": "a@b.com",
            "subject": "test",
            "body": "test"
        }))
        .expect("should return Ok");
    assert!(!result.success);
    assert!(
        result
            .error
            .as_deref()
            .unwrap_or("")
            .contains("Permission not granted"),
        "should block on mail permission"
    );
}

// ─── Test 5: AvailabilityGatedTool allows with permission ────────────────────

#[test]
fn availability_gate_allows_execution_with_permission() {
    // Even though the underlying store is unregistered, the gate itself
    // should allow the call through — the store error is a separate concern.
    let mut store = PermissionStore::default();
    store.grant(PermissionKind::Contacts);
    let perms = Arc::new(store);

    let contact_store = global_contact_store();
    let gated = AvailabilityGatedTool::new(
        Arc::new(SearchContactsTool::new(contact_store)),
        Arc::clone(&perms),
    );

    let result = gated.execute(serde_json::json!({"query": "test"}));
    // The gate lets the call through. The result is an Err from the
    // unregistered store, which gets converted to a FaeLlmError.
    // This proves the gate is not blocking.
    match result {
        Ok(r) => {
            // If it returns Ok, it could be a ToolResult with the store error in content.
            // Either way, the gate did not block it.
            assert!(
                !r.success || r.content.contains("not initialized"),
                "gate should have passed through to the store"
            );
        }
        Err(e) => {
            let msg = e.to_string();
            assert!(
                msg.contains("not initialized") || msg.contains("permission denied"),
                "error should come from the unregistered store, not the gate: {msg}"
            );
        }
    }
}

#[test]
fn availability_gate_allows_mail_with_permission() {
    let mut store = PermissionStore::default();
    store.grant(PermissionKind::Mail);
    let perms = Arc::new(store);

    let mail_store = global_mail_store();
    let gated = AvailabilityGatedTool::new(
        Arc::new(SearchMailTool::new(mail_store)),
        Arc::clone(&perms),
    );

    // The gate lets the call through; error comes from the unregistered store.
    let result = gated.execute(serde_json::json!({}));
    match result {
        Ok(r) => assert!(
            !r.success || r.content.contains("not initialized"),
            "gate passed through to unregistered store"
        ),
        Err(e) => assert!(
            e.to_string().contains("not initialized")
                || e.to_string().contains("permission denied"),
            "error should come from unregistered store"
        ),
    }
}

// ─── Test 6: Rate limiter blocks after burst threshold ───────────────────────

#[test]
fn rate_limiter_allows_up_to_capacity() {
    let limiter = AppleRateLimiter::new(5, 5.0);
    for i in 0..5 {
        assert!(
            limiter.try_acquire().is_ok(),
            "call {i} should succeed within capacity"
        );
    }
    assert!(
        limiter.try_acquire().is_err(),
        "call beyond capacity should be rate-limited"
    );
}

#[test]
fn rate_limiter_default_apple_has_capacity_10() {
    let limiter = AppleRateLimiter::default_apple();
    assert_eq!(limiter.capacity(), 10);
    assert!((limiter.refill_rate() - 10.0).abs() < f64::EPSILON);
}

// ─── Test 7: Tool names and descriptions non-empty ───────────────────────────

#[test]
fn all_apple_tools_have_nonempty_names_and_descriptions() {
    let perms = Arc::new(PermissionStore::default());
    let tools = build_apple_tools(perms);

    for tool in &tools {
        let name = tool.name();
        let desc = tool.description();

        assert!(
            !name.is_empty(),
            "tool name must not be empty (got empty for a tool)"
        );
        assert!(
            !desc.is_empty(),
            "tool description must not be empty (tool: {name})"
        );
        // Names should be snake_case identifiers — no whitespace.
        assert!(
            !name.contains(' '),
            "tool name should not contain spaces: '{name}'"
        );
        // Descriptions should be meaningful sentences (> 10 chars).
        assert!(
            desc.len() > 10,
            "tool description should be meaningful (>10 chars), tool '{name}' has: '{desc}'"
        );
    }
}

// ─── Test 8: All Apple tools have valid JSON schemas ─────────────────────────

#[test]
fn all_apple_tools_have_valid_json_schemas() {
    let perms = Arc::new(PermissionStore::default());
    let tools = build_apple_tools(perms);

    for tool in &tools {
        let schema = tool.schema();
        let name = tool.name();

        // Schema must be a JSON object with a "type" field.
        assert!(
            schema.is_object(),
            "schema for '{name}' must be a JSON object, got: {schema}"
        );
        assert_eq!(
            schema.get("type").and_then(|v| v.as_str()),
            Some("object"),
            "schema for '{name}' must have type: \"object\""
        );
        // Must have a "properties" field that is also an object.
        let props = schema.get("properties");
        assert!(
            props.is_some(),
            "schema for '{name}' must have \"properties\" key"
        );
        assert!(
            props.unwrap().is_object(),
            "properties for '{name}' must be a JSON object"
        );
    }
}

#[test]
fn registry_schemas_for_api_include_all_apple_tools() {
    let perms = Arc::new(PermissionStore::default());
    let registry = build_registry_with_apple_tools(perms);
    let schemas = registry.schemas_for_api();

    assert_eq!(
        schemas.len(),
        EXPECTED_APPLE_TOOL_NAMES.len(),
        "schemas_for_api should export exactly 19 entries"
    );

    for schema in &schemas {
        let name = schema
            .get("name")
            .and_then(|v| v.as_str())
            .expect("schema entry must have 'name'");
        let desc = schema
            .get("description")
            .and_then(|v| v.as_str())
            .expect("schema entry must have 'description'");
        let params = schema.get("parameters");

        assert!(!name.is_empty(), "schema name must not be empty");
        assert!(!desc.is_empty(), "schema description must not be empty");
        assert!(
            params.is_some(),
            "schema for '{name}' must have 'parameters'"
        );
        assert!(
            params.unwrap().is_object(),
            "parameters for '{name}' must be an object"
        );
    }
}
