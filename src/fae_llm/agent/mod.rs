//! Agent loop engine for agentic LLM interactions.
//!
//! This module implements the core agent loop: prompt -> stream -> tool calls
//! -> execute -> continue. It provides safety guards (max turns, max tool
//! calls per turn), timeouts (per-request and per-tool), and cancellation
//! propagation.
//!
//! # Architecture
//!
//! ```text
//! AgentLoop
//!   +-- AgentConfig (limits, timeouts, system prompt)
//!   +-- ProviderAdapter (LLM backend)
//!   +-- ToolRegistry (available tools)
//!   +-- CancellationToken (abort signal)
//! ```
//!
//! # Event Flow
//!
//! ```text
//! 1. Send messages to provider (with timeout)
//! 2. Stream response, accumulate text + tool calls
//! 3. If tool calls: validate args, execute tools, append results, loop
//! 4. If complete: return final result
//! 5. If cancelled or limits hit: return with appropriate StopReason
//! ```
//!
//! # Key Types
//!
//! - [`AgentConfig`] — Configuration (limits, timeouts, system prompt)
//! - [`AgentLoop`] — The main loop engine
//! - [`AgentLoopResult`] — Complete output of an agent run
//! - [`TurnResult`] — Output of a single turn (text + tool calls)
//! - [`ExecutedToolCall`] — A tool call with its result and timing
//! - [`StopReason`] — Why the loop stopped
//! - [`StreamAccumulator`] — Collects streaming events into structured data
//! - [`ToolExecutor`] — Executes tools with timeout and cancellation

pub mod accumulator;
pub mod executor;
pub mod loop_engine;
pub mod types;
pub mod validation;

#[cfg(test)]
mod e2e_workflow_tests;

// Re-export key types for convenience
pub use accumulator::{AccumulatedToolCall, AccumulatedTurn, StreamAccumulator};
pub use executor::ToolExecutor;
pub use loop_engine::{AgentLoop, build_messages_from_result};
pub use types::{AgentConfig, AgentLoopResult, ExecutedToolCall, StopReason, TurnResult};
pub use validation::validate_tool_args;

#[cfg(test)]
mod integration_tests {
    use std::sync::{Arc, Mutex};

    use async_trait::async_trait;
    use futures_util::stream;

    use super::*;
    use crate::fae_llm::config::types::ToolMode;
    use crate::fae_llm::error::FaeLlmError;
    use crate::fae_llm::events::{FinishReason, LlmEvent};
    use crate::fae_llm::provider::{LlmEventStream, ProviderAdapter, ToolDefinition};
    use crate::fae_llm::providers::message::Message;
    use crate::fae_llm::tools::registry::ToolRegistry;
    use crate::fae_llm::tools::types::{Tool, ToolResult};
    use crate::fae_llm::types::{ModelRef, RequestOptions};

    // ── Test Infrastructure ──────────────────────────────────

    /// Mock provider returning predetermined event sequences.
    struct MockProvider {
        responses: Mutex<Vec<Vec<LlmEvent>>>,
    }

    impl MockProvider {
        fn new(responses: Vec<Vec<LlmEvent>>) -> Self {
            Self {
                responses: Mutex::new(responses),
            }
        }

        fn text(text: &str) -> Vec<LlmEvent> {
            vec![
                LlmEvent::StreamStart {
                    request_id: "req-1".into(),
                    model: ModelRef::new("mock"),
                },
                LlmEvent::TextDelta { text: text.into() },
                LlmEvent::StreamEnd {
                    finish_reason: FinishReason::Stop,
                },
            ]
        }

        fn tool_call(call_id: &str, fn_name: &str, args: &str) -> Vec<LlmEvent> {
            vec![
                LlmEvent::StreamStart {
                    request_id: "req-1".into(),
                    model: ModelRef::new("mock"),
                },
                LlmEvent::ToolCallStart {
                    call_id: call_id.into(),
                    function_name: fn_name.into(),
                },
                LlmEvent::ToolCallArgsDelta {
                    call_id: call_id.into(),
                    args_fragment: args.into(),
                },
                LlmEvent::ToolCallEnd {
                    call_id: call_id.into(),
                },
                LlmEvent::StreamEnd {
                    finish_reason: FinishReason::ToolCalls,
                },
            ]
        }

