//! Configuration schema types for fae_llm.
//!
//! Defines the TOML configuration structure including providers, models,
//! defaults, runtime settings, and locked tool-mode behavior.

use crate::fae_llm::providers::profile::CompatibilityProfile;
pub use crate::fae_llm::types::EndpointType;
use crate::fae_llm::types::ReasoningLevel;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Config schema version.
pub const CONFIG_VERSION_V1: u32 = 1;

/// Locked built-in tool names for v1.
pub const DEFAULT_TOOL_NAMES: [&str; 4] = ["read", "bash", "edit", "write"];

/// Root configuration struct for fae_llm.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FaeLlmConfig {
    /// Schema version.
    #[serde(default = "default_config_version")]
    pub config_version: u32,

    /// Provider configurations (OpenAI, Anthropic, local, etc.)
    #[serde(default)]
    pub providers: HashMap<String, ProviderConfig>,

    /// Model configurations.
    #[serde(default)]
    pub models: HashMap<String, ModelConfig>,

    /// Tool execution configuration.
    #[serde(default)]
    pub tools: ToolsConfig,

    /// Default provider/model settings.
    #[serde(default)]
    pub defaults: DefaultsConfig,

    /// Runtime settings.
    #[serde(default)]
    pub runtime: RuntimeConfig,
}

fn default_config_version() -> u32 {
    CONFIG_VERSION_V1
}

impl Default for FaeLlmConfig {
    fn default() -> Self {
        Self {
            config_version: default_config_version(),
            providers: HashMap::new(),
            models: HashMap::new(),
            tools: ToolsConfig::default(),
            defaults: DefaultsConfig::default(),
            runtime: RuntimeConfig::default(),
        }
    }
}

/// Configuration for a single LLM provider.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderConfig {
    /// Type of endpoint (OpenAI, Anthropic, Local, Custom).
    pub endpoint_type: EndpointType,

    /// Whether this provider is available for selection.
    #[serde(default = "default_true")]
    pub enabled: bool,

    /// Base URL for provider API.
    pub base_url: String,

    /// API key (secret reference).
    #[serde(default)]
    pub api_key: SecretRef,

    /// Provider-advertised model IDs.
    #[serde(default)]
    pub models: Vec<String>,

    /// Optional compatibility profile name for OpenAI-compatible providers.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub compat_profile: Option<String>,

    /// Optional resolved compatibility profile object.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub profile: Option<CompatibilityProfile>,
}

/// Configuration for a single model.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelConfig {
    /// Model identifier (e.g. `"gpt-4o"`, `"claude-opus-4"`).
    pub model_id: String,

    /// Human-readable display name.
    pub display_name: String,

    /// Model tier (fast, balanced, reasoning).
    pub tier: ModelTier,

    /// Maximum generated tokens.
    pub max_tokens: usize,
}

/// Model performance tier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ModelTier {
    /// Fast, lightweight models.
    Fast,
    /// Balanced performance/quality.
    Balanced,
    /// High-quality reasoning models.
    Reasoning,
}

/// Tool execution mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolMode {
    /// `read_only`: effective tools are exactly `["read"]`.
    #[default]
    ReadOnly,
    /// `full`: effective tools are exactly `["read", "bash", "edit", "write"]`.
    Full,
}

impl ToolMode {
    /// Locked effective tool set for this mode.
    pub fn effective_tool_names(self) -> &'static [&'static str] {
        match self {
            Self::ReadOnly => &["read"],
            Self::Full => &DEFAULT_TOOL_NAMES,
        }
    }

    /// Whether the provided tool name is allowed in this mode.
    pub fn allows_tool(self, name: &str) -> bool {
        self.effective_tool_names().contains(&name)
    }
}

/// Tool-specific configuration entry.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolConfig {
    /// Optional legacy name field.
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub name: String,

    /// Whether this individual tool is enabled.
    #[serde(default = "default_true")]
    pub enabled: bool,

    /// Tool-specific options (arbitrary key-value pairs).
    #[serde(default, flatten)]
    pub options: HashMap<String, toml::Value>,
}

impl Default for ToolConfig {
    fn default() -> Self {
        Self {
            name: String::new(),
            enabled: true,
            options: HashMap::new(),
        }
    }
}

