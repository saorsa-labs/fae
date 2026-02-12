//! Integration tests for OpenAI-compatible provider compatibility profiles.
//!
//! Tests verify that each profile (z.ai, MiniMax, DeepSeek, etc.) correctly
//! transforms requests and responses according to provider-specific quirks.

use super::profile::{
    CompatibilityProfile, MaxTokensField, ReasoningMode, StopSequenceField, ToolCallFormat,
    resolve_profile,
};

// ── Profile Construction Tests ────────────────────────────────────

#[test]
fn test_openai_default_profile() {
    let profile = CompatibilityProfile::openai_default();

    assert_eq!(profile.name(), "openai");
    assert_eq!(profile.max_tokens_field, MaxTokensField::MaxTokens);
    assert_eq!(profile.reasoning_mode, ReasoningMode::OpenAiO1Style);
    assert_eq!(profile.tool_call_format, ToolCallFormat::Standard);
    assert_eq!(profile.stop_sequence_field, StopSequenceField::Stop);
    assert!(profile.supports_system_message);
    assert!(profile.supports_streaming);
    assert!(profile.supports_stream_usage);
    assert!(profile.needs_stream_options);
    assert_eq!(profile.api_path_override, None);
}

#[test]
fn test_zai_profile() {
    let profile = CompatibilityProfile::zai();

    assert_eq!(profile.name(), "zai");
    assert_eq!(
        profile.max_tokens_field,
        MaxTokensField::MaxCompletionTokens
    );
    assert_eq!(profile.reasoning_mode, ReasoningMode::None);
    assert_eq!(profile.tool_call_format, ToolCallFormat::Standard);
    assert!(profile.supports_system_message);
    assert!(profile.supports_streaming);
    assert!(!profile.needs_stream_options);
}

#[test]
fn test_deepseek_profile() {
    let profile = CompatibilityProfile::deepseek();

    assert_eq!(profile.name(), "deepseek");
    assert_eq!(profile.max_tokens_field, MaxTokensField::MaxTokens);
    assert_eq!(profile.reasoning_mode, ReasoningMode::DeepSeekThinking);
    assert_eq!(profile.tool_call_format, ToolCallFormat::Standard);
    assert!(profile.supports_system_message);
    assert!(profile.supports_streaming);
    assert!(!profile.supports_stream_usage);
    assert!(!profile.needs_stream_options);
}

#[test]
fn test_minimax_profile() {
    let profile = CompatibilityProfile::minimax();

    assert_eq!(profile.name(), "minimax");
    assert_eq!(profile.max_tokens_field, MaxTokensField::MaxTokens);
    assert_eq!(profile.reasoning_mode, ReasoningMode::None);
    assert_eq!(profile.tool_call_format, ToolCallFormat::NoStreaming);
    assert!(profile.supports_system_message);
    assert!(profile.supports_streaming);
    assert!(!profile.needs_stream_options);
}

#[test]
fn test_ollama_profile() {
    let profile = CompatibilityProfile::ollama();

    assert_eq!(profile.name(), "ollama");
    assert_eq!(profile.max_tokens_field, MaxTokensField::MaxTokens);
    assert_eq!(profile.reasoning_mode, ReasoningMode::None);
    assert_eq!(profile.tool_call_format, ToolCallFormat::Standard);
    assert!(!profile.supports_stream_usage);
    assert!(!profile.needs_stream_options);
}

// ── Profile Resolution Tests ──────────────────────────────────────

#[test]
fn test_resolve_profile_openai() {
    let profile = resolve_profile("openai");
    assert_eq!(profile.name(), "openai");
    assert_eq!(profile.reasoning_mode, ReasoningMode::OpenAiO1Style);
}

#[test]
fn test_resolve_profile_zai() {
    let profile = resolve_profile("zai");
    assert_eq!(profile.name(), "zai");
    assert_eq!(
        profile.max_tokens_field,
        MaxTokensField::MaxCompletionTokens
    );
}

