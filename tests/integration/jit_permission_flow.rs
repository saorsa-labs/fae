//! End-to-end integration tests for the JIT (just-in-time) permission flow.
//!
//! Validates:
//! - `capability.request` with `jit: true` emits the correct event payload
//! - Grant/deny via `capability.grant`/`capability.deny` propagates to
//!   the `SharedPermissionStore` used by `AvailabilityGatedTool`
//! - `permissions.changed` event is emitted on both grant and deny
//! - Tool context (`tool_name`, `tool_action`) is preserved in the event
//! - Live shared store propagates across multiple tool gate instances
//! - Revocation blocks a previously-allowed tool

use std::sync::Arc;

use fae::fae_llm::tools::apple::{
    AvailabilityGatedTool, SearchContactsTool, SearchMailTool, global_contact_store,
    global_mail_store,
};
use fae::fae_llm::tools::types::Tool;
use fae::host::channel::{DeviceTransferHandler, command_channel_with_events};
use fae::host::contract::{CommandEnvelope, CommandName};
use fae::permissions::{PermissionKind, PermissionStore};
use tokio::sync::broadcast;

use super::helpers::{drain_events, temp_handler_with_events};

// ─── Test helpers ─────────────────────────────────────────────────────────────

/// Create a `CommandEnvelope` for the given command and payload.
fn envelope(command: CommandName, payload: serde_json::Value) -> CommandEnvelope {
    CommandEnvelope::new("test-req", command, payload)
}

// ─── Test 1: JIT capability.request emits event with jit flag ────────────────

#[test]
fn jit_capability_request_emits_event_with_jit_flag() {
    let (handler, _, _dir, _rt) = temp_handler_with_events();
    let (event_tx, mut event_rx) = broadcast::channel(64);
    let (_client, server) = command_channel_with_events(8, event_tx, handler);

    let cmd = envelope(
        CommandName::CapabilityRequest,
        serde_json::json!({
            "capability": "contacts",
            "reason": "I need to look up Alice's phone",
            "jit": true,
        }),
    );
    let resp = server.route(&cmd).expect("route should succeed");
    assert!(resp.ok, "capability.request should succeed");

    let events = drain_events(&mut event_rx);
    let requested = events
        .iter()
        .find(|e| e.event == "capability.requested")
        .expect("should emit capability.requested event");

    assert_eq!(requested.payload["jit"], true);
    assert_eq!(requested.payload["capability"], "contacts");
}

// ─── Test 2: JIT grant via capability.grant persists to shared store ─────────

#[test]
fn jit_grant_via_capability_grant_persists_to_shared_store() {
    let (handler, _event_rx, _dir, _rt) = temp_handler_with_events();

    // Get the shared store before granting.
    let shared = handler.shared_permissions();
    assert!(
        !shared.lock().unwrap().is_granted(PermissionKind::Contacts),
        "should not be granted initially"
    );

    handler
        .grant_capability("contacts", None)
        .expect("grant should succeed");

    assert!(
        shared.lock().unwrap().is_granted(PermissionKind::Contacts),
        "shared store should reflect the grant"
    );
}

// ─── Test 3: JIT deny via capability.deny persists to shared store ────────────

#[test]
fn jit_deny_via_capability_deny_persists_to_shared_store() {
    let (handler, _event_rx, _dir, _rt) = temp_handler_with_events();

    handler
        .grant_capability("contacts", None)
        .expect("grant should succeed");

    let shared = handler.shared_permissions();
    assert!(
        shared.lock().unwrap().is_granted(PermissionKind::Contacts),
        "should be granted"
    );

    handler
        .deny_capability("contacts", None)
        .expect("deny should succeed");

    assert!(
        !shared.lock().unwrap().is_granted(PermissionKind::Contacts),
        "shared store should reflect the deny"
    );
}

// ─── Test 4: permissions.changed event emitted on JIT grant ──────────────────

#[test]
fn permissions_changed_event_emitted_on_jit_grant() {
    let (handler, mut event_rx, _dir, _rt) = temp_handler_with_events();

    handler
        .grant_capability("contacts", None)
        .expect("grant should succeed");

    let events = drain_events(&mut event_rx);
    let changed = events
        .iter()
        .find(|e| e.event == "permissions.changed")
        .expect("should emit permissions.changed event");

    assert_eq!(changed.payload["kind"], "contacts");
    assert_eq!(changed.payload["granted"], true);
}

