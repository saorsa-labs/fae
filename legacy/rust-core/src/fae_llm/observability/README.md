# Observability Module

Production observability for the fae_llm module: structured tracing, metrics collection, and secret redaction.

## Overview

This module provides three core capabilities:

1. **Structured Tracing** (`spans.rs`) - Hierarchical span constants for distributed tracing
2. **Metrics Collection** (`metrics.rs`) - Pluggable metrics interface for performance tracking
3. **Secret Redaction** (`redact.rs`) - Utilities to prevent API key leaks in logs

## Structured Tracing

### Enabling Tracing

```rust
use tracing_subscriber;

// Basic console output
tracing_subscriber::fmt::init();

// Or with environment-based filtering
tracing_subscriber::fmt()
    .with_env_filter("fae_llm=debug")
    .init();
```

### Span Hierarchy

Spans follow a hierarchical structure:

```
fae_llm.provider.request (provider, model, endpoint_type)
  └─> fae_llm.agent.turn (turn_number, max_turns)
       └─> fae_llm.tool.execute (tool_name, mode, duration_ms)

fae_llm.session.operation (session_id, operation) [parallel to requests]
```

### Using Span Constants

```rust
use fae::fae_llm::observability::spans::*;

let span = tracing::info_span!(
    SPAN_PROVIDER_REQUEST,
    { FIELD_PROVIDER } = "openai",
    { FIELD_MODEL } = "gpt-4",
    { FIELD_ENDPOINT_TYPE } = "completions",
);
let _enter = span.enter();

// Your code here - all logs will be associated with this span
```

### Helper Macros

For convenience, use the provided macros:

```rust
use fae::provider_request_span;

let span = provider_request_span!("openai", "gpt-4", "completions");
let _enter = span.enter();
```

Available macros:
- `provider_request_span!(provider, model, endpoint_type)`
- `agent_turn_span!(turn_number, max_turns)`
- `tool_execute_span!(tool_name, mode)`
- `session_operation_span!(session_id, operation)`

### Field Conventions

All span fields use snake_case constants defined in `spans.rs`:

| Constant | Value | Description |
|----------|-------|-------------|
| `FIELD_PROVIDER` | "provider" | Provider name (openai, anthropic, etc.) |
| `FIELD_MODEL` | "model" | Model identifier |
| `FIELD_ENDPOINT_TYPE` | "endpoint_type" | API endpoint (completions, messages, etc.) |
| `FIELD_TURN_NUMBER` | "turn_number" | Agent loop iteration (1-indexed) |
| `FIELD_MAX_TURNS` | "max_turns" | Maximum turns allowed |
| `FIELD_TOOL_NAME` | "tool_name" | Tool identifier (read, bash, write, etc.) |
| `FIELD_TOOL_MODE` | "mode" | Execution mode (read_only, full) |
| `FIELD_SESSION_ID` | "session_id" | Session identifier |
| `FIELD_OPERATION` | "operation" | Operation type (save, load, delete) |
| `FIELD_REQUEST_ID` | "request_id" | Unique request identifier |

## Metrics Collection

### Default (No-Op) Metrics

By default, `AgentLoop` uses `NoopMetrics` which has zero runtime cost:

```rust
use fae::fae_llm::agent::loop_engine::AgentLoop;
use fae::fae_llm::agent::types::AgentConfig;

let loop_engine = AgentLoop::new(config, provider, registry);
// Uses NoopMetrics internally - no overhead
```

### Custom Metrics Collector

Implement the `MetricsCollector` trait to send metrics to your backend:

```rust
use fae::fae_llm::observability::metrics::MetricsCollector;
use std::sync::Arc;

struct PrometheusMetrics {
    // Your Prometheus client here
}

impl MetricsCollector for PrometheusMetrics {
    fn record_request_latency_ms(&self, provider: &str, model: &str, latency_ms: u64) {
        // Send to Prometheus
    }

    fn record_turn_latency_ms(&self, turn_number: u32, latency_ms: u64) {
        // Send to Prometheus
    }

    fn record_tool_latency_ms(&self, tool_name: &str, latency_ms: u64) {
        // Send to Prometheus
    }

    fn count_event(&self, event_name: &str, label: &str) {
        // Increment counter
    }

    fn count_retry(&self, provider: &str, reason: &str) {
        // Increment retry counter
    }

    fn count_circuit_breaker_open(&self, provider: &str) {
        // Increment circuit breaker counter
    }

    fn count_tool_result(&self, tool_name: &str, success: bool) {
        // Record tool success/failure
    }

    fn record_token_usage(
        &self,
        provider: &str,
        model: &str,
        input_tokens: u64,
        output_tokens: u64,
        reasoning_tokens: u64,
    ) {
        // Record token usage
    }

    fn record_cost(&self, provider: &str, model: &str, cost_usd: f64) {
        // Record cost
    }
}

// Use custom metrics
let metrics = Arc::new(PrometheusMetrics::new());
let loop_engine = AgentLoop::with_metrics(config, provider, registry, metrics);
```

