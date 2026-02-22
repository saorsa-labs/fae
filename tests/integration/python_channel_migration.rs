//! Integration tests for the channel migration to Python skill adapters.
//!
//! Validates that:
//! - Channel skill templates install correctly
//! - ChannelSkillAdapter implements ChannelAdapter
//! - Host commands for channel skill management work
//! - Channel validation still functions after migration

use fae::channels::register_skill_channel;
use fae::channels::skill_adapter::ChannelSkillAdapter;
use fae::channels::traits::ChannelAdapter;
use fae::channels::validate_config;
use fae::config::{ChannelsConfig, DiscordChannelConfig, SpeechConfig};
use fae::skills::channel_templates::{ChannelType, available_channel_types, install_channel_skill};

// ── Template installation ────────────────────────────────────────────────────

#[test]
fn install_discord_channel_skill_end_to_end() {
    let dir = tempfile::tempdir().expect("tempdir");
    let python_dir = dir.path().join("skills");
    std::fs::create_dir_all(&python_dir).unwrap();
    std::fs::create_dir_all(python_dir.join(".state")).unwrap();

    let info = install_channel_skill(ChannelType::Discord, &python_dir).expect("install");
    assert_eq!(info.id, "channel-discord");

    // Verify files were created
    let skill_dir = python_dir.join("channel-discord");
    assert!(skill_dir.join("manifest.toml").is_file());
    assert!(skill_dir.join("skill.py").is_file());

    // Verify manifest content
    let manifest = std::fs::read_to_string(skill_dir.join("manifest.toml")).unwrap();
    assert!(manifest.contains("id = \"channel-discord\""));
    assert!(manifest.contains("DISCORD_BOT_TOKEN"));

    // Verify script content
    let script = std::fs::read_to_string(skill_dir.join("skill.py")).unwrap();
    assert!(script.contains("skill.handshake"));
    assert!(script.contains("skill.invoke"));
    assert!(script.contains("discord.com"));
}

#[test]
fn install_whatsapp_channel_skill_end_to_end() {
    let dir = tempfile::tempdir().expect("tempdir");
    let python_dir = dir.path().join("skills");
    std::fs::create_dir_all(&python_dir).unwrap();
    std::fs::create_dir_all(python_dir.join(".state")).unwrap();

    let info = install_channel_skill(ChannelType::WhatsApp, &python_dir).expect("install");
    assert_eq!(info.id, "channel-whatsapp");

    let skill_dir = python_dir.join("channel-whatsapp");
    let script = std::fs::read_to_string(skill_dir.join("skill.py")).unwrap();
    assert!(script.contains("webhook_verify"));
    assert!(script.contains("graph.facebook.com"));
}

// ── Skill adapter trait ──────────────────────────────────────────────────────

#[test]
fn skill_adapter_implements_channel_adapter_trait() {
    let adapter = ChannelSkillAdapter::new(ChannelType::Discord);
    // ChannelAdapter requires id(), send(), run(), health_check()
    assert_eq!(adapter.id(), "discord");
    assert_eq!(adapter.skill_id(), "channel-discord");
}

#[test]
fn register_skill_channel_returns_valid_adapter() {
    let (id, adapter) = register_skill_channel(ChannelType::WhatsApp);
    assert_eq!(id, "whatsapp");
    assert_eq!(adapter.id(), "whatsapp");
}

#[tokio::test]
async fn skill_adapter_send_succeeds() {
    let adapter = ChannelSkillAdapter::new(ChannelType::Discord);
    let msg = fae::channels::traits::ChannelOutboundMessage {
        reply_target: "123".to_owned(),
        text: "test".to_owned(),
    };
    // Currently a stub that logs and returns Ok
    adapter.send(msg).await.expect("send should not fail");
}

#[tokio::test]
async fn skill_adapter_health_check_returns_true() {
    let adapter = ChannelSkillAdapter::new(ChannelType::WhatsApp);
    let healthy = adapter.health_check().await.expect("health check");
    assert!(healthy);
}

// ── Host commands ────────────────────────────────────────────────────────────

#[test]
fn host_command_skill_channel_install() {
    use fae::host::channel::{NoopDeviceTransferHandler, command_channel};
    use fae::host::contract::{CommandEnvelope, CommandName};

    let handler = NoopDeviceTransferHandler;
    let (_client, server) = command_channel(8, 8, handler);

    let envelope = CommandEnvelope::new(
        "test-1",
        CommandName::SkillChannelInstall,
        serde_json::json!({"channel_type": "discord"}),
    );

    // NoopDeviceTransferHandler returns "not_implemented", which is fine.
    // We're testing that the command routes correctly.
    let resp = server.route(&envelope).expect("should not error");
    assert!(resp.ok);
}

#[test]
fn host_command_skill_channel_list() {
    use fae::host::channel::{NoopDeviceTransferHandler, command_channel};
    use fae::host::contract::{CommandEnvelope, CommandName};

    let handler = NoopDeviceTransferHandler;
    let (_client, server) = command_channel(8, 8, handler);

    let envelope = CommandEnvelope::new(
        "test-2",
        CommandName::SkillChannelList,
        serde_json::json!({}),
    );

    let resp = server.route(&envelope).expect("should not error");
    assert!(resp.ok);
}

#[test]
fn host_command_skill_channel_install_missing_type_returns_error() {
    use fae::host::channel::{NoopDeviceTransferHandler, command_channel};
    use fae::host::contract::{CommandEnvelope, CommandName};

    let handler = NoopDeviceTransferHandler;
    let (_client, server) = command_channel(8, 8, handler);

    let envelope = CommandEnvelope::new(
        "test-3",
        CommandName::SkillChannelInstall,
        serde_json::json!({}),
    );

    let resp = server.route(&envelope);
    assert!(resp.is_err(), "missing channel_type should return error");
}

// ── Validation after migration ───────────────────────────────────────────────

#[test]
fn validation_still_flags_missing_discord_token_after_migration() {
    let config = SpeechConfig {
        channels: ChannelsConfig {
            enabled: true,
            auto_start: true,
            inbound_queue_size: 128,
            gateway: Default::default(),
            discord: Some(DiscordChannelConfig::default()),
            whatsapp: None,
            rate_limits: Default::default(),
            extensions: Vec::new(),
        },
        ..Default::default()
    };

    let issues = validate_config(&config);
    assert!(
        issues.iter().any(|i| i.id == "discord-missing-token"),
        "should still flag missing discord token"
    );
}

#[test]
fn available_channel_types_returns_both() {
    let types = available_channel_types();
    assert_eq!(types.len(), 2);
    assert!(types.contains(&ChannelType::Discord));
    assert!(types.contains(&ChannelType::WhatsApp));
}
