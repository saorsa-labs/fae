//! Configuration and result types for the agent loop.
//!
//! Provides [`AgentConfig`] for controlling loop behavior (turn limits,
//! timeouts) and [`AgentLoopResult`] for capturing the outcome of an
//! agent run including all turns, tool calls, and usage.

use serde::{Deserialize, Serialize};
use std::time::Duration;

use crate::fae_llm::events::FinishReason;
use crate::fae_llm::tools::types::ToolResult;
use crate::fae_llm::usage::TokenUsage;

/// Default maximum number of turns in the agent loop.
pub const DEFAULT_MAX_TURNS: u32 = 25;

/// Default maximum tool calls allowed per turn.
pub const DEFAULT_MAX_TOOL_CALLS_PER_TURN: u32 = 10;

/// Default request timeout in seconds.
pub const DEFAULT_REQUEST_TIMEOUT_SECS: u64 = 120;

/// Default per-tool execution timeout in seconds.
pub const DEFAULT_TOOL_TIMEOUT_SECS: u64 = 30;

/// Default maximum retry attempts for transient errors.
pub const DEFAULT_MAX_RETRY_ATTEMPTS: u32 = 3;

/// Default base delay for exponential backoff in milliseconds.
pub const DEFAULT_RETRY_BASE_DELAY_MS: u64 = 1000;

/// Default maximum delay for exponential backoff in milliseconds.
pub const DEFAULT_RETRY_MAX_DELAY_MS: u64 = 32000;

/// Default backoff multiplier (2.0 for exponential backoff).
pub const DEFAULT_RETRY_BACKOFF_MULTIPLIER: f64 = 2.0;

/// Default consecutive failures before opening circuit.
pub const DEFAULT_CIRCUIT_BREAKER_THRESHOLD: u32 = 5;

/// Default cooldown period in seconds before attempting recovery.
pub const DEFAULT_CIRCUIT_BREAKER_COOLDOWN_SECS: u64 = 60;

/// Retry policy for handling transient failures.
///
/// Implements exponential backoff with jitter for retrying failed requests.
/// Only retryable errors (network errors, rate limits, server errors) are retried.
///
/// # Examples
///
/// ```
/// use fae::fae_llm::agent::types::RetryPolicy;
///
/// let policy = RetryPolicy::default();
/// assert_eq!(policy.max_attempts, 3);
/// assert_eq!(policy.base_delay_ms, 1000);
/// ```
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RetryPolicy {
    /// Maximum number of retry attempts (0 = no retries, 1 = one retry, etc.).
    pub max_attempts: u32,
    /// Base delay in milliseconds for exponential backoff.
    pub base_delay_ms: u64,
    /// Maximum delay in milliseconds (caps exponential growth).
    pub max_delay_ms: u64,
    /// Backoff multiplier (2.0 for exponential backoff).
    pub backoff_multiplier: f64,
}

impl Default for RetryPolicy {
    fn default() -> Self {
        Self {
            max_attempts: DEFAULT_MAX_RETRY_ATTEMPTS,
            base_delay_ms: DEFAULT_RETRY_BASE_DELAY_MS,
            max_delay_ms: DEFAULT_RETRY_MAX_DELAY_MS,
            backoff_multiplier: DEFAULT_RETRY_BACKOFF_MULTIPLIER,
        }
    }
}

impl RetryPolicy {
    /// Create a new retry policy with default values.
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the maximum number of retry attempts.
    pub fn with_max_attempts(mut self, max_attempts: u32) -> Self {
        self.max_attempts = max_attempts;
        self
    }

    /// Set the base delay in milliseconds.
    pub fn with_base_delay_ms(mut self, base_delay_ms: u64) -> Self {
        self.base_delay_ms = base_delay_ms;
        self
    }

    /// Set the maximum delay in milliseconds.
    pub fn with_max_delay_ms(mut self, max_delay_ms: u64) -> Self {
        self.max_delay_ms = max_delay_ms;
        self
    }

    /// Set the backoff multiplier.
    pub fn with_backoff_multiplier(mut self, backoff_multiplier: f64) -> Self {
        self.backoff_multiplier = backoff_multiplier;
        self
    }

