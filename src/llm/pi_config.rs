//! Pi models.json configuration writer.
//!
//! Reads, merges, and writes the `~/.pi/agent/models.json` file so that
//! Pi can discover Fae's local LLM server as a provider. Existing providers
//! in the file are preserved — only the `fae-local` entry is added or updated.

use crate::error::{Result, SpeechError};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;
use tracing::info;

/// Provider name used for the Fae local LLM entry.
const FAE_PROVIDER_KEY: &str = "fae-local";

/// Top-level Pi models configuration.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PiModelsConfig {
    /// Map of provider name to provider configuration.
    #[serde(default)]
    pub providers: HashMap<String, PiProvider>,
}

/// A single LLM provider in Pi's models.json.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PiProvider {
    /// Base URL for the provider's API (e.g. `http://127.0.0.1:8080/v1`).
    pub base_url: String,
    /// API type (e.g. `"openai"`).
    pub api: String,
    /// API key (empty for local providers).
    #[serde(default)]
    pub api_key: String,
    /// Available models from this provider.
    #[serde(default)]
    pub models: Vec<PiModel>,
}

/// A single model within a Pi provider.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PiModel {
    /// Model identifier (must match what the API accepts).
    pub id: String,
    /// Human-readable name.
    pub name: String,
    /// Whether the model supports reasoning/thinking mode.
    #[serde(default)]
    pub reasoning: bool,
    /// Input modalities (e.g. `["text"]`).
    #[serde(default)]
    pub input: Vec<String>,
    /// Context window size in tokens.
    #[serde(default)]
    pub context_window: u32,
    /// Maximum output tokens.
    #[serde(default)]
    pub max_tokens: u32,
    /// Cost per token (informational; 0 for local).
    #[serde(default)]
    pub cost: f64,
}

impl PiModelsConfig {
    /// Look up a provider by name.
    pub fn find_provider(&self, name: &str) -> Option<&PiProvider> {
        self.providers.get(name)
    }

    /// Look up a specific model within a provider.
    pub fn find_model(&self, provider: &str, model_id: &str) -> Option<&PiModel> {
        self.providers
            .get(provider)?
            .models
            .iter()
            .find(|m| m.id == model_id)
    }

    /// List all provider names.
    pub fn list_providers(&self) -> Vec<&str> {
        self.providers.keys().map(String::as_str).collect()
    }

    /// Return cloud providers (excludes `fae-local`).
    pub fn cloud_providers(&self) -> Vec<(&str, &PiProvider)> {
        self.providers
            .iter()
            .filter(|(k, _)| k.as_str() != FAE_PROVIDER_KEY)
            .map(|(k, v)| (k.as_str(), v))
            .collect()
    }
}

/// Read the Pi models configuration from disk.
///
/// Returns an empty [`PiModelsConfig`] if the file does not exist.
///
/// # Errors
///
/// Returns an error if the file exists but cannot be read or parsed.
pub fn read_pi_config(path: &Path) -> Result<PiModelsConfig> {
    if !path.exists() {
        return Ok(PiModelsConfig::default());
    }
    let content = std::fs::read_to_string(path)
        .map_err(|e| SpeechError::Config(format!("read pi config: {e}")))?;
    serde_json::from_str(&content).map_err(|e| SpeechError::Config(format!("parse pi config: {e}")))
}

/// Add or update the `fae-local` provider in Pi's models.json.
///
/// Reads the existing config, merges the Fae provider entry, and writes
/// back atomically (write to temp file, then rename).
///
/// # Errors
///
/// Returns an error if the file cannot be read, written, or renamed.
pub fn write_fae_local_provider(path: &Path, port: u16) -> Result<()> {
    let mut config = read_pi_config(path)?;

    let provider = PiProvider {
        base_url: format!("http://127.0.0.1:{port}/v1"),
        api: "openai".to_owned(),
        api_key: String::new(),
        models: vec![PiModel {
            id: "fae-qwen3".to_owned(),
            name: "Fae Local (Qwen 3 4B)".to_owned(),
            reasoning: false,
            input: vec!["text".to_owned()],
            context_window: 32_768,
            max_tokens: 2048,
            cost: 0.0,
        }],
    };

    config
        .providers
        .insert(FAE_PROVIDER_KEY.to_owned(), provider);

    write_config_atomic(path, &config)?;
    info!("wrote fae-local provider to {}", path.display());
    Ok(())
}

