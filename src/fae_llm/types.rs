//! Core domain types for the fae_llm module.
//!
//! Provides fundamental types used across the module:
//! - [`EndpointType`] — identifies the kind of LLM endpoint
//! - [`ModelRef`] — references a specific model with optional version
//! - [`ReasoningLevel`] — controls thinking/reasoning output
//! - [`RequestOptions`] — configures generation parameters

use serde::{Deserialize, Serialize};
use std::fmt;

/// The kind of LLM endpoint being targeted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EndpointType {
    /// OpenAI API (or compatible).
    OpenAI,
    /// Anthropic Messages API.
    Anthropic,
    /// Local inference endpoint (Ollama, llama.cpp, vLLM, etc.).
    Local,
    /// Custom endpoint with provider-specific handling.
    Custom,
}

impl fmt::Display for EndpointType {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::OpenAI => write!(f, "openai"),
            Self::Anthropic => write!(f, "anthropic"),
            Self::Local => write!(f, "local"),
            Self::Custom => write!(f, "custom"),
        }
    }
}

/// A reference to a specific LLM model.
///
/// # Examples
///
/// ```
/// use fae::fae_llm::types::ModelRef;
///
/// let model = ModelRef::new("gpt-4o");
/// assert_eq!(model.full_name(), "gpt-4o");
///
/// let versioned = ModelRef::new("claude-opus-4").with_version("2025-04-14");
/// assert_eq!(versioned.full_name(), "claude-opus-4@2025-04-14");
/// ```
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ModelRef {
    /// Provider-specific model ID (e.g. `"gpt-4o"`, `"claude-opus-4"`).
    pub model_id: String,
    /// Optional version or snapshot identifier.
    pub version: Option<String>,
}

impl ModelRef {
    /// Create a new model reference with just a model ID.
    pub fn new(model_id: impl Into<String>) -> Self {
        Self {
            model_id: model_id.into(),
            version: None,
        }
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

/// Controls the level of thinking/reasoning output from the model.
///
/// Not all providers support reasoning. When unsupported, this is ignored.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, Default)]
#[serde(rename_all = "lowercase")]
pub enum ReasoningLevel {
    /// No thinking/reasoning blocks.
    #[default]
    Off,
    /// Minimal reasoning (budget mode).
    Low,
    /// Balanced reasoning.
    Medium,
    /// Extended reasoning for high accuracy.
    High,
}

impl fmt::Display for ReasoningLevel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Off => write!(f, "off"),
            Self::Low => write!(f, "low"),
            Self::Medium => write!(f, "medium"),
            Self::High => write!(f, "high"),
        }
    }
}

/// Options controlling LLM generation behavior.
///
/// # Examples
///
/// ```
/// use fae::fae_llm::types::{RequestOptions, ReasoningLevel};
///
/// let opts = RequestOptions::new()
///     .with_max_tokens(4096)
///     .with_temperature(0.3)
///     .with_reasoning(ReasoningLevel::High);
///
/// assert_eq!(opts.max_tokens, Some(4096));
/// assert_eq!(opts.reasoning_level, ReasoningLevel::High);
/// ```
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RequestOptions {
    /// Maximum tokens to generate. `None` means use provider default.
    pub max_tokens: Option<usize>,
    /// Sampling temperature (0.0 = deterministic, 2.0 = max randomness).
    pub temperature: Option<f64>,
    /// Nucleus sampling threshold.
    pub top_p: Option<f64>,
    /// Level of thinking/reasoning output.
    pub reasoning_level: ReasoningLevel,
    /// Whether to stream the response.
    pub stream: bool,
}

impl Default for RequestOptions {
    fn default() -> Self {
        Self {
            max_tokens: Some(2048),
            temperature: Some(0.7),
            top_p: Some(0.9),
            reasoning_level: ReasoningLevel::Off,
            stream: true,
        }
    }
}

impl RequestOptions {
    /// Create request options with default values.
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the maximum number of tokens to generate.
    pub fn with_max_tokens(mut self, max_tokens: usize) -> Self {
        self.max_tokens = Some(max_tokens);
        self
    }

    /// Set the sampling temperature.
    pub fn with_temperature(mut self, temperature: f64) -> Self {
        self.temperature = Some(temperature);
        self
    }

    /// Set the nucleus sampling threshold.
    pub fn with_top_p(mut self, top_p: f64) -> Self {
        self.top_p = Some(top_p);
        self
    }

    /// Set the reasoning level.
    pub fn with_reasoning(mut self, level: ReasoningLevel) -> Self {
        self.reasoning_level = level;
        self
    }