    /// Calculate the delay for a given retry attempt with exponential backoff and jitter.
    ///
    /// Formula: min(base * multiplier^attempt, max_delay) + jitter
    /// where jitter is a random value between 0 and 10% of the delay.
    pub fn delay_for_attempt(&self, attempt: u32) -> Duration {
        if attempt == 0 {
            return Duration::from_millis(0);
        }

        let base = self.base_delay_ms as f64;
        let multiplier = self.backoff_multiplier;
        let max = self.max_delay_ms as f64;

        // Calculate exponential backoff
        let exp = multiplier.powi(attempt as i32 - 1);
        let delay = (base * exp).min(max);

        // Add jitter (0-10% of delay)
        let jitter = delay * (rand::random::<f64>() * 0.1);
        let total_ms = (delay + jitter) as u64;

        Duration::from_millis(total_ms)
    }
}

/// Circuit breaker state.
///
/// Prevents cascade failures by stopping requests after repeated failures.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
pub enum CircuitState {
    /// Circuit is closed - requests are allowed.
    #[default]
    Closed,
    /// Circuit is open - requests are blocked.
    /// Contains the timestamp when the circuit can transition to HalfOpen.
    Open { retry_after_secs: u64 },
    /// Circuit is half-open - testing recovery with limited requests.
    HalfOpen,
}

impl std::fmt::Display for CircuitState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Closed => write!(f, "closed"),
            Self::Open { retry_after_secs } => write!(f, "open (retry after {retry_after_secs}s)"),
            Self::HalfOpen => write!(f, "half-open"),
        }
    }
}

/// Circuit breaker for protecting against provider failures.
///
/// Tracks consecutive failures and opens the circuit after a threshold,
/// preventing further requests until a cooldown period expires.
///
/// # State Transitions
///
/// - Closed → Open: After N consecutive failures
/// - Open → HalfOpen: After cooldown period expires
/// - HalfOpen → Closed: After successful request
/// - HalfOpen → Open: After any failure
///
/// # Examples
///
/// ```
/// use fae::fae_llm::agent::types::CircuitBreaker;
///
/// let mut breaker = CircuitBreaker::default();
/// assert!(breaker.is_request_allowed());
///
/// // Simulate failures
/// for _ in 0..5 {
///     breaker.record_failure();
/// }
/// assert!(!breaker.is_request_allowed()); // Circuit is now open
/// ```
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CircuitBreaker {
    /// Current circuit state.
    pub state: CircuitState,
    /// Number of consecutive failures.
    pub consecutive_failures: u32,
    /// Threshold for opening the circuit.
    pub failure_threshold: u32,
    /// Cooldown period in seconds before allowing recovery.
    pub cooldown_secs: u64,
}

impl Default for CircuitBreaker {
    fn default() -> Self {
        Self {
            state: CircuitState::Closed,
            consecutive_failures: 0,
            failure_threshold: DEFAULT_CIRCUIT_BREAKER_THRESHOLD,
            cooldown_secs: DEFAULT_CIRCUIT_BREAKER_COOLDOWN_SECS,
        }
    }
}

impl CircuitBreaker {
    /// Create a new circuit breaker with default settings.
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the failure threshold.
    pub fn with_failure_threshold(mut self, threshold: u32) -> Self {
        self.failure_threshold = threshold;
        self
    }

    /// Set the cooldown period in seconds.
    pub fn with_cooldown_secs(mut self, secs: u64) -> Self {
        self.cooldown_secs = secs;
        self
    }

    /// Check if a request is allowed in the current circuit state.
    ///
    /// Returns `false` if the circuit is open and cooldown hasn't expired.
    pub fn is_request_allowed(&self) -> bool {
        match self.state {
            CircuitState::Closed | CircuitState::HalfOpen => true,
            CircuitState::Open { .. } => false,
        }
    }

    /// Record a successful request.
    ///
    /// Resets consecutive failures and closes the circuit if half-open.
    pub fn record_success(&mut self) {
        self.consecutive_failures = 0;
        if self.state == CircuitState::HalfOpen {
            self.state = CircuitState::Closed;
        }
    }

    /// Record a failed request.
    ///
    /// Increments consecutive failures and opens circuit if threshold reached.
    pub fn record_failure(&mut self) {
        self.consecutive_failures += 1;

        match self.state {
            CircuitState::Closed => {
                if self.consecutive_failures >= self.failure_threshold {
                    self.state = CircuitState::Open {
                        retry_after_secs: self.cooldown_secs,
                    };
                }
            }
            CircuitState::HalfOpen => {
                // Any failure in half-open state reopens the circuit
                self.state = CircuitState::Open {
                    retry_after_secs: self.cooldown_secs,
                };
            }
            CircuitState::Open { .. } => {
                // Already open, keep counting failures
            }
        }
    }

