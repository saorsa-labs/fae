//! Configuration system for the fae_llm module.
//!
//! Provides TOML-based configuration with:
//! - Multi-provider support (OpenAI, Anthropic, local endpoints, etc.)
//! - Secret resolution (env vars, literals, commands, keychain)
//! - Atomic persistence with backup
//! - Round-trip editing (preserves comments and unknown fields)
//! - Safe partial updates for app menu integration
//! - Default config generation for first-run
//!
//! # Architecture
//!
//! The config module is organized into layers:
//!
//! - **types** — Schema structs (`FaeLlmConfig`, `ProviderConfig`, etc.)
//! - **persist** — Atomic file I/O (`read_config`, `write_config_atomic`, `backup_config`)
//! - **editor** — Round-trip TOML editing via `toml_edit` (`ConfigEditor`)
//! - **service** — Thread-safe config cache with validation (`ConfigService`)
//! - **defaults** — Default config generation for first-run
//!
//! # Quick Start
//!
//! ```
//! use fae::fae_llm::config::{default_config, validate_config};
//!
//! let config = default_config();
//! assert!(validate_config(&config).is_ok());
//! assert!(config.providers.contains_key("openai"));
//! ```

pub mod defaults;
pub mod editor;
pub mod persist;
pub mod service;
pub mod types;

pub use defaults::{default_config, ensure_config_exists};
pub use editor::ConfigEditor;
pub use persist::{backup_config, read_config, write_config_atomic};
pub use service::{ConfigService, ModelUpdate, ProviderUpdate, validate_config};
pub use types::{
    DefaultsConfig, FaeLlmConfig, ModelConfig, ModelTier, ProviderConfig, RuntimeConfig, SecretRef,
    ToolConfig, ToolMode,
};

#[cfg(test)]
mod integration_tests {
    use super::*;

    fn make_test_dir() -> tempfile::TempDir {
        match tempfile::tempdir() {
            Ok(d) => d,
            Err(_) => unreachable!("tempdir creation should not fail"),
        }
    }

    // ── Full config lifecycle ────────────────────────────────────

    /// Create default → write → reload → update → verify round-trip.
    #[test]
    fn full_config_lifecycle() {
        let dir = make_test_dir();
        let path = dir.path().join("config.toml");

        // Create default and write
        let config = default_config();
        let write_result = write_config_atomic(&path, &config);
        assert!(write_result.is_ok());

        // Load via ConfigService
        let service = ConfigService::new(path.clone());
        let load_result = service.load();
        assert!(load_result.is_ok());

        // Verify loaded config matches default
        let loaded = service.get().unwrap_or_default();
        assert!(loaded.providers.contains_key("openai"));
        assert!(loaded.providers.contains_key("anthropic"));
        assert!(loaded.providers.contains_key("local"));
        assert_eq!(loaded.defaults.tool_mode, ToolMode::ReadOnly);

        // Update timeout and tool mode
        let update_result = service.update(|c| {
            c.runtime.request_timeout_secs = 120;
        });
        assert!(update_result.is_ok());

        let mode_result = service.set_tool_mode(ToolMode::Full);
        assert!(mode_result.is_ok());

        // Reload from disk — verify persistence
        let service2 = ConfigService::new(path);
        let reload_result = service2.load();
        assert!(reload_result.is_ok());
        let reloaded = service2.get().unwrap_or_default();
        assert_eq!(reloaded.runtime.request_timeout_secs, 120);
        assert_eq!(reloaded.defaults.tool_mode, ToolMode::Full);
    }

    // ── ensure_config_exists lifecycle ───────────────────────────

    /// ensure_config_exists creates default on missing, then ConfigService loads it.
    #[test]
    fn ensure_config_exists_lifecycle() {
        let dir = make_test_dir();
        let path = dir.path().join("subdir").join("config.toml");

        // File doesn't exist yet
        assert!(!path.exists());

        let ensure_result = ensure_config_exists(&path);
        assert!(ensure_result.is_ok());
        assert!(path.exists());

        // Load and validate
        let service = ConfigService::new(path.clone());
        let load_result = service.load();
        assert!(load_result.is_ok());

        let config = service.get().unwrap_or_default();
        assert!(config.providers.contains_key("openai"));

        // Calling again doesn't overwrite
        let _ = service.update(|c| {
            c.runtime.request_timeout_secs = 999;
        });
        let ensure2 = ensure_config_exists(&path);
        assert!(ensure2.is_ok());

        let service2 = ConfigService::new(path);
        let _ = service2.load();
        let config2 = service2.get().unwrap_or_default();
        assert_eq!(config2.runtime.request_timeout_secs, 999);
    }

