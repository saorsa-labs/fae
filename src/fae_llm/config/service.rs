//! ConfigService — cached config with validation and partial updates.
//!
//! Provides a thread-safe config service that:
//! - Caches the current config in memory
//! - Validates config on load and update
//! - Supports atomic updates with backup
//! - Offers safe partial update methods for app menu integration

use crate::fae_llm::error::FaeLlmError;
use std::path::PathBuf;
use std::sync::{Arc, RwLock};
use toml_edit::DocumentMut;

use super::persist::{
    backup_config, read_config, read_config_text, write_config_atomic, write_toml_text_atomic,
};
use super::types::{FaeLlmConfig, ToolMode};

/// Thread-safe config service with caching, validation, and persistence.
pub struct ConfigService {
    path: PathBuf,
    cache: Arc<RwLock<FaeLlmConfig>>,
}

impl ConfigService {
    /// Create a new ConfigService for the given config file path.
    ///
    /// The cache is initialized with a default config. Call [`load()`](Self::load)
    /// to populate from disk.
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            cache: Arc::new(RwLock::new(FaeLlmConfig::default())),
        }
    }

    /// Load config from disk, validate it, and cache it.
    ///
    /// # Errors
    /// Returns `FaeLlmError::ConfigError` on read, parse, or validation failure.
    pub fn load(&self) -> Result<FaeLlmConfig, FaeLlmError> {
        let config = read_config(&self.path)?;
        validate_config(&config)?;

        let mut cache = self
            .cache
            .write()
            .map_err(|_| FaeLlmError::ConfigError("config cache lock poisoned".into()))?;
        *cache = config.clone();
        Ok(config)
    }

    /// Force reload config from disk.
    ///
    /// # Errors
    /// Returns `FaeLlmError::ConfigError` on read, parse, or validation failure.
    pub fn reload(&self) -> Result<(), FaeLlmError> {
        self.load().map(|_| ())
    }

    /// Get a clone of the cached config.
    ///
    /// # Errors
    /// Returns `FaeLlmError::ConfigError` if the cache lock is poisoned.
    pub fn get(&self) -> Result<FaeLlmConfig, FaeLlmError> {
        let cache = self
            .cache
            .read()
            .map_err(|_| FaeLlmError::ConfigError("config cache lock poisoned".into()))?;
        Ok(cache.clone())
    }

    /// Update the config using a mutation function.
    ///
    /// The function receives a mutable reference to the config. After mutation:
    /// 1. The new config is validated
    /// 2. The old config is backed up
    /// 3. The new config is written atomically
    /// 4. The cache is updated
    ///
    /// # Errors
    /// Returns `FaeLlmError::ConfigError` on validation, backup, or write failure.
    pub fn update<F>(&self, f: F) -> Result<(), FaeLlmError>
    where
        F: FnOnce(&mut FaeLlmConfig),
    {
        let old_config = self.get()?;
        let mut new_config = old_config.clone();
        f(&mut new_config);
        validate_config(&new_config)?;

        self.persist_round_trip_update(&old_config, &new_config)?;

        let mut cache = self
            .cache
            .write()
            .map_err(|_| FaeLlmError::ConfigError("config cache lock poisoned".into()))?;
        *cache = new_config;
        Ok(())
    }

    fn persist_round_trip_update(
        &self,
        old_config: &FaeLlmConfig,
        new_config: &FaeLlmConfig,
    ) -> Result<(), FaeLlmError> {
        // If the on-disk file was removed, fall back to full atomic write.
        if !self.path.exists() {
            backup_config(&self.path)?;
            return write_config_atomic(&self.path, new_config);
        }

        let raw = read_config_text(&self.path)?;
        let mut doc: DocumentMut = raw.parse().map_err(|e| {
            FaeLlmError::ConfigError(format!(
                "failed to parse config file '{}': {e}",
                self.path.display()
            ))
        })?;

        let old_value = toml::Value::try_from(old_config.clone())
            .map_err(|e| FaeLlmError::ConfigError(format!("failed to convert old config: {e}")))?;
        let new_value = toml::Value::try_from(new_config.clone())
            .map_err(|e| FaeLlmError::ConfigError(format!("failed to convert new config: {e}")))?;

        merge_known_tree(doc.as_item_mut(), Some(&old_value), &new_value)?;

        let merged_text = doc.to_string();
        let merged_config: FaeLlmConfig = toml::from_str(&merged_text).map_err(|e| {
            FaeLlmError::ConfigError(format!(
                "merged config is invalid for '{}': {e}",
                self.path.display()
            ))
        })?;
        validate_config(&merged_config)?;

        backup_config(&self.path)?;
        write_toml_text_atomic(&self.path, &merged_text)
    }

    // ── Partial update methods (Task 6) ──

    /// Set the default provider.
    ///
    /// # Errors
    /// Returns error if the provider ID doesn't exist in the config.
    pub fn set_default_provider(&self, provider_id: &str) -> Result<(), FaeLlmError> {
        let config = self.get()?;
        if !config.providers.contains_key(provider_id) {
            return Err(FaeLlmError::ConfigError(format!(
                "provider '{provider_id}' not found in config"
            )));
        }
        self.update(|c| {
            c.defaults.default_provider = Some(provider_id.to_string());
        })
    }

    /// Set the default model.
    ///
    /// # Errors
    /// Returns error if the model ID doesn't exist in the config.
    pub fn set_default_model(&self, model_id: &str) -> Result<(), FaeLlmError> {
        let config = self.get()?;
        if !config.models.contains_key(model_id) {
            return Err(FaeLlmError::ConfigError(format!(
                "model '{model_id}' not found in config"
            )));
        }
        self.update(|c| {
            c.defaults.default_model = Some(model_id.to_string());
        })
    }

    /// Set the tool execution mode.
    pub fn set_tool_mode(&self, mode: ToolMode) -> Result<(), FaeLlmError> {
        self.update(|c| {
            c.tools.set_mode(mode);
            c.defaults.tool_mode = mode;
        })
    }

    /// Update a provider's configuration.
    ///
    /// Only non-None fields in the update are applied.
    ///
    /// # Errors
    /// Returns error if the provider doesn't exist.
    pub fn update_provider(
        &self,
        provider_id: &str,
        update: ProviderUpdate,
    ) -> Result<(), FaeLlmError> {
        let config = self.get()?;
        if !config.providers.contains_key(provider_id) {
            return Err(FaeLlmError::ConfigError(format!(
                "provider '{provider_id}' not found"
            )));
        }
        self.update(|c| {
            if let Some(provider) = c.providers.get_mut(provider_id) {
                if let Some(base_url) = &update.base_url {
                    provider.base_url = base_url.clone();
                }
                if let Some(api_key) = &update.api_key {
                    provider.api_key = api_key.clone();
                }
            }
        })
    }

    /// Update a model's configuration.
    ///
    /// Only non-None fields in the update are applied.
    ///
    /// # Errors
    /// Returns error if the model doesn't exist.
    pub fn update_model(&self, model_id: &str, update: ModelUpdate) -> Result<(), FaeLlmError> {
        let config = self.get()?;
        if !config.models.contains_key(model_id) {
            return Err(FaeLlmError::ConfigError(format!(
                "model '{model_id}' not found"
            )));
        }
        self.update(|c| {
            if let Some(model) = c.models.get_mut(model_id) {
                if let Some(display_name) = &update.display_name {
                    model.display_name = display_name.clone();
                }
                if let Some(max_tokens) = update.max_tokens {
                    model.max_tokens = max_tokens;
                }
            }
        })
    }
}

