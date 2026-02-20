//! FAE LLM module — embedded local LLM integration.
//!
//! This module provides the foundational types for interacting with
//! locally downloaded embedded models through a normalized interface.
//!
//! # Submodules
//!
//! - [`error`] — Error types with stable error codes
//! - [`types`] — Core domain types (endpoints, models, request options)
//! - [`events`] — Normalized streaming event model
//! - [`usage`] — Token usage and cost tracking
//! - [`metadata`] — Request/response metadata
//! - [`config`] — Configuration schema and persistence
//! - [`provider`] — Provider adapter trait
//! - [`providers`] — Local provider implementations (embedded GGUF inference)
//! - [`agent`] — Agent loop engine with tool calling
//! - [`session`] — Session persistence, validation, and conversation context
//! - [`observability`] — Structured tracing, metrics, and secret redaction
//!
//! # Event Model
//!
//! All providers normalize their streaming output to [`events::LlmEvent`],
//! providing a consistent interface regardless of the underlying model.
//!
//! # Error Codes
//!
//! All errors carry a stable code (e.g. `CONFIG_INVALID`, `AUTH_FAILED`)
//! that is safe to match on programmatically.

pub mod agent;
pub mod config;
pub mod error;
pub mod events;
pub mod metadata;
pub mod observability;
pub mod provider;
pub mod providers;
pub mod session;
pub mod tools;
pub mod types;
pub mod usage;

pub use agent::{
    AccumulatedToolCall, AccumulatedTurn, AgentConfig, AgentLoop, AgentLoopResult,
    ExecutedToolCall, StopReason, StreamAccumulator, ToolExecutor, TurnResult,
    build_messages_from_result, validate_tool_args,
};
pub use config::{
    ConfigEditor, ConfigService, DefaultsConfig, FaeLlmConfig, ModelConfig, ModelTier, ModelUpdate,
    ProviderConfig, ProviderUpdate, RuntimeConfig, SecretRef, ToolConfig, ToolMode, backup_config,
    default_config, ensure_config_exists, read_config, validate_config, write_config_atomic,
};
pub use error::FaeLlmError;
pub use events::{AssistantEvent, FinishReason, LlmEvent};
pub use metadata::{RequestMeta, ResponseMeta};
pub use provider::{
    AssistantEventStream, ConversationContext as ProviderConversationContext, LlmError,
    LlmEventStream, ProviderAdapter, ToolDefinition,
};
pub use providers::message::{AssistantToolCall, Message, MessageContent, Role};
pub use session::{
    ConversationContext, FsSessionStore, MemorySessionStore, Session, SessionId, SessionMeta,
    SessionResumeError, SessionStore, validate_message_sequence, validate_session,
};
pub use tools::{BashTool, EditTool, ReadTool, Tool, ToolRegistry, ToolResult, WriteTool};
pub use types::{EndpointType, ModelRef, ReasoningLevel, RequestOptions};
pub use usage::{CostEstimate, TokenPricing, TokenUsage};

#[cfg(test)]
mod integration_tests {
    use super::*;