#[test]
fn test_resolve_profile_zai_with_prefix() {
    let profile = resolve_profile("z.ai");
    assert_eq!(profile.name(), "zai");
    assert_eq!(
        profile.max_tokens_field,
        MaxTokensField::MaxCompletionTokens
    );
}

#[test]
fn test_resolve_profile_deepseek() {
    let profile = resolve_profile("deepseek");
    assert_eq!(profile.name(), "deepseek");
    assert_eq!(profile.reasoning_mode, ReasoningMode::DeepSeekThinking);
}

#[test]
fn test_resolve_profile_minimax() {
    let profile = resolve_profile("minimax");
    assert_eq!(profile.name(), "minimax");
    assert_eq!(profile.tool_call_format, ToolCallFormat::NoStreaming);
}

#[test]
fn test_resolve_profile_ollama() {
    let profile = resolve_profile("ollama");
    assert_eq!(profile.name(), "ollama");
    assert!(!profile.supports_stream_usage);
}

#[test]
fn test_resolve_profile_unknown_fallback() {
    let profile = resolve_profile("unknown-provider");
    assert_eq!(profile.name(), "openai");
    assert_eq!(profile.reasoning_mode, ReasoningMode::OpenAiO1Style);
}

#[test]
fn test_resolve_profile_case_insensitive() {
    let profile = resolve_profile("DeepSeek");
    assert_eq!(profile.name(), "deepseek");

    let profile2 = resolve_profile("OLLAMA");
    assert_eq!(profile2.name(), "ollama");
}

// ── Profile Builder Tests ─────────────────────────────────────────

#[test]
fn test_custom_profile_with_builder() {
    let profile = CompatibilityProfile::new("custom")
        .with_max_tokens_field(MaxTokensField::MaxCompletionTokens)
        .with_reasoning_mode(ReasoningMode::DeepSeekThinking)
        .with_tool_call_format(ToolCallFormat::NoStreaming)
        .with_stop_sequence_field(StopSequenceField::StopSequences)
        .with_system_message_support(false)
        .with_streaming_support(false)
        .with_stream_usage_support(false)
        .with_stream_options(false)
        .with_api_path("/api/custom");

    assert_eq!(profile.name(), "custom");
    assert_eq!(
        profile.max_tokens_field,
        MaxTokensField::MaxCompletionTokens
    );
    assert_eq!(profile.reasoning_mode, ReasoningMode::DeepSeekThinking);
    assert_eq!(profile.tool_call_format, ToolCallFormat::NoStreaming);
    assert_eq!(
        profile.stop_sequence_field,
        StopSequenceField::StopSequences
    );
    assert!(!profile.supports_system_message);
    assert!(!profile.supports_streaming);
    assert!(!profile.supports_stream_usage);
    assert!(!profile.needs_stream_options);
    assert_eq!(profile.api_path_override, Some("/api/custom".to_string()));
}

// ── Max Tokens Field Tests ────────────────────────────────────────

#[test]
fn test_max_tokens_field_openai_standard() {
    let profile = CompatibilityProfile::openai_default();
    assert_eq!(profile.max_tokens_field, MaxTokensField::MaxTokens);
}

#[test]
fn test_max_tokens_field_zai_completion_tokens() {
    let profile = CompatibilityProfile::zai();
    assert_eq!(
        profile.max_tokens_field,
        MaxTokensField::MaxCompletionTokens
    );
}

#[test]
fn test_max_tokens_field_deepseek_standard() {
    let profile = CompatibilityProfile::deepseek();
    assert_eq!(profile.max_tokens_field, MaxTokensField::MaxTokens);
}

#[test]
fn test_max_tokens_field_minimax_standard() {
    let profile = CompatibilityProfile::minimax();
    assert_eq!(profile.max_tokens_field, MaxTokensField::MaxTokens);
}