    /// Attempt to transition from Open to HalfOpen.
    ///
    /// Call this periodically when the circuit is open to check if cooldown has expired.
    /// Returns `true` if the transition occurred.
    pub fn attempt_recovery(&mut self) -> bool {
        if let CircuitState::Open { retry_after_secs } = self.state
            && retry_after_secs == 0
        {
            self.state = CircuitState::HalfOpen;
            return true;
        }
        false
    }

    /// Decrement the retry_after counter (call every second).
    pub fn tick(&mut self) {
        if let CircuitState::Open { retry_after_secs } = &mut self.state
            && *retry_after_secs > 0
        {
            *retry_after_secs -= 1;
        }
    }

    /// Reset the circuit breaker to closed state.
    pub fn reset(&mut self) {
        self.state = CircuitState::Closed;
        self.consecutive_failures = 0;
    }
}

/// Configuration for the agent loop.
///
/// Controls safety limits (max turns, max tool calls per turn),
/// timeouts (request and per-tool), and the system prompt.
///
/// # Examples
///
/// ```
/// use fae::fae_llm::agent::types::AgentConfig;
///
/// let config = AgentConfig::new()
///     .with_max_turns(10)
///     .with_max_tool_calls_per_turn(5)
///     .with_request_timeout_secs(60)
///     .with_tool_timeout_secs(15)
///     .with_system_prompt("You are a helpful coding assistant.");
/// ```
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AgentConfig {
    /// Maximum number of turns (provider round-trips) before stopping.
    pub max_turns: u32,
    /// Maximum tool calls the model may request in a single turn.
    pub max_tool_calls_per_turn: u32,
    /// Timeout for each provider request in seconds.
    pub request_timeout_secs: u64,
    /// Timeout for each individual tool execution in seconds.
    pub tool_timeout_secs: u64,
    /// Optional system prompt prepended to every conversation.
    pub system_prompt: Option<String>,
}

impl Default for AgentConfig {
    fn default() -> Self {
        Self {
            max_turns: DEFAULT_MAX_TURNS,
            max_tool_calls_per_turn: DEFAULT_MAX_TOOL_CALLS_PER_TURN,
            request_timeout_secs: DEFAULT_REQUEST_TIMEOUT_SECS,
            tool_timeout_secs: DEFAULT_TOOL_TIMEOUT_SECS,
            system_prompt: None,
        }
    }
}

impl AgentConfig {
    /// Create a new agent config with default values.
    pub fn new() -> Self {
        Self::default()
    }

    /// Set the maximum number of turns.
    pub fn with_max_turns(mut self, max_turns: u32) -> Self {
        self.max_turns = max_turns;
        self
    }

    /// Set the maximum tool calls per turn.
    pub fn with_max_tool_calls_per_turn(mut self, max: u32) -> Self {
        self.max_tool_calls_per_turn = max;
        self
    }

    /// Set the request timeout in seconds.
    pub fn with_request_timeout_secs(mut self, secs: u64) -> Self {
        self.request_timeout_secs = secs;
        self
    }

    /// Set the per-tool execution timeout in seconds.
    pub fn with_tool_timeout_secs(mut self, secs: u64) -> Self {
        self.tool_timeout_secs = secs;
        self
    }

    /// Set the system prompt.
    pub fn with_system_prompt(mut self, prompt: impl Into<String>) -> Self {
        self.system_prompt = Some(prompt.into());
        self
    }
}

/// A tool call that was executed during the agent loop.
///
/// Contains the original call information, the execution result,
/// and timing data.
#[derive(Debug, Clone)]
pub struct ExecutedToolCall {
    /// The unique call ID from the LLM.
    pub call_id: String,
    /// The function name that was called.
    pub function_name: String,
    /// The parsed arguments.
    pub arguments: serde_json::Value,
    /// The tool execution result.
    pub result: ToolResult,
    /// How long the tool took to execute in milliseconds.
    pub duration_ms: u64,
}

/// The result of a single turn in the agent loop.
///
/// A turn is one round-trip: send messages to the provider,
/// receive a streamed response, and optionally execute tool calls.
#[derive(Debug, Clone)]
pub struct TurnResult {
    /// Text generated by the model in this turn.
    pub text: String,
    /// Thinking/reasoning text (if the model produced it).
    pub thinking: String,
    /// Tool calls that were executed in this turn.
    pub tool_calls: Vec<ExecutedToolCall>,
    /// Why the model stopped generating in this turn.
    pub finish_reason: FinishReason,
    /// Token usage for this turn (if reported by the provider).
    pub usage: Option<TokenUsage>,
}

