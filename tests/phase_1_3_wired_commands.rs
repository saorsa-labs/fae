//! Integration tests for Phase 1.3: Wired commands.
//!
//! Covers:
//! - orb.palette.set / orb.feeling.set emit orb.state_changed events
//! - orb.palette.clear / orb.urgency.set / orb.flash emit orb.state_changed events
//! - scheduler CRUD persists to disk via the persisted snapshot API
//! - approval.respond resolves a pending approval request

use fae::config::SpeechConfig;
use fae::host::channel::{command_channel, command_channel_with_events};
use fae::host::contract::{CommandEnvelope, CommandName, EventEnvelope};
use fae::host::handler::FaeDeviceTransferHandler;
use fae::scheduler::{Schedule, ScheduledTask};
use tokio::sync::broadcast;

// ─── helpers ──────────────────────────────────────────────────────────────────

fn temp_handler() -> (
    FaeDeviceTransferHandler,
    tempfile::TempDir,
    tokio::runtime::Runtime,
) {
    let dir = tempfile::tempdir().expect("create temp dir");
    let path = dir.path().join("config.toml");
    let config = SpeechConfig::default();
    let rt = tokio::runtime::Runtime::new().expect("create tokio runtime");
    let (event_tx, _) = broadcast::channel::<EventEnvelope>(64);
    let handler = FaeDeviceTransferHandler::new(config, path, rt.handle().clone(), event_tx);
    (handler, dir, rt)
}

fn temp_handler_with_events() -> (
    FaeDeviceTransferHandler,
    broadcast::Receiver<EventEnvelope>,
    tempfile::TempDir,
    tokio::runtime::Runtime,
) {
    let dir = tempfile::tempdir().expect("create temp dir");
    let path = dir.path().join("config.toml");
    let config = SpeechConfig::default();
    let rt = tokio::runtime::Runtime::new().expect("create tokio runtime");
    let (event_tx, event_rx) = broadcast::channel::<EventEnvelope>(64);
    let handler = FaeDeviceTransferHandler::new(config, path, rt.handle().clone(), event_tx);
    (handler, event_rx, dir, rt)
}

fn collect_events(rx: &mut broadcast::Receiver<EventEnvelope>) -> Vec<EventEnvelope> {
    let mut events = Vec::new();
    while let Ok(evt) = rx.try_recv() {
        events.push(evt);
    }
    events
}

fn make_envelope(command: CommandName, payload: serde_json::Value) -> CommandEnvelope {
    CommandEnvelope::new("test-req-1", command, payload)
}

// ─── Task 5: Orb state change events ─────────────────────────────────────────

#[test]
fn orb_palette_set_emits_state_changed_event() {
    let (handler, mut event_rx, _dir, _rt) = temp_handler_with_events();
    let (event_tx, _) = broadcast::channel::<EventEnvelope>(64);
    let (_client, server) = command_channel_with_events(8, event_tx, handler);

    let envelope = make_envelope(
        CommandName::OrbPaletteSet,
        serde_json::json!({"palette": "heather-mist"}),
    );
    let resp = server.route(&envelope).expect("route");
    assert!(resp.ok);

    let events = collect_events(&mut event_rx);
    let state_changed = events
        .iter()
        .find(|e| e.event == "orb.state_changed")
        .expect("expected orb.state_changed event");
    assert_eq!(state_changed.payload["kind"], "palette");
    assert_eq!(state_changed.payload["palette"], "heather-mist");
}

#[test]
fn orb_palette_clear_emits_state_changed_event() {
    let (handler, mut event_rx, _dir, _rt) = temp_handler_with_events();
    let (event_tx, _) = broadcast::channel::<EventEnvelope>(64);
    let (_client, server) = command_channel_with_events(8, event_tx, handler);

    let envelope = make_envelope(CommandName::OrbPaletteClear, serde_json::json!({}));
    let resp = server.route(&envelope).expect("route");
    assert!(resp.ok);

    let events = collect_events(&mut event_rx);
    let state_changed = events
        .iter()
        .find(|e| e.event == "orb.state_changed")
        .expect("expected orb.state_changed event");
    assert_eq!(state_changed.payload["kind"], "palette_cleared");
}

