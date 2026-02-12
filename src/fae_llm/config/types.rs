//! Configuration schema types for fae_llm.
//!
//! Defines the TOML configuration structure including providers, models,
//! tools, defaults, and runtime settings.

pub use crate::fae_llm::types::EndpointType;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Root configuration struct for fae_llm.
///
/// This is the top-level structure deserialized from the TOML config file.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct FaeLlmConfig {
    /// Provider configurations (OpenAI, Anthropic, local, etc.)
    #[serde(default)]
    pub providers: HashMap<String, ProviderConfig>,

    /// Model configurations
    #[serde(default)]
    pub models: HashMap<String, ModelConfig>,

    /// Tool configurations
    #[serde(default)]
    pub tools: HashMap<String, ToolConfig>,

    /// Default provider and model settings
    #[serde(default)]
    pub defaults: DefaultsConfig,

    /// Runtime settings (timeouts, retries, logging)
    #[serde(default)]
    pub runtime: RuntimeConfig,
}

/// Configuration for a single LLM provider.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderConfig {
    /// Type of endpoint (OpenAI, Anthropic, Local, Custom)
    pub endpoint_type: EndpointType,

    /// Base URL for the provider API
    pub base_url: String,

    /// API key (secret reference)
    #[serde(default)]
    pub api_key: SecretRef,

    /// List of model IDs available from this provider
    #[serde(default)]
    pub models: Vec<String>,
}

/// Configuration for a single model.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelConfig {
    /// Model identifier (e.g. "gpt-4o", "claude-opus-4")
    pub model_id: String,

    /// Human-readable display name
    pub display_name: String,

    /// Model tier (fast, balanced, reasoning)
    pub tier: ModelTier,

    /// Maximum tokens this model can generate
    pub max_tokens: usize,
}

/// Model performance tier.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ModelTier {
    /// Fast, lightweight models
    Fast,
    /// Balanced performance/quality
    Balanced,
    /// High-quality reasoning models
    Reasoning,
}

/// Configuration for a single tool.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ToolConfig {
    /// Tool name (read, bash, edit, write)
    pub name: String,

    /// Whether this tool is enabled
    #[serde(default = "default_true")]
    pub enabled: bool,

    /// Tool-specific options (arbitrary key-value pairs)
    #[serde(default)]
    pub options: HashMap<String, toml::Value>,
}

fn default_true() -> bool {
    true
}

/// Default provider and model settings.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DefaultsConfig {
    /// Default provider ID to use
    pub default_provider: Option<String>,

    /// Default model ID to use
    pub default_model: Option<String>,

    /// Tool execution mode (read_only or full)
    #[serde(default)]
    pub tool_mode: ToolMode,
}

impl Default for DefaultsConfig {
    fn default() -> Self {
        Self {
            default_provider: None,
            default_model: None,
            tool_mode: ToolMode::ReadOnly,
        }
    }
}

/// Tool execution mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolMode {
    /// Read-only mode (no mutations allowed)
    #[default]
    ReadOnly,
    /// Full mode (all tools enabled)
    Full,
}

/// Runtime configuration settings.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RuntimeConfig {
    /// Request timeout in seconds
    #[serde(default = "default_request_timeout")]
    pub request_timeout_secs: u64,

    /// Maximum number of retries for failed requests
    #[serde(default = "default_max_retries")]
    pub max_retries: u32,

    /// Log level (trace, debug, info, warn, error)
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

impl Default for RuntimeConfig {
    fn default() -> Self {
        Self {
            request_timeout_secs: default_request_timeout(),
            max_retries: default_max_retries(),
            log_level: default_log_level(),
        }
    }
}

/// Reference to a secret value.
///
/// Secrets can be:
/// - Not required (None)
/// - Loaded from environment variable (Env)
/// - Hardcoded literal (Literal) - for development only
/// - Executed from command (Command) - feature-gated, off by default
/// - Retrieved from system keychain (Keychain) - not yet implemented
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum SecretRef {
    /// No secret required
    #[default]
    None,
    /// Load from environment variable
    Env { var: String },
    /// Literal value (development only, insecure)
    Literal { value: String },
    /// Execute command to get value (feature-gated)
    Command { cmd: String },
    /// Retrieve from system keychain (not yet implemented)
    Keychain { service: String, account: String },
}

