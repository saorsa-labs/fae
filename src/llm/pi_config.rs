//! Pi `models.json` configuration integration.
//!
//! Pi discovers custom model providers via `~/.pi/agent/models.json` (see Pi docs:
//! `packages/coding-agent/docs/models.md` in pi-mono).
//!
//! Fae uses this file for two things:
//! 1. Register `fae-local` so Pi can use Fae's local OpenAI-compatible HTTP server.
//! 2. Resolve cloud providers when `cloud_provider` is set in `LlmConfig`.
//!
//! Important: The schema is **camelCase** (baseUrl/apiKey/contextWindow/maxTokens).

use crate::error::{Result, SpeechError};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;
use tracing::info;

/// Provider name used for the Fae local LLM entry.
pub const FAE_PROVIDER_KEY: &str = "fae-local";

/// Model ID exposed by Fae's local OpenAI-compatible HTTP server.
pub const FAE_MODEL_ID: &str = "fae-qwen3";

/// Top-level Pi models configuration.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PiModelsConfig {
    /// Map of provider name to provider configuration.
    #[serde(default)]
    pub providers: HashMap<String, PiProvider>,

    /// Preserve unknown top-level keys on round-trip (future-proofing).
    #[serde(default, flatten)]
    pub extra: HashMap<String, serde_json::Value>,
}

/// A single provider entry in Pi's `models.json`.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PiProvider {
    /// Base URL for the provider's API (e.g. `http://127.0.0.1:8080/v1`).
    #[serde(rename = "baseUrl")]
    pub base_url: Option<String>,

    /// API key (required by Pi when defining custom models; local servers may ignore it).
    #[serde(rename = "apiKey")]
    pub api_key: Option<String>,

    /// API type (e.g. `"openai-completions"`).
    #[serde(default)]
    pub api: Option<String>,

    /// Optional custom headers.
    #[serde(default)]
    pub headers: Option<HashMap<String, String>>,

    /// If true, Pi adds `Authorization: Bearer <apiKey>` automatically.
    #[serde(rename = "authHeader", default)]
    pub auth_header: Option<bool>,

    /// Custom model definitions (when present, Pi treats this provider as a "full replacement").
    #[serde(default)]
    pub models: Option<Vec<PiModel>>,

    /// Preserve unknown provider keys on round-trip.
    #[serde(default, flatten)]
    pub extra: HashMap<String, serde_json::Value>,
}

/// Cost configuration in Pi models.json (per million tokens).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PiCost {
    pub input: f64,
    pub output: f64,
    #[serde(rename = "cacheRead")]
    pub cache_read: f64,
    #[serde(rename = "cacheWrite")]
    pub cache_write: f64,
}

/// A single model definition in Pi models.json.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PiModel {
    pub id: String,

    #[serde(default)]
    pub name: Option<String>,

    /// Override provider `api` for this model.
    #[serde(default)]
    pub api: Option<String>,

    #[serde(default)]
    pub reasoning: Option<bool>,

    /// Input modalities: `["text"]` or `["text", "image"]`.
    #[serde(default)]
    pub input: Option<Vec<String>>,

    #[serde(rename = "contextWindow", default)]
    pub context_window: Option<u32>,

    #[serde(rename = "maxTokens", default)]
    pub max_tokens: Option<u32>,

    #[serde(default)]
    pub cost: Option<PiCost>,

    #[serde(default)]
    pub headers: Option<HashMap<String, String>>,

    /// OpenAI compatibility config (free-form JSON; Pi validates it).
    #[serde(default)]
    pub compat: Option<serde_json::Value>,

    /// User-defined selection priority within the same capability tier.
    ///
    /// Higher values are preferred. When two models share a [`ModelTier`],
    /// the one with the higher priority is tried first.  Defaults to `0`
    /// when absent from `models.json`.
    ///
    /// [`ModelTier`]: crate::model_tier::ModelTier
    #[serde(default)]
    pub priority: Option<i32>,

    /// Preserve unknown model keys on round-trip.
    #[serde(default, flatten)]
    pub extra: HashMap<String, serde_json::Value>,
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
            .as_ref()?
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

    /// Return provider names sorted alphabetically.
    pub fn provider_names(&self) -> Vec<String> {
        let mut names: Vec<String> = self.providers.keys().cloned().collect();
        names.sort();
        names
    }

    /// Return model IDs for a provider, sorted alphabetically.
    pub fn model_ids_for_provider(&self, provider: &str) -> Vec<String> {
        let mut ids = self
            .providers
            .get(provider)
            .and_then(|p| p.models.as_ref())
            .map(|models| models.iter().map(|m| m.id.clone()).collect::<Vec<_>>())
            .unwrap_or_default();
        ids.sort();
        ids.dedup();
        ids
    }

    /// Return all configured provider/model pairs, sorted by provider then model.
    pub fn provider_model_pairs(&self) -> Vec<(String, String)> {
        let mut pairs = Vec::new();
        for provider in self.provider_names() {
            for model in self.model_ids_for_provider(&provider) {
                pairs.push((provider.clone(), model));
            }
        }
        pairs
    }
}