fn default_true() -> bool {
    true
}

/// Root tool configuration block (`[tools]`).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolsConfig {
    /// Tool mode (`read_only` or `full`).
    #[serde(default)]
    pub mode: ToolMode,

    /// Explicitly enabled tool names.
    ///
    /// Effective tools are still determined by `mode`.
    #[serde(default)]
    pub enabled: Vec<String>,

    /// Per-tool entries (e.g. `[tools.read]`).
    #[serde(default, flatten)]
    entries: HashMap<String, ToolConfig>,
}

impl Default for ToolsConfig {
    fn default() -> Self {
        Self {
            mode: ToolMode::ReadOnly,
            enabled: vec!["read".to_string()],
            entries: HashMap::new(),
        }
    }
}

impl ToolsConfig {
    /// Set mode and synchronize `enabled` to the locked effective tool set.
    pub fn set_mode(&mut self, mode: ToolMode) {
        self.mode = mode;
        self.enabled = mode
            .effective_tool_names()
            .iter()
            .map(|n| (*n).to_string())
            .collect();
    }

    /// Effective tool names based on locked mode rules.
    pub fn effective_enabled(&self) -> Vec<String> {
        self.mode
            .effective_tool_names()
            .iter()
            .map(|n| (*n).to_string())
            .collect()
    }

    /// Returns true if this config references only locked tool names.
    pub fn has_only_known_tool_names(&self) -> bool {
        self.enabled
            .iter()
            .all(|n| DEFAULT_TOOL_NAMES.contains(&n.as_str()))
            && self
                .entries
                .keys()
                .all(|n| DEFAULT_TOOL_NAMES.contains(&n.as_str()))
    }

    /// Legacy-compatible map-like insert.
    pub fn insert(&mut self, key: String, value: ToolConfig) -> Option<ToolConfig> {
        self.entries.insert(key, value)
    }

    /// Legacy-compatible contains check.
    pub fn contains_key(&self, key: &str) -> bool {
        self.entries.contains_key(key)
    }

    /// Legacy-compatible getter.
    pub fn get(&self, key: &str) -> Option<&ToolConfig> {
        self.entries.get(key)
    }

    /// Legacy-compatible mutable getter.
    pub fn get_mut(&mut self, key: &str) -> Option<&mut ToolConfig> {
        self.entries.get_mut(key)
    }

    /// Number of tool entries.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Whether there are no tool entries.
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Iterate keys.
    pub fn keys(&self) -> impl Iterator<Item = &String> {
        self.entries.keys()
    }
}

impl std::ops::Index<&str> for ToolsConfig {
    type Output = ToolConfig;

    fn index(&self, index: &str) -> &Self::Output {
        &self.entries[index]
    }
}

/// Default provider/model settings.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DefaultsConfig {
    /// Default provider ID to use.
    #[serde(default, alias = "provider_id")]
    pub default_provider: Option<String>,

    /// Default model ID to use.
    #[serde(default, alias = "model_id")]
    pub default_model: Option<String>,

    /// Default reasoning level.
    #[serde(default)]
    pub reasoning: ReasoningLevel,

    /// Legacy tool mode field; synchronized with `[tools].mode` by service updates.
    #[serde(default)]
    pub tool_mode: ToolMode,
}

impl Default for DefaultsConfig {
    fn default() -> Self {
        Self {
            default_provider: None,
            default_model: None,
            reasoning: ReasoningLevel::Off,
            tool_mode: ToolMode::ReadOnly,
        }
    }
}

/// Local runtime mode (v1 locked to probe-only).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum LocalMode {
    /// Probe endpoint health/status only.
    #[default]
    ProbeOnly,
}

/// Runtime configuration settings.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuntimeConfig {
    /// Local runtime mode.
    #[serde(default)]
    pub local_mode: LocalMode,

    /// Local health-check timeout in milliseconds.
    #[serde(default = "default_health_check_timeout_ms")]
    pub health_check_timeout_ms: u64,

    /// Request timeout in seconds.
    #[serde(default = "default_request_timeout")]
    pub request_timeout_secs: u64,

    /// Maximum request retries.
    #[serde(default = "default_max_retries")]
    pub max_retries: u32,

    /// Log level (trace/debug/info/warn/error).
    #[serde(default = "default_log_level")]
    pub log_level: String,
}

