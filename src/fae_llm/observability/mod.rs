/// Observability infrastructure for fae_llm.
///
/// This module provides structured tracing, metrics collection, and secret redaction
/// for production observability.
///
/// # Tracing
///
/// Structured spans are emitted at key points in the request lifecycle:
/// - Provider requests (OpenAI, Anthropic, local endpoints)
/// - Agent loop turns
/// - Tool executions
/// - Session persistence operations
///
/// Use the span constants and helper macros from [`spans`] for consistent naming.
///
/// # Example
///
/// ```rust,ignore
/// use fae_llm::provider_request_span;
///
/// let span = provider_request_span!("openai", "gpt-4", "completions");
/// let _enter = span.enter();
/// // ... provider request logic ...
/// ```
///
/// # Metrics
///
/// Implement the [`MetricsCollector`](metrics::MetricsCollector) trait to collect performance and usage metrics.
/// A no-op default implementation is provided.
///
/// # Secret Redaction
///
/// Use [`RedactedString`](redact::RedactedString) to prevent accidental leakage of API keys, tokens, and other
/// sensitive data in logs and error messages.
pub mod metrics;
pub mod redact;
pub mod spans;

// Re-export span helpers for convenience
pub use spans::{
    FIELD_ENDPOINT_TYPE, FIELD_ERROR_TYPE, FIELD_MAX_TURNS, FIELD_MODEL, FIELD_OPERATION,
    FIELD_PROVIDER, FIELD_REQUEST_ID, FIELD_SESSION_ID, FIELD_TOOL_MODE, FIELD_TOOL_NAME,
    FIELD_TURN_NUMBER, SPAN_AGENT_TURN, SPAN_PROVIDER_REQUEST, SPAN_SESSION_OPERATION,
    SPAN_TOOL_EXECUTE,
};

// Re-export metrics types for convenience
pub use metrics::{MetricsCollector, NoopMetrics, duration_to_ms};

// Re-export redaction utilities for convenience
pub use redact::{
    RedactedString, redact_all, redact_api_key, redact_api_key_in_json, redact_auth_header,
};