// ── Reasoning Mode Tests ──────────────────────────────────────────

#[test]
fn test_reasoning_mode_openai_o1_style() {
    let profile = CompatibilityProfile::openai_default();
    assert_eq!(profile.reasoning_mode, ReasoningMode::OpenAiO1Style);
}

#[test]
fn test_reasoning_mode_zai_none() {
    let profile = CompatibilityProfile::zai();
    assert_eq!(profile.reasoning_mode, ReasoningMode::None);
}

#[test]
fn test_reasoning_mode_deepseek_thinking() {
    let profile = CompatibilityProfile::deepseek();
    assert_eq!(profile.reasoning_mode, ReasoningMode::DeepSeekThinking);
}

#[test]
fn test_reasoning_mode_minimax_none() {
    let profile = CompatibilityProfile::minimax();
    assert_eq!(profile.reasoning_mode, ReasoningMode::None);
}

#[test]
fn test_reasoning_mode_ollama_none() {
    let profile = CompatibilityProfile::ollama();
    assert_eq!(profile.reasoning_mode, ReasoningMode::None);
}

// ── Tool Call Format Tests ────────────────────────────────────────

#[test]
fn test_tool_call_format_openai_standard() {
    let profile = CompatibilityProfile::openai_default();
    assert_eq!(profile.tool_call_format, ToolCallFormat::Standard);
}

#[test]
fn test_tool_call_format_zai_standard() {
    let profile = CompatibilityProfile::zai();
    assert_eq!(profile.tool_call_format, ToolCallFormat::Standard);
}

#[test]
fn test_tool_call_format_deepseek_standard() {
    let profile = CompatibilityProfile::deepseek();
    assert_eq!(profile.tool_call_format, ToolCallFormat::Standard);
}

#[test]
fn test_tool_call_format_minimax_no_streaming() {
    let profile = CompatibilityProfile::minimax();
    assert_eq!(profile.tool_call_format, ToolCallFormat::NoStreaming);
}

#[test]
fn test_tool_call_format_ollama_standard() {
    let profile = CompatibilityProfile::ollama();
    assert_eq!(profile.tool_call_format, ToolCallFormat::Standard);
}

// ── Stream Options Tests ──────────────────────────────────────────

#[test]
fn test_stream_options_openai_needed() {
    let profile = CompatibilityProfile::openai_default();
    assert!(profile.needs_stream_options);
    assert!(profile.supports_stream_usage);
}

#[test]
fn test_stream_options_zai_not_needed() {
    let profile = CompatibilityProfile::zai();
    assert!(!profile.needs_stream_options);
    // z.ai still supports stream usage, just doesn't need stream_options
    assert!(profile.supports_stream_usage);
}

#[test]
fn test_stream_options_deepseek_not_needed() {
    let profile = CompatibilityProfile::deepseek();
    assert!(!profile.needs_stream_options);
    assert!(!profile.supports_stream_usage);
}

#[test]
fn test_stream_options_minimax_not_needed() {
    let profile = CompatibilityProfile::minimax();
    assert!(!profile.needs_stream_options);
}

#[test]
fn test_stream_options_ollama_not_needed() {
    let profile = CompatibilityProfile::ollama();
    assert!(!profile.needs_stream_options);
    assert!(!profile.supports_stream_usage);
}

// ── System Message Support Tests ──────────────────────────────────

#[test]
fn test_system_message_support_all_profiles() {
    // All current profiles support system messages
    assert!(CompatibilityProfile::openai_default().supports_system_message);
    assert!(CompatibilityProfile::zai().supports_system_message);
    assert!(CompatibilityProfile::deepseek().supports_system_message);
    assert!(CompatibilityProfile::minimax().supports_system_message);
    assert!(CompatibilityProfile::ollama().supports_system_message);
}

// ── Streaming Support Tests ───────────────────────────────────────