### Metrics Collected

| Metric | Method | Description |
|--------|--------|-------------|
| Request Latency | `record_request_latency_ms()` | Total agent loop duration |
| Turn Latency | `record_turn_latency_ms()` | Single iteration duration |
| Tool Latency | `record_tool_latency_ms()` | Individual tool execution time |
| Event Count | `count_event()` | Generic event counter |
| Retry Count | `count_retry()` | Request retry tracking |
| Circuit Breaker | `count_circuit_breaker_open()` | Circuit breaker trips |
| Tool Result | `count_tool_result()` | Tool success/failure count |
| Token Usage | `record_token_usage()` | Input/output/reasoning tokens |
| Cost | `record_cost()` | Request cost in USD |

## Secret Redaction

### RedactedString Wrapper

Wrap sensitive values to prevent leakage in logs:

```rust
use fae::fae_llm::observability::redact::RedactedString;

let api_key = RedactedString::new("sk-1234567890abcdefghijklmnopqrstuv");

println!("{}", api_key);        // Prints: [REDACTED]
println!("{:?}", api_key);      // Prints: RedactedString("[REDACTED]")

// Access when needed (not in logs!)
let key = api_key.as_str();
```

### Redaction Functions

```rust
use fae::fae_llm::observability::redact::*;

// Redact OpenAI/Anthropic API keys
let text = "Error with sk-1234567890abcdefghijklmnopqrstuv";
let safe = redact_api_key(text);
// "Error with sk-***REDACTED***"

// Redact Authorization headers
let log = "Request failed: Authorization: Bearer abc123";
let safe = redact_auth_header(log);
// "Request failed: Authorization: Bearer ***REDACTED***"

// Redact API keys in JSON
let json = r#"{"api_key": "secret123", "model": "gpt-4"}"#;
let safe = redact_api_key_in_json(json);
// {"api_key": "***REDACTED***", "model": "gpt-4"}

// Redact all known patterns (convenience)
let text = "sk-abc123 Authorization: Bearer token456";
let safe = redact_all(text);
// Both patterns redacted
```

### Redaction Patterns

The following patterns are automatically detected:

- `sk-*` (OpenAI keys)
- `anthropic-key-*` (Anthropic keys)
- `Authorization: Bearer *` (auth headers)
- `"api_key": "..."` in JSON payloads

### Best Practices

1. **Wrap secrets at creation**: Use `RedactedString` when storing API keys in structs
2. **Redact before logging**: Apply `redact_all()` to error messages before creating events
3. **Never log raw configs**: Implement custom Debug for config structs to redact secrets
4. **Test redaction**: Verify that formatted output never contains real secrets

## Integration Example

Complete example showing all three observability features:

```rust
use fae::fae_llm::agent::loop_engine::AgentLoop;
use fae::fae_llm::agent::types::AgentConfig;
use fae::fae_llm::observability::metrics::{MetricsCollector, NoopMetrics};
use fae::fae_llm::observability::redact::RedactedString;
use std::sync::Arc;
use tracing_subscriber;

// 1. Enable tracing
tracing_subscriber::fmt()
    .with_env_filter("fae_llm=debug")
    .init();

// 2. Create metrics collector (or use NoopMetrics)
let metrics: Arc<dyn MetricsCollector> = Arc::new(NoopMetrics);

// 3. Wrap sensitive config values
let api_key = RedactedString::new("sk-abc123");

// 4. Create agent loop with observability
let loop_engine = AgentLoop::with_metrics(
    config,
    provider,
    registry,
    metrics,
);

// 5. Run - all spans, metrics, and redaction happen automatically
let result = loop_engine.run("Hello").await?;
```

## Performance

- **Tracing**: Zero cost when disabled at compile time via `tracing` feature flags
- **Metrics**: `NoopMetrics` has zero runtime overhead (inlined no-ops)
- **Redaction**: Minimal overhead, only applied when creating log messages

## Testing

All observability features are tested:

- Span constants verified for uniqueness and structure
- Metrics trait has no-op default implementation
- Redaction patterns tested against real API key formats
- Integration tests verify span emission in real request flows

See `tests.rs` for examples of testing with observability.