// ─── Test 5: permissions.changed event emitted on JIT deny ───────────────────

#[test]
fn permissions_changed_event_emitted_on_jit_deny() {
    let (handler, mut event_rx, _dir, _rt) = temp_handler_with_events();

    handler
        .grant_capability("contacts", None)
        .expect("grant should succeed");

    // Drain the grant event.
    drain_events(&mut event_rx);

    handler
        .deny_capability("contacts", None)
        .expect("deny should succeed");

    let events = drain_events(&mut event_rx);
    let changed = events
        .iter()
        .find(|e| e.event == "permissions.changed")
        .expect("should emit permissions.changed event after deny");

    assert_eq!(changed.payload["kind"], "contacts");
    assert_eq!(changed.payload["granted"], false);
}

// ─── Test 6: Tool context preserved in capability.requested event ─────────────

#[test]
fn capability_request_with_tool_context_preserved_in_event() {
    let (handler, _, _dir, _rt) = temp_handler_with_events();
    let (event_tx, mut event_rx) = broadcast::channel(64);
    let (_client, server) = command_channel_with_events(8, event_tx, handler);

    let cmd = envelope(
        CommandName::CapabilityRequest,
        serde_json::json!({
            "capability": "contacts",
            "reason": "need to search for contacts",
            "jit": true,
            "tool_name": "search_contacts",
            "tool_action": "search contacts for Bob",
        }),
    );
    server.route(&cmd).expect("route should succeed");

    let events = drain_events(&mut event_rx);
    let requested = events
        .iter()
        .find(|e| e.event == "capability.requested")
        .expect("should emit capability.requested event");

    assert_eq!(requested.payload["tool_name"], "search_contacts");
    assert_eq!(requested.payload["tool_action"], "search contacts for Bob");
    assert_eq!(requested.payload["jit"], true);
}

// ─── Test 7: Shared store live view — multiple gates see same grant ────────────

#[test]
fn shared_permission_store_live_view_reflects_runtime_grant() {
    let shared = PermissionStore::default_shared();
    let contacts = global_contact_store();
    let mail = global_mail_store();

    // Two tool gates sharing the same permission store.
    let contact_gate = AvailabilityGatedTool::new(
        Arc::new(SearchContactsTool::new(Arc::clone(&contacts))),
        Arc::clone(&shared),
    );
    let mail_gate = AvailabilityGatedTool::new(
        Arc::new(SearchMailTool::new(Arc::clone(&mail))),
        Arc::clone(&shared),
    );

    // Both blocked initially.
    let r = contact_gate.execute(serde_json::json!({})).unwrap();
    assert!(!r.success, "contacts gate should block before grant");

    let r = mail_gate.execute(serde_json::json!({})).unwrap();
    assert!(!r.success, "mail gate should block before grant");

    // Grant contacts only.
    shared.lock().unwrap().grant(PermissionKind::Contacts);

    // Contacts gate now passes (store error from unregistered store is fine).
    let r = contact_gate.execute(serde_json::json!({"query": "test"}));
    // Gate passed — store error is expected since store is unregistered.
    match r {
        Ok(result) => {
            // Either success (unlikely with unregistered store) or a store-level error.
            // What matters is the gate did NOT block it with "Permission not granted".
            assert!(
                result.success
                    || result
                        .error
                        .as_deref()
                        .map(|e| !e.contains("Permission not granted"))
                        .unwrap_or(true),
                "contacts gate should have passed to the store level"
            );
        }
        Err(e) => {
            assert!(
                e.to_string().contains("not initialized")
                    || e.to_string().contains("permission denied"),
                "error should come from the store, not the gate: {e}"
            );
        }
    }

    // Mail gate still blocked (mail not granted).
    let r = mail_gate.execute(serde_json::json!({})).unwrap();
    assert!(
        !r.success,
        "mail gate should still block — only contacts was granted"
    );
    let err = r.error.as_deref().unwrap_or("");
    assert!(
        err.contains("Permission not granted: mail"),
        "mail gate error should mention mail permission: {err}"
    );
}

