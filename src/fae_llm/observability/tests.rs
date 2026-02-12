//! Integration tests for observability features.
//!
//! These tests verify that tracing spans, metrics collection, and secret redaction
//! work correctly in end-to-end scenarios.

#[cfg(test)]
mod observability_integration_tests {
    use crate::fae_llm::observability::metrics::{MetricsCollector, NoopMetrics};
    use crate::fae_llm::observability::redact::{RedactedString, redact_all};
    use crate::fae_llm::observability::spans::*;

    // ── Tracing Span Tests ─────────────────────────────────────────

    #[test]
    fn span_constants_follow_hierarchy() {
        // Verify spans use consistent dot-separated naming
        assert!(SPAN_PROVIDER_REQUEST.starts_with("fae_llm."));
        assert!(SPAN_AGENT_TURN.starts_with("fae_llm."));
        assert!(SPAN_TOOL_EXECUTE.starts_with("fae_llm."));
        assert!(SPAN_SESSION_OPERATION.starts_with("fae_llm."));

        // Verify uniqueness
        let spans = [
            SPAN_PROVIDER_REQUEST,
            SPAN_AGENT_TURN,
            SPAN_TOOL_EXECUTE,
            SPAN_SESSION_OPERATION,
        ];
        let unique: std::collections::HashSet<_> = spans.iter().collect();
        assert_eq!(spans.len(), unique.len(), "Span names must be unique");
    }

    #[test]
    fn field_constants_use_snake_case() {
        // Verify field naming conventions
        assert_eq!(FIELD_PROVIDER, "provider");
        assert_eq!(FIELD_MODEL, "model");
        assert_eq!(FIELD_ENDPOINT_TYPE, "endpoint_type");
        assert_eq!(FIELD_TURN_NUMBER, "turn_number");
        assert_eq!(FIELD_MAX_TURNS, "max_turns");
        assert_eq!(FIELD_TOOL_NAME, "tool_name");
        assert_eq!(FIELD_TOOL_MODE, "mode");
        assert_eq!(FIELD_SESSION_ID, "session_id");
        assert_eq!(FIELD_OPERATION, "operation");
        assert_eq!(FIELD_REQUEST_ID, "request_id");
    }

    #[test]
    fn span_creation_compiles() {
        // Verify span creation syntax works
        let _span = tracing::info_span!(
            SPAN_PROVIDER_REQUEST,
            { FIELD_PROVIDER } = "openai",
            { FIELD_MODEL } = "gpt-4",
            { FIELD_ENDPOINT_TYPE } = "completions",
        );

        let _turn_span = tracing::info_span!(
            SPAN_AGENT_TURN,
            { FIELD_TURN_NUMBER } = 1_u32,
            { FIELD_MAX_TURNS } = 10_u32,
        );

        let _tool_span = tracing::info_span!(
            SPAN_TOOL_EXECUTE,
            { FIELD_TOOL_NAME } = "read",
            { FIELD_TOOL_MODE } = "read_only",
        );
    }

    // ── Metrics Collection Tests ───────────────────────────────────

    #[test]
    fn noop_metrics_has_zero_cost() {
        let metrics = NoopMetrics;

        // All methods should compile and do nothing
        metrics.record_request_latency_ms("openai", "gpt-4", 1000);
        metrics.record_turn_latency_ms(1, 500);
        metrics.record_tool_latency_ms("read", 100);
        metrics.count_event("test", "label");
        metrics.count_retry("openai", "rate_limit");
        metrics.count_circuit_breaker_open("anthropic");
        metrics.count_tool_result("bash", true);
        metrics.record_token_usage("openai", "gpt-4", 100, 200, 0);
        metrics.record_cost("openai", "gpt-4", 0.01);

        // Test passes if no panics and compiles
    }

    #[test]
    fn custom_metrics_collector_trait_works() {
        use std::sync::Arc;
        use std::sync::atomic::{AtomicU64, Ordering};

        struct TestMetrics {
            request_count: Arc<AtomicU64>,
        }

        impl MetricsCollector for TestMetrics {
            fn record_request_latency_ms(&self, _provider: &str, _model: &str, _latency_ms: u64) {
                self.request_count.fetch_add(1, Ordering::SeqCst);
            }

            fn record_turn_latency_ms(&self, _turn_number: u32, _latency_ms: u64) {}
            fn record_tool_latency_ms(&self, _tool_name: &str, _latency_ms: u64) {}
            fn count_event(&self, _event_name: &str, _label: &str) {}
            fn count_retry(&self, _provider: &str, _reason: &str) {}
            fn count_circuit_breaker_open(&self, _provider: &str) {}
            fn count_tool_result(&self, _tool_name: &str, _success: bool) {}
            fn record_token_usage(
                &self,
                _provider: &str,
                _model: &str,
                _input: u64,
                _output: u64,
                _reasoning: u64,
            ) {
            }
            fn record_cost(&self, _provider: &str, _model: &str, _cost_usd: f64) {}
        }

        let counter = Arc::new(AtomicU64::new(0));
        let metrics = TestMetrics {
            request_count: Arc::clone(&counter),
        };

        metrics.record_request_latency_ms("openai", "gpt-4", 1000);
        metrics.record_request_latency_ms("anthropic", "claude", 2000);

        assert_eq!(counter.load(Ordering::SeqCst), 2);
    }

    // ── Secret Redaction Tests ─────────────────────────────────────