#[test]
fn test_streaming_support_all_profiles() {
    // All current profiles support streaming
    assert!(CompatibilityProfile::openai_default().supports_streaming);
    assert!(CompatibilityProfile::zai().supports_streaming);
    assert!(CompatibilityProfile::deepseek().supports_streaming);
    assert!(CompatibilityProfile::minimax().supports_streaming);
    assert!(CompatibilityProfile::ollama().supports_streaming);
}

// ── Stop Sequence Field Tests ─────────────────────────────────────

#[test]
fn test_stop_sequence_field_defaults() {
    // All current profiles use "stop" field (not "stop_sequences")
    assert_eq!(
        CompatibilityProfile::openai_default().stop_sequence_field,
        StopSequenceField::Stop
    );
    assert_eq!(
        CompatibilityProfile::zai().stop_sequence_field,
        StopSequenceField::Stop
    );
    assert_eq!(
        CompatibilityProfile::deepseek().stop_sequence_field,
        StopSequenceField::Stop
    );
    assert_eq!(
        CompatibilityProfile::minimax().stop_sequence_field,
        StopSequenceField::Stop
    );
    assert_eq!(
        CompatibilityProfile::ollama().stop_sequence_field,
        StopSequenceField::Stop
    );
}

// ── API Path Override Tests ───────────────────────────────────────

#[test]
fn test_api_path_override_defaults() {
    // Standard profiles use default path (None)
    assert_eq!(
        CompatibilityProfile::openai_default().api_path_override,
        None
    );
    assert_eq!(CompatibilityProfile::zai().api_path_override, None);
    assert_eq!(CompatibilityProfile::deepseek().api_path_override, None);
    assert_eq!(CompatibilityProfile::minimax().api_path_override, None);
    assert_eq!(CompatibilityProfile::ollama().api_path_override, None);
}

#[test]
fn test_api_path_override_custom() {
    let profile = CompatibilityProfile::new("custom").with_api_path("/api/custom");
    assert_eq!(profile.api_path_override, Some("/api/custom".to_string()));
}

// ── Enum Serialization Tests ──────────────────────────────────────

#[test]
fn test_max_tokens_field_serde() {
    let field1 = MaxTokensField::MaxTokens;
    let json1 = serde_json::to_string(&field1).unwrap_or_else(|e| {
        panic!("Serialization failed: {e}");
    });
    assert_eq!(json1, "\"max_tokens\"");

    let field2 = MaxTokensField::MaxCompletionTokens;
    let json2 = serde_json::to_string(&field2).unwrap_or_else(|e| {
        panic!("Serialization failed: {e}");
    });
    assert_eq!(json2, "\"max_completion_tokens\"");

    let deserialized1: MaxTokensField = serde_json::from_str(&json1).unwrap_or_else(|e| {
        panic!("Deserialization failed: {e}");
    });
    assert_eq!(deserialized1, MaxTokensField::MaxTokens);

    let deserialized2: MaxTokensField = serde_json::from_str(&json2).unwrap_or_else(|e| {
        panic!("Deserialization failed: {e}");
    });
    assert_eq!(deserialized2, MaxTokensField::MaxCompletionTokens);
}

#[test]
fn test_reasoning_mode_serde() {
    let mode1 = ReasoningMode::None;
    let json1 = serde_json::to_string(&mode1).unwrap_or_else(|e| {
        panic!("Serialization failed: {e}");
    });
    assert_eq!(json1, "\"none\"");

    let mode2 = ReasoningMode::OpenAiO1Style;
    let json2 = serde_json::to_string(&mode2).unwrap_or_else(|e| {
        panic!("Serialization failed: {e}");
    });
    assert_eq!(json2, "\"open_ai_o1_style\"");

    let mode3 = ReasoningMode::DeepSeekThinking;
    let json3 = serde_json::to_string(&mode3).unwrap_or_else(|e| {
        panic!("Serialization failed: {e}");
    });
    assert_eq!(json3, "\"deep_seek_thinking\"");
}

