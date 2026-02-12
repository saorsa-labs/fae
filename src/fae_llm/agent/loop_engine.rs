//! Core agent loop engine.
//!
//! Implements the agentic loop: prompt -> stream -> tool calls -> execute
//! -> continue. The [`AgentLoop`] struct ties together a provider adapter,
//! tool registry, and configuration to drive multi-turn LLM interactions.

use std::sync::Arc;

use futures_util::StreamExt;
use tokio_util::sync::CancellationToken;

use super::accumulator::StreamAccumulator;
use super::executor::ToolExecutor;
use super::types::{AgentConfig, AgentLoopResult, ExecutedToolCall, StopReason, TurnResult};
use crate::fae_llm::error::FaeLlmError;
use crate::fae_llm::events::FinishReason;
use crate::fae_llm::observability::metrics::{MetricsCollector, NoopMetrics};
use crate::fae_llm::observability::spans::*;
use crate::fae_llm::provider::{ProviderAdapter, ToolDefinition};
use crate::fae_llm::providers::message::{AssistantToolCall, Message};
use crate::fae_llm::tools::registry::ToolRegistry;
use crate::fae_llm::types::RequestOptions;
use crate::fae_llm::usage::TokenUsage;

/// The core agent loop engine.
///
/// Drives multi-turn LLM interactions with tool calling. Each iteration
/// sends the conversation to the provider, streams the response, and
/// if the model requests tool calls, executes them and continues.
///
/// # Safety Guards
///
/// - **Max turns**: Stops after [`AgentConfig::max_turns`] provider round-trips
/// - **Max tool calls per turn**: Stops if a single response has too many tool calls
/// - **Request timeout**: Each provider request has a deadline
/// - **Tool timeout**: Each tool execution has a deadline
/// - **Cancellation**: Can be aborted via [`cancel()`](Self::cancel)
pub struct AgentLoop {
    config: AgentConfig,
    provider: Arc<dyn ProviderAdapter>,
    tool_executor: ToolExecutor,
    tool_definitions: Vec<ToolDefinition>,
    cancel: CancellationToken,
    metrics: Arc<dyn MetricsCollector>,
}

impl AgentLoop {
    /// Create a new agent loop.
    ///
    /// # Arguments
    ///
    /// * `config` — Loop configuration (limits, timeouts, system prompt)
    /// * `provider` — The LLM provider adapter
    /// * `registry` — The tool registry (tools available to the model)
    pub fn new(
        config: AgentConfig,
        provider: Arc<dyn ProviderAdapter>,
        registry: Arc<ToolRegistry>,
    ) -> Self {
        Self::with_metrics(config, provider, registry, Arc::new(NoopMetrics))
    }

    /// Create a new agent loop with a custom metrics collector.
    ///
    /// # Arguments
    ///
    /// * `config` — Loop configuration (limits, timeouts, system prompt)
    /// * `provider` — The LLM provider adapter
    /// * `registry` — The tool registry (tools available to the model)
    /// * `metrics` — Metrics collector for observability
    pub fn with_metrics(
        config: AgentConfig,
        provider: Arc<dyn ProviderAdapter>,
        registry: Arc<ToolRegistry>,
        metrics: Arc<dyn MetricsCollector>,
    ) -> Self {
        // Build tool definitions from registry for the provider
        let tool_definitions: Vec<ToolDefinition> = registry
            .schemas_for_api()
            .into_iter()
            .filter_map(|schema| {
                let name = schema.get("name")?.as_str()?.to_string();
                let description = schema.get("description")?.as_str()?.to_string();
                let parameters = schema.get("parameters")?.clone();
                Some(ToolDefinition::new(name, description, parameters))
            })
            .collect();

        let tool_executor = ToolExecutor::new(registry, config.tool_timeout_secs);

        Self {
            config,
            provider,
            tool_executor,
            tool_definitions,
            cancel: CancellationToken::new(),
            metrics,
        }
    }

    /// Cancel the agent loop.
    ///
    /// This signals cancellation to the current and all future operations.
    /// The loop will stop at the next cancellation check point.
    pub fn cancel(&self) {
        self.cancel.cancel();
    }

    /// Returns the cancellation token for external cancellation control.
    pub fn cancellation_token(&self) -> CancellationToken {
        self.cancel.clone()
    }

