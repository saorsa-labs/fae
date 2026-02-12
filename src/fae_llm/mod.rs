//! FAE LLM module — multi-provider LLM integration.
//!
//! This module provides the foundational types for interacting with
//! multiple LLM providers (OpenAI, Anthropic, local endpoints, etc.)
//! through a normalized interface.
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
//! - [`providers`] — Provider implementations (OpenAI, etc.)
//!
//! # Event Model
//!
//! All providers normalize their streaming output to [`events::LlmEvent`],
//! providing a consistent interface regardless of the underlying API.
//!
//! # Error Codes
//!
//! All errors carry a stable code (e.g. `CONFIG_INVALID`, `AUTH_FAILED`)
//! that is safe to match on programmatically.

pub mod config;
pub mod error;
pub mod events;
pub mod metadata;
pub mod provider;
pub mod providers;
pub mod tools;
pub mod types;
pub mod usage;

pub use config::{
    ConfigEditor, ConfigService, DefaultsConfig, FaeLlmConfig, ModelConfig, ModelTier, ModelUpdate,
    ProviderConfig, ProviderUpdate, RuntimeConfig, SecretRef, ToolConfig, ToolMode, backup_config,
    default_config, ensure_config_exists, read_config, validate_config, write_config_atomic,
};
pub use error::FaeLlmError;
pub use events::{FinishReason, LlmEvent};
pub use metadata::{RequestMeta, ResponseMeta};
pub use provider::{LlmEventStream, ProviderAdapter, ToolDefinition};
pub use providers::local_probe::{
    LocalModel, LocalProbeService, ProbeConfig, ProbeResult, ProbeStatus,
};
pub use providers::message::{AssistantToolCall, Message, MessageContent, Role};
pub use providers::openai::{OpenAiAdapter, OpenAiApiMode, OpenAiConfig};
pub use providers::profile::{CompatibilityProfile, ProfileRegistry, resolve_profile};
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
        let model = ModelRef::new("gpt-4o").with_version("2025-01");
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
        assert_eq!(parsed.reasoning_level, ReasoningLevel::Medium);

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
        let resp = ResponseMeta::new("req-1", "gpt-4o", FinishReason::Stop, 1200)
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

    // ── Provider Integration Tests ────────────────────────────

    /// Full SSE text stream: parse raw SSE bytes → LlmEvent sequence.
    #[test]
    fn provider_integration_completions_text_stream() {
        use providers::openai::{ToolCallAccumulator, parse_completions_chunk};
        use providers::sse::parse_sse_text;

        let raw = concat!(
            "data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"delta\":{\"role\":\"assistant\"},\"index\":0}]}\n\n",
            "data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"delta\":{\"content\":\"The\"},\"index\":0}]}\n\n",
            "data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"delta\":{\"content\":\" answer\"},\"index\":0}]}\n\n",
            "data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"delta\":{\"content\":\" is 42.\"},\"index\":0}]}\n\n",
            "data: {\"id\":\"chatcmpl-1\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\",\"index\":0}],\"usage\":{\"prompt_tokens\":10,\"completion_tokens\":5}}\n\n",
            "data: [DONE]\n\n",
        );

        let sse_events = parse_sse_text(raw);
        let mut acc = ToolCallAccumulator::new();
        let mut all_events = Vec::new();

        for sse in &sse_events {
            if sse.is_done() {
                continue;
            }
            all_events.extend(parse_completions_chunk(&sse.data, &mut acc, None));
        }

        // Collect text
        let text: String = all_events
            .iter()
            .filter_map(|e| match e {
                LlmEvent::TextDelta { text } => Some(text.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(text, "The answer is 42.");

        // Verify stream ends correctly
        assert!(all_events.last().is_some_and(|e| matches!(
            e,
            LlmEvent::StreamEnd {
                finish_reason: FinishReason::Stop
            }
        )));
    }

    /// Full SSE tool call stream: parse raw SSE → tool events.
    #[test]
    fn provider_integration_completions_tool_stream() {
        use providers::openai::{ToolCallAccumulator, parse_completions_chunk};
        use providers::sse::parse_sse_text;

        let raw = concat!(
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_abc\",\"type\":\"function\",\"function\":{\"name\":\"read\",\"arguments\":\"\"}}]},\"index\":0}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"path\\\":\\\"src/\"}}]},\"index\":0}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"main.rs\\\"}\"}}]},\"index\":0}]}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\",\"index\":0}]}\n\n",
            "data: [DONE]\n\n",
        );

        let sse_events = parse_sse_text(raw);
        let mut acc = ToolCallAccumulator::new();
        let mut all_events = Vec::new();

        for sse in &sse_events {
            if sse.is_done() {
                continue;
            }
            all_events.extend(parse_completions_chunk(&sse.data, &mut acc, None));
        }

        // Verify tool call sequence: Start, ArgsDelta, ArgsDelta, End, StreamEnd
        let starts: Vec<_> = all_events
            .iter()
            .filter(|e| matches!(e, LlmEvent::ToolCallStart { .. }))
            .collect();
        assert_eq!(starts.len(), 1);

        let ends: Vec<_> = all_events
            .iter()
            .filter(|e| matches!(e, LlmEvent::ToolCallEnd { .. }))
            .collect();
        assert_eq!(ends.len(), 1);

        // Collect args
        let args: String = all_events
            .iter()
            .filter_map(|e| match e {
                LlmEvent::ToolCallArgsDelta { args_fragment, .. } => Some(args_fragment.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(args, r#"{"path":"src/main.rs"}"#);

        // Finish reason
        assert!(all_events.last().is_some_and(|e| matches!(
            e,
            LlmEvent::StreamEnd {
                finish_reason: FinishReason::ToolCalls
            }
        )));
    }

    /// Parallel tool calls in a single response.
    #[test]
    fn provider_integration_parallel_tool_calls() {
        use providers::openai::{ToolCallAccumulator, parse_completions_chunk};
        use providers::sse::parse_sse_text;

        let raw = concat!(
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"function\":{\"name\":\"read\",\"arguments\":\"\"}},{\"index\":1,\"id\":\"call_2\",\"function\":{\"name\":\"bash\",\"arguments\":\"\"}}]},\"index\":0}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{\\\"p\\\":\\\"a\\\"}\"}}]},\"index\":0}]}\n\n",
            "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":1,\"function\":{\"arguments\":\"{\\\"c\\\":\\\"ls\\\"}\"}}]},\"index\":0}]}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\",\"index\":0}]}\n\n",
            "data: [DONE]\n\n",
        );

        let sse_events = parse_sse_text(raw);
        let mut acc = ToolCallAccumulator::new();
        let mut all_events = Vec::new();

        for sse in &sse_events {
            if sse.is_done() {
                continue;
            }
            all_events.extend(parse_completions_chunk(&sse.data, &mut acc, None));
        }

        let starts: Vec<_> = all_events
            .iter()
            .filter(|e| matches!(e, LlmEvent::ToolCallStart { .. }))
            .collect();
        assert_eq!(starts.len(), 2);

        let ends: Vec<_> = all_events
            .iter()
            .filter(|e| matches!(e, LlmEvent::ToolCallEnd { .. }))
            .collect();
        assert_eq!(ends.len(), 2);
    }

    /// Responses API text stream integration.
    #[test]
    fn provider_integration_responses_text_stream() {
        use providers::openai::{ToolCallAccumulator, parse_responses_event};
        use providers::sse::parse_sse_text;

        let raw = concat!(
            "event: response.output_text.delta\ndata: {\"delta\":\"Hello \"}\n\n",
            "event: response.output_text.delta\ndata: {\"delta\":\"world!\"}\n\n",
            "event: response.completed\ndata: {\"response\":{\"status\":\"completed\"}}\n\n",
        );

        let sse_events = parse_sse_text(raw);
        let mut acc = ToolCallAccumulator::new();
        let mut all_events = Vec::new();

        for sse in &sse_events {
            let event_type = sse.event_type.as_deref().unwrap_or("");
            all_events.extend(parse_responses_event(event_type, &sse.data, &mut acc, None));
        }

        let text: String = all_events
            .iter()
            .filter_map(|e| match e {
                LlmEvent::TextDelta { text } => Some(text.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(text, "Hello world!");

        assert!(all_events.last().is_some_and(|e| matches!(
            e,
            LlmEvent::StreamEnd {
                finish_reason: FinishReason::Stop
            }
        )));
    }

    /// Incremental SSE parsing (split across byte chunks).
    #[test]
    fn provider_integration_incremental_sse() {
        use providers::openai::{ToolCallAccumulator, parse_completions_chunk};
        use providers::sse::SseLineParser;

        let raw = b"data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}, \"index\":0}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\",\"index\":0}]}\n\ndata: [DONE]\n\n";

        // Split arbitrarily into two chunks
        let mid = raw.len() / 2;
        let chunk1 = &raw[..mid];
        let chunk2 = &raw[mid..];

        let mut parser = SseLineParser::new();
        let mut acc = ToolCallAccumulator::new();
        let mut all_events = Vec::new();

        for sse in parser.push(chunk1) {
            if !sse.is_done() {
                all_events.extend(parse_completions_chunk(&sse.data, &mut acc, None));
            }
        }
        for sse in parser.push(chunk2) {
            if !sse.is_done() {
                all_events.extend(parse_completions_chunk(&sse.data, &mut acc, None));
            }
        }

        let text: String = all_events
            .iter()
            .filter_map(|e| match e {
                LlmEvent::TextDelta { text } => Some(text.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(text, "Hi");
    }

    /// Malformed SSE data does not panic, gracefully returns empty events.
    #[test]
    fn provider_integration_malformed_sse_graceful() {
        use providers::openai::{ToolCallAccumulator, parse_completions_chunk};
        use providers::sse::parse_sse_text;

        let raw = concat!(
            "data: not-json-at-all\n\n",
            "data: {\"completely\":\"wrong structure\"}\n\n",
            "data: {\"choices\":\"not-an-array\"}\n\n",
            "data: {\"choices\":[{\"no-delta\":true}]}\n\n",
            "data: \n\n",
        );

        let sse_events = parse_sse_text(raw);
        let mut acc = ToolCallAccumulator::new();
        let mut all_events = Vec::new();

        for sse in &sse_events {
            if sse.is_done() {
                continue;
            }
            all_events.extend(parse_completions_chunk(&sse.data, &mut acc, None));
        }

        // No events emitted from malformed data, no panics
        assert!(all_events.is_empty());
    }

    /// Empty stream produces no events.
    #[test]
    fn provider_integration_empty_stream() {
        use providers::sse::parse_sse_text;

        let sse_events = parse_sse_text("data: [DONE]\n\n");
        // Only the DONE sentinel, which is filtered
        assert_eq!(sse_events.len(), 1);
        assert!(sse_events[0].is_done());
    }

    /// HTTP error mapping covers key status codes.
    #[test]
    fn provider_integration_error_mapping() {
        let auth_err = providers::openai::OpenAiAdapter::map_http_error(
            reqwest::StatusCode::UNAUTHORIZED,
            r#"{"error":{"message":"Incorrect API key"}}"#,
        );
        assert_eq!(auth_err.code(), "AUTH_FAILED");

        let rate_err = providers::openai::OpenAiAdapter::map_http_error(
            reqwest::StatusCode::TOO_MANY_REQUESTS,
            r#"{"error":{"message":"Rate limit exceeded"}}"#,
        );
        assert_eq!(rate_err.code(), "REQUEST_FAILED");

        let server_err = providers::openai::OpenAiAdapter::map_http_error(
            reqwest::StatusCode::INTERNAL_SERVER_ERROR,
            "Internal error",
        );
        assert_eq!(server_err.code(), "PROVIDER_ERROR");
    }

    /// OpenAI adapter provides correct name.
    #[test]
    fn provider_integration_adapter_name() {
        let config = OpenAiConfig::new("test-key", "gpt-4o");
        let adapter = OpenAiAdapter::new(config);
        assert_eq!(adapter.name(), "openai");
    }

    /// ToolDefinition round-trips through the request builder.
    #[test]
    fn provider_integration_tool_definition_in_request() {
        use providers::openai::build_completions_request;

        let tools = vec![
            ToolDefinition::new(
                "read",
                "Read file content",
                serde_json::json!({
                    "type": "object",
                    "properties": { "path": { "type": "string" } },
                    "required": ["path"]
                }),
            ),
            ToolDefinition::new(
                "bash",
                "Run a command",
                serde_json::json!({
                    "type": "object",
                    "properties": { "command": { "type": "string" } },
                    "required": ["command"]
                }),
            ),
        ];

        let opts = RequestOptions::new();
        let body = build_completions_request("gpt-4o", &[], &opts, &tools);

        let tools_arr = body["tools"].as_array();
        assert!(tools_arr.is_some_and(|t| t.len() == 2));
        if let Some(tools_arr) = tools_arr {
            assert_eq!(tools_arr[0]["function"]["name"], "read");
            assert_eq!(tools_arr[1]["function"]["name"], "bash");
        }
    }

    /// Message types correctly map through the request builder.
    #[test]
    fn provider_integration_message_types_in_request() {
        use providers::openai::build_completions_request;

        let messages = vec![
            Message::system("You are a coding assistant."),
            Message::user("Read main.rs"),
            Message::assistant_with_tool_calls(
                Some("I'll read that for you.".into()),
                vec![AssistantToolCall {
                    call_id: "call_1".into(),
                    function_name: "read".into(),
                    arguments: r#"{"path":"main.rs"}"#.into(),
                }],
            ),
            Message::tool_result("call_1", "fn main() {}"),
            Message::assistant("Here's the file content."),
        ];

        let opts = RequestOptions::new();
        let body = build_completions_request("gpt-4o", &messages, &opts, &[]);

        let msgs = body["messages"].as_array();
        assert!(msgs.is_some_and(|m| m.len() == 5));
        if let Some(msgs) = msgs {
            assert_eq!(msgs[0]["role"], "system");
            assert_eq!(msgs[1]["role"], "user");
            assert_eq!(msgs[2]["role"], "assistant");
            assert!(msgs[2]["tool_calls"].is_array());
            assert_eq!(msgs[3]["role"], "tool");
            assert_eq!(msgs[3]["tool_call_id"], "call_1");
            assert_eq!(msgs[4]["role"], "assistant");
        }
    }

    // ── Profile Integration Tests ─────────────────────────────

    /// Build a request for z.ai and verify field names match expectations.
    #[test]
    fn profile_integration_zai_request() {
        use providers::openai::build_completions_request;
        use providers::profile::apply_profile_to_request;

        let profile = CompatibilityProfile::zai();
        let opts = RequestOptions::new()
            .with_max_tokens(4096)
            .with_stream(true)
            .with_temperature(0.5);
        let messages = vec![Message::user("Hello")];
        let mut body = build_completions_request("zai-model", &messages, &opts, &[]);
        apply_profile_to_request(&mut body, &profile);

        // z.ai: max_tokens -> max_completion_tokens
        assert!(body.get("max_tokens").is_none());
        assert_eq!(body["max_completion_tokens"], 4096);
        // z.ai: no stream_options
        assert!(body.get("stream_options").is_none());
        // Temperature preserved
        assert_eq!(body["temperature"], 0.5);
    }

    /// Build a request for DeepSeek and verify field names.
    #[test]
    fn profile_integration_deepseek_request() {
        use providers::openai::build_completions_request;
        use providers::profile::apply_profile_to_request;

        let profile = CompatibilityProfile::deepseek();
        let opts = RequestOptions::new()
            .with_max_tokens(2048)
            .with_stream(true);
        let mut body =
            build_completions_request("deepseek-chat", &[Message::user("Hi")], &opts, &[]);
        apply_profile_to_request(&mut body, &profile);

        // DeepSeek: keeps max_tokens
        assert_eq!(body["max_tokens"], 2048);
        assert!(body.get("max_completion_tokens").is_none());
        // DeepSeek: no stream_options
        assert!(body.get("stream_options").is_none());
    }

    /// Build a request for MiniMax and verify tool format.
    #[test]
    fn profile_integration_minimax_request() {
        use providers::openai::build_completions_request;
        use providers::profile::apply_profile_to_request;

        let profile = CompatibilityProfile::minimax();
        let tools = vec![ToolDefinition::new(
            "read",
            "Read a file",
            serde_json::json!({"type": "object", "properties": {"path": {"type": "string"}}}),
        )];
        let opts = RequestOptions::new().with_max_tokens(1024);
        let mut body =
            build_completions_request("minimax-01", &[Message::user("Hi")], &opts, &tools);
        apply_profile_to_request(&mut body, &profile);

        // MiniMax: keeps max_tokens
        assert_eq!(body["max_tokens"], 1024);
        // Tools are present
        assert!(body["tools"].is_array());
    }

    /// Build a request for Ollama (local) and verify defaults.
    #[test]
    fn profile_integration_ollama_request() {
        use providers::openai::build_completions_request;
        use providers::profile::apply_profile_to_request;

        let profile = CompatibilityProfile::ollama();
        let opts = RequestOptions::new().with_max_tokens(512).with_stream(true);
        let mut body = build_completions_request("llama3", &[Message::user("Hi")], &opts, &[]);
        apply_profile_to_request(&mut body, &profile);

        // Ollama: keeps max_tokens
        assert_eq!(body["max_tokens"], 512);
        // Ollama: no stream_options
        assert!(body.get("stream_options").is_none());
    }

    /// Custom profile overrides a built-in profile.
    #[test]
    fn profile_integration_custom_override() {
        use providers::profile::ProfileRegistry;

        let mut registry = ProfileRegistry::new();
        let custom = CompatibilityProfile::new("my-deepseek").with_system_message_support(false);
        registry.register("deepseek", custom);

        let profile = registry.resolve("deepseek");
        assert_eq!(profile.name(), "my-deepseek");
        assert!(!profile.supports_system_message);
    }

    /// Unknown providers fall back to OpenAI defaults end-to-end.
    #[test]
    fn profile_integration_unknown_provider_fallback() {
        let profile = resolve_profile("some-random-llm");
        assert_eq!(profile.name(), "openai");
        assert!(profile.needs_stream_options);
    }

    /// DeepSeek profile normalizes "thinking_done" finish reason in a full stream.
    #[test]
    fn profile_integration_deepseek_thinking_stream() {
        use providers::openai::{ToolCallAccumulator, parse_completions_chunk};
        use providers::sse::parse_sse_text;

        let profile = CompatibilityProfile::deepseek();
        let sse_data = concat!(
            "data: {\"choices\":[{\"delta\":{\"content\":\"Result\"},\"index\":0}]}\n\n",
            "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"thinking_done\",\"index\":0}]}\n\n",
            "data: [DONE]\n\n",
        );

        let sse_events = parse_sse_text(sse_data);
        let mut acc = ToolCallAccumulator::new();
        let mut all_events = Vec::new();

        for sse in &sse_events {
            if sse.is_done() {
                continue;
            }
            all_events.extend(parse_completions_chunk(&sse.data, &mut acc, Some(&profile)));
        }

        // Text was captured
        let text: String = all_events
            .iter()
            .filter_map(|e| match e {
                LlmEvent::TextDelta { text } => Some(text.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(text, "Result");

        // "thinking_done" was normalized to Stop
        let last = all_events.last();
        assert!(last.is_some_and(|e| matches!(
            e,
            LlmEvent::StreamEnd {
                finish_reason: FinishReason::Stop
            }
        )));
    }

    // ── Local Probe Integration Tests ─────────────────────────

    /// ProbeConfig default values are sensible.
    #[test]
    fn probe_integration_config_defaults() {
        let config = ProbeConfig::default();
        assert_eq!(config.endpoint_url, "http://localhost:11434");
        assert_eq!(config.timeout_secs, 5);
        assert_eq!(config.retry_count, 2);
        assert_eq!(config.retry_delay_ms, 500);
    }

    /// All ProbeStatus variants can be constructed.
    #[test]
    fn probe_integration_status_construction() {
        let available = ProbeStatus::Available {
            models: vec![LocalModel::new("llama3:8b")],
            endpoint_url: "http://localhost:11434".to_string(),
            latency_ms: 10,
        };
        assert!(available.is_available());

        let not_running = ProbeStatus::NotRunning;
        assert!(!not_running.is_available());

        let timeout = ProbeStatus::Timeout;
        assert!(!timeout.is_available());

        let unhealthy = ProbeStatus::Unhealthy {
            status_code: 503,
            message: "overloaded".to_string(),
        };
        assert!(!unhealthy.is_available());

        let incompat = ProbeStatus::IncompatibleResponse {
            detail: "HTML".to_string(),
        };
        assert!(!incompat.is_available());
    }

    /// ProbeStatus JSON serialization round-trip for all variants.
    #[test]
    fn probe_integration_status_serde() {
        let statuses: Vec<ProbeStatus> = vec![
            ProbeStatus::Available {
                models: vec![
                    LocalModel::new("a"),
                    LocalModel::new("b").with_name("Model B"),
                ],
                endpoint_url: "http://localhost:8080".to_string(),
                latency_ms: 42,
            },
            ProbeStatus::NotRunning,
            ProbeStatus::Timeout,
            ProbeStatus::Unhealthy {
                status_code: 500,
                message: "error".to_string(),
            },
            ProbeStatus::IncompatibleResponse {
                detail: "bad format".to_string(),
            },
        ];

        for status in &statuses {
            let json = serde_json::to_string(status).unwrap_or_default();
            assert!(!json.is_empty());
            let parsed: Result<ProbeStatus, _> = serde_json::from_str(&json);
            assert!(parsed.is_ok(), "failed to parse: {json}");
        }
    }

    /// ProbeStatus convenience methods work correctly.
    #[test]
    fn probe_integration_convenience_methods() {
        let available = ProbeStatus::Available {
            models: vec![LocalModel::new("llama3"), LocalModel::new("mistral")],
            endpoint_url: "http://localhost:11434".to_string(),
            latency_ms: 5,
        };
        assert!(available.is_available());
        assert_eq!(available.models().len(), 2);
        assert_eq!(
            available.endpoint_url(),
            Some("http://localhost:11434" as &str)
        );

        let not_running = ProbeStatus::NotRunning;
        assert!(!not_running.is_available());
        assert!(not_running.models().is_empty());
        assert!(not_running.endpoint_url().is_none());
    }

    /// Probing an unreachable port returns NotRunning or Timeout.
    #[tokio::test]
    async fn probe_integration_unreachable_endpoint() {
        let config = ProbeConfig::new("http://127.0.0.1:19998")
            .with_timeout_secs(1)
            .with_retry_count(0);
        let service = LocalProbeService::new(config);
        let result = service.probe().await;
        assert!(result.is_ok());
        let status = result.unwrap_or(ProbeStatus::IncompatibleResponse {
            detail: "bad".into(),
        });
        assert!(
            matches!(status, ProbeStatus::NotRunning | ProbeStatus::Timeout),
            "expected NotRunning or Timeout, got: {status}"
        );
    }

    /// Display output is human-readable for all variants.
    #[test]
    fn probe_integration_display_output() {
        let statuses: Vec<ProbeStatus> = vec![
            ProbeStatus::Available {
                models: vec![LocalModel::new("x")],
                endpoint_url: "http://localhost:11434".to_string(),
                latency_ms: 10,
            },
            ProbeStatus::NotRunning,
            ProbeStatus::Timeout,
            ProbeStatus::Unhealthy {
                status_code: 404,
                message: "not found".to_string(),
            },
            ProbeStatus::IncompatibleResponse {
                detail: "HTML page".to_string(),
            },
        ];

        for status in &statuses {
            let display = status.to_string();
            assert!(!display.is_empty());
            // Verify display contains meaningful content
            assert!(display.len() > 5);
        }
    }

    /// All probe-related types are Send + Sync.
    #[test]
    fn probe_integration_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<ProbeStatus>();
        assert_send_sync::<ProbeConfig>();
        assert_send_sync::<LocalModel>();
        assert_send_sync::<LocalProbeService>();
        assert_send_sync::<providers::local_probe::ProbeError>();
    }

    /// LocalModel display name fallback behavior.
    #[test]
    fn probe_integration_local_model_display() {
        let with_name = LocalModel::new("llama3:8b").with_name("Llama 3 8B");
        assert_eq!(with_name.to_string(), "Llama 3 8B");

        let without_name = LocalModel::new("qwen2:7b");
        assert_eq!(without_name.to_string(), "qwen2:7b");
    }
}