    #[test]
    fn redacted_string_never_leaks() {
        let secret = RedactedString::new("sk-1234567890abcdefghijklmnopqrstuv");

        // Verify Display doesn't leak
        let display = format!("{}", secret);
        assert_eq!(display, "[REDACTED]");
        assert!(!display.contains("sk-"));

        // Verify Debug doesn't leak
        let debug = format!("{:?}", secret);
        assert!(debug.contains("[REDACTED]"));
        assert!(!debug.contains("sk-"));
    }

    #[test]
    fn api_key_redaction_works() {
        let text = "Failed to connect with API key: sk-1234567890abcdefghijklmnopqrstuv";
        let redacted = redact_all(text);

        assert!(redacted.contains("sk-***REDACTED***"));
        assert!(!redacted.contains("sk-1234567890"));
    }

    #[test]
    fn auth_header_redaction_works() {
        let log = "Request error: Authorization: Bearer my-secret-token-12345";
        let redacted = redact_all(log);

        assert!(redacted.contains("Bearer ***REDACTED***"));
        assert!(!redacted.contains("my-secret-token"));
    }

    #[test]
    fn json_api_key_redaction_works() {
        let json = r#"{"api_key": "secret123", "model": "gpt-4"}"#;
        let redacted = redact_all(json);

        assert!(redacted.contains(r#""api_key": "***REDACTED***""#));
        assert!(!redacted.contains("secret123"));
        assert!(redacted.contains("gpt-4")); // Non-secret data preserved
    }

    #[test]
    fn redaction_preserves_context() {
        let error_msg = "OpenAI API error (sk-abc123): rate limit exceeded";
        let redacted = redact_all(error_msg);

        // Secret is redacted
        assert!(redacted.contains("sk-***REDACTED***"));
        assert!(!redacted.contains("abc123"));

        // Context is preserved
        assert!(redacted.contains("OpenAI API error"));
        assert!(redacted.contains("rate limit exceeded"));
    }

    // ── Integration Scenario Tests ─────────────────────────────────

    #[test]
    fn observability_features_compose() {
        // This test verifies that all three observability features can be used together

        // 1. Tracing span
        let _span = tracing::info_span!(
            SPAN_PROVIDER_REQUEST,
            { FIELD_PROVIDER } = "openai",
            { FIELD_MODEL } = "gpt-4",
        );

        // 2. Metrics collection
        let metrics = NoopMetrics;
        metrics.record_request_latency_ms("openai", "gpt-4", 1250);

        // 3. Secret redaction
        let api_key = RedactedString::new("sk-test-key");
        let error = format!("Request failed for {}", api_key);
        assert!(error.contains("[REDACTED]"));
        assert!(!error.contains("sk-test-key"));

        // All three features work together without conflicts
    }

    #[test]
    fn end_to_end_observability_scenario() {
        use std::sync::Arc;
        use std::sync::atomic::{AtomicU64, Ordering};

        // Simulated end-to-end agent loop scenario with full observability

        struct TestMetrics {
            requests: Arc<AtomicU64>,
            turns: Arc<AtomicU64>,
            tools: Arc<AtomicU64>,
        }

        impl MetricsCollector for TestMetrics {
            fn record_request_latency_ms(&self, _p: &str, _m: &str, _l: u64) {
                self.requests.fetch_add(1, Ordering::SeqCst);
            }
            fn record_turn_latency_ms(&self, _t: u32, _l: u64) {
                self.turns.fetch_add(1, Ordering::SeqCst);
            }
            fn record_tool_latency_ms(&self, _n: &str, _l: u64) {
                self.tools.fetch_add(1, Ordering::SeqCst);
            }
            fn count_event(&self, _e: &str, _l: &str) {}
            fn count_retry(&self, _p: &str, _r: &str) {}
            fn count_circuit_breaker_open(&self, _p: &str) {}
            fn count_tool_result(&self, _n: &str, _s: bool) {}
            fn record_token_usage(&self, _p: &str, _m: &str, _i: u64, _o: u64, _r: u64) {}
            fn record_cost(&self, _p: &str, _m: &str, _c: f64) {}
        }

        let metrics = TestMetrics {
            requests: Arc::new(AtomicU64::new(0)),
            turns: Arc::new(AtomicU64::new(0)),
            tools: Arc::new(AtomicU64::new(0)),
        };

        // Simulate provider request
        {
            let _span = tracing::info_span!(SPAN_PROVIDER_REQUEST);
            metrics.record_request_latency_ms("openai", "gpt-4", 1000);

            // Simulate agent turn
            {
                let _turn_span = tracing::info_span!(SPAN_AGENT_TURN);
                metrics.record_turn_latency_ms(1, 500);

                // Simulate tool execution
                {
                    let _tool_span = tracing::info_span!(SPAN_TOOL_EXECUTE);
                    metrics.record_tool_latency_ms("read", 100);
                }
            }
        }

        // Verify metrics were collected
        assert_eq!(metrics.requests.load(Ordering::SeqCst), 1);
        assert_eq!(metrics.turns.load(Ordering::SeqCst), 1);
        assert_eq!(metrics.tools.load(Ordering::SeqCst), 1);

        // Verify redaction still works
        let log = "Error with sk-abc123 in tool execution";
        let safe = redact_all(log);
        assert!(safe.contains("sk-***REDACTED***"));
    }
}
