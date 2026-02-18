//! End-to-end tests: capability bridge persists permissions and onboarding state.

use fae::config::SpeechConfig;
use fae::host::channel::command_channel;
use fae::host::contract::{CommandEnvelope, CommandName};
use fae::host::handler::FaeDeviceTransferHandler;
use fae::permissions::PermissionKind;

fn temp_handler() -> (FaeDeviceTransferHandler, tempfile::TempDir) {
    let dir = tempfile::tempdir().expect("create temp dir");
    let path = dir.path().join("config.toml");
    let config = SpeechConfig::default();
    (FaeDeviceTransferHandler::new(config, path), dir)
}

#[test]
fn capability_grant_via_channel_persists_to_disk() {
    let (handler, dir) = temp_handler();
    let config_path = dir.path().join("config.toml");

    let (_client, server) = command_channel(8, 8, handler);

    let envelope = CommandEnvelope::new(
        "req-1",
        CommandName::CapabilityGrant,
        serde_json::json!({"capability": "calendar"}),
    );

    let resp = server.route(&envelope).expect("route");
    assert!(resp.ok);
    assert_eq!(resp.payload["accepted"], true);
    assert_eq!(resp.payload["capability"], "calendar");

    // Verify persisted to disk
    let loaded = SpeechConfig::from_file(&config_path).expect("load config");
    assert!(loaded.permissions.is_granted(PermissionKind::Calendar));
}

#[test]
fn capability_deny_via_channel_revokes_and_persists() {
    let (handler, dir) = temp_handler();
    let config_path = dir.path().join("config.toml");

    let (_client, server) = command_channel(8, 8, handler);

    // Grant first
    let grant = CommandEnvelope::new(
        "req-1",
        CommandName::CapabilityGrant,
        serde_json::json!({"capability": "mail"}),
    );
    server.route(&grant).expect("grant");

    // Deny
    let deny = CommandEnvelope::new(
        "req-2",
        CommandName::CapabilityDeny,
        serde_json::json!({"capability": "mail"}),
    );
    let resp = server.route(&deny).expect("deny");
    assert!(resp.ok);

    // Verify revoked on disk
    let loaded = SpeechConfig::from_file(&config_path).expect("load config");
    assert!(!loaded.permissions.is_granted(PermissionKind::Mail));
}

#[test]
fn onboarding_get_state_returns_default_false() {
    let (handler, _dir) = temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    let envelope = CommandEnvelope::new(
        "req-1",
        CommandName::OnboardingGetState,
        serde_json::json!({}),
    );

    let resp = server.route(&envelope).expect("route");
    assert!(resp.ok);
    assert_eq!(resp.payload["onboarded"], false);
}

#[test]
fn onboarding_complete_sets_flag_and_persists() {
    let (handler, dir) = temp_handler();
    let config_path = dir.path().join("config.toml");

    let (_client, server) = command_channel(8, 8, handler);

    let envelope = CommandEnvelope::new(
        "req-1",
        CommandName::OnboardingComplete,
        serde_json::json!({}),
    );

    let resp = server.route(&envelope).expect("route");
    assert!(resp.ok);
    assert_eq!(resp.payload["onboarded"], true);

    // Verify persisted
    let loaded = SpeechConfig::from_file(&config_path).expect("load config");
    assert!(loaded.onboarded);
}

#[test]
fn unknown_capability_returns_error() {
    let (handler, _dir) = temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    let envelope = CommandEnvelope::new(
        "req-1",
        CommandName::CapabilityGrant,
        serde_json::json!({"capability": "teleportation"}),
    );

    let resp = server.route(&envelope);
    assert!(resp.is_err());
}

#[test]
fn onboarding_state_reflects_granted_permissions() {
    let (handler, _dir) = temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    // Grant some permissions
    for cap in &["contacts", "calendar", "files"] {
        let envelope = CommandEnvelope::new(
            format!("req-{cap}"),
            CommandName::CapabilityGrant,
            serde_json::json!({"capability": cap}),
        );
        server.route(&envelope).expect("grant");
    }

    // Query onboarding state
    let state_envelope = CommandEnvelope::new(
        "req-state",
        CommandName::OnboardingGetState,
        serde_json::json!({}),
    );

    let resp = server.route(&state_envelope).expect("state");
    assert!(resp.ok);
    assert_eq!(resp.payload["onboarded"], false);
    let granted = resp.payload["granted_permissions"]
        .as_array()
        .expect("array");
    assert_eq!(granted.len(), 3);
}

