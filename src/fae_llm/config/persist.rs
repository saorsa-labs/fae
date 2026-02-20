//! Atomic config file operations.
//!
//! Provides functions for reading, writing, and backing up TOML config files
//! with atomic write guarantees (temp file → fsync → rename).

use crate::fae_llm::error::FaeLlmError;
use std::io::Write;
use std::path::Path;

use super::types::FaeLlmConfig;

/// Read a config file from disk and deserialize it.
///
/// # Errors
/// Returns `FaeLlmError::ConfigError` if the file cannot be read or parsed.
pub fn read_config(path: &Path) -> Result<FaeLlmConfig, FaeLlmError> {
    let contents = read_config_text(path)?;
    toml::from_str(&contents).map_err(|e| {
        FaeLlmError::ConfigError(format!(
            "failed to parse config file '{}': {e}",
            path.display()
        ))
    })
}

/// Read raw TOML config text from disk.
///
/// # Errors
/// Returns `FaeLlmError::ConfigError` if the file cannot be read.
pub fn read_config_text(path: &Path) -> Result<String, FaeLlmError> {
    std::fs::read_to_string(path).map_err(|e| {
        FaeLlmError::ConfigError(format!(
            "failed to read config file '{}': {e}",
            path.display()
        ))
    })
}

/// Write a config file atomically (temp file → fsync → rename).
///
/// This ensures that a crash during write will not corrupt the config file.
///
/// # Errors
/// Returns `FaeLlmError::ConfigError` on serialization, write, or rename failure.
pub fn write_config_atomic(path: &Path, config: &FaeLlmConfig) -> Result<(), FaeLlmError> {
    let toml_str = toml::to_string_pretty(config)
        .map_err(|e| FaeLlmError::ConfigError(format!("failed to serialize config: {e}")))?;
    write_toml_text_atomic(path, &toml_str)
}

/// Write TOML text atomically (temp file → fsync → rename).
///
/// This preserves caller-provided formatting/comments and avoids partial writes.
pub fn write_toml_text_atomic(path: &Path, toml_text: &str) -> Result<(), FaeLlmError> {
    let tmp_path = path.with_extension("toml.tmp");

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| {
            FaeLlmError::ConfigError(format!(
                "failed to create config directory '{}': {e}",
                parent.display()
            ))
        })?;
    }

    let mut file = std::fs::File::create(&tmp_path).map_err(|e| {
        FaeLlmError::ConfigError(format!(
            "failed to create temp file '{}': {e}",
            tmp_path.display()
        ))
    })?;

    file.write_all(toml_text.as_bytes())
        .map_err(|e| FaeLlmError::ConfigError(format!("failed to write temp file: {e}")))?;

    file.sync_all()
        .map_err(|e| FaeLlmError::ConfigError(format!("failed to sync temp file: {e}")))?;

    std::fs::rename(&tmp_path, path).map_err(|e| {
        FaeLlmError::ConfigError(format!(
            "failed to rename '{}' to '{}': {e}",
            tmp_path.display(),
            path.display()
        ))
    })
}

/// Backup a config file by copying it to `{path}.backup`.
///
/// Returns `Ok(())` if the source file doesn't exist (nothing to back up).
///
/// # Errors
/// Returns `FaeLlmError::ConfigError` if the copy fails.
pub fn backup_config(path: &Path) -> Result<(), FaeLlmError> {
    if !path.exists() {
        return Ok(());
    }

    let backup_path = path.with_extension("toml.backup");
    std::fs::copy(path, &backup_path).map_err(|e| {
        FaeLlmError::ConfigError(format!(
            "failed to backup config '{}' to '{}': {e}",
            path.display(),
            backup_path.display()
        ))
    })?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fae_llm::config::types::{EndpointType, ProviderConfig, SecretRef};

    fn make_test_dir() -> tempfile::TempDir {
        match tempfile::tempdir() {
            Ok(d) => d,
            Err(_) => unreachable!("tempdir creation should not fail"),
        }
    }

    #[test]
    fn write_and_read_config() {
        let dir = make_test_dir();
        let path = dir.path().join("config.toml");

        let mut config = FaeLlmConfig::default();
        config.providers.insert(
            "openai".to_string(),
            ProviderConfig {
                endpoint_type: EndpointType::OpenAI,
                enabled: true,
                base_url: "https://api.openai.com/v1".to_string(),
                api_key: SecretRef::Env {
                    var: "OPENAI_API_KEY".to_string(),
                },
                models: vec!["gpt-4o".to_string()],
            },
        );
        config.runtime.request_timeout_secs = 60;

        let write_result = write_config_atomic(&path, &config);
        assert!(write_result.is_ok());
        assert!(path.exists());

        let read_result = read_config(&path);
        assert!(read_result.is_ok());
        let loaded = read_result.unwrap_or_default();
        assert_eq!(loaded.providers.len(), 1);
        assert!(loaded.providers.contains_key("openai"));
        assert_eq!(loaded.runtime.request_timeout_secs, 60);
    }

    #[test]
    fn write_atomic_creates_file() {
        let dir = make_test_dir();
        let path = dir.path().join("new_config.toml");

        assert!(!path.exists());
        let result = write_config_atomic(&path, &FaeLlmConfig::default());
        assert!(result.is_ok());
        assert!(path.exists());
    }

    #[test]
    fn read_config_not_found() {
        let result = read_config(Path::new("/tmp/nonexistent_fae_llm_config_test.toml"));
        assert!(result.is_err());
    }

    #[test]
    fn read_config_invalid_toml() {
        let dir = make_test_dir();
        let path = dir.path().join("bad.toml");
        std::fs::write(&path, "{{{{not valid toml!!!!").unwrap_or_default();
        let result = read_config(&path);
        assert!(result.is_err());
    }

    #[test]
    fn backup_config_creates_backup() {
        let dir = make_test_dir();
        let path = dir.path().join("config.toml");

        let config = FaeLlmConfig::default();
        let _ = write_config_atomic(&path, &config);

        let result = backup_config(&path);
        assert!(result.is_ok());

        let backup_path = path.with_extension("toml.backup");
        assert!(backup_path.exists());

        let backup_result = read_config(&backup_path);
        assert!(backup_result.is_ok());
    }

    #[test]
    fn backup_config_missing_source() {
        let result = backup_config(Path::new("/tmp/nonexistent_fae_llm_backup_test.toml"));
        assert!(result.is_ok());
    }
}
