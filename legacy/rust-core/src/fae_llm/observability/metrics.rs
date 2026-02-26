/// Metrics collection for observability.
///
/// The [`MetricsCollector`] trait allows pluggable metrics backends (Prometheus, StatsD, etc.)
/// while keeping the fae_llm core decoupled from specific metrics systems.
///
/// # Example
///
/// ```rust,ignore
/// use std::sync::Arc;
/// use fae::fae_llm::observability::metrics::{MetricsCollector, NoopMetrics};
///
/// let metrics: Arc<dyn MetricsCollector> = Arc::new(NoopMetrics);
/// metrics.record_request_latency_ms("openai", "gpt-4", 1250);
/// metrics.count_event("tool_success", "read");
/// ```
///
/// # Thread Safety
///
/// All methods take `&self` (not `&mut self`) to allow concurrent access from multiple tasks.
/// Implementors should use interior mutability (e.g., `Arc<Mutex<>>`, `AtomicU64`) as needed.
use std::time::Duration;

/// Metrics collection interface for fae_llm operations.
///
/// Implementations can send metrics to Prometheus, StatsD, CloudWatch, or any other backend.
/// The default [`NoopMetrics`] implementation does nothing (zero runtime cost).
///
/// # Methods
///
/// ## Latency Recording
/// - [`record_request_latency_ms`](MetricsCollector::record_request_latency_ms) - Total request latency
/// - [`record_turn_latency_ms`](MetricsCollector::record_turn_latency_ms) - Agent loop turn latency
/// - [`record_tool_latency_ms`](MetricsCollector::record_tool_latency_ms) - Tool execution latency
///
/// ## Event Counting
/// - [`count_event`](MetricsCollector::count_event) - Generic event counter
/// - [`count_retry`](MetricsCollector::count_retry) - Request retry events
/// - [`count_circuit_breaker_open`](MetricsCollector::count_circuit_breaker_open) - Circuit breaker trips
/// - [`count_tool_result`](MetricsCollector::count_tool_result) - Tool execution outcomes
///
/// ## Usage Tracking
/// - [`record_token_usage`](MetricsCollector::record_token_usage) - Input/output/reasoning token counts
/// - [`record_cost`](MetricsCollector::record_cost) - Request cost in USD
pub trait MetricsCollector: Send + Sync {
    /// Record total request latency (provider request + agent loop).
    ///
    /// # Arguments
    /// - `provider` - Provider name (e.g., "openai", "anthropic")
    /// - `model` - Model identifier (e.g., "gpt-4", "claude-3-5-sonnet-20241022")
    /// - `latency_ms` - Total latency in milliseconds
    fn record_request_latency_ms(&self, provider: &str, model: &str, latency_ms: u64);

    /// Record agent turn latency (single iteration of the agent loop).
    ///
    /// # Arguments
    /// - `turn_number` - Turn index (1-indexed)
    /// - `latency_ms` - Turn latency in milliseconds
    fn record_turn_latency_ms(&self, turn_number: u32, latency_ms: u64);

    /// Record tool execution latency.
    ///
    /// # Arguments
    /// - `tool_name` - Tool identifier (e.g., "read", "bash", "edit", "write")
    /// - `latency_ms` - Execution latency in milliseconds
    fn record_tool_latency_ms(&self, tool_name: &str, latency_ms: u64);

    /// Record a generic event count (increment by 1).
    ///
    /// # Arguments
    /// - `event_name` - Event type (e.g., "retry", "timeout", "validation_error")
    /// - `label` - Optional label for categorization (e.g., provider name)
    fn count_event(&self, event_name: &str, label: &str);

    /// Record a retry event (request failed and was retried).
    ///
    /// # Arguments
    /// - `provider` - Provider name
    /// - `reason` - Retry reason (e.g., "rate_limit", "timeout", "server_error")
    fn count_retry(&self, provider: &str, reason: &str);

    /// Record a circuit breaker opening (provider temporarily unavailable).
    ///
    /// # Arguments
    /// - `provider` - Provider name
    fn count_circuit_breaker_open(&self, provider: &str);

    /// Record a tool execution result.
    ///
    /// # Arguments
    /// - `tool_name` - Tool identifier
    /// - `success` - Whether tool execution succeeded
    fn count_tool_result(&self, tool_name: &str, success: bool);