#[test]
fn capability_request_validates_but_does_not_persist() {
    let (handler, dir) = temp_handler();
    let config_path = dir.path().join("config.toml");

    let (_client, server) = command_channel(8, 8, handler);

    // Request (not grant) — should validate but not persist
    let envelope = CommandEnvelope::new(
        "req-1",
        CommandName::CapabilityRequest,
        serde_json::json!({
            "capability": "microphone",
            "reason": "need to listen to you"
        }),
    );

    let resp = server.route(&envelope).expect("route");
    assert!(resp.ok);

    // Config should not exist on disk (nothing was saved)
    assert!(!config_path.is_file());
}

// ---- JIT capability integration tests ----

#[test]
fn capability_request_jit_true_validates_and_succeeds() {
    let (handler, _dir) = temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    let envelope = CommandEnvelope::new(
        "req-jit-true",
        CommandName::CapabilityRequest,
        serde_json::json!({
            "capability": "microphone",
            "reason": "Need to hear you mid-conversation",
            "jit": true
        }),
    );

    let resp = server.route(&envelope).expect("route");
    assert!(resp.ok, "jit:true capability.request should succeed");
    assert_eq!(resp.payload["accepted"], true);
    assert_eq!(resp.payload["capability"], "microphone");
}

#[test]
fn capability_request_jit_false_also_validates_successfully() {
    let (handler, _dir) = temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    let envelope = CommandEnvelope::new(
        "req-jit-false",
        CommandName::CapabilityRequest,
        serde_json::json!({
            "capability": "contacts",
            "reason": "Read your name from contacts",
            "jit": false
        }),
    );

    let resp = server.route(&envelope).expect("route");
    assert!(resp.ok, "jit:false capability.request should succeed");
    assert_eq!(resp.payload["accepted"], true);
}

#[test]
fn capability_request_jit_omitted_defaults_to_non_jit() {
    let (handler, _dir) = temp_handler();
    let (_client, server) = command_channel(8, 8, handler);

    // No jit field at all — should succeed with default false behaviour
    let envelope = CommandEnvelope::new(
        "req-jit-omit",
        CommandName::CapabilityRequest,
        serde_json::json!({
            "capability": "calendar",
            "reason": "Check your schedule"
        }),
    );

    let resp = server.route(&envelope).expect("route");
    assert!(resp.ok, "capability.request without jit should succeed");
}

#[test]
fn full_onboarding_lifecycle() {
    let (handler, dir) = temp_handler();
    let config_path = dir.path().join("config.toml");

    let (_client, server) = command_channel(8, 8, handler);

    // 1. Check initial state
    let state = server
        .route(&CommandEnvelope::new(
            "s1",
            CommandName::OnboardingGetState,
            serde_json::json!({}),
        ))
        .expect("state");
    assert!(!state.payload["onboarded"].as_bool().expect("bool"));

    // 2. Grant required permissions
    server
        .route(&CommandEnvelope::new(
            "g1",
            CommandName::CapabilityGrant,
            serde_json::json!({"capability": "microphone"}),
        ))
        .expect("grant mic");
    server
        .route(&CommandEnvelope::new(
            "g2",
            CommandName::CapabilityGrant,
            serde_json::json!({"capability": "contacts"}),
        ))
        .expect("grant contacts");

    // 3. Complete onboarding
    server
        .route(&CommandEnvelope::new(
            "c1",
            CommandName::OnboardingComplete,
            serde_json::json!({}),
        ))
        .expect("complete");

    // 4. Verify final state
    let final_state = server
        .route(&CommandEnvelope::new(
            "s2",
            CommandName::OnboardingGetState,
            serde_json::json!({}),
        ))
        .expect("final state");
    assert!(final_state.payload["onboarded"].as_bool().expect("bool"));

    let granted = final_state.payload["granted_permissions"]
        .as_array()
        .expect("array");
    assert_eq!(granted.len(), 2);

    // 5. Verify disk persistence
    let loaded = SpeechConfig::from_file(&config_path).expect("load");
    assert!(loaded.onboarded);
    assert!(loaded.permissions.is_granted(PermissionKind::Microphone));
    assert!(loaded.permissions.is_granted(PermissionKind::Contacts));
}