/// Partial update for a provider.
#[derive(Debug, Clone, Default)]
pub struct ProviderUpdate {
    /// New base URL (if Some)
    pub base_url: Option<String>,
    /// New API key reference (if Some)
    pub api_key: Option<super::types::SecretRef>,
}

/// Partial update for a model.
#[derive(Debug, Clone, Default)]
pub struct ModelUpdate {
    /// New display name (if Some)
    pub display_name: Option<String>,
    /// New max tokens (if Some)
    pub max_tokens: Option<usize>,
}

/// Validate a config for consistency.
///
/// Checks:
/// - Default provider references a valid provider (if set)
/// - Default model references a valid model (if set)
/// - All provider base_urls are non-empty
///
/// # Errors
/// Returns `FaeLlmError::ConfigError` if validation fails.
pub fn validate_config(config: &FaeLlmConfig) -> Result<(), FaeLlmError> {
    // Check default provider reference
    if let Some(ref provider_id) = config.defaults.default_provider
        && !config.providers.contains_key(provider_id)
    {
        return Err(FaeLlmError::ConfigValidationError(format!(
            "default_provider '{provider_id}' not found in providers"
        )));
    }

    // Check default model reference
    if let Some(ref model_id) = config.defaults.default_model
        && !config.models.contains_key(model_id)
    {
        return Err(FaeLlmError::ConfigValidationError(format!(
            "default_model '{model_id}' not found in models"
        )));
    }

    // Check provider base_urls are non-empty
    for (name, provider) in &config.providers {
        if provider.base_url.is_empty() {
            return Err(FaeLlmError::ConfigValidationError(format!(
                "provider '{name}' has empty base_url"
            )));
        }
    }

    // Check tool names only use the locked v1 set.
    if !config.tools.has_only_known_tool_names() {
        return Err(FaeLlmError::ConfigValidationError(
            "tools config contains unknown tool names; allowed: read, bash, edit, write".into(),
        ));
    }

    Ok(())
}