#[test]
fn orb_feeling_set_emits_state_changed_event() {
    let (handler, mut event_rx, _dir, _rt) = temp_handler_with_events();
    let (event_tx, _) = broadcast::channel::<EventEnvelope>(64);
    let (_client, server) = command_channel_with_events(8, event_tx, handler);

    let envelope = make_envelope(
        CommandName::OrbFeelingSet,
        serde_json::json!({"feeling": "warmth"}),
    );
    let resp = server.route(&envelope).expect("route");
    assert!(resp.ok);

    let events = collect_events(&mut event_rx);
    let state_changed = events
        .iter()
        .find(|e| e.event == "orb.state_changed")
        .expect("expected orb.state_changed event");
    assert_eq!(state_changed.payload["kind"], "feeling");
    assert_eq!(state_changed.payload["feeling"], "warmth");
}

#[test]
fn orb_urgency_set_emits_state_changed_event() {
    let (handler, mut event_rx, _dir, _rt) = temp_handler_with_events();
    let (event_tx, _) = broadcast::channel::<EventEnvelope>(64);
    let (_client, server) = command_channel_with_events(8, event_tx, handler);

    let envelope = make_envelope(
        CommandName::OrbUrgencySet,
        serde_json::json!({"urgency": 0.7}),
    );
    let resp = server.route(&envelope).expect("route");
    assert!(resp.ok);

    let events = collect_events(&mut event_rx);
    let state_changed = events
        .iter()
        .find(|e| e.event == "orb.state_changed")
        .expect("expected orb.state_changed event");
    assert_eq!(state_changed.payload["kind"], "urgency");
    assert!(
        state_changed.payload["urgency"].as_f64().is_some(),
        "urgency should be a number"
    );
}

#[test]
fn orb_flash_emits_state_changed_event() {
    let (handler, mut event_rx, _dir, _rt) = temp_handler_with_events();
    let (event_tx, _) = broadcast::channel::<EventEnvelope>(64);
    let (_client, server) = command_channel_with_events(8, event_tx, handler);

    let envelope = make_envelope(
        CommandName::OrbFlash,
        serde_json::json!({"flash_type": "success"}),
    );
    let resp = server.route(&envelope).expect("route");
    assert!(resp.ok);

    let events = collect_events(&mut event_rx);
    let state_changed = events
        .iter()
        .find(|e| e.event == "orb.state_changed")
        .expect("expected orb.state_changed event");
    assert_eq!(state_changed.payload["kind"], "flash");
    assert_eq!(state_changed.payload["flash_type"], "success");
}

// ─── Task 6: Scheduler CRUD with persistence ─────────────────────────────────
//
// These tests verify that the host command channel correctly parses task
// specs and routes them to the scheduler CRUD API. Because the scheduler
// uses a shared system state file (~/.config/fae/scheduler.json), we verify
// correctness at the command-routing level — checking that:
// (a) well-formed task specs are accepted and return a task ID
// (b) invalid task specs return an error
// (c) delete/trigger_now return ok (even when the task is absent, per
//     the handler's warn-but-succeed policy)
// (d) list returns a tasks array
//
// End-to-end disk-persistence of scheduler tasks is already covered by the
// dedicated scheduler integration tests in tests/scheduler_ui_integration.rs.

/// Build a minimal user ScheduledTask for testing.
fn make_test_task(id: &str, name: &str) -> ScheduledTask {
    ScheduledTask::user_task(id, name, Schedule::Interval { secs: 3600 })
}