impl SecretRef {
    /// Resolve the secret to its actual value.
    ///
    /// # Returns
    /// - `Ok(None)` if no secret is configured (variant `None`)
    /// - `Ok(Some(value))` for successfully resolved secrets
    /// - `Err(FaeLlmError::ConfigError)` for resolution failures
    pub fn resolve(&self) -> Result<Option<String>, crate::fae_llm::error::FaeLlmError> {
        match self {
            Self::None => Ok(None),
            Self::Env { var } => std::env::var(var).map(Some).map_err(|_| {
                crate::fae_llm::error::FaeLlmError::ConfigError(format!(
                    "environment variable '{var}' not set"
                ))
            }),
            Self::Literal { value } => Ok(Some(value.clone())),
            Self::Command { .. } => Err(crate::fae_llm::error::FaeLlmError::ConfigError(
                "command-based secret resolution is not enabled".into(),
            )),
            Self::Keychain { .. } => Err(crate::fae_llm::error::FaeLlmError::ConfigError(
                "keychain-based secret resolution is not yet implemented".into(),
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fae_llm_config_default() {
        let config = FaeLlmConfig::default();
        assert!(config.providers.is_empty());
        assert!(config.models.is_empty());
        assert!(config.tools.is_empty());
        assert_eq!(config.defaults.tool_mode, ToolMode::ReadOnly);
        assert_eq!(config.runtime.request_timeout_secs, 30);
    }

    #[test]
    fn provider_config_construction() {
        let provider = ProviderConfig {
            endpoint_type: EndpointType::OpenAI,
            base_url: "https://api.openai.com/v1".to_string(),
            api_key: SecretRef::Env {
                var: "OPENAI_API_KEY".to_string(),
            },
            models: vec!["gpt-4o".to_string()],
        };
        assert_eq!(provider.endpoint_type, EndpointType::OpenAI);
        assert_eq!(provider.models.len(), 1);
    }

    #[test]
    fn model_config_construction() {
        let model = ModelConfig {
            model_id: "gpt-4o".to_string(),
            display_name: "GPT-4o".to_string(),
            tier: ModelTier::Balanced,
            max_tokens: 4096,
        };
        assert_eq!(model.model_id, "gpt-4o");
        assert_eq!(model.tier, ModelTier::Balanced);
        assert_eq!(model.max_tokens, 4096);
    }

    #[test]
    fn tool_config_construction() {
        let tool = ToolConfig {
            name: "read".to_string(),
            enabled: true,
            options: HashMap::new(),
        };
        assert_eq!(tool.name, "read");
        assert!(tool.enabled);
    }

    #[test]
    fn defaults_config_default() {
        let defaults = DefaultsConfig::default();
        assert!(defaults.default_provider.is_none());
        assert!(defaults.default_model.is_none());
        assert_eq!(defaults.tool_mode, ToolMode::ReadOnly);
    }

    #[test]
    fn runtime_config_default() {
        let runtime = RuntimeConfig::default();
        assert_eq!(runtime.request_timeout_secs, 30);
        assert_eq!(runtime.max_retries, 3);
        assert_eq!(runtime.log_level, "info");
    }

    #[test]
    fn secret_ref_none() {
        let secret = SecretRef::None;
        assert_eq!(secret, SecretRef::None);
    }

    #[test]
    fn secret_ref_env() {
        let secret = SecretRef::Env {
            var: "MY_KEY".to_string(),
        };
        match secret {
            SecretRef::Env { var } => assert_eq!(var, "MY_KEY"),
            _ => unreachable!("Expected Env variant"),
        }
    }

    #[test]
    fn secret_ref_literal() {
        let secret = SecretRef::Literal {
            value: "sk-test".to_string(),
        };
        match secret {
            SecretRef::Literal { value } => assert_eq!(value, "sk-test"),
            _ => unreachable!("Expected Literal variant"),
        }
    }

    #[test]
    fn secret_ref_command() {
        let secret = SecretRef::Command {
            cmd: "echo secret".to_string(),
        };
        match secret {
            SecretRef::Command { cmd } => assert_eq!(cmd, "echo secret"),
            _ => unreachable!("Expected Command variant"),
        }
    }

    #[test]
    fn secret_ref_keychain() {
        let secret = SecretRef::Keychain {
            service: "fae".to_string(),
            account: "openai".to_string(),
        };
        match secret {
            SecretRef::Keychain { service, account } => {
                assert_eq!(service, "fae");
                assert_eq!(account, "openai");
            }
            _ => unreachable!("Expected Keychain variant"),
        }
    }

    #[test]
    fn model_tier_serde_round_trip() {
        let tier = ModelTier::Fast;
        let json = serde_json::to_string(&tier).unwrap_or_default();
        assert_eq!(json, "\"fast\"");
        let parsed: ModelTier = serde_json::from_str(&json).unwrap_or(ModelTier::Balanced);
        assert_eq!(parsed, ModelTier::Fast);
    }

    #[test]
    fn tool_mode_serde_round_trip() {
        let mode = ToolMode::Full;
        let json = serde_json::to_string(&mode).unwrap_or_default();
        assert_eq!(json, "\"full\"");
        let parsed: ToolMode = serde_json::from_str(&json).unwrap_or(ToolMode::ReadOnly);
        assert_eq!(parsed, ToolMode::Full);
    }

    #[test]
    fn secret_ref_default_is_none() {
        let secret = SecretRef::default();
        assert_eq!(secret, SecretRef::None);
    }

    // ── SecretRef::resolve ──────────────────────────────────────

    #[test]
    fn secret_ref_resolve_none() {
        let secret = SecretRef::None;
        let result = secret.resolve();
        assert!(result.is_ok());
        assert!(result.unwrap_or(Some("bad".into())).is_none());
    }

    #[test]
    fn secret_ref_resolve_env_existing() {
        // SAFETY: tests run serially for env var mutation
        unsafe { std::env::set_var("FAE_TEST_SECRET_RESOLVE_OK", "test-value-42") };
        let secret = SecretRef::Env {
            var: "FAE_TEST_SECRET_RESOLVE_OK".to_string(),
        };
        let result = secret.resolve();
        assert!(result.is_ok());
        assert_eq!(result.unwrap_or(None), Some("test-value-42".to_string()));
        unsafe { std::env::remove_var("FAE_TEST_SECRET_RESOLVE_OK") };
    }

    #[test]
    fn secret_ref_resolve_env_missing() {
        unsafe { std::env::remove_var("FAE_TEST_SECRET_RESOLVE_MISS") };
        let secret = SecretRef::Env {
            var: "FAE_TEST_SECRET_RESOLVE_MISS".to_string(),
        };
        let result = secret.resolve();
        assert!(result.is_err());
    }

    #[test]
    fn secret_ref_resolve_literal() {
        let secret = SecretRef::Literal {
            value: "sk-test-key".to_string(),
        };
        let result = secret.resolve();
        assert!(result.is_ok());
        assert_eq!(result.unwrap_or(None), Some("sk-test-key".to_string()));
    }

    #[test]
    fn secret_ref_resolve_command_not_allowed() {
        let secret = SecretRef::Command {
            cmd: "echo secret".to_string(),
        };
        let result = secret.resolve();
        assert!(result.is_err());
    }

    #[test]
    fn secret_ref_resolve_keychain_not_implemented() {
        let secret = SecretRef::Keychain {
            service: "fae".to_string(),
            account: "openai".to_string(),
        };
        let result = secret.resolve();
        assert!(result.is_err());
    }

    // ── Config TOML round-trip ──────────────────────────────────

    #[test]
    fn fae_llm_config_serde_round_trip() {
        let mut config = FaeLlmConfig::default();
        config.providers.insert(
            "openai".to_string(),
            ProviderConfig {
                endpoint_type: EndpointType::OpenAI,
                base_url: "https://api.openai.com/v1".to_string(),
                api_key: SecretRef::Env {
                    var: "OPENAI_API_KEY".to_string(),
                },
                models: vec!["gpt-4o".to_string()],
            },
        );

        let toml_str = toml::to_string(&config).unwrap_or_default();
        assert!(toml_str.contains("[providers.openai]"));

        let parsed: FaeLlmConfig = toml::from_str(&toml_str).unwrap_or_default();
        assert_eq!(parsed.providers.len(), 1);
        assert!(parsed.providers.contains_key("openai"));
    }
}
