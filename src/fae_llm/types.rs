//! Core domain types for the fae_llm module.
//!
//! Provides fundamental types used across the module:
//! - [`EndpointType`] — identifies the provider endpoint contract
//! - [`ModelRef`] — references a provider/model selection
//! - [`ReasoningLevel`] — controls thinking/reasoning output
//! - [`RequestOptions`] — configures request behavior and headers

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fmt;

/// The provider endpoint contract being targeted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum EndpointType {
    /// OpenAI-compatible chat/completions endpoint.
    #[serde(alias = "openai")]
    #[default]
    OpenAiCompletions,
    /// OpenAI Responses endpoint.
    OpenAiResponses,
    /// Anthropic Messages endpoint.
    #[serde(alias = "anthropic")]
    AnthropicMessages,
    /// Local endpoint profile.
    Local,
    /// Custom provider-specific endpoint.
    Custom,
}

impl EndpointType {
    #[allow(non_upper_case_globals)]
    /// Back-compat alias for `OpenAiCompletions`.
    pub const OpenAI: Self = Self::OpenAiCompletions;

    #[allow(non_upper_case_globals)]
    /// Back-compat alias for `AnthropicMessages`.
    pub const Anthropic: Self = Self::AnthropicMessages;
}

impl fmt::Display for EndpointType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::OpenAiCompletions => write!(f, "openai_completions"),
            Self::OpenAiResponses => write!(f, "openai_responses"),
            Self::AnthropicMessages => write!(f, "anthropic_messages"),
            Self::Local => write!(f, "local"),
            Self::Custom => write!(f, "custom"),
        }
    }
}

/// A reference to a provider+model selection.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ModelRef {
    /// Provider identifier (e.g. `"openai"`, `"anthropic"`, `"fae-local"`).
    #[serde(default = "default_provider_id")]
    pub provider_id: String,
    /// Provider-specific model ID.
    pub model_id: String,
    /// Endpoint contract for this model.
    #[serde(default)]
    pub endpoint_type: EndpointType,
    /// Base URL used for this model/provider.
    #[serde(default)]
    pub base_url: String,
    /// Optional model snapshot/version.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<String>,
}

fn default_provider_id() -> String {
    "unknown".to_string()
}

impl ModelRef {
    /// Create a new model reference with safe defaults.
    pub fn new(model_id: impl Into<String>) -> Self {
        Self {
            provider_id: default_provider_id(),
            model_id: model_id.into(),
            endpoint_type: EndpointType::OpenAiCompletions,
            base_url: String::new(),
            version: None,
        }
    }

    /// Set the provider identifier.
    pub fn with_provider(mut self, provider_id: impl Into<String>) -> Self {
        self.provider_id = provider_id.into();
        self
    }

    /// Set the endpoint contract.
    pub fn with_endpoint_type(mut self, endpoint_type: EndpointType) -> Self {
        self.endpoint_type = endpoint_type;
        self
    }

    /// Set the provider base URL.
    pub fn with_base_url(mut self, base_url: impl Into<String>) -> Self {
        self.base_url = base_url.into();
        self
    }

    /// Attach a version to this model reference.
    pub fn with_version(mut self, version: impl Into<String>) -> Self {
        self.version = Some(version.into());
        self
    }

    /// Returns `"model_id"` or `"model_id@version"` when a version is set.
    pub fn full_name(&self) -> String {
        match &self.version {
            Some(v) => format!("{}@{}", self.model_id, v),
            None => self.model_id.clone(),
        }
    }
}

impl fmt::Display for ModelRef {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.full_name())
    }
}

/// Controls model reasoning/thinking level.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ReasoningLevel {
    /// Disable reasoning output.
    #[default]
    Off,
    /// Minimal reasoning budget.
    Minimal,
    /// Low reasoning budget.
    Low,
    /// Medium reasoning budget.
    Medium,
    /// High reasoning budget.
    High,
}

impl fmt::Display for ReasoningLevel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Off => write!(f, "off"),
            Self::Minimal => write!(f, "minimal"),
            Self::Low => write!(f, "low"),
            Self::Medium => write!(f, "medium"),
            Self::High => write!(f, "high"),
        }
    }
}