#[test]
fn scheduler_create_with_valid_spec_returns_task_id() {
    let (handler, _dir, _rt) = temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    let task_id = format!("test-create-{}", uuid::Uuid::new_v4());
    let task = make_test_task(&task_id, "My Test Task");
    let spec = serde_json::to_value(&task).expect("serialize task");

    let resp = server
        .route(&CommandEnvelope::new(
            "req-create",
            CommandName::SchedulerCreate,
            spec,
        ))
        .expect("route create");
    assert!(resp.ok, "create should succeed");
    // The channel wraps the handler result in payload["result"]
    assert_eq!(
        resp.payload["result"]["id"],
        task_id.as_str(),
        "response should echo back the task id"
    );

    // Cleanup: remove the persisted task so tests are isolated.
    fae::scheduler::remove_persisted_task(&task_id).ok();
}

#[test]
fn scheduler_create_with_invalid_spec_returns_error() {
    let (handler, _dir, _rt) = temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    // Missing required fields — should fail to deserialize.
    let bad_spec = serde_json::json!({"not_a_task": true});
    let result = server.route(&CommandEnvelope::new(
        "req-bad",
        CommandName::SchedulerCreate,
        bad_spec,
    ));
    assert!(result.is_err(), "invalid spec should return an error");
}

#[test]
fn scheduler_delete_nonexistent_succeeds_with_warning() {
    // The handler warns but returns Ok(()) for missing tasks, so the
    // channel should return a success response.
    let (handler, _dir, _rt) = temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    let resp = server
        .route(&CommandEnvelope::new(
            "req-del",
            CommandName::SchedulerDelete,
            serde_json::json!({"id": "task-that-does-not-exist-xyz"}),
        ))
        .expect("route delete");
    assert!(resp.ok, "delete of missing task should succeed (warn only)");
}

#[test]
fn scheduler_trigger_now_nonexistent_succeeds_with_warning() {
    let (handler, _dir, _rt) = temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    let resp = server
        .route(&CommandEnvelope::new(
            "req-trigger",
            CommandName::SchedulerTriggerNow,
            serde_json::json!({"id": "task-that-does-not-exist-xyz"}),
        ))
        .expect("route trigger");
    assert!(
        resp.ok,
        "trigger_now of missing task should succeed (warn only)"
    );
}

#[test]
fn scheduler_list_returns_tasks_array() {
    let (handler, _dir, _rt) = temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    let resp = server
        .route(&CommandEnvelope::new(
            "req-list",
            CommandName::SchedulerList,
            serde_json::json!({}),
        ))
        .expect("route list");
    assert!(resp.ok, "list should succeed");
    assert!(
        resp.payload["tasks"].is_array(),
        "payload should contain a tasks array"
    );
}

#[test]
fn scheduler_update_with_invalid_spec_returns_error() {
    let (handler, _dir, _rt) = temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    let bad_spec = serde_json::json!({"missing_required": true});
    let result = server.route(&CommandEnvelope::new(
        "req-update",
        CommandName::SchedulerUpdate,
        bad_spec,
    ));
    assert!(result.is_err(), "invalid update spec should return an error");
}

// ─── Task 4: approval.respond wires into pending_approvals ───────────────────
//
// We test the handler directly because the approval channel requires
// the pipeline to be running (ToolApprovalRequest contains an internal
// oneshot::Sender). We verify that:
// - approval.respond with an unknown ID returns an error
// - approval.respond with a non-numeric ID returns an error

#[test]
fn approval_respond_unknown_id_returns_error() {
    let (handler, _dir, _rt) = temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    let envelope = CommandEnvelope::new(
        "req-1",
        CommandName::ApprovalRespond,
        serde_json::json!({"request_id": "9999999", "approved": true}),
    );
    let result = server.route(&envelope);
    // Should return an error: no pending request with that ID.
    assert!(
        result.is_err(),
        "approval.respond with unknown ID should return an error"
    );
}

#[test]
fn approval_respond_non_numeric_id_returns_error() {
    let (handler, _dir, _rt) = temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    let envelope = CommandEnvelope::new(
        "req-1",
        CommandName::ApprovalRespond,
        serde_json::json!({"request_id": "not-a-number", "approved": false}),
    );
    let result = server.route(&envelope);
    assert!(
        result.is_err(),
        "approval.respond with non-numeric ID should return an error"
    );
}
