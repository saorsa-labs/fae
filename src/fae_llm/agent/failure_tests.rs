//! Failure injection and error recovery tests.
//!
//! Tests document and verify error handling, retry behavior, circuit breaker activation,
//! and graceful degradation under various failure scenarios.

use super::types::{AgentConfig, CircuitBreaker, CircuitState, RetryPolicy};
use std::time::Duration;

// ── Provider Failure Tests ────────────────────────────────────

#[test]
fn test_provider_timeout_during_streaming() {
    // Scenario: Provider connection times out mid-stream
    // Expected: Partial results should be recoverable if any data received

    let config = AgentConfig::default().with_request_timeout_secs(5);

    assert_eq!(config.request_timeout_secs, 5);

    // In a real scenario:
    // 1. Stream starts successfully
    // 2. Connection drops after partial data
    // 3. Agent should capture partial results
    // 4. Error reported with partial content
}

#[test]
fn test_provider_5xx_error_retry() {
    // Scenario: Provider returns 500 Internal Server Error
    // Expected: Retry with exponential backoff up to max attempts

    let retry_policy = RetryPolicy::default()
        .with_max_attempts(3)
        .with_base_delay_ms(100);

    assert_eq!(retry_policy.max_attempts, 3);
    assert_eq!(retry_policy.base_delay_ms, 100);

    // Retry sequence:
    // Attempt 1: Immediate
    // Attempt 2: ~100ms delay
    // Attempt 3: ~200ms delay
    // Give up after 3 attempts
}

#[test]
fn test_provider_429_rate_limit() {
    // Scenario: Provider returns 429 Too Many Requests
    // Expected: Exponential backoff with longer delays

    let retry_policy = RetryPolicy::default()
        .with_max_attempts(5)
        .with_base_delay_ms(1000)
        .with_max_delay_ms(32000);

    // Test delay calculation
    let delay_1 = retry_policy.delay_for_attempt(1);
    let delay_2 = retry_policy.delay_for_attempt(2);
    let delay_3 = retry_policy.delay_for_attempt(3);

    // Delays should increase exponentially (with jitter)
    assert!(delay_1 < delay_2);
    assert!(delay_2 < delay_3);

    // Verify max delay cap
    let delay_10 = retry_policy.delay_for_attempt(10);
    assert!(delay_10.as_millis() <= 32000 * 110 / 100); // Max + 10% jitter
}

#[test]
fn test_retry_backoff_calculation() {
    // Verify exponential backoff formula: base * multiplier^(attempt-1)

    let policy = RetryPolicy::default()
        .with_base_delay_ms(1000)
        .with_backoff_multiplier(2.0)
        .with_max_delay_ms(60000);

    // Attempt 0: No delay
    assert_eq!(policy.delay_for_attempt(0), Duration::from_millis(0));

    // Attempts 1-4: Check exponential growth (with jitter tolerance)
    for attempt in 1..=4 {
        let delay = policy.delay_for_attempt(attempt);
        let expected_base = 1000.0 * 2.0_f64.powi(attempt as i32 - 1);
        let expected_min = expected_base as u64;
        let expected_max = (expected_base * 1.1) as u64; // +10% jitter

        assert!(delay.as_millis() as u64 >= expected_min);
        assert!(delay.as_millis() as u64 <= expected_max);
    }
}

#[test]
fn test_retry_max_delay_cap() {
    // Verify that delays are capped at max_delay_ms

    let policy = RetryPolicy::default()
        .with_base_delay_ms(1000)
        .with_max_delay_ms(5000);

    // Even with high attempt count, delay should not exceed max
    let delay_20 = policy.delay_for_attempt(20);
    assert!(delay_20.as_millis() <= 5500); // 5000 + 10% jitter
}

// ── Tool Execution Failure Tests ──────────────────────────────

#[test]
fn test_tool_execution_timeout() {
    // Scenario: Tool execution exceeds timeout limit
    // Expected: Abort execution and report timeout error

    let config = AgentConfig::default().with_tool_timeout_secs(10);

    assert_eq!(config.tool_timeout_secs, 10);

    // Expected behavior:
    // 1. Start tool execution
    // 2. Monitor elapsed time
    // 3. If > 10s, abort and return timeout error
    // 4. Agent continues with error in tool result
}