/// Why the agent loop stopped.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub enum StopReason {
    /// The model completed its response naturally.
    Complete,
    /// The maximum number of turns was reached.
    MaxTurns,
    /// Too many tool calls in a single turn.
    MaxToolCalls,
    /// The loop was cancelled by the caller.
    Cancelled,
    /// An error occurred during the loop.
    Error(String),
}

impl std::fmt::Display for StopReason {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Complete => write!(f, "complete"),
            Self::MaxTurns => write!(f, "max_turns"),
            Self::MaxToolCalls => write!(f, "max_tool_calls"),
            Self::Cancelled => write!(f, "cancelled"),
            Self::Error(msg) => write!(f, "error: {msg}"),
        }
    }
}

/// The complete result of an agent loop run.
///
/// Contains all turns, the final accumulated text, total token usage,
/// and the reason the loop stopped.
#[derive(Debug, Clone)]
pub struct AgentLoopResult {
    /// All turns executed during the loop.
    pub turns: Vec<TurnResult>,
    /// The final text output (from the last turn's text).
    pub final_text: String,
    /// Total token usage accumulated across all turns.
    pub total_usage: TokenUsage,
    /// Why the agent loop stopped.
    pub stop_reason: StopReason,
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── AgentConfig ──────────────────────────────────────────

    #[test]
    fn agent_config_defaults() {
        let config = AgentConfig::new();
        assert_eq!(config.max_turns, DEFAULT_MAX_TURNS);
        assert_eq!(
            config.max_tool_calls_per_turn,
            DEFAULT_MAX_TOOL_CALLS_PER_TURN
        );
        assert_eq!(config.request_timeout_secs, DEFAULT_REQUEST_TIMEOUT_SECS);
        assert_eq!(config.tool_timeout_secs, DEFAULT_TOOL_TIMEOUT_SECS);
        assert!(config.system_prompt.is_none());
    }

    #[test]
    fn agent_config_builder() {
        let config = AgentConfig::new()
            .with_max_turns(10)
            .with_max_tool_calls_per_turn(5)
            .with_request_timeout_secs(60)
            .with_tool_timeout_secs(15)
            .with_system_prompt("You are helpful.");
        assert_eq!(config.max_turns, 10);
        assert_eq!(config.max_tool_calls_per_turn, 5);
        assert_eq!(config.request_timeout_secs, 60);
        assert_eq!(config.tool_timeout_secs, 15);
        assert_eq!(config.system_prompt.as_deref(), Some("You are helpful."));
    }

    #[test]
    fn agent_config_serde_round_trip() {
        let original = AgentConfig::new()
            .with_max_turns(8)
            .with_system_prompt("test prompt");
        let json = serde_json::to_string(&original).unwrap_or_default();
        let parsed: Result<AgentConfig, _> = serde_json::from_str(&json);
        assert!(parsed.is_ok());
        let parsed = match parsed {
            Ok(c) => c,
            Err(_) => unreachable!("deserialization succeeded"),
        };
        assert_eq!(parsed.max_turns, 8);
        assert_eq!(parsed.system_prompt.as_deref(), Some("test prompt"));
    }

    #[test]
    fn agent_config_clone() {
        let config = AgentConfig::new().with_max_turns(5);
        let cloned = config.clone();
        assert_eq!(cloned.max_turns, 5);
    }

    #[test]
    fn agent_config_debug() {
        let config = AgentConfig::new();
        let debug = format!("{config:?}");
        assert!(debug.contains("AgentConfig"));
        assert!(debug.contains("max_turns"));
    }

