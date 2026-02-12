//! Compatibility profiles for OpenAI-compatible LLM providers.
//!
//! Different providers expose an OpenAI-compatible API but with subtle
//! differences in field names, supported features, and response formats.
//! A [`CompatibilityProfile`] captures these differences as a set of flags
//! that the adapter uses to normalize requests and responses.
//!
//! # Built-in Profiles
//!
//! ```
//! use fae::fae_llm::providers::profile::CompatibilityProfile;
//!
//! let openai = CompatibilityProfile::openai_default();
//! assert_eq!(openai.name(), "openai");
//!
//! let deepseek = CompatibilityProfile::deepseek();
//! assert_eq!(deepseek.name(), "deepseek");
//! ```
//!
//! # Profile Resolution
//!
//! ```
//! use fae::fae_llm::providers::profile::resolve_profile;
//!
//! let profile = resolve_profile("deepseek");
//! assert_eq!(profile.name(), "deepseek");
//!
//! // Unknown providers fall back to OpenAI defaults
//! let fallback = resolve_profile("some-unknown-provider");
//! assert_eq!(fallback.name(), "openai");
//! ```

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

/// How the provider names the max output tokens field.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MaxTokensField {
    /// Standard `max_tokens` field (most providers).
    #[default]
    MaxTokens,
    /// Newer `max_completion_tokens` field (OpenAI o-series, z.ai).
    MaxCompletionTokens,
}

/// How the provider handles reasoning/thinking output.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ReasoningMode {
    /// No reasoning support.
    #[default]
    None,
    /// OpenAI o-series style (`reasoning_effort` parameter).
    OpenAiO1Style,
    /// DeepSeek-style thinking (`enable_thinking: true` in extra_body).
    DeepSeekThinking,
}

/// How the provider handles tool call streaming.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolCallFormat {
    /// Full OpenAI-standard streaming tool calls.
    #[default]
    Standard,
    /// Supports parallel tool calls but same streaming format.
    ParallelOnly,
    /// Does not stream tool call arguments (only final result).
    NoStreaming,
    /// No tool call support at all.
    Unsupported,
}

/// How the provider names the stop sequence field.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StopSequenceField {
    /// Standard `stop` field.
    #[default]
    Stop,
    /// Alternative `stop_sequences` field.
    StopSequences,
}

/// A compatibility profile describing a provider's API quirks.
///
/// Profiles are used by the OpenAI-compatible adapter to normalize
/// requests and responses for providers with subtle API differences.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CompatibilityProfile {
    /// Profile name (e.g. "openai", "deepseek", "ollama").
    name: String,

    /// How to name the max tokens field in requests.
    pub max_tokens_field: MaxTokensField,

    /// How reasoning/thinking output works.
    pub reasoning_mode: ReasoningMode,

    /// How tool calls are streamed.
    pub tool_call_format: ToolCallFormat,

    /// How to name the stop sequence field.
    pub stop_sequence_field: StopSequenceField,

    /// Whether the provider supports system messages directly.
    /// If false, system content is prepended to the first user message.
    pub supports_system_message: bool,

    /// Whether the provider supports streaming (`stream: true`).
    pub supports_streaming: bool,

    /// Whether the provider includes usage in streaming responses.
    pub supports_stream_usage: bool,

    /// Whether to send `stream_options` with `include_usage: true`.
    pub needs_stream_options: bool,

    /// Custom API path override (e.g. some providers use `/api/chat` instead of `/v1/chat/completions`).
    pub api_path_override: Option<String>,
}