fn default_request_timeout() -> u64 {
    30
}

fn default_max_retries() -> u32 {
    3
}

fn default_log_level() -> String {
    "info".to_string()
}

fn default_health_check_timeout_ms() -> u64 {
    2_000
}

impl Default for RuntimeConfig {
    fn default() -> Self {
        Self {
            local_mode: LocalMode::ProbeOnly,
            health_check_timeout_ms: default_health_check_timeout_ms(),
            request_timeout_secs: default_request_timeout(),
            max_retries: default_max_retries(),
            log_level: default_log_level(),
        }
    }
}

/// Reference to a secret value.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum SecretRef {
    /// No secret required.
    #[default]
    None,
    /// Load from environment variable.
    Env { var: String },
    /// Literal value (dev only).
    Literal { value: String },
    /// Execute command to get value (disabled by default).
    Command { cmd: String },
    /// Retrieve from keychain.
    Keychain { service: String, account: String },
}

impl SecretRef {
    /// Resolve secret material.
    pub fn resolve(&self) -> Result<Option<String>, crate::fae_llm::error::FaeLlmError> {
        match self {
            Self::None => Ok(None),
            Self::Env { var } => std::env::var(var).map(Some).map_err(|_| {
                crate::fae_llm::error::FaeLlmError::SecretResolutionError(format!(
                    "environment variable '{var}' not set"
                ))
            }),
            Self::Literal { value } => Ok(Some(value.clone())),
            Self::Command { .. } => Err(crate::fae_llm::error::FaeLlmError::SecretResolutionError(
                "command-based secret resolution is not enabled".into(),
            )),
            Self::Keychain { .. } => {
                Err(crate::fae_llm::error::FaeLlmError::SecretResolutionError(
                    "keychain-based secret resolution is not yet implemented".into(),
                ))
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fae_llm_config_default_has_version_and_probe_mode() {
        let config = FaeLlmConfig::default();
        assert_eq!(config.config_version, CONFIG_VERSION_V1);
        assert_eq!(config.runtime.local_mode, LocalMode::ProbeOnly);
        assert_eq!(config.runtime.health_check_timeout_ms, 2_000);
    }

    #[test]
    fn tool_mode_effective_sets_are_locked() {
        assert_eq!(ToolMode::ReadOnly.effective_tool_names(), &["read"]);
        assert_eq!(
            ToolMode::Full.effective_tool_names(),
            &["read", "bash", "edit", "write"]
        );
    }

    #[test]
    fn tools_config_mode_syncs_enabled_list() {
        let mut tools = ToolsConfig::default();
        assert_eq!(tools.enabled, vec!["read".to_string()]);

        tools.set_mode(ToolMode::Full);
        assert_eq!(
            tools.enabled,
            vec![
                "read".to_string(),
                "bash".to_string(),
                "edit".to_string(),
                "write".to_string()
            ]
        );
    }

    #[test]
    fn tools_config_legacy_map_api() {
        let mut tools = ToolsConfig::default();
        tools.insert(
            "read".to_string(),
            ToolConfig {
                name: "read".to_string(),
                enabled: true,
                options: HashMap::new(),
            },
        );

        assert_eq!(tools.len(), 1);
        assert!(tools.contains_key("read"));
        assert!(tools["read"].enabled);
    }

    #[test]
    fn defaults_config_supports_reasoning_and_legacy_fields() {
        let defaults = DefaultsConfig::default();
        assert_eq!(defaults.reasoning, ReasoningLevel::Off);
        assert_eq!(defaults.tool_mode, ToolMode::ReadOnly);
    }

    #[test]
    fn secret_ref_resolve_uses_secret_resolution_error_variant() {
        unsafe { std::env::remove_var("FAE_TEST_SECRET_RESOLVE_MISS") };
        let secret = SecretRef::Env {
            var: "FAE_TEST_SECRET_RESOLVE_MISS".to_string(),
        };
        let result = secret.resolve();
        assert!(matches!(
            result,
            Err(crate::fae_llm::error::FaeLlmError::SecretResolutionError(_))
        ));
    }
}