// ─── Test 8: Revocation via deny blocks previously-allowed tool ───────────────

#[test]
fn revocation_via_deny_blocks_previously_allowed_tool() {
    let mut store = PermissionStore::default();
    store.grant(PermissionKind::Contacts);
    let shared = store.into_shared();

    let contacts = global_contact_store();
    let gate = AvailabilityGatedTool::new(
        Arc::new(SearchContactsTool::new(Arc::clone(&contacts))),
        Arc::clone(&shared),
    );

    // Gate allows when permission is granted.
    let r = gate.execute(serde_json::json!({"query": "test"}));
    match r {
        Ok(result) => {
            // Passes gate — store-level error is fine.
            assert!(
                result.success
                    || result
                        .error
                        .as_deref()
                        .map(|e| !e.contains("Permission not granted"))
                        .unwrap_or(true),
                "gate should pass when permission is granted"
            );
        }
        Err(e) => {
            assert!(
                e.to_string().contains("not initialized")
                    || e.to_string().contains("permission denied"),
                "error should come from unregistered store: {e}"
            );
        }
    }

    // Revoke contacts.
    shared.lock().unwrap().deny(PermissionKind::Contacts);

    // Gate now blocks.
    let r = gate.execute(serde_json::json!({"query": "test"})).unwrap();
    assert!(!r.success, "gate should block after revocation");
    let err = r.error.as_deref().unwrap_or("");
    assert!(
        err.contains("Permission not granted: contacts"),
        "error should mention contacts permission: {err}"
    );
}

// ─── Test: permissions.changed includes all_granted list ─────────────────────

#[test]
fn permissions_changed_event_includes_all_granted() {
    let (handler, mut event_rx, _dir, _rt) = temp_handler_with_events();

    handler
        .grant_capability("contacts", None)
        .expect("grant contacts");
    drain_events(&mut event_rx);

    handler
        .grant_capability("calendar", None)
        .expect("grant calendar");

    let events = drain_events(&mut event_rx);
    let changed = events
        .iter()
        .find(|e| e.event == "permissions.changed")
        .expect("should emit permissions.changed event");

    let all_granted = changed.payload["all_granted"]
        .as_array()
        .expect("all_granted should be an array");

    assert!(
        all_granted.iter().any(|v| v.as_str() == Some("contacts")),
        "all_granted should include contacts"
    );
    assert!(
        all_granted.iter().any(|v| v.as_str() == Some("calendar")),
        "all_granted should include calendar"
    );
}

// ─── Test: shared_permissions() accessor returns live view ───────────────────

#[test]
fn shared_permissions_is_consistent_with_config() {
    let (handler, _event_rx, _dir, _rt) = temp_handler_with_events();

    handler.grant_capability("mail", None).expect("grant mail");
    handler
        .grant_capability("reminders", None)
        .expect("grant reminders");

    let shared = handler.shared_permissions();
    let guard = shared.lock().unwrap();

    assert!(guard.is_granted(PermissionKind::Mail));
    assert!(guard.is_granted(PermissionKind::Reminders));
    assert!(!guard.is_granted(PermissionKind::Camera));
}

// ─── Test: capability.request without JIT fields defaults to None ─────────────

#[test]
fn capability_request_without_jit_fields_has_null_context() {
    let (handler, _, _dir, _rt) = temp_handler_with_events();
    let (event_tx, mut event_rx) = broadcast::channel(64);
    let (_client, server) = command_channel_with_events(8, event_tx, handler);

    let cmd = envelope(
        CommandName::CapabilityRequest,
        serde_json::json!({
            "capability": "calendar",
            "reason": "need calendar access",
        }),
    );
    server.route(&cmd).expect("route should succeed");

    let events = drain_events(&mut event_rx);
    let requested = events
        .iter()
        .find(|e| e.event == "capability.requested")
        .expect("should emit capability.requested event");

    // jit defaults to false
    assert_eq!(requested.payload["jit"], false);
    // tool_name and tool_action are null when not provided
    assert!(
        requested.payload["tool_name"].is_null(),
        "tool_name should be null when not provided"
    );
    assert!(
        requested.payload["tool_action"].is_null(),
        "tool_action should be null when not provided"
    );
}