/// Read the Pi models configuration from disk.
///
/// Returns an empty [`PiModelsConfig`] if the file does not exist.
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
pub fn write_fae_local_provider(path: &Path, port: u16) -> Result<()> {
    let mut config = read_pi_config(path)?;

    let provider = PiProvider {
        base_url: Some(format!("http://127.0.0.1:{port}/v1")),
        api: Some("openai-completions".to_owned()),
        api_key: Some("fae-local".to_owned()), // required by Pi when models are defined
        models: Some(vec![PiModel {
            id: FAE_MODEL_ID.to_owned(),
            name: Some("Fae Local (Qwen 3 4B)".to_owned()),
            api: None,
            reasoning: Some(false),
            input: Some(vec!["text".to_owned()]),
            context_window: Some(32_768),
            max_tokens: Some(2048),
            cost: Some(PiCost {
                input: 0.0,
                output: 0.0,
                cache_read: 0.0,
                cache_write: 0.0,
            }),
            headers: None,
            compat: Some(serde_json::json!({
                // Pi's OpenAI client requests usage in streaming by default; our server
                // does not emit usage in SSE chunks, so disable the request.
                "supportsUsageInStreaming": false,
                // Fae's server accepts `max_tokens`.
                "maxTokensField": "max_tokens"
            })),
            priority: None,
            extra: HashMap::new(),
        }]),
        headers: None,
        auth_header: None,
        extra: HashMap::new(),
    };

    config
        .providers
        .insert(FAE_PROVIDER_KEY.to_owned(), provider);

    write_config_atomic(path, &config)?;
    info!("wrote {FAE_PROVIDER_KEY} provider to {}", path.display());
    Ok(())
}

/// Remove the `fae-local` provider from Pi's models.json.
///
/// If the provider is not present or the file does not exist, this is a no-op.
pub fn remove_fae_local_provider(path: &Path) -> Result<()> {
    if !path.exists() {
        return Ok(());
    }
    let mut config = read_pi_config(path)?;
    if config.providers.remove(FAE_PROVIDER_KEY).is_none() {
        return Ok(());
    }
    write_config_atomic(path, &config)?;
    info!(
        "removed {FAE_PROVIDER_KEY} provider from {}",
        path.display()
    );
    Ok(())
}

