//! Default configuration generation.
//!
//! Provides a sensible default config for first-run scenarios.

use crate::fae_llm::error::FaeLlmError;
use std::path::Path;

use super::persist::write_config_atomic;
use super::types::{
    DefaultsConfig, EndpointType, FaeLlmConfig, ProviderConfig, RuntimeConfig, SecretRef,
    ToolConfig, ToolMode,
};

/// Generate a default configuration with local embedded provider and tools.
///
/// Includes:
/// - Local embedded provider (downloaded GGUF models)
/// - All 4 tools enabled (read, bash, edit, write)
/// - Tool mode: read_only (safe default)
/// - Reasonable timeouts (30s, 3 retries)
pub fn default_config() -> FaeLlmConfig {
    let mut config = FaeLlmConfig::default();

    // Local embedded provider
    config.providers.insert(
        "local".to_string(),
        ProviderConfig {
            endpoint_type: EndpointType::Local,
            enabled: true,
            base_url: String::new(),
            api_key: SecretRef::None,
            models: Vec::new(),
        },
    );

    // Tools
    for name in &["read", "bash", "edit", "write"] {
        config.tools.insert(
            name.to_string(),
            ToolConfig {
                name: String::new(),
                enabled: true,
                options: std::collections::HashMap::new(),
            },
        );
    }
    config.tools.set_mode(ToolMode::ReadOnly);

    // Defaults
    config.defaults = DefaultsConfig {
        default_provider: Some("local".to_string()),
        default_model: None,
        tool_mode: ToolMode::ReadOnly,
        reasoning: crate::fae_llm::types::ReasoningLevel::Off,
    };

    // Runtime
    config.runtime = RuntimeConfig::default();

    config
}

/// Create a default config file if one doesn't already exist.
///
/// # Errors
/// Returns `FaeLlmError::ConfigError` if the file cannot be written.
pub fn ensure_config_exists(path: &Path) -> Result<(), FaeLlmError> {
    if path.exists() {
        return Ok(());
    }

    // Create parent directories if needed
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| {
            FaeLlmError::ConfigError(format!(
                "failed to create config directory '{}': {e}",
                parent.display()
            ))
        })?;
    }

    let config = default_config();
    write_config_atomic(path, &config)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_test_dir() -> tempfile::TempDir {
        match tempfile::tempdir() {
            Ok(d) => d,
            Err(_) => unreachable!("tempdir creation should not fail"),
        }
    }

    #[test]
    fn default_config_has_local_provider() {
        let config = default_config();
        assert!(config.providers.contains_key("local"));
        assert_eq!(config.providers.len(), 1);
    }

    #[test]
    fn default_config_has_tools() {
        let config = default_config();
        assert_eq!(config.tools.len(), 4);
        for name in &["read", "bash", "edit", "write"] {
            assert!(config.tools.contains_key(name));
            let tool = &config.tools[name];
            assert!(tool.enabled);
        }
    }

    #[test]
    fn default_config_safe_defaults() {
        let config = default_config();
        assert_eq!(config.defaults.tool_mode, ToolMode::ReadOnly);
        assert_eq!(config.defaults.default_provider, Some("local".to_string()));
    }

    #[test]
    fn default_config_runtime_settings() {
        let config = default_config();
        assert_eq!(config.runtime.request_timeout_secs, 30);
        assert_eq!(config.runtime.max_retries, 3);
        assert_eq!(config.runtime.log_level, "info");
    }

    #[test]
    fn default_config_serializes_to_toml() {
        let config = default_config();
        let result = toml::to_string_pretty(&config);
        assert!(result.is_ok());
        let toml_str = result.unwrap_or_default();
        assert!(toml_str.contains("[providers."));
        assert!(toml_str.contains("[tools."));
        assert!(toml_str.contains("[defaults]"));
        assert!(toml_str.contains("[runtime]"));
    }

    #[test]
    fn ensure_config_exists_creates_file() {
        let dir = make_test_dir();
        let path = dir.path().join("subdir").join("config.toml");

        assert!(!path.exists());
        let result = ensure_config_exists(&path);
        assert!(result.is_ok());
        assert!(path.exists());
    }

    #[test]
    fn ensure_config_exists_does_not_overwrite() {
        let dir = make_test_dir();
        let path = dir.path().join("config.toml");

        // Write a minimal config
        std::fs::write(&path, "[runtime]\nrequest_timeout_secs = 99\n").unwrap_or_default();

        let result = ensure_config_exists(&path);
        assert!(result.is_ok());

        // Should not be overwritten
        let contents = std::fs::read_to_string(&path).unwrap_or_default();
        assert!(contents.contains("99"));
    }
}