    /// Run the agent loop with a user message.
    ///
    /// Builds the initial conversation (system prompt + user message)
    /// and runs the loop until completion or a stop condition.
    ///
    /// # Errors
    ///
    /// Returns [`FaeLlmError`] if the initial provider request fails.
    /// Tool and stream errors are captured in the result rather than
    /// propagated as top-level errors.
    pub async fn run(&self, user_message: &str) -> Result<AgentLoopResult, FaeLlmError> {
        let mut messages = Vec::new();

        // Add system prompt if configured
        if let Some(ref system_prompt) = self.config.system_prompt {
            messages.push(Message::system(system_prompt.as_str()));
        }

        messages.push(Message::user(user_message));

        self.run_loop(messages).await
    }

    /// Run the agent loop with pre-existing messages.
    ///
    /// Use this for continuing a conversation or providing
    /// custom message history.
    ///
    /// # Errors
    ///
    /// Returns [`FaeLlmError`] if the initial provider request fails.
    pub async fn run_with_messages(
        &self,
        messages: Vec<Message>,
    ) -> Result<AgentLoopResult, FaeLlmError> {
        self.run_loop(messages).await
    }

    /// Continue a conversation from a previous agent loop result.
    ///
    /// Reconstructs the message history from the previous result,
    /// appends the new user message, and runs the loop.
    ///
    /// # Arguments
    ///
    /// * `previous` — The result of a previous agent loop run
    /// * `user_message` — The new user message to continue with
    ///
    /// # Errors
    ///
    /// Returns [`FaeLlmError`] if the provider request fails.
    pub async fn run_continuation(
        &self,
        previous: &AgentLoopResult,
        user_message: &str,
    ) -> Result<AgentLoopResult, FaeLlmError> {
        let mut messages =
            build_messages_from_result(previous, self.config.system_prompt.as_deref());
        messages.push(Message::user(user_message));
        self.run_loop(messages).await
    }