    // ── Secret resolution ───────────────────────────────────────

    /// Secret resolution works for env vars and literals.
    #[test]
    fn secret_resolution_integration() {
        // None returns Ok(None)
        let none_secret = SecretRef::None;
        let result = none_secret.resolve();
        assert!(result.is_ok());
        assert!(result.unwrap_or(Some("bad".into())).is_none());

        // Literal returns the value
        let literal = SecretRef::Literal {
            value: "sk-test-123".to_string(),
        };
        let result = literal.resolve();
        assert!(result.is_ok());
        assert_eq!(result.unwrap_or(None), Some("sk-test-123".to_string()));

        // Env with set variable
        unsafe { std::env::set_var("FAE_INTEGRATION_SECRET_TEST", "env-value-42") };
        let env_secret = SecretRef::Env {
            var: "FAE_INTEGRATION_SECRET_TEST".to_string(),
        };
        let result = env_secret.resolve();
        assert!(result.is_ok());
        assert_eq!(result.unwrap_or(None), Some("env-value-42".to_string()));
        unsafe { std::env::remove_var("FAE_INTEGRATION_SECRET_TEST") };

        // Env with missing variable
        unsafe { std::env::remove_var("FAE_INTEGRATION_MISSING_VAR") };
        let missing = SecretRef::Env {
            var: "FAE_INTEGRATION_MISSING_VAR".to_string(),
        };
        assert!(missing.resolve().is_err());

        // Command returns error (not enabled)
        let cmd = SecretRef::Command {
            cmd: "echo secret".to_string(),
        };
        assert!(cmd.resolve().is_err());

        // Keychain returns error (not implemented)
        let keychain = SecretRef::Keychain {
            service: "fae".to_string(),
            account: "test".to_string(),
        };
        assert!(keychain.resolve().is_err());
    }

    // ── Validation errors ───────────────────────────────────────

    /// Validation catches invalid provider references.
    #[test]
    fn validation_catches_invalid_references() {
        // Invalid default provider
        let mut config = default_config();
        config.defaults.default_provider = Some("nonexistent".to_string());
        assert!(validate_config(&config).is_err());

        // Invalid default model
        let mut config = default_config();
        config.defaults.default_model = Some("nonexistent".to_string());
        assert!(validate_config(&config).is_err());

        // Empty base URL
        let mut config = default_config();
        if let Some(provider) = config.providers.get_mut("openai") {
            provider.base_url = String::new();
        }
        assert!(validate_config(&config).is_err());

        // Valid references
        let mut config = default_config();
        config.defaults.default_provider = Some("openai".to_string());
        config.defaults.default_model = Some("gpt-4o".to_string());
        assert!(validate_config(&config).is_ok());
    }

    // ── Partial update API ──────────────────────────────────────

    /// Partial updates validate and persist correctly.
    #[test]
    fn partial_update_api_integration() {
        let dir = make_test_dir();
        let path = dir.path().join("config.toml");
        let config = default_config();
        let _ = write_config_atomic(&path, &config);

        let service = ConfigService::new(path.clone());
        let _ = service.load();

        // Set default provider
        assert!(service.set_default_provider("openai").is_ok());
        let c = service.get().unwrap_or_default();
        assert_eq!(c.defaults.default_provider, Some("openai".to_string()));

        // Set default model
        assert!(service.set_default_model("gpt-4o").is_ok());
        let c = service.get().unwrap_or_default();
        assert_eq!(c.defaults.default_model, Some("gpt-4o".to_string()));

        // Invalid provider/model rejected
        assert!(service.set_default_provider("fake").is_err());
        assert!(service.set_default_model("fake").is_err());

        // Update provider URL
        let update = ProviderUpdate {
            base_url: Some("https://custom.openai.com/v1".to_string()),
            ..Default::default()
        };
        assert!(service.update_provider("openai", update).is_ok());

        // Persist and reload verification
        let service2 = ConfigService::new(path);
        let _ = service2.load();
        let c2 = service2.get().unwrap_or_default();
        assert_eq!(
            c2.providers["openai"].base_url,
            "https://custom.openai.com/v1"
        );
        assert_eq!(c2.defaults.default_provider, Some("openai".to_string()));
    }