/// Remove the `fae-local` provider from Pi's models.json.
///
/// If the provider is not present or the file does not exist, this is a no-op.
///
/// # Errors
///
/// Returns an error if the file cannot be read or written.
pub fn remove_fae_local_provider(path: &Path) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    let mut config = read_pi_config(path)?;
    if config.providers.remove(FAE_PROVIDER_KEY).is_none() {
        return Ok(()); // Nothing to remove
    }
    write_config_atomic(path, &config)?;
    info!("removed fae-local provider from {}", path.display());
    Ok(())
}

/// Write the config to a temporary file and atomically rename it to `path`.
fn write_config_atomic(path: &Path, config: &PiModelsConfig) -> Result<()> {
    // Ensure parent directory exists.
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| SpeechError::Config(format!("create pi config dir: {e}")))?;
    }

    let json = serde_json::to_string_pretty(config)
        .map_err(|e| SpeechError::Config(format!("serialize pi config: {e}")))?;

    // Write to a temp file in the same directory, then rename for atomicity.
    let tmp_path = path.with_extension("json.tmp");
    std::fs::write(&tmp_path, &json)
        .map_err(|e| SpeechError::Config(format!("write pi config tmp: {e}")))?;
    std::fs::rename(&tmp_path, path)
        .map_err(|e| SpeechError::Config(format!("rename pi config: {e}")))?;

    Ok(())
}