    #[test]
    fn agent_config_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<AgentConfig>();
    }

    // ── ExecutedToolCall ──────────────────────────────────────

    #[test]
    fn executed_tool_call_construction() {
        let call = ExecutedToolCall {
            call_id: "call_1".into(),
            function_name: "read".into(),
            arguments: serde_json::json!({"path": "main.rs"}),
            result: ToolResult::success("fn main() {}".to_string()),
            duration_ms: 42,
        };
        assert_eq!(call.call_id, "call_1");
        assert_eq!(call.function_name, "read");
        assert_eq!(call.duration_ms, 42);
        assert!(call.result.success);
    }

    #[test]
    fn executed_tool_call_clone() {
        let call = ExecutedToolCall {
            call_id: "call_1".into(),
            function_name: "bash".into(),
            arguments: serde_json::json!({"command": "ls"}),
            result: ToolResult::success("file.txt".to_string()),
            duration_ms: 100,
        };
        let cloned = call.clone();
        assert_eq!(cloned.call_id, "call_1");
        assert_eq!(cloned.duration_ms, 100);
    }

    #[test]
    fn executed_tool_call_debug() {
        let call = ExecutedToolCall {
            call_id: "call_1".into(),
            function_name: "read".into(),
            arguments: serde_json::json!({}),
            result: ToolResult::success("ok".to_string()),
            duration_ms: 5,
        };
        let debug = format!("{call:?}");
        assert!(debug.contains("ExecutedToolCall"));
        assert!(debug.contains("call_1"));
    }

    // ── TurnResult ───────────────────────────────────────────

    #[test]
    fn turn_result_text_only() {
        let turn = TurnResult {
            text: "Hello world".into(),
            thinking: String::new(),
            tool_calls: Vec::new(),
            finish_reason: FinishReason::Stop,
            usage: Some(TokenUsage::new(100, 50)),
        };
        assert_eq!(turn.text, "Hello world");
        assert!(turn.tool_calls.is_empty());
        assert_eq!(turn.finish_reason, FinishReason::Stop);
    }

    #[test]
    fn turn_result_with_tools() {
        let tool_call = ExecutedToolCall {
            call_id: "call_1".into(),
            function_name: "read".into(),
            arguments: serde_json::json!({"path": "test.rs"}),
            result: ToolResult::success("content".to_string()),
            duration_ms: 10,
        };
        let turn = TurnResult {
            text: "I'll read that.".into(),
            thinking: String::new(),
            tool_calls: vec![tool_call],
            finish_reason: FinishReason::ToolCalls,
            usage: None,
        };
        assert_eq!(turn.tool_calls.len(), 1);
        assert_eq!(turn.finish_reason, FinishReason::ToolCalls);
    }

    #[test]
    fn turn_result_with_thinking() {
        let turn = TurnResult {
            text: "Answer: 42".into(),
            thinking: "Let me think step by step...".into(),
            tool_calls: Vec::new(),
            finish_reason: FinishReason::Stop,
            usage: None,
        };
        assert_eq!(turn.thinking, "Let me think step by step...");
    }

    #[test]
    fn turn_result_clone() {
        let turn = TurnResult {
            text: "test".into(),
            thinking: String::new(),
            tool_calls: Vec::new(),
            finish_reason: FinishReason::Stop,
            usage: None,
        };
        let cloned = turn.clone();
        assert_eq!(cloned.text, "test");
    }

    // ── StopReason ───────────────────────────────────────────

    #[test]
    fn stop_reason_display() {
        assert_eq!(StopReason::Complete.to_string(), "complete");
        assert_eq!(StopReason::MaxTurns.to_string(), "max_turns");
        assert_eq!(StopReason::MaxToolCalls.to_string(), "max_tool_calls");
        assert_eq!(StopReason::Cancelled.to_string(), "cancelled");
        assert_eq!(
            StopReason::Error("timeout".into()).to_string(),
            "error: timeout"
        );
    }

    #[test]
    fn stop_reason_equality() {
        assert_eq!(StopReason::Complete, StopReason::Complete);
        assert_ne!(StopReason::Complete, StopReason::MaxTurns);
        assert_eq!(StopReason::Error("a".into()), StopReason::Error("a".into()));
        assert_ne!(StopReason::Error("a".into()), StopReason::Error("b".into()));
    }

    #[test]
    fn stop_reason_serde_round_trip() {
        let reasons = [
            StopReason::Complete,
            StopReason::MaxTurns,
            StopReason::MaxToolCalls,
            StopReason::Cancelled,
            StopReason::Error("something".into()),
        ];
        for reason in &reasons {
            let json = serde_json::to_string(reason).unwrap_or_default();
            let parsed: Result<StopReason, _> = serde_json::from_str(&json);
            assert!(parsed.is_ok(), "failed to parse: {json}");
            match parsed {
                Ok(r) => assert_eq!(r, *reason),
                Err(_) => unreachable!("deserialization succeeded"),
            }
        }
    }

    #[test]
    fn stop_reason_clone() {
        let reason = StopReason::Error("test".into());
        let cloned = reason.clone();
        assert_eq!(reason, cloned);
    }

    #[test]
    fn stop_reason_debug() {
        let reason = StopReason::Complete;
        let debug = format!("{reason:?}");
        assert!(debug.contains("Complete"));
    }

    // ── AgentLoopResult ──────────────────────────────────────

    #[test]
    fn agent_loop_result_construction() {
        let turn = TurnResult {
            text: "Done.".into(),
            thinking: String::new(),
            tool_calls: Vec::new(),
            finish_reason: FinishReason::Stop,
            usage: Some(TokenUsage::new(200, 100)),
        };
        let result = AgentLoopResult {
            turns: vec![turn],
            final_text: "Done.".into(),
            total_usage: TokenUsage::new(200, 100),
            stop_reason: StopReason::Complete,
        };
        assert_eq!(result.turns.len(), 1);
        assert_eq!(result.final_text, "Done.");
        assert_eq!(result.total_usage.total(), 300);
        assert_eq!(result.stop_reason, StopReason::Complete);
    }

    #[test]
    fn agent_loop_result_multi_turn() {
        let turn1 = TurnResult {
            text: "Let me check.".into(),
            thinking: String::new(),
            tool_calls: vec![ExecutedToolCall {
                call_id: "call_1".into(),
                function_name: "read".into(),
                arguments: serde_json::json!({"path": "a.rs"}),
                result: ToolResult::success("code".to_string()),
                duration_ms: 10,
            }],
            finish_reason: FinishReason::ToolCalls,
            usage: Some(TokenUsage::new(100, 50)),
        };
        let turn2 = TurnResult {
            text: "Here's the file.".into(),
            thinking: String::new(),
            tool_calls: Vec::new(),
            finish_reason: FinishReason::Stop,
            usage: Some(TokenUsage::new(150, 80)),
        };
        let mut total = TokenUsage::new(100, 50);
        total.add(&TokenUsage::new(150, 80));
        let result = AgentLoopResult {
            turns: vec![turn1, turn2],
            final_text: "Here's the file.".into(),
            total_usage: total,
            stop_reason: StopReason::Complete,
        };
        assert_eq!(result.turns.len(), 2);
        assert_eq!(result.total_usage.prompt_tokens, 250);
        assert_eq!(result.total_usage.completion_tokens, 130);
    }

    #[test]
    fn agent_loop_result_clone() {
        let result = AgentLoopResult {
            turns: Vec::new(),
            final_text: "test".into(),
            total_usage: TokenUsage::default(),
            stop_reason: StopReason::Complete,
        };
        let cloned = result.clone();
        assert_eq!(cloned.final_text, "test");
    }

    #[test]
    fn agent_loop_result_debug() {
        let result = AgentLoopResult {
            turns: Vec::new(),
            final_text: "output".into(),
            total_usage: TokenUsage::default(),
            stop_reason: StopReason::Complete,
        };
        let debug = format!("{result:?}");
        assert!(debug.contains("AgentLoopResult"));
        assert!(debug.contains("output"));
    }

    #[test]
    fn all_agent_types_are_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<AgentConfig>();
        assert_send_sync::<StopReason>();
        // ExecutedToolCall, TurnResult, AgentLoopResult contain ToolResult
        // which has String fields — all Send + Sync
        assert_send_sync::<ExecutedToolCall>();
        assert_send_sync::<TurnResult>();
        assert_send_sync::<AgentLoopResult>();
        assert_send_sync::<RetryPolicy>();
        assert_send_sync::<CircuitBreaker>();
        assert_send_sync::<CircuitState>();
    }

    // ── RetryPolicy ───────────────────────────────────────────

    #[test]
    fn retry_policy_defaults() {
        let policy = RetryPolicy::new();
        assert_eq!(policy.max_attempts, DEFAULT_MAX_RETRY_ATTEMPTS);
        assert_eq!(policy.base_delay_ms, DEFAULT_RETRY_BASE_DELAY_MS);
        assert_eq!(policy.max_delay_ms, DEFAULT_RETRY_MAX_DELAY_MS);
        assert_eq!(policy.backoff_multiplier, DEFAULT_RETRY_BACKOFF_MULTIPLIER);
    }

    #[test]
    fn retry_policy_builder() {
        let policy = RetryPolicy::new()
            .with_max_attempts(5)
            .with_base_delay_ms(500)
            .with_max_delay_ms(16000)
            .with_backoff_multiplier(1.5);
        assert_eq!(policy.max_attempts, 5);
        assert_eq!(policy.base_delay_ms, 500);
        assert_eq!(policy.max_delay_ms, 16000);
        assert_eq!(policy.backoff_multiplier, 1.5);
    }

    #[test]
    fn retry_policy_delay_zero_attempt() {
        let policy = RetryPolicy::new();
        let delay = policy.delay_for_attempt(0);
        assert_eq!(delay.as_millis(), 0);
    }

    #[test]
    fn retry_policy_delay_first_attempt() {
        let policy = RetryPolicy::new().with_base_delay_ms(1000);
        let delay = policy.delay_for_attempt(1);
        // Should be ~1000ms + jitter (0-10%)
        assert!(delay.as_millis() >= 1000);
        assert!(delay.as_millis() <= 1100);
    }

    #[test]
    fn retry_policy_delay_exponential_growth() {
        let policy = RetryPolicy::new()
            .with_base_delay_ms(1000)
            .with_backoff_multiplier(2.0)
            .with_max_delay_ms(100000);
        let delay1 = policy.delay_for_attempt(1);
        let delay2 = policy.delay_for_attempt(2);
        let delay3 = policy.delay_for_attempt(3);
        // Delays should grow exponentially: ~1s, ~2s, ~4s (+ jitter)
        assert!(delay1.as_millis() >= 1000 && delay1.as_millis() <= 1100);
        assert!(delay2.as_millis() >= 2000 && delay2.as_millis() <= 2200);
        assert!(delay3.as_millis() >= 4000 && delay3.as_millis() <= 4400);
    }

    #[test]
    fn retry_policy_delay_capped_by_max() {
        let policy = RetryPolicy::new()
            .with_base_delay_ms(1000)
            .with_backoff_multiplier(2.0)
            .with_max_delay_ms(3000);
        let delay5 = policy.delay_for_attempt(5);
        // Without cap: 1000 * 2^4 = 16000ms
        // With cap: 3000ms + jitter (max 3300ms)
        assert!(delay5.as_millis() <= 3300);
    }

    #[test]
    fn retry_policy_serde_round_trip() {
        let original = RetryPolicy::new().with_max_attempts(4);
        let json = serde_json::to_string(&original).unwrap_or_default();
        let parsed: Result<RetryPolicy, _> = serde_json::from_str(&json);
        assert!(parsed.is_ok());
        let parsed = match parsed {
            Ok(p) => p,
            Err(_) => unreachable!("deserialization succeeded"),
        };
        assert_eq!(parsed.max_attempts, 4);
    }

    #[test]
    fn retry_policy_clone() {
        let policy = RetryPolicy::new().with_max_attempts(3);
        let cloned = policy.clone();
        assert_eq!(cloned.max_attempts, 3);
    }

    #[test]
    fn retry_policy_debug() {
        let policy = RetryPolicy::new();
        let debug = format!("{policy:?}");
        assert!(debug.contains("RetryPolicy"));
        assert!(debug.contains("max_attempts"));
    }

    // ── CircuitBreaker ───────────────────────────────────────────

    #[test]
    fn circuit_breaker_defaults() {
        let breaker = CircuitBreaker::new();
        assert_eq!(breaker.state, CircuitState::Closed);
        assert_eq!(breaker.consecutive_failures, 0);
        assert_eq!(breaker.failure_threshold, DEFAULT_CIRCUIT_BREAKER_THRESHOLD);
        assert_eq!(breaker.cooldown_secs, DEFAULT_CIRCUIT_BREAKER_COOLDOWN_SECS);
    }

    #[test]
    fn circuit_breaker_builder() {
        let breaker = CircuitBreaker::new()
            .with_failure_threshold(3)
            .with_cooldown_secs(30);
        assert_eq!(breaker.failure_threshold, 3);
        assert_eq!(breaker.cooldown_secs, 30);
    }

    #[test]
    fn circuit_breaker_allows_requests_when_closed() {
        let breaker = CircuitBreaker::new();
        assert!(breaker.is_request_allowed());
    }

    #[test]
    fn circuit_breaker_opens_after_threshold_failures() {
        let mut breaker = CircuitBreaker::new().with_failure_threshold(3);
        assert!(breaker.is_request_allowed());

        breaker.record_failure();
        assert!(breaker.is_request_allowed()); // Still closed (1/3)

        breaker.record_failure();
        assert!(breaker.is_request_allowed()); // Still closed (2/3)

        breaker.record_failure();
        assert!(!breaker.is_request_allowed()); // Now open (3/3)
        assert_eq!(breaker.consecutive_failures, 3);
        assert!(matches!(breaker.state, CircuitState::Open { .. }));
    }

    #[test]
    fn circuit_breaker_blocks_requests_when_open() {
        let mut breaker = CircuitBreaker::new().with_failure_threshold(2);
        breaker.record_failure();
        breaker.record_failure();
        assert!(!breaker.is_request_allowed());
    }

    #[test]
    fn circuit_breaker_transitions_to_half_open_after_cooldown() {
        let mut breaker = CircuitBreaker::new()
            .with_failure_threshold(1)
            .with_cooldown_secs(3);
        breaker.record_failure();
        assert_eq!(
            breaker.state,
            CircuitState::Open {
                retry_after_secs: 3
            }
        );

        // Tick down the cooldown
        breaker.tick();
        assert_eq!(
            breaker.state,
            CircuitState::Open {
                retry_after_secs: 2
            }
        );
        breaker.tick();
        assert_eq!(
            breaker.state,
            CircuitState::Open {
                retry_after_secs: 1
            }
        );
        breaker.tick();
        assert_eq!(
            breaker.state,
            CircuitState::Open {
                retry_after_secs: 0
            }
        );

        // Attempt recovery
        let transitioned = breaker.attempt_recovery();
        assert!(transitioned);
        assert_eq!(breaker.state, CircuitState::HalfOpen);
    }

    #[test]
    fn circuit_breaker_closes_on_success_in_half_open() {
        let mut breaker = CircuitBreaker::new().with_failure_threshold(1);
        breaker.record_failure();
        breaker.state = CircuitState::HalfOpen;

        breaker.record_success();
        assert_eq!(breaker.state, CircuitState::Closed);
        assert_eq!(breaker.consecutive_failures, 0);
    }

    #[test]
    fn circuit_breaker_reopens_on_failure_in_half_open() {
        let mut breaker = CircuitBreaker::new()
            .with_failure_threshold(2)
            .with_cooldown_secs(60);
        breaker.state = CircuitState::HalfOpen;
        breaker.consecutive_failures = 2;

        breaker.record_failure();
        assert_eq!(
            breaker.state,
            CircuitState::Open {
                retry_after_secs: 60
            }
        );
        assert_eq!(breaker.consecutive_failures, 3);
    }

    #[test]
    fn circuit_breaker_success_resets_failures() {
        let mut breaker = CircuitBreaker::new().with_failure_threshold(5);
        breaker.record_failure();
        breaker.record_failure();
        assert_eq!(breaker.consecutive_failures, 2);

        breaker.record_success();
        assert_eq!(breaker.consecutive_failures, 0);
        assert_eq!(breaker.state, CircuitState::Closed);
    }

    #[test]
    fn circuit_breaker_reset() {
        let mut breaker = CircuitBreaker::new().with_failure_threshold(1);
        breaker.record_failure();
        assert_eq!(
            breaker.state,
            CircuitState::Open {
                retry_after_secs: 60
            }
        );
        assert_eq!(breaker.consecutive_failures, 1);

        breaker.reset();
        assert_eq!(breaker.state, CircuitState::Closed);
        assert_eq!(breaker.consecutive_failures, 0);
    }

    #[test]
    fn circuit_state_display() {
        assert_eq!(CircuitState::Closed.to_string(), "closed");
        assert_eq!(CircuitState::HalfOpen.to_string(), "half-open");
        assert_eq!(
            CircuitState::Open {
                retry_after_secs: 30
            }
            .to_string(),
            "open (retry after 30s)"
        );
    }

    #[test]
    fn circuit_state_equality() {
        assert_eq!(CircuitState::Closed, CircuitState::Closed);
        assert_eq!(CircuitState::HalfOpen, CircuitState::HalfOpen);
        assert_eq!(
            CircuitState::Open {
                retry_after_secs: 10
            },
            CircuitState::Open {
                retry_after_secs: 10
            }
        );
        assert_ne!(
            CircuitState::Open {
                retry_after_secs: 10
            },
            CircuitState::Open {
                retry_after_secs: 20
            }
        );
    }

    #[test]
    fn circuit_breaker_serde_round_trip() {
        let original = CircuitBreaker::new().with_failure_threshold(7);
        let json = serde_json::to_string(&original).unwrap_or_default();
        let parsed: Result<CircuitBreaker, _> = serde_json::from_str(&json);
        assert!(parsed.is_ok());
        let parsed = match parsed {
            Ok(b) => b,
            Err(_) => unreachable!("deserialization succeeded"),
        };
        assert_eq!(parsed.failure_threshold, 7);
    }

    #[test]
    fn circuit_breaker_clone() {
        let breaker = CircuitBreaker::new().with_failure_threshold(4);
        let cloned = breaker.clone();
        assert_eq!(cloned.failure_threshold, 4);
    }

    #[test]
    fn circuit_breaker_debug() {
        let breaker = CircuitBreaker::new();
        let debug = format!("{breaker:?}");
        assert!(debug.contains("CircuitBreaker"));
        assert!(debug.contains("state"));
    }

    #[test]
    fn circuit_breaker_allows_requests_when_half_open() {
        let mut breaker = CircuitBreaker::new();
        breaker.state = CircuitState::HalfOpen;
        assert!(breaker.is_request_allowed());
    }
}