#[test]
fn test_tool_call_format_serde() {
    let format1 = ToolCallFormat::Standard;
    let json1 = serde_json::to_string(&format1).unwrap_or_else(|e| {
        panic!("Serialization failed: {e}");
    });
    assert_eq!(json1, "\"standard\"");

    let format2 = ToolCallFormat::NoStreaming;
    let json2 = serde_json::to_string(&format2).unwrap_or_else(|e| {
        panic!("Serialization failed: {e}");
    });
    assert_eq!(json2, "\"no_streaming\"");

    let format3 = ToolCallFormat::Unsupported;
    let json3 = serde_json::to_string(&format3).unwrap_or_else(|e| {
        panic!("Serialization failed: {e}");
    });
    assert_eq!(json3, "\"unsupported\"");
}

// ── Profile Equality Tests ────────────────────────────────────────

#[test]
fn test_profile_name_uniqueness() {
    let profiles = [
        CompatibilityProfile::openai_default(),
        CompatibilityProfile::zai(),
        CompatibilityProfile::deepseek(),
        CompatibilityProfile::minimax(),
        CompatibilityProfile::ollama(),
    ];

    let names: Vec<&str> = profiles.iter().map(|p| p.name()).collect();

    // All names should be unique
    let mut sorted_names = names.clone();
    sorted_names.sort_unstable();
    sorted_names.dedup();

    assert_eq!(
        names.len(),
        sorted_names.len(),
        "Profile names are not unique"
    );
}

// ── Profile Feature Matrix Tests ──────────────────────────────────

#[test]
fn test_profile_feature_matrix() {
    // This test documents the expected feature matrix for all profiles
    let profiles = [
        ("openai", CompatibilityProfile::openai_default()),
        ("zai", CompatibilityProfile::zai()),
        ("deepseek", CompatibilityProfile::deepseek()),
        ("minimax", CompatibilityProfile::minimax()),
        ("ollama", CompatibilityProfile::ollama()),
    ];

    for (name, profile) in profiles {
        match name {
            "openai" => {
                assert_eq!(profile.max_tokens_field, MaxTokensField::MaxTokens);
                assert_eq!(profile.reasoning_mode, ReasoningMode::OpenAiO1Style);
                assert!(profile.needs_stream_options);
                assert_eq!(profile.tool_call_format, ToolCallFormat::Standard);
            }
            "zai" => {
                assert_eq!(
                    profile.max_tokens_field,
                    MaxTokensField::MaxCompletionTokens
                );
                assert_eq!(profile.reasoning_mode, ReasoningMode::None);
                assert!(!profile.needs_stream_options);
                assert_eq!(profile.tool_call_format, ToolCallFormat::Standard);
            }
            "deepseek" => {
                assert_eq!(profile.max_tokens_field, MaxTokensField::MaxTokens);
                assert_eq!(profile.reasoning_mode, ReasoningMode::DeepSeekThinking);
                assert!(!profile.needs_stream_options);
                assert!(!profile.supports_stream_usage);
                assert_eq!(profile.tool_call_format, ToolCallFormat::Standard);
            }
            "minimax" => {
                assert_eq!(profile.max_tokens_field, MaxTokensField::MaxTokens);
                assert_eq!(profile.reasoning_mode, ReasoningMode::None);
                assert!(!profile.needs_stream_options);
                assert_eq!(profile.tool_call_format, ToolCallFormat::NoStreaming);
            }
            "ollama" => {
                assert_eq!(profile.max_tokens_field, MaxTokensField::MaxTokens);
                assert_eq!(profile.reasoning_mode, ReasoningMode::None);
                assert!(!profile.needs_stream_options);
                assert!(!profile.supports_stream_usage);
                assert_eq!(profile.tool_call_format, ToolCallFormat::Standard);
            }
            _ => panic!("Unknown profile: {name}"),
        }
    }
}