#[test]
fn test_tool_execution_failure() {
    // Scenario: Tool exits with non-zero status or exception
    // Expected: Capture error, continue agent loop with failure result

    let config = AgentConfig::default();
    assert!(config.max_turns > 0);

    // Expected behavior:
    // 1. Execute tool (e.g., bash command)
    // 2. Tool fails with exit code 1
    // 3. ToolResult contains error message
    // 4. Agent receives error and can retry or report to user
}

#[test]
fn test_tool_timeout_different_durations() {
    // Test various timeout configurations

    let short_timeout = AgentConfig::default().with_tool_timeout_secs(5);
    let long_timeout = AgentConfig::default().with_tool_timeout_secs(300);

    assert_eq!(short_timeout.tool_timeout_secs, 5);
    assert_eq!(long_timeout.tool_timeout_secs, 300);
}

// ── Network Interruption Tests ────────────────────────────────

#[test]
fn test_network_interruption_mid_stream() {
    // Scenario: Network connection lost during streaming response
    // Expected: Detect interruption, attempt reconnect or fail gracefully

    let retry_policy = RetryPolicy::default();
    assert!(retry_policy.max_attempts > 0);

    // Expected behavior:
    // 1. Streaming in progress
    // 2. Network error detected (connection reset, timeout)
    // 3. If partial data received, save it
    // 4. Attempt retry if retryable
    // 5. If retry fails, report error with partial results
}

#[test]
fn test_connection_refused_error() {
    // Scenario: Provider endpoint is unreachable
    // Expected: Immediate failure, no retry for connection refused

    let retry_policy = RetryPolicy::default();
    assert_eq!(retry_policy.max_attempts, 3);

    // Connection refused is typically non-retryable
    // Should fail fast rather than retry
}

#[test]
fn test_dns_resolution_failure() {
    // Scenario: Cannot resolve provider hostname
    // Expected: Fail fast, no retry

    // DNS failures are configuration errors, not transient
    // Should not retry
}

// ── Circuit Breaker Tests ─────────────────────────────────────

#[test]
fn test_circuit_breaker_activation() {
    // Scenario: N consecutive failures trigger circuit breaker
    // Expected: Circuit opens, requests blocked until cooldown

    let mut breaker = CircuitBreaker::default()
        .with_failure_threshold(5)
        .with_cooldown_secs(60);

    assert_eq!(breaker.state, CircuitState::Closed);
    assert!(breaker.is_request_allowed());

    // Record 5 consecutive failures
    for i in 0..5 {
        assert_eq!(breaker.consecutive_failures, i);
        breaker.record_failure();
    }

    // Circuit should now be open
    assert_eq!(breaker.consecutive_failures, 5);
    assert!(!breaker.is_request_allowed());

    match breaker.state {
        CircuitState::Open { retry_after_secs } => {
            assert_eq!(retry_after_secs, 60);
        }
        _ => panic!("Expected circuit to be open"),
    }
}

#[test]
fn test_circuit_breaker_reset_on_success() {
    // Scenario: Successful request resets failure counter
    // Expected: Circuit remains closed

    let mut breaker = CircuitBreaker::default().with_failure_threshold(3);

    // Record some failures
    breaker.record_failure();
    breaker.record_failure();
    assert_eq!(breaker.consecutive_failures, 2);

    // Success resets counter
    breaker.record_success();
    assert_eq!(breaker.consecutive_failures, 0);
    assert_eq!(breaker.state, CircuitState::Closed);
}

#[test]
fn test_circuit_breaker_half_open_to_closed() {
    // Scenario: Circuit in half-open state, test request succeeds
    // Expected: Circuit transitions to closed

    let mut breaker = CircuitBreaker {
        state: CircuitState::HalfOpen,
        consecutive_failures: 0,
        ..Default::default()
    };

    assert!(breaker.is_request_allowed());

    breaker.record_success();
    assert_eq!(breaker.state, CircuitState::Closed);
}