fn merge_known_tree(
    doc_item: &mut toml_edit::Item,
    old_value: Option<&toml::Value>,
    new_value: &toml::Value,
) -> Result<(), FaeLlmError> {
    match new_value {
        toml::Value::Table(new_table) => {
            if !doc_item.is_table() {
                *doc_item = toml_edit::Item::Table(toml_edit::Table::new());
            }

            let table = doc_item.as_table_mut().ok_or_else(|| {
                FaeLlmError::ConfigError("failed to access TOML table during merge".into())
            })?;
            let old_table = old_value.and_then(toml::Value::as_table);

            for (key, new_child) in new_table {
                let old_child = old_table.and_then(|tbl| tbl.get(key));
                merge_known_tree(&mut table[key], old_child, new_child)?;
            }

            if let Some(old_table) = old_table {
                for key in old_table.keys() {
                    if !new_table.contains_key(key) {
                        table.remove(key);
                    }
                }
            }
        }
        _ => {
            *doc_item = toml_value_to_item(new_value)?;
        }
    }

    Ok(())
}

fn toml_value_to_item(value: &toml::Value) -> Result<toml_edit::Item, FaeLlmError> {
    let parsed: toml_edit::Value = value.to_string().parse().map_err(|e| {
        FaeLlmError::ConfigError(format!("failed to convert TOML value during merge: {e}"))
    })?;
    Ok(toml_edit::Item::Value(parsed))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fae_llm::config::defaults::default_config;
    use crate::fae_llm::config::persist::write_config_atomic;
    use crate::fae_llm::config::types::{EndpointType, ProviderConfig};

    fn make_test_dir() -> tempfile::TempDir {
        match tempfile::tempdir() {
            Ok(d) => d,
            Err(_) => unreachable!("tempdir creation should not fail"),
        }
    }

    fn write_default_config(dir: &tempfile::TempDir) -> PathBuf {
        let path = dir.path().join("config.toml");
        let config = default_config();
        let _ = write_config_atomic(&path, &config);
        path
    }

    #[test]
    fn config_service_load_and_get() {
        let dir = make_test_dir();
        let path = write_default_config(&dir);

        let service = ConfigService::new(path);
        let load_result = service.load();
        assert!(load_result.is_ok());

        let get_result = service.get();
        assert!(get_result.is_ok());
        let config = get_result.unwrap_or_default();
        assert!(config.providers.contains_key("openai"));
    }

    #[test]
    fn config_service_update() {
        let dir = make_test_dir();
        let path = write_default_config(&dir);

        let service = ConfigService::new(path);
        let _ = service.load();

        let result = service.update(|c| {
            c.runtime.request_timeout_secs = 120;
        });
        assert!(result.is_ok());

        let config = service.get().unwrap_or_default();
        assert_eq!(config.runtime.request_timeout_secs, 120);
    }

    #[test]
    fn config_service_set_default_provider() {
        let dir = make_test_dir();
        let path = write_default_config(&dir);

        let service = ConfigService::new(path);
        let _ = service.load();

        let result = service.set_default_provider("openai");
        assert!(result.is_ok());

        let config = service.get().unwrap_or_default();
        assert_eq!(config.defaults.default_provider, Some("openai".to_string()));
    }

    #[test]
    fn config_service_set_default_provider_invalid() {
        let dir = make_test_dir();
        let path = write_default_config(&dir);

        let service = ConfigService::new(path);
        let _ = service.load();

        let result = service.set_default_provider("nonexistent");
        assert!(result.is_err());
    }

    #[test]
    fn config_service_set_default_model() {
        let dir = make_test_dir();
        let path = write_default_config(&dir);

        let service = ConfigService::new(path);
        let _ = service.load();

        let result = service.set_default_model("gpt-4o");
        assert!(result.is_ok());
    }

    #[test]
    fn config_service_set_default_model_invalid() {
        let dir = make_test_dir();
        let path = write_default_config(&dir);

        let service = ConfigService::new(path);
        let _ = service.load();

        let result = service.set_default_model("nonexistent");
        assert!(result.is_err());
    }

    #[test]
    fn config_service_set_tool_mode() {
        let dir = make_test_dir();
        let path = write_default_config(&dir);

        let service = ConfigService::new(path);
        let _ = service.load();

        let result = service.set_tool_mode(ToolMode::Full);
        assert!(result.is_ok());

        let config = service.get().unwrap_or_default();
        assert_eq!(config.defaults.tool_mode, ToolMode::Full);
        assert_eq!(config.tools.mode, ToolMode::Full);
        assert_eq!(
            config.tools.effective_enabled(),
            vec![
                "read".to_string(),
                "bash".to_string(),
                "edit".to_string(),
                "write".to_string()
            ]
        );
    }

    #[test]
    fn config_service_update_provider() {
        let dir = make_test_dir();
        let path = write_default_config(&dir);

        let service = ConfigService::new(path);
        let _ = service.load();

        let result = service.update_provider(
            "openai",
            ProviderUpdate {
                base_url: Some("https://custom.openai.com/v1".to_string()),
                ..Default::default()
            },
        );
        assert!(result.is_ok());

        let config = service.get().unwrap_or_default();
        let provider = &config.providers["openai"];
        assert_eq!(provider.base_url, "https://custom.openai.com/v1");
    }

    #[test]
    fn config_service_update_provider_invalid() {
        let dir = make_test_dir();
        let path = write_default_config(&dir);

        let service = ConfigService::new(path);
        let _ = service.load();

        let result = service.update_provider("nonexistent", ProviderUpdate::default());
        assert!(result.is_err());
    }

    #[test]
    fn validate_config_ok() {
        let config = default_config();
        let result = validate_config(&config);
        assert!(result.is_ok());
    }

    #[test]
    fn validate_config_invalid_default_provider() {
        let mut config = default_config();
        config.defaults.default_provider = Some("nonexistent".to_string());
        let result = validate_config(&config);
        assert!(result.is_err());
    }

    #[test]
    fn validate_config_invalid_default_model() {
        let mut config = default_config();
        config.defaults.default_model = Some("nonexistent".to_string());
        let result = validate_config(&config);
        assert!(result.is_err());
    }

    #[test]
    fn validate_config_empty_base_url() {
        let mut config = default_config();
        if let Some(provider) = config.providers.get_mut("openai") {
            provider.base_url = String::new();
        }
        let result = validate_config(&config);
        assert!(result.is_err());
    }

    #[test]
    fn validate_config_no_defaults() {
        let mut config = FaeLlmConfig::default();
        config.providers.insert(
            "test".to_string(),
            ProviderConfig {
                endpoint_type: EndpointType::Custom,
                enabled: true,
                base_url: "https://example.com".to_string(),
                api_key: super::super::types::SecretRef::None,
                models: Vec::new(),
                compat_profile: None,
                profile: None,
            },
        );
        // No default_provider or default_model set — should be OK
        let result = validate_config(&config);
        assert!(result.is_ok());
    }

    #[test]
    fn validate_config_rejects_unknown_tool_names() {
        let mut config = default_config();
        config.tools.enabled.push("grep".to_string());
        let result = validate_config(&config);
        assert!(result.is_err());
        assert!(matches!(result, Err(FaeLlmError::ConfigValidationError(_))));
    }
}