/// Request options controlling model generation.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RequestOptions {
    /// Sampling temperature.
    pub temperature: Option<f64>,
    /// Maximum generated tokens.
    pub max_tokens: Option<u32>,
    /// Reasoning mode/effort.
    #[serde(default, alias = "reasoning_level")]
    pub reasoning: Option<ReasoningLevel>,
    /// End-to-end timeout in milliseconds.
    #[serde(default)]
    pub timeout_ms: Option<u64>,
    /// Extra request headers.
    #[serde(default)]
    pub headers: HashMap<String, String>,
    /// Optional nucleus sampling threshold.
    #[serde(default)]
    pub top_p: Option<f64>,
    /// Whether to request streaming responses.
    #[serde(default = "default_stream")]
    pub stream: bool,
}

fn default_stream() -> bool {
    true
}

impl Default for RequestOptions {
    fn default() -> Self {
        Self {
            temperature: Some(0.7),
            max_tokens: Some(2048),
            reasoning: Some(ReasoningLevel::Off),
            timeout_ms: None,
            headers: HashMap::new(),
            top_p: Some(0.9),
            stream: true,
        }
    }
}

impl RequestOptions {
    /// Create request options with default values.
    pub fn new() -> Self {
        Self::default()
    }

    /// Set maximum tokens.
    pub fn with_max_tokens(mut self, max_tokens: u32) -> Self {
        self.max_tokens = Some(max_tokens);
        self
    }

    /// Set sampling temperature.
    pub fn with_temperature(mut self, temperature: f64) -> Self {
        self.temperature = Some(temperature);
        self
    }

    /// Set nucleus sampling threshold.
    pub fn with_top_p(mut self, top_p: f64) -> Self {
        self.top_p = Some(top_p);
        self
    }

    /// Set reasoning level.
    pub fn with_reasoning(mut self, level: ReasoningLevel) -> Self {
        self.reasoning = Some(level);
        self
    }

    /// Set timeout in milliseconds.
    pub fn with_timeout_ms(mut self, timeout_ms: u64) -> Self {
        self.timeout_ms = Some(timeout_ms);
        self
    }

    /// Add a custom header.
    pub fn with_header(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.headers.insert(key.into(), value.into());
        self
    }

    /// Set streaming mode.
    pub fn with_stream(mut self, stream: bool) -> Self {
        self.stream = stream;
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endpoint_type_compat_aliases_parse() {
        let openai: EndpointType = serde_json::from_str("\"openai\"").unwrap_or_default();
        assert_eq!(openai, EndpointType::OpenAiCompletions);

        let anthropic: EndpointType = serde_json::from_str("\"anthropic\"").unwrap_or_default();
        assert_eq!(anthropic, EndpointType::AnthropicMessages);
    }

    #[test]
    fn model_ref_defaults_and_builders() {
        let model = ModelRef::new("gpt-4o")
            .with_provider("openai")
            .with_endpoint_type(EndpointType::OpenAiResponses)
            .with_base_url("https://api.openai.com/v1")
            .with_version("2026-01");

        assert_eq!(model.provider_id, "openai");
        assert_eq!(model.model_id, "gpt-4o");
        assert_eq!(model.endpoint_type, EndpointType::OpenAiResponses);
        assert_eq!(model.base_url, "https://api.openai.com/v1");
        assert_eq!(model.full_name(), "gpt-4o@2026-01");
    }

    #[test]
    fn reasoning_level_includes_minimal() {
        assert_eq!(ReasoningLevel::Minimal.to_string(), "minimal");
    }

    #[test]
    fn request_options_supports_locked_fields() {
        let opts = RequestOptions::new()
            .with_max_tokens(4096)
            .with_temperature(0.3)
            .with_reasoning(ReasoningLevel::High)
            .with_timeout_ms(15_000)
            .with_header("x-test", "1")
            .with_stream(false);

        assert_eq!(opts.max_tokens, Some(4096));
        assert_eq!(opts.temperature, Some(0.3));
        assert_eq!(opts.reasoning, Some(ReasoningLevel::High));
        assert_eq!(opts.timeout_ms, Some(15_000));
        assert_eq!(opts.headers.get("x-test"), Some(&"1".to_string()));
        assert!(!opts.stream);
    }

    #[test]
    fn request_options_accepts_legacy_reasoning_level_key() {
        let json = r#"{"reasoning_level":"low","max_tokens":128}"#;
        let opts: RequestOptions = serde_json::from_str(json).unwrap_or_default();
        assert_eq!(opts.reasoning, Some(ReasoningLevel::Low));
        assert_eq!(opts.max_tokens, Some(128));
    }
}