    /// Record token usage for a request.
    ///
    /// # Arguments
    /// - `provider` - Provider name
    /// - `model` - Model identifier
    /// - `input_tokens` - Input tokens consumed
    /// - `output_tokens` - Output tokens generated
    /// - `reasoning_tokens` - Reasoning tokens (extended thinking, o1 models)
    fn record_token_usage(
        &self,
        provider: &str,
        model: &str,
        input_tokens: u64,
        output_tokens: u64,
        reasoning_tokens: u64,
    );

    /// Record request cost in USD.
    ///
    /// # Arguments
    /// - `provider` - Provider name
    /// - `model` - Model identifier
    /// - `cost_usd` - Total cost in USD (can be fractional, e.g., 0.00125)
    fn record_cost(&self, provider: &str, model: &str, cost_usd: f64);
}

/// No-op metrics collector (default implementation).
///
/// This implementation does nothing and has zero runtime cost. Use it when metrics
/// collection is disabled or during development.
///
/// # Example
///
/// ```rust
/// use fae::fae_llm::observability::metrics::{MetricsCollector, NoopMetrics};
///
/// let metrics = NoopMetrics;
/// metrics.record_request_latency_ms("openai", "gpt-4", 1000); // No-op
/// ```
#[derive(Debug, Clone, Copy, Default)]
pub struct NoopMetrics;

impl MetricsCollector for NoopMetrics {
    fn record_request_latency_ms(&self, _provider: &str, _model: &str, _latency_ms: u64) {
        // No-op
    }

    fn record_turn_latency_ms(&self, _turn_number: u32, _latency_ms: u64) {
        // No-op
    }

    fn record_tool_latency_ms(&self, _tool_name: &str, _latency_ms: u64) {
        // No-op
    }

    fn count_event(&self, _event_name: &str, _label: &str) {
        // No-op
    }

    fn count_retry(&self, _provider: &str, _reason: &str) {
        // No-op
    }

    fn count_circuit_breaker_open(&self, _provider: &str) {
        // No-op
    }

    fn count_tool_result(&self, _tool_name: &str, _success: bool) {
        // No-op
    }

    fn record_token_usage(
        &self,
        _provider: &str,
        _model: &str,
        _input_tokens: u64,
        _output_tokens: u64,
        _reasoning_tokens: u64,
    ) {
        // No-op
    }

    fn record_cost(&self, _provider: &str, _model: &str, _cost_usd: f64) {
        // No-op
    }
}

/// Helper to convert [`Duration`] to milliseconds as `u64`.
///
/// Useful when passing [`std::time::Instant::elapsed()`] to metrics methods.
///
/// # Example
///
/// ```rust
/// use std::time::{Duration, Instant};
/// use fae::fae_llm::observability::metrics::duration_to_ms;
///
/// let start = Instant::now();
/// // ... some work ...
/// let elapsed_ms = duration_to_ms(start.elapsed());
/// ```
pub fn duration_to_ms(duration: Duration) -> u64 {
    duration.as_millis().try_into().unwrap_or(u64::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn noop_metrics_compiles() {
        let metrics = NoopMetrics;
        metrics.record_request_latency_ms("test", "model", 100);
        metrics.count_event("test_event", "label");
    }

    #[test]
    fn noop_metrics_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<NoopMetrics>();
    }

    #[test]
    fn duration_to_ms_conversion() {
        let dur = Duration::from_millis(1234);
        assert_eq!(duration_to_ms(dur), 1234);

        let dur = Duration::from_secs(2);
        assert_eq!(duration_to_ms(dur), 2000);

        let dur = Duration::from_micros(500);
        assert_eq!(duration_to_ms(dur), 0);
    }

    #[test]
    fn trait_methods_are_non_blocking() {
        // This test verifies the trait signature allows &self (not &mut self)
        // which enables concurrent calls from multiple tasks
        let metrics: &dyn MetricsCollector = &NoopMetrics;
        metrics.record_request_latency_ms("test", "model", 100);
        metrics.count_event("event", "label");
        metrics.record_token_usage("test", "model", 100, 200, 50);
    }
}