/// Returns the default path for Pi's models.json: `~/.pi/agent/models.json`.
pub fn default_pi_models_path() -> Option<std::path::PathBuf> {
    std::env::var_os("HOME").map(|home| {
        std::path::PathBuf::from(home)
            .join(".pi")
            .join("agent")
            .join("models.json")
    })
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;
    use std::path::PathBuf;

    fn temp_path(name: &str) -> PathBuf {
        std::env::temp_dir()
            .join("fae-test-pi-config")
            .join(name)
            .join("models.json")
    }

    fn cleanup(path: &Path) {
        if let Some(parent) = path.parent() {
            let _ = std::fs::remove_dir_all(parent);
        }
    }

    #[test]
    fn read_missing_file_returns_empty() {
        let path = temp_path("read-missing");
        cleanup(&path);
        let config = read_pi_config(&path).unwrap();
        assert!(config.providers.is_empty());
    }

    #[test]
    fn write_and_read_round_trip() {
        let path = temp_path("round-trip");
        cleanup(&path);

        write_fae_local_provider(&path, 8080).unwrap();

        let config = read_pi_config(&path).unwrap();
        assert!(config.providers.contains_key("fae-local"));
        let fae = &config.providers["fae-local"];
        assert_eq!(fae.base_url, "http://127.0.0.1:8080/v1");
        assert_eq!(fae.api, "openai");
        assert!(fae.api_key.is_empty());
        assert_eq!(fae.models.len(), 1);
        assert_eq!(fae.models[0].id, "fae-qwen3");

        cleanup(&path);
    }

    #[test]
    fn write_preserves_existing_providers() {
        let path = temp_path("preserve");
        cleanup(&path);

        // Pre-populate with an existing provider.
        let mut config = PiModelsConfig::default();
        config.providers.insert(
            "ollama".to_owned(),
            PiProvider {
                base_url: "http://localhost:11434/v1".to_owned(),
                api: "openai".to_owned(),
                api_key: String::new(),
                models: vec![PiModel {
                    id: "llama3".to_owned(),
                    name: "Llama 3".to_owned(),
                    reasoning: false,
                    input: vec!["text".to_owned()],
                    context_window: 8192,
                    max_tokens: 4096,
                    cost: 0.0,
                }],
            },
        );
        write_config_atomic(&path, &config).unwrap();

        // Now write fae-local — should preserve ollama.
        write_fae_local_provider(&path, 9090).unwrap();

        let updated = read_pi_config(&path).unwrap();
        assert!(updated.providers.contains_key("ollama"));
        assert!(updated.providers.contains_key("fae-local"));
        assert_eq!(
            updated.providers["ollama"].base_url,
            "http://localhost:11434/v1"
        );
        assert_eq!(
            updated.providers["fae-local"].base_url,
            "http://127.0.0.1:9090/v1"
        );

        cleanup(&path);
    }

    #[test]
    fn remove_fae_local_provider_cleans_up() {
        let path = temp_path("remove");
        cleanup(&path);

        write_fae_local_provider(&path, 8080).unwrap();
        assert!(
            read_pi_config(&path)
                .unwrap()
                .providers
                .contains_key("fae-local")
        );

        remove_fae_local_provider(&path).unwrap();
        assert!(
            !read_pi_config(&path)
                .unwrap()
                .providers
                .contains_key("fae-local")
        );

        cleanup(&path);
    }

    #[test]
    fn remove_nonexistent_is_noop() {
        let path = temp_path("remove-noop");
        cleanup(&path);
        // No file at all — should not error.
        remove_fae_local_provider(&path).unwrap();
    }

    #[test]
    fn write_updates_existing_fae_entry() {
        let path = temp_path("update");
        cleanup(&path);

        write_fae_local_provider(&path, 8080).unwrap();
        write_fae_local_provider(&path, 9999).unwrap();

        let config = read_pi_config(&path).unwrap();
        assert_eq!(
            config.providers["fae-local"].base_url,
            "http://127.0.0.1:9999/v1"
        );

        cleanup(&path);
    }

    #[test]
    fn pi_models_config_serde_round_trip() {
        let config = PiModelsConfig::default();
        let json = serde_json::to_string(&config).unwrap();
        let parsed: PiModelsConfig = serde_json::from_str(&json).unwrap();
        assert!(parsed.providers.is_empty());
    }

    fn sample_config() -> PiModelsConfig {
        let mut config = PiModelsConfig::default();
        config.providers.insert(
            "fae-local".to_owned(),
            PiProvider {
                base_url: "http://127.0.0.1:8080/v1".to_owned(),
                api: "openai".to_owned(),
                api_key: String::new(),
                models: vec![PiModel {
                    id: "fae-qwen3".to_owned(),
                    name: "Fae Local".to_owned(),
                    reasoning: false,
                    input: vec!["text".to_owned()],
                    context_window: 32_768,
                    max_tokens: 2048,
                    cost: 0.0,
                }],
            },
        );
        config.providers.insert(
            "anthropic".to_owned(),
            PiProvider {
                base_url: "https://api.anthropic.com/v1".to_owned(),
                api: "anthropic".to_owned(),
                api_key: "sk-test".to_owned(),
                models: vec![PiModel {
                    id: "claude-3-haiku".to_owned(),
                    name: "Claude 3 Haiku".to_owned(),
                    reasoning: false,
                    input: vec!["text".to_owned()],
                    context_window: 200_000,
                    max_tokens: 4096,
                    cost: 0.001,
                }],
            },
        );
        config
    }

    #[test]
    fn find_provider_returns_some_for_existing() {
        let config = sample_config();
        let p = config.find_provider("anthropic").unwrap();
        assert_eq!(p.api, "anthropic");
    }

    #[test]
    fn find_provider_returns_none_for_missing() {
        let config = sample_config();
        assert!(config.find_provider("nonexistent").is_none());
    }

    #[test]
    fn find_model_returns_some_for_existing() {
        let config = sample_config();
        let m = config.find_model("anthropic", "claude-3-haiku").unwrap();
        assert_eq!(m.name, "Claude 3 Haiku");
    }

    #[test]
    fn find_model_returns_none_for_wrong_model() {
        let config = sample_config();
        assert!(config.find_model("anthropic", "gpt-4").is_none());
    }

    #[test]
    fn find_model_returns_none_for_wrong_provider() {
        let config = sample_config();
        assert!(config.find_model("openai", "claude-3-haiku").is_none());
    }

    #[test]
    fn list_providers_returns_all() {
        let config = sample_config();
        let mut names = config.list_providers();
        names.sort();
        assert_eq!(names, vec!["anthropic", "fae-local"]);
    }

    #[test]
    fn cloud_providers_excludes_fae_local() {
        let config = sample_config();
        let cloud = config.cloud_providers();
        assert_eq!(cloud.len(), 1);
        assert_eq!(cloud[0].0, "anthropic");
    }

    #[test]
    fn cloud_providers_empty_when_only_fae_local() {
        let mut config = PiModelsConfig::default();
        config.providers.insert(
            "fae-local".to_owned(),
            PiProvider {
                base_url: "http://127.0.0.1:8080/v1".to_owned(),
                api: "openai".to_owned(),
                api_key: String::new(),
                models: vec![],
            },
        );
        assert!(config.cloud_providers().is_empty());
    }
}
