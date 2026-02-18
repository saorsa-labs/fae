//! Integration tests: permission store + config serialization round-trips.

use fae::config::SpeechConfig;
use fae::permissions::{PermissionKind, PermissionStore};

#[test]
fn config_with_permissions_roundtrips_via_toml() {
    let mut config = SpeechConfig::default();
    config.permissions.grant(PermissionKind::Microphone);
    config.permissions.grant(PermissionKind::Contacts);
    config.permissions.deny(PermissionKind::Calendar);
    config.onboarded = true;

    let toml_str = toml::to_string(&config).expect("serialize to TOML");
    let restored: SpeechConfig = toml::from_str(&toml_str).expect("deserialize from TOML");

    assert!(restored.permissions.is_granted(PermissionKind::Microphone));
    assert!(restored.permissions.is_granted(PermissionKind::Contacts));
    assert!(!restored.permissions.is_granted(PermissionKind::Calendar));
    assert!(restored.onboarded);
}

#[test]
fn config_without_permissions_section_deserializes() {
    // Minimal TOML — no [permissions] section at all.
    let toml_str = "";
    let config: SpeechConfig = toml::from_str(toml_str).expect("deserialize empty TOML");

    assert!(config.permissions.grants.is_empty());
    assert!(!config.onboarded);
}

#[test]
fn onboarded_flag_defaults_false() {
    let config = SpeechConfig::default();
    assert!(!config.onboarded, "onboarded should default to false");
}

#[test]
fn onboarded_flag_roundtrips() {
    let config = SpeechConfig {
        onboarded: true,
        ..Default::default()
    };

    let toml_str = toml::to_string(&config).expect("serialize");
    let restored: SpeechConfig = toml::from_str(&toml_str).expect("deserialize");
    assert!(restored.onboarded);
}

#[test]
fn permission_store_serde_json_roundtrip() {
    let mut store = PermissionStore::default();
    store.grant(PermissionKind::Microphone);
    store.grant(PermissionKind::Files);
    store.deny(PermissionKind::Location);

    let json = serde_json::to_string(&store).expect("serialize to JSON");
    let restored: PermissionStore = serde_json::from_str(&json).expect("deserialize from JSON");

    assert!(restored.is_granted(PermissionKind::Microphone));
    assert!(restored.is_granted(PermissionKind::Files));
    assert!(!restored.is_granted(PermissionKind::Location));
}