    /// The main agent loop implementation.
    async fn run_loop(&self, mut messages: Vec<Message>) -> Result<AgentLoopResult, FaeLlmError> {
        let mut turns = Vec::new();
        let total_usage = TokenUsage::default();
        let request_timeout = tokio::time::Duration::from_secs(self.config.request_timeout_secs);
        let options = RequestOptions::new().with_stream(true);
        let loop_start = std::time::Instant::now();

        for _turn_idx in 0..self.config.max_turns {
            let turn_number = _turn_idx + 1;
            let turn_start = std::time::Instant::now();

            let turn_span = tracing::info_span!(
                SPAN_AGENT_TURN,
                { FIELD_TURN_NUMBER } = turn_number,
                { FIELD_MAX_TURNS } = self.config.max_turns,
            );
            let _turn_enter = turn_span.enter();

            tracing::debug!(
                turn_number = turn_number,
                max_turns = self.config.max_turns,
                "Starting agent turn"
            );

            // Check cancellation
            if self.cancel.is_cancelled() {
                tracing::info!("Agent loop cancelled");
                return Ok(AgentLoopResult {
                    final_text: last_text(&turns),
                    turns,
                    total_usage,
                    stop_reason: StopReason::Cancelled,
                });
            }

            // Send to provider with timeout
            let stream = tokio::select! {
                _ = self.cancel.cancelled() => {
                    return Ok(AgentLoopResult {
                        final_text: last_text(&turns),
                        turns,
                        total_usage,
                        stop_reason: StopReason::Cancelled,
                    });
                }
                result = tokio::time::timeout(
                    request_timeout,
                    self.provider.send(&messages, &options, &self.tool_definitions)
                ) => {
                    match result {
                        Ok(Ok(stream)) => stream,
                        Ok(Err(e)) => {
                            return Ok(AgentLoopResult {
                                final_text: last_text(&turns),
                                turns,
                                total_usage,
                                stop_reason: StopReason::Error(format!("{e}")),
                            });
                        }
                        Err(_elapsed) => {
                            return Ok(AgentLoopResult {
                                final_text: last_text(&turns),
                                turns,
                                total_usage,
                                stop_reason: StopReason::Error(format!(
                                    "request timed out after {}s",
                                    self.config.request_timeout_secs
                                )),
                            });
                        }
                    }
                }
            };

            // Consume stream and accumulate events
            let mut acc = StreamAccumulator::new();
            let mut stream = stream;

            loop {
                tokio::select! {
                    _ = self.cancel.cancelled() => {
                        let turn = acc.finish();
                        turns.push(TurnResult {
                            text: turn.text,
                            thinking: turn.thinking,
                            tool_calls: Vec::new(),
                            finish_reason: FinishReason::Cancelled,
                            usage: None,
                        });
                        return Ok(AgentLoopResult {
                            final_text: last_text(&turns),
                            turns,
                            total_usage,
                            stop_reason: StopReason::Cancelled,
                        });
                    }
                    event = stream.next() => {
                        match event {
                            Some(e) => acc.push(e),
                            None => break,
                        }
                    }
                }
            }

            let accumulated = acc.finish();

            // Check for stream error
            if let Some(ref error) = accumulated.error {
                turns.push(TurnResult {
                    text: accumulated.text,
                    thinking: accumulated.thinking,
                    tool_calls: Vec::new(),
                    finish_reason: accumulated.finish_reason,
                    usage: None,
                });
                return Ok(AgentLoopResult {
                    final_text: last_text(&turns),
                    turns,
                    total_usage,
                    stop_reason: StopReason::Error(error.clone()),
                });
            }

            // If the model wants to call tools
            if accumulated.finish_reason == FinishReason::ToolCalls
                && !accumulated.tool_calls.is_empty()
            {
                // Check max tool calls per turn
                if accumulated.tool_calls.len() as u32 > self.config.max_tool_calls_per_turn {
                    turns.push(TurnResult {
                        text: accumulated.text,
                        thinking: accumulated.thinking,
                        tool_calls: Vec::new(),
                        finish_reason: accumulated.finish_reason,
                        usage: None,
                    });
                    return Ok(AgentLoopResult {
                        final_text: last_text(&turns),
                        turns,
                        total_usage,
                        stop_reason: StopReason::MaxToolCalls,
                    });
                }

                // Execute tools
                let tool_results = self
                    .tool_executor
                    .execute_tools(&accumulated.tool_calls, &self.cancel)
                    .await;

                // Build executed tool calls and messages
                let mut executed_calls = Vec::new();
                let mut assistant_tool_calls = Vec::new();

                for (i, result) in tool_results.into_iter().enumerate() {
                    let acc_call = &accumulated.tool_calls[i];
                    match result {
                        Ok(exec) => {
                            // Record metrics for tool execution
                            self.metrics
                                .record_tool_latency_ms(&exec.function_name, exec.duration_ms);
                            self.metrics
                                .count_tool_result(&exec.function_name, exec.result.success);

                            assistant_tool_calls.push(AssistantToolCall {
                                call_id: exec.call_id.clone(),
                                function_name: exec.function_name.clone(),
                                arguments: exec.arguments.to_string(),
                            });

                            // Add tool result message
                            let content = if exec.result.success {
                                exec.result.content.clone()
                            } else {
                                exec.result
                                    .error
                                    .clone()
                                    .unwrap_or_else(|| "tool execution failed".to_string())
                            };
                            messages.push(Message::tool_result(&exec.call_id, content));

                            executed_calls.push(exec);
                        }
                        Err(e) => {
                            // Tool failed — include error as tool result
                            let call_id = acc_call.call_id.clone();
                            let error_msg = format!("Error: {e}");
                            self.metrics
                                .count_tool_result(&acc_call.function_name, false);

                            assistant_tool_calls.push(AssistantToolCall {
                                call_id: call_id.clone(),
                                function_name: acc_call.function_name.clone(),
                                arguments: acc_call.arguments_json.clone(),
                            });
                            messages.push(Message::tool_result(&call_id, &error_msg));

                            executed_calls.push(ExecutedToolCall {
                                call_id,
                                function_name: acc_call.function_name.clone(),
                                arguments: serde_json::Value::Null,
                                result: crate::fae_llm::tools::types::ToolResult::failure(
                                    error_msg,
                                ),
                                duration_ms: 0,
                            });
                        }
                    }
                }

                // Add the assistant message with tool calls to conversation
                // Insert BEFORE the tool result messages
                let insert_pos = messages.len() - executed_calls.len();
                messages.insert(
                    insert_pos,
                    Message::assistant_with_tool_calls(
                        if accumulated.text.is_empty() {
                            None
                        } else {
                            Some(accumulated.text.clone())
                        },
                        assistant_tool_calls,
                    ),
                );

                let turn_duration_ms = turn_start.elapsed().as_millis() as u64;
                self.metrics
                    .record_turn_latency_ms(turn_number as u32, turn_duration_ms);

                turns.push(TurnResult {
                    text: accumulated.text,
                    thinking: accumulated.thinking,
                    tool_calls: executed_calls,
                    finish_reason: accumulated.finish_reason,
                    usage: None,
                });

                // Continue the loop for the next turn
                continue;
            }

            // No tool calls — the model is done
            let turn_duration_ms = turn_start.elapsed().as_millis() as u64;
            self.metrics
                .record_turn_latency_ms(turn_number as u32, turn_duration_ms);

            turns.push(TurnResult {
                text: accumulated.text,
                thinking: accumulated.thinking,
                tool_calls: Vec::new(),
                finish_reason: accumulated.finish_reason,
                usage: None,
            });

            let total_latency_ms = loop_start.elapsed().as_millis() as u64;
            let provider_name = self.provider.name();
            // Model name not directly accessible from provider trait - use "unknown" for now
            self.metrics
                .record_request_latency_ms(provider_name, "unknown", total_latency_ms);

            return Ok(AgentLoopResult {
                final_text: last_text(&turns),
                turns,
                total_usage,
                stop_reason: StopReason::Complete,
            });
        }

        // Max turns reached
        let total_latency_ms = loop_start.elapsed().as_millis() as u64;
        let provider_name = self.provider.name();
        // Model name not directly accessible from provider trait - use "unknown" for now
        self.metrics
            .record_request_latency_ms(provider_name, "unknown", total_latency_ms);

        Ok(AgentLoopResult {
            final_text: last_text(&turns),
            turns,
            total_usage,
            stop_reason: StopReason::MaxTurns,
        })
    }
}