impl CompatibilityProfile {
    /// Create a new profile with the given name and OpenAI-standard defaults.
    pub fn new(name: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            max_tokens_field: MaxTokensField::MaxTokens,
            reasoning_mode: ReasoningMode::None,
            tool_call_format: ToolCallFormat::Standard,
            stop_sequence_field: StopSequenceField::Stop,
            supports_system_message: true,
            supports_streaming: true,
            supports_stream_usage: true,
            needs_stream_options: true,
            api_path_override: None,
        }
    }

    /// Returns the profile name.
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Set the max tokens field naming.
    pub fn with_max_tokens_field(mut self, field: MaxTokensField) -> Self {
        self.max_tokens_field = field;
        self
    }

    /// Set the reasoning mode.
    pub fn with_reasoning_mode(mut self, mode: ReasoningMode) -> Self {
        self.reasoning_mode = mode;
        self
    }

    /// Set the tool call format.
    pub fn with_tool_call_format(mut self, format: ToolCallFormat) -> Self {
        self.tool_call_format = format;
        self
    }

    /// Set the stop sequence field naming.
    pub fn with_stop_sequence_field(mut self, field: StopSequenceField) -> Self {
        self.stop_sequence_field = field;
        self
    }

    /// Set whether system messages are supported.
    pub fn with_system_message_support(mut self, supported: bool) -> Self {
        self.supports_system_message = supported;
        self
    }

    /// Set whether streaming is supported.
    pub fn with_streaming_support(mut self, supported: bool) -> Self {
        self.supports_streaming = supported;
        self
    }

    /// Set whether stream usage is supported.
    pub fn with_stream_usage_support(mut self, supported: bool) -> Self {
        self.supports_stream_usage = supported;
        self
    }

    /// Set whether stream_options is needed.
    pub fn with_stream_options(mut self, needed: bool) -> Self {
        self.needs_stream_options = needed;
        self
    }

    /// Set a custom API path override.
    pub fn with_api_path(mut self, path: impl Into<String>) -> Self {
        self.api_path_override = Some(path.into());
        self
    }

    // ── Built-in Profiles ─────────────────────────────────────

    /// Standard OpenAI profile (default for unknown providers).
    pub fn openai_default() -> Self {
        Self::new("openai")
            .with_max_tokens_field(MaxTokensField::MaxTokens)
            .with_reasoning_mode(ReasoningMode::OpenAiO1Style)
            .with_stream_options(true)
    }

    /// z.ai profile — uses max_completion_tokens, no reasoning.
    pub fn zai() -> Self {
        Self::new("zai")
            .with_max_tokens_field(MaxTokensField::MaxCompletionTokens)
            .with_reasoning_mode(ReasoningMode::None)
            .with_stream_options(false)
    }

    /// DeepSeek profile — thinking mode, standard tools.
    pub fn deepseek() -> Self {
        Self::new("deepseek")
            .with_max_tokens_field(MaxTokensField::MaxTokens)
            .with_reasoning_mode(ReasoningMode::DeepSeekThinking)
            .with_stream_options(false)
            .with_stream_usage_support(false)
    }

    /// MiniMax profile — max_tokens, no streaming tool calls.
    pub fn minimax() -> Self {
        Self::new("minimax")
            .with_max_tokens_field(MaxTokensField::MaxTokens)
            .with_reasoning_mode(ReasoningMode::None)
            .with_tool_call_format(ToolCallFormat::NoStreaming)
            .with_stream_options(false)
    }

    /// Ollama local profile — basic OpenAI-compatible.
    pub fn ollama() -> Self {
        Self::new("ollama")
            .with_max_tokens_field(MaxTokensField::MaxTokens)
            .with_reasoning_mode(ReasoningMode::None)
            .with_tool_call_format(ToolCallFormat::Standard)
            .with_stream_options(false)
            .with_stream_usage_support(false)
    }

    /// llama.cpp server profile — limited tool support.
    pub fn llamacpp() -> Self {
        Self::new("llamacpp")
            .with_max_tokens_field(MaxTokensField::MaxTokens)
            .with_reasoning_mode(ReasoningMode::None)
            .with_tool_call_format(ToolCallFormat::NoStreaming)
            .with_stream_options(false)
            .with_stream_usage_support(false)
    }

    /// vLLM profile — mostly OpenAI-compatible.
    pub fn vllm() -> Self {
        Self::new("vllm")
            .with_max_tokens_field(MaxTokensField::MaxTokens)
            .with_reasoning_mode(ReasoningMode::None)
            .with_tool_call_format(ToolCallFormat::Standard)
            .with_stream_options(false)
            .with_stream_usage_support(false)
    }
}