        fn error_stream(msg: &str) -> Vec<LlmEvent> {
            vec![
                LlmEvent::StreamStart {
                    request_id: "req-1".into(),
                    model: ModelRef::new("mock"),
                },
                LlmEvent::StreamError { error: msg.into() },
            ]
        }
    }

    #[async_trait]
    impl ProviderAdapter for MockProvider {
        fn name(&self) -> &str {
            "mock"
        }

        async fn send(
            &self,
            _messages: &[Message],
            _options: &RequestOptions,
            _tools: &[ToolDefinition],
        ) -> Result<LlmEventStream, FaeLlmError> {
            let events = {
                let mut responses = self.responses.lock().unwrap_or_else(|e| e.into_inner());
                if responses.is_empty() {
                    vec![
                        LlmEvent::StreamStart {
                            request_id: "req-empty".into(),
                            model: ModelRef::new("mock"),
                        },
                        LlmEvent::StreamEnd {
                            finish_reason: FinishReason::Stop,
                        },
                    ]
                } else {
                    responses.remove(0)
                }
            };
            Ok(Box::pin(stream::iter(events)))
        }
    }

    /// Provider that always fails on send.
    struct FailingProvider;

    #[async_trait]
    impl ProviderAdapter for FailingProvider {
        fn name(&self) -> &str {
            "failing"
        }

        async fn send(
            &self,
            _messages: &[Message],
            _options: &RequestOptions,
            _tools: &[ToolDefinition],
        ) -> Result<LlmEventStream, FaeLlmError> {
            Err(FaeLlmError::RequestError(
                "provider unavailable".to_string(),
            ))
        }
    }

    /// Echo tool: returns its input.
    struct EchoTool;