    /// Set whether to stream the response.
    pub fn with_stream(mut self, stream: bool) -> Self {
        self.stream = stream;
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── EndpointType ───────────────────────────────────────────

    #[test]
    fn endpoint_type_display() {
        assert_eq!(EndpointType::OpenAI.to_string(), "openai");
        assert_eq!(EndpointType::Anthropic.to_string(), "anthropic");
        assert_eq!(EndpointType::Local.to_string(), "local");
        assert_eq!(EndpointType::Custom.to_string(), "custom");
    }

    #[test]
    fn endpoint_type_serde_round_trip() {
        let json = serde_json::to_string(&EndpointType::OpenAI);
        assert!(json.is_ok());
        let json = json.unwrap_or_default();
        assert_eq!(json, "\"openai\"");

        let parsed: std::result::Result<EndpointType, _> = serde_json::from_str(&json);
        assert!(parsed.is_ok());
        assert_eq!(parsed.unwrap_or(EndpointType::Custom), EndpointType::OpenAI);
    }

    #[test]
    fn endpoint_type_equality() {
        assert_eq!(EndpointType::Local, EndpointType::Local);
        assert_ne!(EndpointType::OpenAI, EndpointType::Anthropic);
    }

    // ── ModelRef ───────────────────────────────────────────────

    #[test]
    fn model_ref_new() {
        let m = ModelRef::new("gpt-4o");
        assert_eq!(m.model_id, "gpt-4o");
        assert!(m.version.is_none());
    }

    #[test]
    fn model_ref_with_version() {
        let m = ModelRef::new("claude-opus-4").with_version("2025-04-14");
        assert_eq!(m.model_id, "claude-opus-4");
        assert_eq!(m.version.as_deref(), Some("2025-04-14"));
    }

    #[test]
    fn model_ref_full_name_no_version() {
        let m = ModelRef::new("llama3:8b");
        assert_eq!(m.full_name(), "llama3:8b");
    }

    #[test]
    fn model_ref_full_name_with_version() {
        let m = ModelRef::new("gpt-4o").with_version("2025-01");
        assert_eq!(m.full_name(), "gpt-4o@2025-01");
    }

    #[test]
    fn model_ref_display() {
        let m = ModelRef::new("mixtral").with_version("v0.1");
        assert_eq!(m.to_string(), "mixtral@v0.1");
    }

    #[test]
    fn model_ref_serde_round_trip() {
        let original = ModelRef::new("gpt-4o").with_version("latest");
        let json = serde_json::to_string(&original);
        assert!(json.is_ok());
        let parsed: std::result::Result<ModelRef, _> =
            serde_json::from_str(&json.unwrap_or_default());
        assert!(parsed.is_ok());
        assert_eq!(parsed.unwrap_or_else(|_| ModelRef::new("")), original);
    }

    #[test]
    fn model_ref_equality() {
        let a = ModelRef::new("gpt-4o");
        let b = ModelRef::new("gpt-4o");
        assert_eq!(a, b);

        let c = ModelRef::new("gpt-4o").with_version("v1");
        assert_ne!(a, c);
    }

    // ── ReasoningLevel ─────────────────────────────────────────

    #[test]
    fn reasoning_level_default_is_off() {
        assert_eq!(ReasoningLevel::default(), ReasoningLevel::Off);
    }

    #[test]
    fn reasoning_level_display() {
        assert_eq!(ReasoningLevel::Off.to_string(), "off");
        assert_eq!(ReasoningLevel::Low.to_string(), "low");
        assert_eq!(ReasoningLevel::Medium.to_string(), "medium");
        assert_eq!(ReasoningLevel::High.to_string(), "high");
    }

    #[test]
    fn reasoning_level_serde_round_trip() {
        let json = serde_json::to_string(&ReasoningLevel::High);
        assert!(json.is_ok());
        assert_eq!(json.unwrap_or_default(), "\"high\"");
    }

    // ── RequestOptions ─────────────────────────────────────────

    #[test]
    fn request_options_defaults() {
        let opts = RequestOptions::new();
        assert_eq!(opts.max_tokens, Some(2048));
        assert_eq!(opts.temperature, Some(0.7));
        assert_eq!(opts.top_p, Some(0.9));
        assert_eq!(opts.reasoning_level, ReasoningLevel::Off);
        assert!(opts.stream);
    }

    #[test]
    fn request_options_builder() {
        let opts = RequestOptions::new()
            .with_max_tokens(4096)
            .with_temperature(0.3)
            .with_top_p(0.95)
            .with_reasoning(ReasoningLevel::Medium)
            .with_stream(false);

        assert_eq!(opts.max_tokens, Some(4096));
        assert_eq!(opts.temperature, Some(0.3));
        assert_eq!(opts.top_p, Some(0.95));
        assert_eq!(opts.reasoning_level, ReasoningLevel::Medium);
        assert!(!opts.stream);
    }

    #[test]
    fn request_options_serde_round_trip() {
        let original = RequestOptions::new().with_max_tokens(1024);
        let json = serde_json::to_string(&original);
        assert!(json.is_ok());
        let parsed: std::result::Result<RequestOptions, _> =
            serde_json::from_str(&json.unwrap_or_default());
        assert!(parsed.is_ok());
        let parsed = parsed.unwrap_or_default();
        assert_eq!(parsed.max_tokens, Some(1024));
    }
}