    // ── Atomic write and backup ─────────────────────────────────

    /// Backup config is created and can be recovered.
    #[test]
    fn atomic_write_with_backup_recovery() {
        let dir = make_test_dir();
        let path = dir.path().join("config.toml");

        // Write initial config
        let config = default_config();
        let _ = write_config_atomic(&path, &config);
        assert!(path.exists());

        // Create backup
        let backup_result = backup_config(&path);
        assert!(backup_result.is_ok());

        let backup_path = path.with_extension("toml.backup");
        assert!(backup_path.exists());

        // Modify the original
        let mut modified = config.clone();
        modified.runtime.request_timeout_secs = 999;
        let _ = write_config_atomic(&path, &modified);

        // Read both to verify they differ
        let current = read_config(&path).unwrap_or_default();
        let backup = read_config(&backup_path).unwrap_or_default();
        assert_eq!(current.runtime.request_timeout_secs, 999);
        assert_eq!(backup.runtime.request_timeout_secs, 30);

        // Recover from backup (simulate restore)
        std::fs::copy(&backup_path, &path).unwrap_or_default();
        let recovered = read_config(&path).unwrap_or_default();
        assert_eq!(recovered.runtime.request_timeout_secs, 30);
    }

    // ── Round-trip editing ──────────────────────────────────────

    /// ConfigEditor preserves comments during round-trip editing.
    #[test]
    fn round_trip_editor_preserves_comments() {
        let dir = make_test_dir();
        let path = dir.path().join("config.toml");

        let content = r#"# FAE LLM Configuration
# This comment should be preserved

[runtime]
# Timeout in seconds
request_timeout_secs = 30
max_retries = 3
log_level = "info"

[defaults]
tool_mode = "read_only"
"#;
        std::fs::write(&path, content).unwrap_or_default();

        let editor = ConfigEditor::load(&path);
        assert!(editor.is_ok());
        let mut editor = match editor {
            Ok(e) => e,
            Err(_) => unreachable!("editor load should succeed"),
        };

        // Modify a value
        let _ = editor.set_integer("runtime.request_timeout_secs", 60);

        // Verify comments preserved
        let output = editor.to_toml_string();
        assert!(output.contains("# FAE LLM Configuration"));
        assert!(output.contains("# This comment should be preserved"));
        assert!(output.contains("# Timeout in seconds"));
        assert!(output.contains("60"));
        assert!(!output.contains("= 30"));

        // Save and reload
        let _ = editor.save();
        let editor2 = ConfigEditor::load(&path);
        assert!(editor2.is_ok());
        let editor2 = match editor2 {
            Ok(e) => e,
            Err(_) => unreachable!("editor reload should succeed"),
        };
        let val = editor2.get_integer("runtime.request_timeout_secs");
        assert_eq!(val.unwrap_or(0), 60);
    }

    // ── TOML serialization round-trip ───────────────────────────

    /// Full config survives TOML serialization and deserialization.
    #[test]
    fn config_toml_round_trip() {
        let config = default_config();

        // Serialize
        let toml_str = toml::to_string(&config).unwrap_or_default();
        assert!(!toml_str.is_empty());
        assert!(toml_str.contains("[providers.openai]"));
        assert!(toml_str.contains("[models.gpt-4o]"));

        // Deserialize
        let parsed: FaeLlmConfig = toml::from_str(&toml_str).unwrap_or_default();
        assert_eq!(parsed.providers.len(), config.providers.len());
        assert_eq!(parsed.models.len(), config.models.len());
        assert_eq!(parsed.tools.len(), config.tools.len());
        assert_eq!(
            parsed.runtime.request_timeout_secs,
            config.runtime.request_timeout_secs
        );
    }

    // ── Model tiers ─────────────────────────────────────────────

    /// All model tiers serialize/deserialize correctly in config context.
    #[test]
    fn model_tier_in_config_context() {
        let tiers = [ModelTier::Fast, ModelTier::Balanced, ModelTier::Reasoning];
        for tier in &tiers {
            let model = ModelConfig {
                model_id: "test".to_string(),
                display_name: "Test".to_string(),
                tier: *tier,
                max_tokens: 4096,
            };
            let json = serde_json::to_string(&model).unwrap_or_default();
            let parsed: serde_json::Value = serde_json::from_str(&json).unwrap_or_default();
            assert!(parsed.get("tier").is_some());
        }
    }
}