/// Write the config to a temporary file and atomically rename it to `path`.
fn write_config_atomic(path: &Path, config: &PiModelsConfig) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| SpeechError::Config(format!("create pi config dir: {e}")))?;
    }

    let json = serde_json::to_string_pretty(config)
        .map_err(|e| SpeechError::Config(format!("serialize pi config: {e}")))?;

    let tmp_path = path.with_extension("json.tmp");
    std::fs::write(&tmp_path, &json)
        .map_err(|e| SpeechError::Config(format!("write pi config tmp: {e}")))?;
    std::fs::rename(&tmp_path, path)
        .map_err(|e| SpeechError::Config(format!("rename pi config: {e}")))?;

    // Restrict permissions — models.json may contain API keys.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let perms = std::fs::Permissions::from_mode(0o600);
        let _ = std::fs::set_permissions(path, perms);
    }

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
        assert!(config.providers.contains_key(FAE_PROVIDER_KEY));
        let fae = &config.providers[FAE_PROVIDER_KEY];
        assert_eq!(fae.base_url.as_deref(), Some("http://127.0.0.1:8080/v1"));
        assert_eq!(fae.api.as_deref(), Some("openai-completions"));
        assert_eq!(fae.api_key.as_deref(), Some("fae-local"));
        let models = fae.models.as_ref().unwrap();
        assert_eq!(models.len(), 1);
        assert_eq!(models[0].id, FAE_MODEL_ID);

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
                base_url: Some("http://localhost:11434/v1".to_owned()),
                api: Some("openai-completions".to_owned()),
                api_key: Some("ollama".to_owned()),
                models: Some(vec![PiModel {
                    id: "llama3".to_owned(),
                    name: Some("Llama 3".to_owned()),
                    api: None,
                    reasoning: Some(false),
                    input: Some(vec!["text".to_owned()]),
                    context_window: Some(8192),
                    max_tokens: Some(2048),
                    cost: None,
                    headers: None,
                    compat: None,
                    priority: None,
                    extra: HashMap::new(),
                }]),
                headers: None,
                auth_header: None,
                extra: HashMap::new(),
            },
        );
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, serde_json::to_string_pretty(&config).unwrap()).unwrap();

        write_fae_local_provider(&path, 9090).unwrap();

        let updated = read_pi_config(&path).unwrap();
        assert!(updated.providers.contains_key("ollama"));
        assert!(updated.providers.contains_key(FAE_PROVIDER_KEY));
        assert_eq!(
            updated.providers[FAE_PROVIDER_KEY].base_url.as_deref(),
            Some("http://127.0.0.1:9090/v1")
        );

        cleanup(&path);
    }

    #[test]
    fn remove_fae_local_provider_cleans_up() {
        let path = temp_path("remove");
        cleanup(&path);

        write_fae_local_provider(&path, 8080).unwrap();
        remove_fae_local_provider(&path).unwrap();

        let config = read_pi_config(&path).unwrap();
        assert!(!config.providers.contains_key(FAE_PROVIDER_KEY));
        cleanup(&path);
    }

    #[test]
    fn provider_helpers_return_sorted_values() {
        let mut config = PiModelsConfig::default();
        config.providers.insert(
            "zeta".to_owned(),
            PiProvider {
                models: Some(vec![
                    PiModel {
                        id: "m2".to_owned(),
                        name: None,
                        api: None,
                        reasoning: None,
                        input: None,
                        context_window: None,
                        max_tokens: None,
                        cost: None,
                        headers: None,
                        compat: None,
                        priority: None,
                        extra: HashMap::new(),
                    },
                    PiModel {
                        id: "m1".to_owned(),
                        name: None,
                        api: None,
                        reasoning: None,
                        input: None,
                        context_window: None,
                        max_tokens: None,
                        cost: None,
                        headers: None,
                        compat: None,
                        priority: None,
                        extra: HashMap::new(),
                    },
                ]),
                ..PiProvider::default()
            },
        );
        config.providers.insert(
            "alpha".to_owned(),
            PiProvider {
                models: Some(vec![PiModel {
                    id: "a1".to_owned(),
                    name: None,
                    api: None,
                    reasoning: None,
                    input: None,
                    context_window: None,
                    max_tokens: None,
                    cost: None,
                    headers: None,
                    compat: None,
                    priority: None,
                    extra: HashMap::new(),
                }]),
                ..PiProvider::default()
            },
        );

        assert_eq!(
            config.provider_names(),
            vec!["alpha".to_owned(), "zeta".to_owned()]
        );
        assert_eq!(
            config.model_ids_for_provider("zeta"),
            vec!["m1".to_owned(), "m2".to_owned()]
        );
        assert_eq!(
            config.provider_model_pairs(),
            vec![
                ("alpha".to_owned(), "a1".to_owned()),
                ("zeta".to_owned(), "m1".to_owned()),
                ("zeta".to_owned(), "m2".to_owned())
            ]
        );
    }
}