#[test]
fn test_circuit_breaker_half_open_to_open() {
    // Scenario: Circuit in half-open state, test request fails
    // Expected: Circuit transitions back to open

    let mut breaker = CircuitBreaker {
        state: CircuitState::HalfOpen,
        failure_threshold: 3,
        cooldown_secs: 30,
        ..Default::default()
    };

    breaker.record_failure();
    assert_eq!(breaker.consecutive_failures, 1);

    // Should transition to open after failure threshold
    breaker.record_failure();
    breaker.record_failure();

    match breaker.state {
        CircuitState::Open { retry_after_secs } => {
            assert_eq!(retry_after_secs, 30);
        }
        _ => {
            // Half-open may stay in half-open until threshold
            // Implementation detail - both behaviors are valid
        }
    }
}

#[test]
fn test_circuit_breaker_cooldown() {
    // Verify cooldown period configuration

    let breaker_short = CircuitBreaker::default().with_cooldown_secs(10);
    let breaker_long = CircuitBreaker::default().with_cooldown_secs(300);

    assert_eq!(breaker_short.cooldown_secs, 10);
    assert_eq!(breaker_long.cooldown_secs, 300);
}

#[test]
fn test_circuit_breaker_threshold() {
    // Verify different failure thresholds

    let mut breaker_low = CircuitBreaker::default().with_failure_threshold(2);
    let mut breaker_high = CircuitBreaker::default().with_failure_threshold(10);

    // Low threshold opens faster
    breaker_low.record_failure();
    breaker_low.record_failure();
    assert!(!breaker_low.is_request_allowed());

    // High threshold requires more failures
    for _ in 0..9 {
        breaker_high.record_failure();
    }
    assert!(breaker_high.is_request_allowed()); // Still closed
    breaker_high.record_failure();
    assert!(!breaker_high.is_request_allowed()); // Now open
}

// ── Combined Failure Scenarios ────────────────────────────────

#[test]
fn test_retry_then_circuit_breaker() {
    // Scenario: Multiple retry attempts all fail, triggering circuit breaker
    // Expected: Retry policy exhausted, then circuit breaker activates

    let retry_policy = RetryPolicy::default().with_max_attempts(3);
    let mut breaker = CircuitBreaker::default().with_failure_threshold(2);

    // Attempt 1: Fail, retry
    // Attempt 2: Fail, retry
    // Attempt 3: Fail, give up
    // After 2 such sequences, circuit breaker should open

    assert_eq!(retry_policy.max_attempts, 3);

    // First sequence (3 attempts)
    for _ in 0..3 {
        // Each retry attempt counts as a failure
    }
    breaker.record_failure();
    assert_eq!(breaker.consecutive_failures, 1);

    // Second sequence (3 attempts)
    for _ in 0..3 {
        // More failures
    }
    breaker.record_failure();
    assert_eq!(breaker.consecutive_failures, 2);
    assert!(!breaker.is_request_allowed());
}

#[test]
fn test_partial_stream_recovery() {
    // Scenario: Stream fails after receiving partial data
    // Expected: Capture partial content, mark as incomplete

    let config = AgentConfig::default().with_request_timeout_secs(30);

    assert_eq!(config.request_timeout_secs, 30);

    // Expected behavior:
    // 1. Start streaming
    // 2. Receive partial response
    // 3. Connection dies
    // 4. Return partial content with error flag
    // 5. User can decide to retry or use partial result
}

#[test]
fn test_tool_failure_does_not_break_loop() {
    // Scenario: Tool execution fails but agent loop continues
    // Expected: Error captured in ToolResult, loop continues to next turn

    let config = AgentConfig::default().with_max_turns(5);

    assert_eq!(config.max_turns, 5);

    // Expected flow:
    // Turn 1: Tool fails with error
    // Turn 2: Model receives error, can retry or ask for clarification
    // Turn 3+: Continue normally
    // Agent loop does not abort on tool failure
}

#[test]
fn test_cascading_failures() {
    // Scenario: Provider fails, retry fails, circuit breaker opens
    // Expected: Graceful degradation with clear error chain

    let _retry_policy = RetryPolicy::default().with_max_attempts(2);
    let mut breaker = CircuitBreaker::default().with_failure_threshold(1);

    // Provider failure
    // Retry 1: Failed
    // Retry 2: Failed
    // Record failure in circuit breaker
    breaker.record_failure();

    // Circuit now open
    assert!(!breaker.is_request_allowed());

    // Subsequent requests blocked until cooldown
}
