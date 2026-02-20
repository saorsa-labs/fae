//! Integration tests: full onboarding lifecycle via the host command channel
//! and the production `FaeDeviceTransferHandler`.
//!
//! These tests exercise the end-to-end flow from the initial "welcome" state
//! through phase advances to final completion, verifying that state transitions
//! are persisted to disk and correctly reflected in subsequent queries.

use fae::config::SpeechConfig;
use fae::host::channel::command_channel;
use fae::host::contract::{CommandEnvelope, CommandName, EventEnvelope};
use fae::host::handler::FaeDeviceTransferHandler;
use fae::onboarding::OnboardingPhase;
use fae::personality;
use tokio::sync::broadcast;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn temp_handler() -> (
    FaeDeviceTransferHandler,
    tempfile::TempDir,
    tokio::runtime::Runtime,
) {
    let dir = tempfile::tempdir().expect("create temp dir");
    let path = dir.path().join("config.toml");
    let config = SpeechConfig::default();
    let rt = tokio::runtime::Runtime::new().expect("create tokio runtime");
    let (event_tx, _) = broadcast::channel::<EventEnvelope>(16);
    let handler = FaeDeviceTransferHandler::new(config, path, rt.handle().clone(), event_tx);
    (handler, dir, rt)
}

fn route(
    server: &fae::host::channel::HostCommandServer<FaeDeviceTransferHandler>,
    name: CommandName,
    payload: serde_json::Value,
    req_id: &str,
) -> serde_json::Value {
    let envelope = CommandEnvelope::new(req_id, name, payload);
    let resp = server.route(&envelope).expect("route should succeed");
    assert!(resp.ok, "response should be ok for {req_id}");
    resp.payload
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[test]
fn onboarding_state_includes_phase_field() {
    let (handler, _dir, _rt) = temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    let payload = route(
        &server,
        CommandName::OnboardingGetState,
        serde_json::json!({}),
        "s1",
    );
    assert_eq!(payload["onboarded"], false);
    assert_eq!(
        payload["phase"].as_str().expect("phase must be a string"),
        "welcome",
        "initial phase must be welcome"
    );
}

#[test]
fn onboarding_advance_cycles_through_all_phases() {
    let (handler, _dir, _rt) = temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    // Welcome → Permissions
    let p1 = route(
        &server,
        CommandName::OnboardingAdvance,
        serde_json::json!({}),
        "a1",
    );
    assert_eq!(p1["accepted"], true);
    assert_eq!(
        p1["phase"], "permissions",
        "first advance should reach permissions"
    );

    // Permissions → Ready
    let p2 = route(
        &server,
        CommandName::OnboardingAdvance,
        serde_json::json!({}),
        "a2",
    );
    assert_eq!(p2["phase"], "ready", "second advance should reach ready");

    // Ready → Complete
    let p3 = route(
        &server,
        CommandName::OnboardingAdvance,
        serde_json::json!({}),
        "a3",
    );
    assert_eq!(
        p3["phase"], "complete",
        "third advance should reach complete"
    );

    // Complete stays at Complete (idempotent)
    let p4 = route(
        &server,
        CommandName::OnboardingAdvance,
        serde_json::json!({}),
        "a4",
    );
    assert_eq!(
        p4["phase"], "complete",
        "further advance from complete must stay at complete"
    );
}

#[test]
fn onboarding_advance_persists_phase_to_disk() {
    let (handler, dir, _rt) = temp_handler();
    let config_path = dir.path().join("config.toml");
    let (_client, server) = command_channel(8, 8, handler);

    // Advance twice
    server
        .route(&CommandEnvelope::new(
            "a1",
            CommandName::OnboardingAdvance,
            serde_json::json!({}),
        ))
        .expect("advance 1");
    server
        .route(&CommandEnvelope::new(
            "a2",
            CommandName::OnboardingAdvance,
            serde_json::json!({}),
        ))
        .expect("advance 2");

    // Load fresh from disk
    let loaded = SpeechConfig::from_file(&config_path).expect("load config");
    assert_eq!(
        loaded.onboarding_phase.as_str(),
        "ready",
        "after two advances config must show ready phase"
    );
}

#[test]
fn onboarding_state_reflects_current_phase_after_advance() {
    let (handler, _dir, _rt) = temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    // Advance to permissions
    server
        .route(&CommandEnvelope::new(
            "a1",
            CommandName::OnboardingAdvance,
            serde_json::json!({}),
        ))
        .expect("advance");

    // Query state — should reflect new phase
    let state = route(
        &server,
        CommandName::OnboardingGetState,
        serde_json::json!({}),
        "s1",
    );
    assert_eq!(state["phase"], "permissions");
}

#[test]
fn onboarding_complete_after_full_advance_cycle() {
    let (handler, dir, _rt) = temp_handler();
    let config_path = dir.path().join("config.toml");
    let (_client, server) = command_channel(8, 8, handler);

    // Advance through all phases
    for id in &["a1", "a2", "a3"] {
        server
            .route(&CommandEnvelope::new(
                *id,
                CommandName::OnboardingAdvance,
                serde_json::json!({}),
            ))
            .expect("advance");
    }

    // Complete
    let complete = route(
        &server,
        CommandName::OnboardingComplete,
        serde_json::json!({}),
        "c1",
    );
    assert_eq!(complete["accepted"], true);
    assert_eq!(complete["onboarded"], true);

    // Verify final state query
    let state = route(
        &server,
        CommandName::OnboardingGetState,
        serde_json::json!({}),
        "s1",
    );
    assert_eq!(state["onboarded"], true);
    assert_eq!(state["phase"], "complete");

    // Verify disk persistence
    let loaded = SpeechConfig::from_file(&config_path).expect("load config");
    assert!(loaded.onboarded, "onboarded must be true on disk");
    assert_eq!(
        loaded.onboarding_phase,
        OnboardingPhase::Complete,
        "phase must be complete on disk"
    );
}

#[test]
fn onboarding_advance_emits_phase_advanced_event() {
    let (handler, _dir, _rt) = temp_handler();
    let (client, server) = command_channel(8, 8, handler);
    let mut events = client.subscribe_events();

    // Route advance synchronously (server.route, not async client.send)
    server
        .route(&CommandEnvelope::new(
            "a1",
            CommandName::OnboardingAdvance,
            serde_json::json!({}),
        ))
        .expect("advance");

    // The event was broadcast; try_recv without async
    let event = events
        .try_recv()
        .expect("event must be available synchronously");
    assert_eq!(event.event, "onboarding.phase_advanced");
    assert_eq!(event.payload["phase"], "permissions");
}

#[test]
fn onboarding_set_user_name_persists_and_injects_into_prompt() {
    let (handler, dir, _rt) = temp_handler();
    let config_path = dir.path().join("config.toml");
    let (_client, server) = command_channel(8, 8, handler);

    // 1. Send set_user_name with "Alice"
    let resp = route(
        &server,
        CommandName::OnboardingSetUserName,
        serde_json::json!({"name": "Alice"}),
        "n1",
    );
    assert_eq!(resp["accepted"], true);
    assert_eq!(resp["name"], "Alice");

    // 2. Verify config on disk has user_name
    let loaded = SpeechConfig::from_file(&config_path).expect("load config");
    assert_eq!(
        loaded.user_name.as_deref(),
        Some("Alice"),
        "user_name must be persisted to config"
    );

    // 3. Verify the assembled system prompt contains "Alice"
    let prompt = personality::assemble_prompt("fae", "", None, false, Some("Alice"));
    assert!(
        prompt.contains("Alice"),
        "assembled prompt must contain user name"
    );
    assert!(
        prompt.contains("User context:"),
        "assembled prompt must contain user context section"
    );

    // 4. Complete onboarding
    let complete = route(
        &server,
        CommandName::OnboardingComplete,
        serde_json::json!({}),
        "c1",
    );
    assert_eq!(complete["accepted"], true);
    assert_eq!(complete["onboarded"], true);

    // 5. Verify the name persists after completion
    let loaded_after = SpeechConfig::from_file(&config_path).expect("load config after complete");
    assert_eq!(
        loaded_after.user_name.as_deref(),
        Some("Alice"),
        "user_name must survive onboarding completion"
    );
    assert!(
        loaded_after.onboarded,
        "onboarded must be true after completion"
    );
}

#[test]
fn onboarding_set_user_name_empty_returns_error() {
    let (handler, _dir, _rt) = temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    let envelope = CommandEnvelope::new(
        "n2",
        CommandName::OnboardingSetUserName,
        serde_json::json!({"name": "   "}),
    );
    let result = server.route(&envelope);
    assert!(
        result.is_err(),
        "empty/whitespace name should be rejected"
    );
}

#[test]
fn onboarding_set_user_name_missing_field_returns_error() {
    let (handler, _dir, _rt) = temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    let envelope = CommandEnvelope::new(
        "n3",
        CommandName::OnboardingSetUserName,
        serde_json::json!({}),
    );
    let result = server.route(&envelope);
    assert!(result.is_err(), "missing name field should be rejected");
}