/// Extract the text from the last turn, or empty if no turns.
fn last_text(turns: &[TurnResult]) -> String {
    turns.last().map_or_else(String::new, |t| t.text.clone())
}

/// Build a conversation message list from an [`AgentLoopResult`].
///
/// Reconstructs the message history from the turns, including
/// tool calls and tool results, suitable for continuing the conversation.
pub fn build_messages_from_result(
    result: &AgentLoopResult,
    system_prompt: Option<&str>,
) -> Vec<Message> {
    let mut messages = Vec::new();

    if let Some(prompt) = system_prompt {
        messages.push(Message::system(prompt));
    }

    for turn in &result.turns {
        if !turn.tool_calls.is_empty() {
            // Assistant message with tool calls
            let tool_calls: Vec<AssistantToolCall> = turn
                .tool_calls
                .iter()
                .map(|tc| AssistantToolCall {
                    call_id: tc.call_id.clone(),
                    function_name: tc.function_name.clone(),
                    arguments: tc.arguments.to_string(),
                })
                .collect();

            messages.push(Message::assistant_with_tool_calls(
                if turn.text.is_empty() {
                    None
                } else {
                    Some(turn.text.clone())
                },
                tool_calls,
            ));

            // Tool results
            for tc in &turn.tool_calls {
                let content = if tc.result.success {
                    tc.result.content.clone()
                } else {
                    tc.result
                        .error
                        .clone()
                        .unwrap_or_else(|| "tool execution failed".to_string())
                };
                messages.push(Message::tool_result(&tc.call_id, content));
            }
        } else if !turn.text.is_empty() {
            // Text-only assistant message
            messages.push(Message::assistant(&turn.text));
        }
    }

    messages
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::fae_llm::config::types::ToolMode;
    use crate::fae_llm::events::LlmEvent;
    use crate::fae_llm::provider::LlmEventStream;
    use crate::fae_llm::tools::types::{Tool, ToolResult};
    use crate::fae_llm::types::ModelRef;

    use async_trait::async_trait;
    use std::sync::Mutex;

    // ── Mock Provider ────────────────────────────────────────

    /// A mock provider that returns predetermined event sequences.
    struct MockProvider {
        /// Each call to send() pops from the front.
        responses: Mutex<Vec<Vec<LlmEvent>>>,
    }

    impl MockProvider {
        fn new(responses: Vec<Vec<LlmEvent>>) -> Self {
            Self {
                responses: Mutex::new(responses),
            }
        }

        /// Single text response.
        fn text_response(text: &str) -> Vec<LlmEvent> {
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

        /// Tool call response.
        fn tool_call_response(call_id: &str, fn_name: &str, args: &str) -> Vec<LlmEvent> {
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
                    // Default: empty stop
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
            Ok(Box::pin(futures_util::stream::iter(events)))
        }
    }

    // ── Mock Tool ────────────────────────────────────────────

    struct MockTool {
        tool_name: &'static str,
        response: &'static str,
    }

    impl Tool for MockTool {
        fn name(&self) -> &str {
            self.tool_name
        }
        fn description(&self) -> &str {
            "Mock tool"
        }
        fn schema(&self) -> serde_json::Value {
            serde_json::json!({
                "type": "object",
                "properties": {
                    "input": { "type": "string" }
                }
            })
        }
        fn execute(&self, _args: serde_json::Value) -> Result<ToolResult, FaeLlmError> {
            Ok(ToolResult::success(self.response.to_string()))
        }
        fn allowed_in_mode(&self, _mode: ToolMode) -> bool {
            true
        }
    }

    fn make_registry_with_mock() -> Arc<ToolRegistry> {
        let mut reg = ToolRegistry::new(ToolMode::Full);
        reg.register(Arc::new(MockTool {
            tool_name: "read",
            response: "file content here",
        }));
        reg.register(Arc::new(MockTool {
            tool_name: "bash",
            response: "command output",
        }));
        Arc::new(reg)
    }

    // ── Text-only response ───────────────────────────────────

    #[tokio::test]
    async fn agent_loop_text_only() {
        let provider = Arc::new(MockProvider::new(vec![MockProvider::text_response(
            "Hello, I'm an AI!",
        )]));
        let registry = make_registry_with_mock();
        let config = AgentConfig::new();

        let agent = AgentLoop::new(config, provider, registry);
        let result = agent.run("Hi").await;

        assert!(result.is_ok());
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("run succeeded"),
        };
        assert_eq!(result.turns.len(), 1);
        assert_eq!(result.final_text, "Hello, I'm an AI!");
        assert_eq!(result.stop_reason, StopReason::Complete);
        assert!(result.turns[0].tool_calls.is_empty());
    }

    // ── Single tool call ─────────────────────────────────────

    #[tokio::test]
    async fn agent_loop_single_tool_call() {
        let provider = Arc::new(MockProvider::new(vec![
            MockProvider::tool_call_response("call_1", "read", r#"{"input":"test"}"#),
            MockProvider::text_response("Here's the file content."),
        ]));
        let registry = make_registry_with_mock();
        let config = AgentConfig::new();

        let agent = AgentLoop::new(config, provider, registry);
        let result = agent.run("Read the file").await;

        assert!(result.is_ok());
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("run succeeded"),
        };
        assert_eq!(result.turns.len(), 2);
        // First turn: tool call
        assert_eq!(result.turns[0].tool_calls.len(), 1);
        assert_eq!(result.turns[0].tool_calls[0].function_name, "read");
        assert!(result.turns[0].tool_calls[0].result.success);
        // Second turn: text response
        assert_eq!(result.turns[1].text, "Here's the file content.");
        assert_eq!(result.stop_reason, StopReason::Complete);
        assert_eq!(result.final_text, "Here's the file content.");
    }

    // ── Multi-turn tool loop ─────────────────────────────────

    #[tokio::test]
    async fn agent_loop_multi_turn_tools() {
        let provider = Arc::new(MockProvider::new(vec![
            MockProvider::tool_call_response("call_1", "read", r#"{"input":"a"}"#),
            MockProvider::tool_call_response("call_2", "bash", r#"{"input":"b"}"#),
            MockProvider::text_response("Done with both tools."),
        ]));
        let registry = make_registry_with_mock();
        let config = AgentConfig::new();

        let agent = AgentLoop::new(config, provider, registry);
        let result = agent.run("Do two things").await;

        assert!(result.is_ok());
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("run succeeded"),
        };
        assert_eq!(result.turns.len(), 3);
        assert_eq!(result.turns[0].tool_calls[0].function_name, "read");
        assert_eq!(result.turns[1].tool_calls[0].function_name, "bash");
        assert_eq!(result.final_text, "Done with both tools.");
        assert_eq!(result.stop_reason, StopReason::Complete);
    }

    // ── Max turns reached ────────────────────────────────────

    #[tokio::test]
    async fn agent_loop_max_turns() {
        // Provider always returns tool calls — loop should stop at max_turns
        let responses: Vec<Vec<LlmEvent>> = (0..10)
            .map(|i| {
                MockProvider::tool_call_response(&format!("call_{i}"), "read", r#"{"input":"x"}"#)
            })
            .collect();
        let provider = Arc::new(MockProvider::new(responses));
        let registry = make_registry_with_mock();
        let config = AgentConfig::new().with_max_turns(3);

        let agent = AgentLoop::new(config, provider, registry);
        let result = agent.run("Keep calling tools").await;

        assert!(result.is_ok());
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("run succeeded"),
        };
        assert_eq!(result.turns.len(), 3);
        assert_eq!(result.stop_reason, StopReason::MaxTurns);
    }

    // ── Max tool calls per turn ──────────────────────────────

    #[tokio::test]
    async fn agent_loop_max_tool_calls_per_turn() {
        // Provider returns 5 tool calls in one turn
        let events = vec![
            LlmEvent::StreamStart {
                request_id: "req-1".into(),
                model: ModelRef::new("mock"),
            },
            LlmEvent::ToolCallStart {
                call_id: "c1".into(),
                function_name: "read".into(),
            },
            LlmEvent::ToolCallEnd {
                call_id: "c1".into(),
            },
            LlmEvent::ToolCallStart {
                call_id: "c2".into(),
                function_name: "read".into(),
            },
            LlmEvent::ToolCallEnd {
                call_id: "c2".into(),
            },
            LlmEvent::ToolCallStart {
                call_id: "c3".into(),
                function_name: "read".into(),
            },
            LlmEvent::ToolCallEnd {
                call_id: "c3".into(),
            },
            LlmEvent::StreamEnd {
                finish_reason: FinishReason::ToolCalls,
            },
        ];

        let provider = Arc::new(MockProvider::new(vec![events]));
        let registry = make_registry_with_mock();
        let config = AgentConfig::new().with_max_tool_calls_per_turn(2);

        let agent = AgentLoop::new(config, provider, registry);
        let result = agent.run("Call many tools").await;

        assert!(result.is_ok());
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("run succeeded"),
        };
        assert_eq!(result.stop_reason, StopReason::MaxToolCalls);
    }

    // ── Cancellation ─────────────────────────────────────────

    #[tokio::test]
    async fn agent_loop_cancelled() {
        let provider = Arc::new(MockProvider::new(vec![MockProvider::text_response("test")]));
        let registry = make_registry_with_mock();
        let config = AgentConfig::new();

        let agent = AgentLoop::new(config, provider, registry);
        agent.cancel(); // Cancel immediately

        let result = agent.run("Hi").await;
        assert!(result.is_ok());
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("run succeeded"),
        };
        assert_eq!(result.stop_reason, StopReason::Cancelled);
    }

    // ── Unknown tool ─────────────────────────────────────────

    #[tokio::test]
    async fn agent_loop_unknown_tool() {
        let provider = Arc::new(MockProvider::new(vec![
            MockProvider::tool_call_response("call_1", "nonexistent", r#"{"input":"x"}"#),
            MockProvider::text_response("OK, that tool failed."),
        ]));
        let registry = make_registry_with_mock();
        let config = AgentConfig::new();

        let agent = AgentLoop::new(config, provider, registry);
        let result = agent.run("Use unknown tool").await;

        assert!(result.is_ok());
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("run succeeded"),
        };
        // The tool error is captured in the tool call result, not as a top-level error
        assert_eq!(result.turns.len(), 2);
        assert!(!result.turns[0].tool_calls[0].result.success);
        assert_eq!(result.stop_reason, StopReason::Complete);
    }

    // ── System prompt ────────────────────────────────────────

    #[tokio::test]
    async fn agent_loop_with_system_prompt() {
        let provider = Arc::new(MockProvider::new(vec![MockProvider::text_response(
            "I am helpful!",
        )]));
        let registry = make_registry_with_mock();
        let config = AgentConfig::new().with_system_prompt("You are helpful.");

        let agent = AgentLoop::new(config, provider, registry);
        let result = agent.run("Hi").await;

        assert!(result.is_ok());
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("run succeeded"),
        };
        assert_eq!(result.final_text, "I am helpful!");
    }

    // ── Empty response ───────────────────────────────────────

    #[tokio::test]
    async fn agent_loop_empty_response() {
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
        let registry = make_registry_with_mock();
        let config = AgentConfig::new();

        let agent = AgentLoop::new(config, provider, registry);
        let result = agent.run("Hi").await;

        assert!(result.is_ok());
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("run succeeded"),
        };
        assert!(result.final_text.is_empty());
        assert_eq!(result.stop_reason, StopReason::Complete);
    }

    // ── Stream error ─────────────────────────────────────────

    #[tokio::test]
    async fn agent_loop_stream_error() {
        let events = vec![
            LlmEvent::StreamStart {
                request_id: "req-1".into(),
                model: ModelRef::new("mock"),
            },
            LlmEvent::TextDelta {
                text: "partial".into(),
            },
            LlmEvent::StreamError {
                error: "connection lost".into(),
            },
        ];
        let provider = Arc::new(MockProvider::new(vec![events]));
        let registry = make_registry_with_mock();
        let config = AgentConfig::new();

        let agent = AgentLoop::new(config, provider, registry);
        let result = agent.run("Hi").await;

        assert!(result.is_ok());
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("run succeeded"),
        };
        assert_eq!(
            result.stop_reason,
            StopReason::Error("connection lost".into())
        );
    }

    // ── build_messages_from_result ───────────────────────────

    #[test]
    fn build_messages_text_only() {
        let result = AgentLoopResult {
            turns: vec![TurnResult {
                text: "Hello!".into(),
                thinking: String::new(),
                tool_calls: Vec::new(),
                finish_reason: FinishReason::Stop,
                usage: None,
            }],
            final_text: "Hello!".into(),
            total_usage: TokenUsage::default(),
            stop_reason: StopReason::Complete,
        };

        let messages = build_messages_from_result(&result, Some("Be helpful."));
        assert_eq!(messages.len(), 2); // system + assistant
        assert_eq!(
            messages[0].role,
            crate::fae_llm::providers::message::Role::System
        );
        assert_eq!(
            messages[1].role,
            crate::fae_llm::providers::message::Role::Assistant
        );
    }

    #[test]
    fn build_messages_with_tool_calls() {
        let result = AgentLoopResult {
            turns: vec![
                TurnResult {
                    text: "Let me check.".into(),
                    thinking: String::new(),
                    tool_calls: vec![ExecutedToolCall {
                        call_id: "c1".into(),
                        function_name: "read".into(),
                        arguments: serde_json::json!({"path": "test.rs"}),
                        result: ToolResult::success("code".to_string()),
                        duration_ms: 10,
                    }],
                    finish_reason: FinishReason::ToolCalls,
                    usage: None,
                },
                TurnResult {
                    text: "Here it is.".into(),
                    thinking: String::new(),
                    tool_calls: Vec::new(),
                    finish_reason: FinishReason::Stop,
                    usage: None,
                },
            ],
            final_text: "Here it is.".into(),
            total_usage: TokenUsage::default(),
            stop_reason: StopReason::Complete,
        };

        let messages = build_messages_from_result(&result, None);
        // assistant (with tool call) + tool_result + assistant (text)
        assert_eq!(messages.len(), 3);
    }

    #[test]
    fn build_messages_no_system_prompt() {
        let result = AgentLoopResult {
            turns: vec![TurnResult {
                text: "Hi".into(),
                thinking: String::new(),
                tool_calls: Vec::new(),
                finish_reason: FinishReason::Stop,
                usage: None,
            }],
            final_text: "Hi".into(),
            total_usage: TokenUsage::default(),
            stop_reason: StopReason::Complete,
        };

        let messages = build_messages_from_result(&result, None);
        assert_eq!(messages.len(), 1); // Just assistant
    }

    // ── run_with_messages ────────────────────────────────────

    #[tokio::test]
    async fn agent_loop_run_with_messages() {
        let provider = Arc::new(MockProvider::new(vec![MockProvider::text_response(
            "Continued!",
        )]));
        let registry = make_registry_with_mock();
        let config = AgentConfig::new();

        let agent = AgentLoop::new(config, provider, registry);
        let messages = vec![
            Message::user("First message"),
            Message::assistant("First reply"),
            Message::user("Second message"),
        ];
        let result = agent.run_with_messages(messages).await;

        assert!(result.is_ok());
        let result = match result {
            Ok(r) => r,
            Err(_) => unreachable!("run succeeded"),
        };
        assert_eq!(result.final_text, "Continued!");
    }

    // ── run_continuation ────────────────────────────────────

    #[tokio::test]
    async fn agent_loop_continuation_from_text() {
        // First run
        let provider1 = Arc::new(MockProvider::new(vec![MockProvider::text_response(
            "First answer.",
        )]));
        let registry1 = make_registry_with_mock();
        let config1 = AgentConfig::new().with_system_prompt("Be helpful.");
        let agent1 = AgentLoop::new(config1, provider1, registry1);
        let first_result = agent1.run("Hello").await;
        assert!(first_result.is_ok());
        let first_result = match first_result {
            Ok(r) => r,
            Err(_) => unreachable!("first run succeeded"),
        };

        // Continuation
        let provider2 = Arc::new(MockProvider::new(vec![MockProvider::text_response(
            "Second answer.",
        )]));
        let registry2 = make_registry_with_mock();
        let config2 = AgentConfig::new().with_system_prompt("Be helpful.");
        let agent2 = AgentLoop::new(config2, provider2, registry2);
        let second_result = agent2.run_continuation(&first_result, "Follow up").await;

        assert!(second_result.is_ok());
        let second_result = match second_result {
            Ok(r) => r,
            Err(_) => unreachable!("continuation succeeded"),
        };
        assert_eq!(second_result.final_text, "Second answer.");
        assert_eq!(second_result.stop_reason, StopReason::Complete);
    }

    #[tokio::test]
    async fn agent_loop_continuation_from_tool_call() {
        // First run with a tool call
        let provider1 = Arc::new(MockProvider::new(vec![
            MockProvider::tool_call_response("call_1", "read", r#"{"input":"x"}"#),
            MockProvider::text_response("I read the file."),
        ]));
        let registry1 = make_registry_with_mock();
        let config1 = AgentConfig::new();
        let agent1 = AgentLoop::new(config1, provider1, registry1);
        let first_result = agent1.run("Read something").await;
        assert!(first_result.is_ok());
        let first_result = match first_result {
            Ok(r) => r,
            Err(_) => unreachable!("first run succeeded"),
        };
        assert_eq!(first_result.turns.len(), 2);

        // Continuation
        let provider2 = Arc::new(MockProvider::new(vec![MockProvider::text_response(
            "Here is more info.",
        )]));
        let registry2 = make_registry_with_mock();
        let config2 = AgentConfig::new();
        let agent2 = AgentLoop::new(config2, provider2, registry2);
        let second_result = agent2.run_continuation(&first_result, "Tell me more").await;

        assert!(second_result.is_ok());
        let second_result = match second_result {
            Ok(r) => r,
            Err(_) => unreachable!("continuation succeeded"),
        };
        assert_eq!(second_result.final_text, "Here is more info.");
    }

    #[tokio::test]
    async fn agent_loop_continuation_preserves_tool_results() {
        // First run with tool call
        let provider1 = Arc::new(MockProvider::new(vec![
            MockProvider::tool_call_response("call_1", "read", r#"{"input":"data"}"#),
            MockProvider::text_response("Got data."),
        ]));
        let registry1 = make_registry_with_mock();
        let config1 = AgentConfig::new();
        let agent1 = AgentLoop::new(config1, provider1, registry1);
        let first_result = agent1.run("Get data").await;
        assert!(first_result.is_ok());
        let first_result = match first_result {
            Ok(r) => r,
            Err(_) => unreachable!("first run succeeded"),
        };

        // Verify that build_messages_from_result includes the tool call and result
        let messages = build_messages_from_result(&first_result, None);
        // Should have: assistant(with tool call) + tool_result + assistant(text)
        assert_eq!(messages.len(), 3);

        // The first message should be an assistant with tool calls
        assert_eq!(
            messages[0].role,
            crate::fae_llm::providers::message::Role::Assistant
        );
        assert_eq!(messages[0].tool_calls.len(), 1);

        // Second message should be tool result
        assert_eq!(
            messages[1].role,
            crate::fae_llm::providers::message::Role::Tool
        );

        // Third should be assistant text
        assert_eq!(
            messages[2].role,
            crate::fae_llm::providers::message::Role::Assistant
        );
    }

    // ── Send + Sync ──────────────────────────────────────────

    #[test]
    fn agent_loop_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<AgentLoop>();
    }
}