/// Resolve a profile by provider name.
///
/// Known providers return their specific profile. Unknown providers
/// fall back to the OpenAI default profile.
///
/// # Examples
///
/// ```
/// use fae::fae_llm::providers::profile::resolve_profile;
///
/// let profile = resolve_profile("deepseek");
/// assert_eq!(profile.name(), "deepseek");
///
/// let fallback = resolve_profile("unknown-provider");
/// assert_eq!(fallback.name(), "openai");
/// ```
pub fn resolve_profile(provider_name: &str) -> CompatibilityProfile {
    match provider_name.to_lowercase().as_str() {
        "openai" => CompatibilityProfile::openai_default(),
        "zai" | "z.ai" => CompatibilityProfile::zai(),
        "deepseek" => CompatibilityProfile::deepseek(),
        "minimax" => CompatibilityProfile::minimax(),
        "ollama" => CompatibilityProfile::ollama(),
        "llamacpp" | "llama.cpp" | "llama-cpp" => CompatibilityProfile::llamacpp(),
        "vllm" => CompatibilityProfile::vllm(),
        _ => CompatibilityProfile::openai_default(),
    }
}

/// Registry for custom compatibility profiles.
///
/// Allows overriding built-in profiles or adding profiles for new
/// providers at runtime (e.g. from config).
#[derive(Debug, Clone, Default)]
pub struct ProfileRegistry {
    profiles: HashMap<String, CompatibilityProfile>,
}

impl ProfileRegistry {
    /// Create an empty registry.
    pub fn new() -> Self {
        Self::default()
    }

    /// Register a custom profile by name.
    pub fn register(&mut self, name: impl Into<String>, profile: CompatibilityProfile) {
        self.profiles.insert(name.into(), profile);
    }

    /// Resolve a profile, checking custom registry first, then built-in.
    pub fn resolve(&self, provider_name: &str) -> CompatibilityProfile {
        let key = provider_name.to_lowercase();
        if let Some(profile) = self.profiles.get(&key) {
            return profile.clone();
        }
        resolve_profile(provider_name)
    }
}

/// Apply a compatibility profile to a request body.
///
/// Modifies the JSON request body according to the profile's flags:
/// - Renames `max_tokens` to `max_completion_tokens` if needed
/// - Adds/removes `stream_options`
/// - Merges system message into user message if not supported
pub fn apply_profile_to_request(body: &mut serde_json::Value, profile: &CompatibilityProfile) {
    let obj = match body.as_object_mut() {
        Some(o) => o,
        None => return,
    };

    // Rename max_tokens field
    if profile.max_tokens_field == MaxTokensField::MaxCompletionTokens
        && let Some(val) = obj.remove("max_tokens")
    {
        obj.insert("max_completion_tokens".into(), val);
    }

    // Handle stream_options
    if !profile.needs_stream_options {
        obj.remove("stream_options");
    }

    // Handle system message merging
    if !profile.supports_system_message {
        merge_system_into_user(obj);
    }
}

/// Merge system messages into the first user message when the provider
/// doesn't support system messages directly.
fn merge_system_into_user(obj: &mut serde_json::Map<String, serde_json::Value>) {
    let messages = match obj.get_mut("messages").and_then(|m| m.as_array_mut()) {
        Some(m) => m,
        None => return,
    };

    // Collect system message content
    let mut system_parts: Vec<String> = Vec::new();
    messages.retain(|msg| {
        if msg.get("role").and_then(|r| r.as_str()) == Some("system") {
            if let Some(content) = msg.get("content").and_then(|c| c.as_str()) {
                system_parts.push(content.to_string());
            }
            false
        } else {
            true
        }
    });

    if system_parts.is_empty() {
        return;
    }

    let system_text = system_parts.join("\n");

    // Prepend to first user message
    if let Some(first_user) = messages
        .iter_mut()
        .find(|m| m.get("role").and_then(|r| r.as_str()) == Some("user"))
    {
        let merged = first_user
            .get("content")
            .and_then(|c| c.as_str())
            .map(|content| format!("{system_text}\n\n{content}"));
        if let Some(merged) = merged
            && let Some(obj) = first_user.as_object_mut()
        {
            obj.insert("content".into(), serde_json::json!(merged));
        }
    }
}