    /// Simulate a full event stream: start → thinking → text → tool call → text → end.
    #[test]
    fn full_event_stream_lifecycle() {
        let model = ModelRef::new("claude-opus-4").with_version("2025-04-14");
        let request = RequestMeta::new("req-integration-1", model.clone());

        let events = [
            LlmEvent::StreamStart {
                request_id: request.request_id.clone(),
                model,
            },
            LlmEvent::ThinkingStart,
            LlmEvent::ThinkingDelta {
                text: "Let me analyze this...".into(),
            },
            LlmEvent::ThinkingEnd,
            LlmEvent::TextDelta {
                text: "I'll read the file first.".into(),
            },
            LlmEvent::ToolCallStart {
                call_id: "tc_1".into(),
                function_name: "read_file".into(),
            },
            LlmEvent::ToolCallArgsDelta {
                call_id: "tc_1".into(),
                args_fragment: r#"{"path":"src/main.rs"}"#.into(),
            },
            LlmEvent::ToolCallEnd {
                call_id: "tc_1".into(),
            },
            LlmEvent::TextDelta {
                text: "Here's the result.".into(),
            },
            LlmEvent::StreamEnd {
                finish_reason: FinishReason::Stop,
            },
        ];

        // Verify stream structure
        assert!(matches!(events[0], LlmEvent::StreamStart { .. }));
        assert!(matches!(
            events[events.len() - 1],
            LlmEvent::StreamEnd { .. }
        ));

        // Collect text output
        let text: String = events
            .iter()
            .filter_map(|e| match e {
                LlmEvent::TextDelta { text } => Some(text.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(text, "I'll read the file first.Here's the result.");

        // Build response metadata
        let response = ResponseMeta::new(
            &request.request_id,
            "claude-opus-4-20250414",
            FinishReason::Stop,
            request.elapsed_ms(),
        )
        .with_usage(TokenUsage::new(800, 350).with_reasoning_tokens(100));

        assert_eq!(response.request_id, "req-integration-1");
        assert!(response.usage.is_some_and(|u| u.total() == 1250));
    }

    /// Accumulate TokenUsage across a multi-turn conversation and calculate cost.
    #[test]
    fn multi_turn_usage_accumulation_with_cost() {
        let pricing = TokenPricing::new(15.0, 75.0); // Claude Opus pricing

        let turns = [
            TokenUsage::new(500, 200),
            TokenUsage::new(700, 300).with_reasoning_tokens(100),
            TokenUsage::new(1200, 400).with_reasoning_tokens(50),
            TokenUsage::new(1800, 600),
        ];

        let mut total = TokenUsage::default();
        for turn in &turns {
            total.add(turn);
        }

        assert_eq!(total.prompt_tokens, 4200);
        assert_eq!(total.completion_tokens, 1500);
        assert_eq!(total.reasoning_tokens, Some(150));
        assert_eq!(total.total(), 5850);

        let cost = CostEstimate::calculate(&total, &pricing);
        // Input: 4200/1M * $15 = $0.063
        // Output: (1500 + 150)/1M * $75 = $0.12375
        let expected = 0.063 + 0.12375;
        assert!((cost.usd - expected).abs() < 0.000001);
    }

    /// All serializable types round-trip through JSON correctly.
    #[test]
    fn json_serialization_round_trip_all_types() {
        // EndpointType
        let endpoint = EndpointType::Anthropic;
        let json = serde_json::to_string(&endpoint).unwrap_or_default();
        let parsed: EndpointType = serde_json::from_str(&json).unwrap_or(EndpointType::Custom);
        assert_eq!(parsed, endpoint);

        // ModelRef
        let model = ModelRef::new("llama3:8b").with_version("2025-01");
        let json = serde_json::to_string(&model).unwrap_or_default();
        let parsed: ModelRef = serde_json::from_str(&json).unwrap_or_else(|_| ModelRef::new(""));
        assert_eq!(parsed, model);

        // ReasoningLevel
        let level = ReasoningLevel::High;
        let json = serde_json::to_string(&level).unwrap_or_default();
        let parsed: ReasoningLevel = serde_json::from_str(&json).unwrap_or(ReasoningLevel::Off);
        assert_eq!(parsed, level);

        // RequestOptions
        let opts = RequestOptions::new()
            .with_max_tokens(4096)
            .with_temperature(0.3)
            .with_reasoning(ReasoningLevel::Medium);
        let json = serde_json::to_string(&opts).unwrap_or_default();
        let parsed: RequestOptions = serde_json::from_str(&json).unwrap_or_default();
        assert_eq!(parsed.max_tokens, Some(4096));
        assert_eq!(parsed.reasoning, Some(ReasoningLevel::Medium));

        // FinishReason
        let reason = FinishReason::ToolCalls;
        let json = serde_json::to_string(&reason).unwrap_or_default();
        let parsed: FinishReason = serde_json::from_str(&json).unwrap_or(FinishReason::Other);
        assert_eq!(parsed, reason);

        // TokenUsage
        let usage = TokenUsage::new(1000, 500).with_reasoning_tokens(100);
        let json = serde_json::to_string(&usage).unwrap_or_default();
        let parsed: TokenUsage = serde_json::from_str(&json).unwrap_or_default();
        assert_eq!(parsed, usage);

        // TokenPricing
        let pricing = TokenPricing::new(3.0, 15.0);
        let json = serde_json::to_string(&pricing).unwrap_or_default();
        let parsed: TokenPricing =
            serde_json::from_str(&json).unwrap_or_else(|_| TokenPricing::new(0.0, 0.0));
        assert_eq!(parsed, pricing);

        // CostEstimate
        let cost = CostEstimate::calculate(&usage, &pricing);
        let json = serde_json::to_string(&cost).unwrap_or_default();
        let parsed: serde_json::Value = serde_json::from_str(&json).unwrap_or_default();
        assert!(parsed.get("usd").is_some());
        assert!(parsed.get("pricing").is_some());

        // ResponseMeta
        let resp = ResponseMeta::new("req-1", "llama3:8b", FinishReason::Stop, 1200)
            .with_usage(TokenUsage::new(100, 50));
        let json = serde_json::to_string(&resp).unwrap_or_default();
        let parsed: ResponseMeta = serde_json::from_str(&json)
            .unwrap_or_else(|_| ResponseMeta::new("", "", FinishReason::Other, 0));
        assert_eq!(parsed.request_id, "req-1");
        assert_eq!(parsed.finish_reason, FinishReason::Stop);
    }

    /// All error codes are stable SCREAMING_SNAKE_CASE identifiers.
    #[test]
    fn all_error_codes_are_stable() {
        let errors: [FaeLlmError; 7] = [
            FaeLlmError::ConfigError("x".into()),
            FaeLlmError::AuthError("x".into()),
            FaeLlmError::RequestError("x".into()),
            FaeLlmError::StreamError("x".into()),
            FaeLlmError::ToolError("x".into()),
            FaeLlmError::TimeoutError("x".into()),
            FaeLlmError::ProviderError("x".into()),
        ];

        let expected_codes: [&str; 7] = [
            "CONFIG_INVALID",
            "AUTH_FAILED",
            "REQUEST_FAILED",
            "STREAM_FAILED",
            "TOOL_FAILED",
            "TIMEOUT_ERROR",
            "PROVIDER_ERROR",
        ];

        for (err, expected) in errors.iter().zip(expected_codes.iter()) {
            assert_eq!(err.code(), *expected);
            // Verify code is SCREAMING_SNAKE_CASE
            assert!(
                err.code()
                    .chars()
                    .all(|c: char| c.is_ascii_uppercase() || c == '_'),
                "code {:?} is not SCREAMING_SNAKE_CASE",
                err.code()
            );
            // Verify Display includes the code
            let display = format!("{err}");
            assert!(
                display.starts_with(&format!("[{expected}]")),
                "display {:?} doesn't start with [{expected}]",
                display
            );
        }
    }

    /// RequestMeta and ResponseMeta are linked by request_id.
    #[test]
    fn request_response_correlation() {
        let req = RequestMeta::new("req-corr-1", ModelRef::new("llama3:8b"));

        let resp = ResponseMeta::new(
            &req.request_id,
            "llama3:8b-instruct",
            FinishReason::Length,
            2500,
        )
        .with_usage(TokenUsage::new(2000, 4096));

        assert_eq!(req.request_id, resp.request_id);
        assert_eq!(resp.latency_ms, 2500);
        assert_eq!(resp.finish_reason, FinishReason::Length);
        assert!(resp.usage.is_some_and(|u| u.completion_tokens == 4096));
    }

    /// Multiple endpoint types can be used to configure different providers.
    #[test]
    fn endpoint_type_covers_all_providers() {
        let endpoints = [
            EndpointType::OpenAI,
            EndpointType::Anthropic,
            EndpointType::Local,
            EndpointType::Custom,
        ];

        // All display as lowercase
        for ep in &endpoints {
            let s = ep.to_string();
            assert_eq!(s, s.to_lowercase());
        }

        // All are distinct
        for (i, a) in endpoints.iter().enumerate() {
            for (j, b) in endpoints.iter().enumerate() {
                if i != j {
                    assert_ne!(a, b);
                }
            }
        }
    }
}