    impl Tool for EchoTool {
        fn name(&self) -> &str {
            "echo"
        }
        fn description(&self) -> &str {
            "Echo input"
        }
        fn schema(&self) -> serde_json::Value {
            serde_json::json!({
                "type": "object",
                "properties": { "message": { "type": "string" } }
            })
        }
        fn execute(&self, args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
            let msg = args["message"].as_str().unwrap_or("empty");
            Ok(ToolResult::success(msg.to_string()))
        }
        fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
            true
        }
    }

    /// Slow tool for timeout testing.
    struct SlowTool;

    impl Tool for SlowTool {
        fn name(&self) -> &str {
            "slow"
        }
        fn description(&self) -> &str {
            "Slow tool"
        }
        fn schema(&self) -> serde_json::Value {
            serde_json::json!({
                "type": "object",
                "properties": {}
            })
        }
        fn execute(&self, _args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
            std::thread::sleep(std::time::Duration::from_secs(5));
            Ok(ToolResult::success("done".to_string()))
        }
        fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
            true
        }
    }

    fn registry_with_echo() -> Arc<ToolRegistry> {
        let mut reg = ToolRegistry::new(ToolMode::Full);
        reg.register(Arc::new(EchoTool));
        Arc::new(reg)
    }

    fn registry_with_echo_and_slow() -> Arc<ToolRegistry> {
        let mut reg = ToolRegistry::new(ToolMode::Full);
        reg.register(Arc::new(EchoTool));
        reg.register(Arc::new(SlowTool));
        Arc::new(reg)
    }

    fn empty_registry() -> Arc<ToolRegistry> {
        Arc::new(ToolRegistry::new(ToolMode::Full))
    }

    // ── Integration Test: Text-only response ─────────────────

    #[tokio::test]
    async fn integration_text_only_response() {
        let provider = Arc::new(MockProvider::new(vec![MockProvider::text("Hello!")]));
        let agent = AgentLoop::new(AgentConfig::new(), provider, registry_with_echo());

        let result = agent.run("Hi").await;
        assert!(result.is_ok());
        let r = result.unwrap_or_else(|_| unreachable!());
        assert_eq!(r.turns.len(), 1);
        assert_eq!(r.final_text, "Hello!");
        assert_eq!(r.stop_reason, StopReason::Complete);
        assert!(r.turns[0].tool_calls.is_empty());
    }

    // ── Integration Test: Single tool call ───────────────────

    #[tokio::test]
    async fn integration_single_tool_call() {
        let provider = Arc::new(MockProvider::new(vec![
            MockProvider::tool_call("c1", "echo", r#"{"message":"world"}"#),
            MockProvider::text("Echo returned: world"),
        ]));
        let agent = AgentLoop::new(AgentConfig::new(), provider, registry_with_echo());

        let result = agent.run("Echo something").await;
        assert!(result.is_ok());
        let r = result.unwrap_or_else(|_| unreachable!());
        assert_eq!(r.turns.len(), 2);
        assert_eq!(r.turns[0].tool_calls.len(), 1);
        assert_eq!(r.turns[0].tool_calls[0].function_name, "echo");
        assert!(r.turns[0].tool_calls[0].result.success);
        assert_eq!(r.turns[0].tool_calls[0].result.content, "world");
        assert_eq!(r.final_text, "Echo returned: world");
        assert_eq!(r.stop_reason, StopReason::Complete);
    }

    // ── Integration Test: Multi-turn tool loop ───────────────

    #[tokio::test]
    async fn integration_multi_turn_tool_loop() {
        let provider = Arc::new(MockProvider::new(vec![
            MockProvider::tool_call("c1", "echo", r#"{"message":"first"}"#),
            MockProvider::tool_call("c2", "echo", r#"{"message":"second"}"#),
            MockProvider::text("Both done."),
        ]));
        let agent = AgentLoop::new(AgentConfig::new(), provider, registry_with_echo());

        let result = agent.run("Do two things").await;
        assert!(result.is_ok());
        let r = result.unwrap_or_else(|_| unreachable!());
        assert_eq!(r.turns.len(), 3);
        assert_eq!(r.turns[0].tool_calls[0].result.content, "first");
        assert_eq!(r.turns[1].tool_calls[0].result.content, "second");
        assert_eq!(r.final_text, "Both done.");
    }

    // ── Integration Test: Max turns reached ──────────────────

    #[tokio::test]
    async fn integration_max_turns_reached() {
        let responses: Vec<Vec<LlmEvent>> = (0..10)
            .map(|i| MockProvider::tool_call(&format!("c{i}"), "echo", r#"{"message":"loop"}"#))
            .collect();
        let provider = Arc::new(MockProvider::new(responses));
        let config = AgentConfig::new().with_max_turns(3);
        let agent = AgentLoop::new(config, provider, registry_with_echo());

        let result = agent.run("Loop forever").await;
        assert!(result.is_ok());
        let r = result.unwrap_or_else(|_| unreachable!());
        assert_eq!(r.turns.len(), 3);
        assert_eq!(r.stop_reason, StopReason::MaxTurns);
    }

    // ── Integration Test: Max tool calls per turn ────────────

    #[tokio::test]
    async fn integration_max_tool_calls_per_turn() {
        // 3 tool calls in one turn, but limit is 2
        let events = vec![
            LlmEvent::StreamStart {
                request_id: "req-1".into(),
                model: ModelRef::new("mock"),
            },
            LlmEvent::ToolCallStart {
                call_id: "a".into(),
                function_name: "echo".into(),
            },
            LlmEvent::ToolCallEnd {
                call_id: "a".into(),
            },
            LlmEvent::ToolCallStart {
                call_id: "b".into(),
                function_name: "echo".into(),
            },
            LlmEvent::ToolCallEnd {
                call_id: "b".into(),
            },
            LlmEvent::ToolCallStart {
                call_id: "c".into(),
                function_name: "echo".into(),
            },
            LlmEvent::ToolCallEnd {
                call_id: "c".into(),
            },
            LlmEvent::StreamEnd {
                finish_reason: FinishReason::ToolCalls,
            },
        ];
        let provider = Arc::new(MockProvider::new(vec![events]));
        let config = AgentConfig::new().with_max_tool_calls_per_turn(2);
        let agent = AgentLoop::new(config, provider, registry_with_echo());

        let result = agent.run("Call many").await;
        assert!(result.is_ok());
        let r = result.unwrap_or_else(|_| unreachable!());
        assert_eq!(r.stop_reason, StopReason::MaxToolCalls);
    }

    // ── Integration Test: Tool timeout ───────────────────────

    #[tokio::test]
    async fn integration_tool_timeout() {
        let provider = Arc::new(MockProvider::new(vec![
            MockProvider::tool_call("c1", "slow", r#"{}"#),
            MockProvider::text("Recovered."),
        ]));
        let config = AgentConfig::new().with_tool_timeout_secs(1);
        let agent = AgentLoop::new(config, provider, registry_with_echo_and_slow());

        let result = agent.run("Call slow tool").await;
        assert!(result.is_ok());
        let r = result.unwrap_or_else(|_| unreachable!());
        // Tool timed out, but error is captured as tool result
        assert_eq!(r.turns[0].tool_calls.len(), 1);
        assert!(!r.turns[0].tool_calls[0].result.success);
        // Agent continues and gets the recovery text
        assert_eq!(r.final_text, "Recovered.");
    }

    // ── Integration Test: Cancellation ───────────────────────

    #[tokio::test]
    async fn integration_cancellation_before_start() {
        let provider = Arc::new(MockProvider::new(vec![MockProvider::text("test")]));
        let agent = AgentLoop::new(AgentConfig::new(), provider, registry_with_echo());
        agent.cancel();

        let result = agent.run("Hi").await;
        assert!(result.is_ok());
        let r = result.unwrap_or_else(|_| unreachable!());
        assert_eq!(r.stop_reason, StopReason::Cancelled);
    }

    #[tokio::test]
    async fn integration_cancellation_during_tool_execution() {
        let provider = Arc::new(MockProvider::new(vec![MockProvider::tool_call(
            "c1", "slow", r#"{}"#,
        )]));
        let config = AgentConfig::new().with_tool_timeout_secs(30);
        let agent = AgentLoop::new(config, provider, registry_with_echo_and_slow());

        let cancel = agent.cancellation_token();
        tokio::spawn(async move {
            tokio::time::sleep(tokio::time::Duration::from_millis(100)).await;
            cancel.cancel();
        });

        let result = agent.run("Call slow").await;
        assert!(result.is_ok());
        let r = result.unwrap_or_else(|_| unreachable!());
        // Should be cancelled (tool was slow and we cancelled after 100ms)
        assert!(
            r.stop_reason == StopReason::Cancelled || matches!(r.stop_reason, StopReason::Error(_))
        );
    }

    // ── Integration Test: Invalid tool args ──────────────────

    #[tokio::test]
    async fn integration_invalid_tool_args() {
        // Model sends invalid JSON as args
        let events = vec![
            LlmEvent::StreamStart {
                request_id: "req-1".into(),
                model: ModelRef::new("mock"),
            },
            LlmEvent::ToolCallStart {
                call_id: "c1".into(),
                function_name: "echo".into(),
            },
            LlmEvent::ToolCallArgsDelta {
                call_id: "c1".into(),
                args_fragment: "not valid json {{{".into(),
            },
            LlmEvent::ToolCallEnd {
                call_id: "c1".into(),
            },
            LlmEvent::StreamEnd {
                finish_reason: FinishReason::ToolCalls,
            },
        ];
        let provider = Arc::new(MockProvider::new(vec![
            events,
            MockProvider::text("OK, bad args."),
        ]));
        let agent = AgentLoop::new(AgentConfig::new(), provider, registry_with_echo());

        let result = agent.run("Bad args").await;
        assert!(result.is_ok());
        let r = result.unwrap_or_else(|_| unreachable!());
        // Tool call should have failed gracefully
        assert!(!r.turns[0].tool_calls[0].result.success);
        assert_eq!(r.final_text, "OK, bad args.");
    }

    // ── Integration Test: Unknown tool name ──────────────────

    #[tokio::test]
    async fn integration_unknown_tool_name() {
        let provider = Arc::new(MockProvider::new(vec![
            MockProvider::tool_call("c1", "nonexistent_tool", r#"{}"#),
            MockProvider::text("Tool not found."),
        ]));
        let agent = AgentLoop::new(AgentConfig::new(), provider, registry_with_echo());

        let result = agent.run("Call fake tool").await;
        assert!(result.is_ok());
        let r = result.unwrap_or_else(|_| unreachable!());
        assert!(!r.turns[0].tool_calls[0].result.success);
        assert!(
            r.turns[0].tool_calls[0]
                .result
                .error
                .as_deref()
                .unwrap_or("")
                .contains("not found")
        );
        assert_eq!(r.final_text, "Tool not found.");
    }

    // ── Integration Test: Empty response from provider ───────

    #[tokio::test]
    async fn integration_empty_response() {
        let events = vec![
            LlmEvent::StreamStart {
                request_id: "req-1".into(),
                model: ModelRef::new("mock"),
            },
            LlmEvent::StreamEnd {
                finish_reason: FinishReason::Stop,
            },
        ];
        let provider = Arc::new(MockProvider::new(vec![events]));
        let agent = AgentLoop::new(AgentConfig::new(), provider, registry_with_echo());

        let result = agent.run("Hello").await;
        assert!(result.is_ok());
        let r = result.unwrap_or_else(|_| unreachable!());
        assert!(r.final_text.is_empty());
        assert_eq!(r.stop_reason, StopReason::Complete);
    }

    // ── Integration Test: Provider request failure ───────────

    #[tokio::test]
    async fn integration_provider_request_failure() {
        let provider: Arc<dyn ProviderAdapter> = Arc::new(FailingProvider);
        let agent = AgentLoop::new(AgentConfig::new(), provider, empty_registry());

        let result = agent.run("Hello").await;
        assert!(result.is_ok());
        let r = result.unwrap_or_else(|_| unreachable!());
        assert!(matches!(r.stop_reason, StopReason::Error(_)));
    }

    // ── Integration Test: Stream error ───────────────────────

    #[tokio::test]
    async fn integration_stream_error() {
        let provider = Arc::new(MockProvider::new(vec![MockProvider::error_stream(
            "stream broken",
        )]));
        let agent = AgentLoop::new(AgentConfig::new(), provider, registry_with_echo());

        let result = agent.run("Hello").await;
        assert!(result.is_ok());
        let r = result.unwrap_or_else(|_| unreachable!());
        assert_eq!(
            r.stop_reason,
            StopReason::Error("stream broken".to_string())
        );
    }

    // ── Integration Test: Conversation continuation ──────────

    #[tokio::test]
    async fn integration_conversation_continuation() {
        // First interaction
        let provider1 = Arc::new(MockProvider::new(vec![
            MockProvider::tool_call("c1", "echo", r#"{"message":"data"}"#),
            MockProvider::text("Got data."),
        ]));
        let config = AgentConfig::new().with_system_prompt("Be helpful.");
        let agent1 = AgentLoop::new(config, provider1, registry_with_echo());
        let first = agent1.run("Get data").await;
        assert!(first.is_ok());
        let first = first.unwrap_or_else(|_| unreachable!());
        assert_eq!(first.stop_reason, StopReason::Complete);

        // Continuation
        let provider2 = Arc::new(MockProvider::new(vec![MockProvider::text("More data.")]));
        let config2 = AgentConfig::new().with_system_prompt("Be helpful.");
        let agent2 = AgentLoop::new(config2, provider2, registry_with_echo());
        let second = agent2.run_continuation(&first, "More please").await;
        assert!(second.is_ok());
        let second = second.unwrap_or_else(|_| unreachable!());
        assert_eq!(second.final_text, "More data.");
        assert_eq!(second.stop_reason, StopReason::Complete);
    }

    // ── Integration Test: All agent types are Send + Sync ────

    #[test]
    fn integration_all_types_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<AgentConfig>();
        assert_send_sync::<AgentLoop>();
        assert_send_sync::<AgentLoopResult>();
        assert_send_sync::<TurnResult>();
        assert_send_sync::<ExecutedToolCall>();
        assert_send_sync::<StopReason>();
        assert_send_sync::<StreamAccumulator>();
        assert_send_sync::<AccumulatedToolCall>();
        assert_send_sync::<AccumulatedTurn>();
    }

    // ── Integration Test: No tools registered ────────────────

    #[tokio::test]
    async fn integration_no_tools_registered() {
        // Even with tool calls in response, unknown tools handled gracefully
        let provider = Arc::new(MockProvider::new(vec![
            MockProvider::tool_call("c1", "echo", r#"{"message":"x"}"#),
            MockProvider::text("Handled."),
        ]));
        let agent = AgentLoop::new(AgentConfig::new(), provider, empty_registry());

        let result = agent.run("Call echo").await;
        assert!(result.is_ok());
        let r = result.unwrap_or_else(|_| unreachable!());
        assert!(!r.turns[0].tool_calls[0].result.success);
        assert_eq!(r.final_text, "Handled.");
    }

    // ── Integration Test: build_messages_from_result ─────────

    #[test]
    fn integration_build_messages_round_trip() {
        let result = AgentLoopResult {
            turns: vec![
                TurnResult {
                    text: String::new(),
                    thinking: String::new(),
                    tool_calls: vec![ExecutedToolCall {
                        call_id: "c1".into(),
                        function_name: "echo".into(),
                        arguments: serde_json::json!({"message": "hi"}),
                        result: ToolResult::success("hi".to_string()),
                        duration_ms: 5,
                    }],
                    finish_reason: FinishReason::ToolCalls,
                    usage: None,
                },
                TurnResult {
                    text: "Final answer.".into(),
                    thinking: String::new(),
                    tool_calls: Vec::new(),
                    finish_reason: FinishReason::Stop,
                    usage: None,
                },
            ],
            final_text: "Final answer.".into(),
            total_usage: crate::fae_llm::usage::TokenUsage::default(),
            stop_reason: StopReason::Complete,
        };

        let messages = build_messages_from_result(&result, Some("System prompt."));
        // system + assistant(tool) + tool_result + assistant(text) = 4
        assert_eq!(messages.len(), 4);
        assert_eq!(
            messages[0].role,
            crate::fae_llm::providers::message::Role::System
        );
        assert_eq!(
            messages[1].role,
            crate::fae_llm::providers::message::Role::Assistant
        );
        assert_eq!(messages[1].tool_calls.len(), 1);
        assert_eq!(
            messages[2].role,
            crate::fae_llm::providers::message::Role::Tool
        );
        assert_eq!(
            messages[3].role,
            crate::fae_llm::providers::message::Role::Assistant
        );
    }

    // ── Integration Test: Thinking content preserved ─────────

    #[tokio::test]
    async fn integration_thinking_content_preserved() {
        let events = vec![
            LlmEvent::StreamStart {
                request_id: "req-1".into(),
                model: ModelRef::new("mock"),
            },
            LlmEvent::ThinkingStart,
            LlmEvent::ThinkingDelta {
                text: "Let me think...".into(),
            },
            LlmEvent::ThinkingEnd,
            LlmEvent::TextDelta {
                text: "Answer: 42".into(),
            },
            LlmEvent::StreamEnd {
                finish_reason: FinishReason::Stop,
            },
        ];
        let provider = Arc::new(MockProvider::new(vec![events]));
        let agent = AgentLoop::new(AgentConfig::new(), provider, registry_with_echo());

        let result = agent.run("Think and answer").await;
        assert!(result.is_ok());
        let r = result.unwrap_or_else(|_| unreachable!());
        assert_eq!(r.turns[0].thinking, "Let me think...");
        assert_eq!(r.final_text, "Answer: 42");
    }
}