/// Map a provider-specific finish reason to the standard set.
///
/// Providers may use non-standard strings for finish reasons.
/// This function normalizes them based on the profile's reasoning mode.
/// Unknown reasons are mapped to `"other"`.
pub fn normalize_finish_reason(reason: &str, profile: &CompatibilityProfile) -> &'static str {
    match (reason, profile.reasoning_mode) {
        ("thinking_done", ReasoningMode::DeepSeekThinking) => "stop",
        _ => match reason {
            "stop" | "end_turn" => "stop",
            "length" | "max_tokens" => "length",
            "tool_calls" | "function_call" => "tool_calls",
            "content_filter" | "safety" => "content_filter",
            _ => "other",
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── Profile Construction ──────────────────────────────────

    #[test]
    fn new_profile_has_defaults() {
        let p = CompatibilityProfile::new("test");
        assert_eq!(p.name(), "test");
        assert_eq!(p.max_tokens_field, MaxTokensField::MaxTokens);
        assert_eq!(p.reasoning_mode, ReasoningMode::None);
        assert_eq!(p.tool_call_format, ToolCallFormat::Standard);
        assert_eq!(p.stop_sequence_field, StopSequenceField::Stop);
        assert!(p.supports_system_message);
        assert!(p.supports_streaming);
        assert!(p.supports_stream_usage);
        assert!(p.needs_stream_options);
        assert!(p.api_path_override.is_none());
    }

    #[test]
    fn builder_methods_work() {
        let p = CompatibilityProfile::new("custom")
            .with_max_tokens_field(MaxTokensField::MaxCompletionTokens)
            .with_reasoning_mode(ReasoningMode::DeepSeekThinking)
            .with_tool_call_format(ToolCallFormat::NoStreaming)
            .with_stop_sequence_field(StopSequenceField::StopSequences)
            .with_system_message_support(false)
            .with_streaming_support(false)
            .with_stream_usage_support(false)
            .with_stream_options(false)
            .with_api_path("/api/chat");

        assert_eq!(p.max_tokens_field, MaxTokensField::MaxCompletionTokens);
        assert_eq!(p.reasoning_mode, ReasoningMode::DeepSeekThinking);
        assert_eq!(p.tool_call_format, ToolCallFormat::NoStreaming);
        assert_eq!(p.stop_sequence_field, StopSequenceField::StopSequences);
        assert!(!p.supports_system_message);
        assert!(!p.supports_streaming);
        assert!(!p.supports_stream_usage);
        assert!(!p.needs_stream_options);
        assert_eq!(p.api_path_override.as_deref(), Some("/api/chat"));
    }

    // ── Built-in Profiles ─────────────────────────────────────

    #[test]
    fn openai_default_profile() {
        let p = CompatibilityProfile::openai_default();
        assert_eq!(p.name(), "openai");
        assert_eq!(p.max_tokens_field, MaxTokensField::MaxTokens);
        assert_eq!(p.reasoning_mode, ReasoningMode::OpenAiO1Style);
        assert!(p.needs_stream_options);
    }

    #[test]
    fn zai_profile() {
        let p = CompatibilityProfile::zai();
        assert_eq!(p.name(), "zai");
        assert_eq!(p.max_tokens_field, MaxTokensField::MaxCompletionTokens);
        assert_eq!(p.reasoning_mode, ReasoningMode::None);
        assert!(!p.needs_stream_options);
    }

    #[test]
    fn deepseek_profile() {
        let p = CompatibilityProfile::deepseek();
        assert_eq!(p.name(), "deepseek");
        assert_eq!(p.reasoning_mode, ReasoningMode::DeepSeekThinking);
        assert!(!p.supports_stream_usage);
    }

    #[test]
    fn minimax_profile() {
        let p = CompatibilityProfile::minimax();
        assert_eq!(p.name(), "minimax");
        assert_eq!(p.tool_call_format, ToolCallFormat::NoStreaming);
    }

    #[test]
    fn ollama_profile() {
        let p = CompatibilityProfile::ollama();
        assert_eq!(p.name(), "ollama");
        assert!(!p.supports_stream_usage);
        assert!(!p.needs_stream_options);
    }

    #[test]
    fn llamacpp_profile() {
        let p = CompatibilityProfile::llamacpp();
        assert_eq!(p.name(), "llamacpp");
        assert_eq!(p.tool_call_format, ToolCallFormat::NoStreaming);
    }

    #[test]
    fn vllm_profile() {
        let p = CompatibilityProfile::vllm();
        assert_eq!(p.name(), "vllm");
        assert_eq!(p.tool_call_format, ToolCallFormat::Standard);
    }

    // ── Profile Resolution ────────────────────────────────────

    #[test]
    fn resolve_known_providers() {
        assert_eq!(resolve_profile("openai").name(), "openai");
        assert_eq!(resolve_profile("zai").name(), "zai");
        assert_eq!(resolve_profile("z.ai").name(), "zai");
        assert_eq!(resolve_profile("deepseek").name(), "deepseek");
        assert_eq!(resolve_profile("minimax").name(), "minimax");
        assert_eq!(resolve_profile("ollama").name(), "ollama");
        assert_eq!(resolve_profile("llamacpp").name(), "llamacpp");
        assert_eq!(resolve_profile("llama.cpp").name(), "llamacpp");
        assert_eq!(resolve_profile("llama-cpp").name(), "llamacpp");
        assert_eq!(resolve_profile("vllm").name(), "vllm");
    }

    #[test]
    fn resolve_case_insensitive() {
        assert_eq!(resolve_profile("OpenAI").name(), "openai");
        assert_eq!(resolve_profile("DEEPSEEK").name(), "deepseek");
        assert_eq!(resolve_profile("Ollama").name(), "ollama");
    }

    #[test]
    fn resolve_unknown_falls_back_to_openai() {
        let p = resolve_profile("some-random-provider");
        assert_eq!(p.name(), "openai");
    }

    // ── Profile Registry ──────────────────────────────────────

    #[test]
    fn registry_empty_resolves_builtin() {
        let registry = ProfileRegistry::new();
        let p = registry.resolve("deepseek");
        assert_eq!(p.name(), "deepseek");
    }

    #[test]
    fn registry_custom_overrides_builtin() {
        let mut registry = ProfileRegistry::new();
        let custom = CompatibilityProfile::new("custom-deepseek")
            .with_tool_call_format(ToolCallFormat::Unsupported);
        registry.register("deepseek", custom);

        let p = registry.resolve("deepseek");
        assert_eq!(p.name(), "custom-deepseek");
        assert_eq!(p.tool_call_format, ToolCallFormat::Unsupported);
    }

    #[test]
    fn registry_fallback_for_unknown() {
        let registry = ProfileRegistry::new();
        let p = registry.resolve("unknown-provider");
        assert_eq!(p.name(), "openai");
    }

    // ── apply_profile_to_request ──────────────────────────────

    #[test]
    fn apply_renames_max_tokens_for_zai() {
        let profile = CompatibilityProfile::zai();
        let mut body = serde_json::json!({
            "model": "test",
            "max_tokens": 4096,
            "stream_options": { "include_usage": true },
        });
        apply_profile_to_request(&mut body, &profile);

        assert!(body.get("max_tokens").is_none());
        assert_eq!(body["max_completion_tokens"], 4096);
        // stream_options removed for zai
        assert!(body.get("stream_options").is_none());
    }

    #[test]
    fn apply_keeps_max_tokens_for_ollama() {
        let profile = CompatibilityProfile::ollama();
        let mut body = serde_json::json!({
            "model": "test",
            "max_tokens": 2048,
        });
        apply_profile_to_request(&mut body, &profile);

        assert_eq!(body["max_tokens"], 2048);
        assert!(body.get("max_completion_tokens").is_none());
    }

    #[test]
    fn apply_removes_stream_options_when_not_needed() {
        let profile = CompatibilityProfile::deepseek();
        let mut body = serde_json::json!({
            "model": "test",
            "stream_options": { "include_usage": true },
        });
        apply_profile_to_request(&mut body, &profile);

        assert!(body.get("stream_options").is_none());
    }

    #[test]
    fn apply_merges_system_when_unsupported() {
        let profile = CompatibilityProfile::new("no-system").with_system_message_support(false);
        let mut body = serde_json::json!({
            "model": "test",
            "messages": [
                { "role": "system", "content": "You are helpful." },
                { "role": "user", "content": "Hello" }
            ]
        });
        apply_profile_to_request(&mut body, &profile);

        let messages = body["messages"].as_array();
        assert!(messages.is_some_and(|m| m.len() == 1));
        if let Some(msgs) = messages {
            assert_eq!(msgs[0]["role"], "user");
            let content = msgs[0]["content"].as_str().unwrap_or_default();
            assert!(content.contains("You are helpful."));
            assert!(content.contains("Hello"));
        }
    }

    #[test]
    fn apply_no_system_message_no_op() {
        let profile = CompatibilityProfile::new("no-system").with_system_message_support(false);
        let mut body = serde_json::json!({
            "model": "test",
            "messages": [
                { "role": "user", "content": "Hello" }
            ]
        });
        apply_profile_to_request(&mut body, &profile);

        let messages = body["messages"].as_array();
        assert!(messages.is_some_and(|m| m.len() == 1));
    }

    // ── normalize_finish_reason ───────────────────────────────

    #[test]
    fn normalize_standard_reasons() {
        let openai = CompatibilityProfile::openai_default();
        assert_eq!(normalize_finish_reason("stop", &openai), "stop");
        assert_eq!(normalize_finish_reason("length", &openai), "length");
        assert_eq!(normalize_finish_reason("tool_calls", &openai), "tool_calls");
        assert_eq!(
            normalize_finish_reason("content_filter", &openai),
            "content_filter"
        );
    }

    #[test]
    fn normalize_deepseek_thinking_done() {
        let deepseek = CompatibilityProfile::deepseek();
        assert_eq!(normalize_finish_reason("thinking_done", &deepseek), "stop");
    }

    #[test]
    fn normalize_alternative_names() {
        let openai = CompatibilityProfile::openai_default();
        assert_eq!(normalize_finish_reason("end_turn", &openai), "stop");
        assert_eq!(normalize_finish_reason("max_tokens", &openai), "length");
        assert_eq!(
            normalize_finish_reason("function_call", &openai),
            "tool_calls"
        );
        assert_eq!(normalize_finish_reason("safety", &openai), "content_filter");
    }

    // ── Serialization ─────────────────────────────────────────

    #[test]
    fn profile_serde_json_round_trip() {
        let original = CompatibilityProfile::deepseek();
        let json = serde_json::to_string(&original).unwrap_or_default();
        let parsed: Result<CompatibilityProfile, _> = serde_json::from_str(&json);
        assert!(parsed.is_ok());
        match parsed {
            Ok(p) => {
                assert_eq!(p.name(), "deepseek");
                assert_eq!(p.reasoning_mode, ReasoningMode::DeepSeekThinking);
            }
            Err(_) => unreachable!("deserialization succeeded"),
        }
    }

    #[test]
    fn profile_serde_toml_round_trip() {
        let original = CompatibilityProfile::zai();
        let toml_str = toml::to_string(&original).unwrap_or_default();
        let parsed: Result<CompatibilityProfile, _> = toml::from_str(&toml_str);
        assert!(parsed.is_ok());
        match parsed {
            Ok(p) => {
                assert_eq!(p.name(), "zai");
                assert_eq!(p.max_tokens_field, MaxTokensField::MaxCompletionTokens);
            }
            Err(_) => unreachable!("toml deserialization succeeded"),
        }
    }

    #[test]
    fn enum_serde_round_trips() {
        // MaxTokensField
        let json = serde_json::to_string(&MaxTokensField::MaxCompletionTokens).unwrap_or_default();
        let parsed: Result<MaxTokensField, _> = serde_json::from_str(&json);
        assert!(parsed.is_ok_and(|v| v == MaxTokensField::MaxCompletionTokens));

        // ReasoningMode
        let json = serde_json::to_string(&ReasoningMode::DeepSeekThinking).unwrap_or_default();
        let parsed: Result<ReasoningMode, _> = serde_json::from_str(&json);
        assert!(parsed.is_ok_and(|v| v == ReasoningMode::DeepSeekThinking));

        // ToolCallFormat
        let json = serde_json::to_string(&ToolCallFormat::NoStreaming).unwrap_or_default();
        let parsed: Result<ToolCallFormat, _> = serde_json::from_str(&json);
        assert!(parsed.is_ok_and(|v| v == ToolCallFormat::NoStreaming));
    }
}
