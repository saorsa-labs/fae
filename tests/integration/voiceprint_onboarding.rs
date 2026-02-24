//! Integration tests for onboarding voiceprint lifecycle commands.

use fae::config::SpeechConfig;
use fae::host::channel::command_channel;
use fae::host::contract::{CommandEnvelope, CommandName};
use fae::host::handler::FaeDeviceTransferHandler;
use fae::memory::{MemoryStore, PrimaryUser};
use tokio::sync::broadcast;

fn make_handler() -> (
    FaeDeviceTransferHandler,
    tempfile::TempDir,
    tokio::runtime::Runtime,
) {
    let dir = tempfile::tempdir().expect("tempdir");
    let cfg_path = dir.path().join("config.toml");
    let mut cfg = SpeechConfig::default();
    cfg.memory.root_dir = dir.path().join("data");

    let rt = tokio::runtime::Runtime::new().expect("runtime");
    let (event_tx, _) = broadcast::channel(32);
    let handler = FaeDeviceTransferHandler::new(cfg, cfg_path, rt.handle().clone(), event_tx);
    (handler, dir, rt)
}

#[test]
fn voiceprint_get_state_defaults_to_not_enrolled() {
    let (handler, _dir, _rt) = make_handler();
    let (_client, server) = command_channel(8, 8, handler);

    let resp = server
        .route(&CommandEnvelope::new(
            "vp-state-1",
            CommandName::OnboardingVoiceprintGetState,
            serde_json::json!({}),
        ))
        .expect("route");
    assert!(resp.ok);
    assert_eq!(resp.payload["enrolled"], false);
    assert_eq!(resp.payload["enabled"], false);
}

#[test]
fn voiceprint_start_finalize_and_reset_lifecycle() {
    let (handler, dir, _rt) = make_handler();
    let (_client, server) = command_channel(8, 8, handler);

    // 1. Start enrollment
    let start = server
        .route(&CommandEnvelope::new(
            "vp-start-1",
            CommandName::OnboardingVoiceprintStartEnrollment,
            serde_json::json!({}),
        ))
        .expect("start");
    assert!(start.ok);
    assert_eq!(start.payload["accepted"], true);
    assert_eq!(start.payload["enrollment_active"], true);

    // 2. Finalize should fail when insufficient samples exist.
    let finalize_err = server.route(&CommandEnvelope::new(
        "vp-finalize-err",
        CommandName::OnboardingVoiceprintFinalize,
        serde_json::json!({}),
    ));
    assert!(finalize_err.is_err(), "finalize must fail without samples");

    // 3. Seed enrollment samples directly in memory.
    let store = MemoryStore::new(&dir.path().join("data"));
    store.ensure_dirs().expect("ensure memory dirs");
    let user = PrimaryUser {
        name: "Alice".to_owned(),
        voiceprint: None,
        voiceprints: vec![
            vec![1.0, 0.0, 0.0],
            vec![0.98, 0.02, 0.0],
            vec![0.99, 0.01, 0.0],
        ],
        voiceprint_centroid: None,
        voiceprint_threshold: None,
        voiceprint_version: None,
        voiceprint_updated_at: None,
        voice_sample_wav: None,
    };
    store.save_primary_user(&user).expect("save user");

    // 4. Finalize should now succeed.
    let finalize = server
        .route(&CommandEnvelope::new(
            "vp-finalize-ok",
            CommandName::OnboardingVoiceprintFinalize,
            serde_json::json!({}),
        ))
        .expect("finalize");
    assert!(finalize.ok);
    assert_eq!(finalize.payload["accepted"], true);
    assert_eq!(finalize.payload["enrolled"], true);

    let state_after = server
        .route(&CommandEnvelope::new(
            "vp-state-2",
            CommandName::OnboardingVoiceprintGetState,
            serde_json::json!({}),
        ))
        .expect("state after finalize");
    assert_eq!(state_after.payload["enrolled"], true);
    assert_eq!(state_after.payload["enabled"], true);

    // 5. Reset should remove enrollment.
    let reset = server
        .route(&CommandEnvelope::new(
            "vp-reset-1",
            CommandName::OnboardingVoiceprintReset,
            serde_json::json!({}),
        ))
        .expect("reset");
    assert!(reset.ok);
    assert_eq!(reset.payload["accepted"], true);

    let state_after_reset = server
        .route(&CommandEnvelope::new(
            "vp-state-3",
            CommandName::OnboardingVoiceprintGetState,
            serde_json::json!({}),
        ))
        .expect("state after reset");
    assert_eq!(state_after_reset.payload["enrolled"], false);
}
