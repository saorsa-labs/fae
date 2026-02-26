/// Structured tracing spans for observability.
///
/// This module defines standardized span names and field keys for consistent
/// tracing across the fae_llm module. Spans follow the hierarchy:
///
/// ```text
/// fae_llm.provider.request
///   └─> fae_llm.agent.turn
///        └─> fae_llm.tool.execute
/// fae_llm.session.operation (parallel to request spans)
/// ```
///
/// # Example
///
/// ```rust,ignore
/// use tracing::info_span;
/// use fae_llm::observability::spans::*;
///
/// let span = info_span!(
///     SPAN_PROVIDER_REQUEST,
///     { FIELD_PROVIDER } = "openai",
///     { FIELD_MODEL } = "gpt-4",
///     { FIELD_ENDPOINT_TYPE } = "completions"
/// );
/// let _enter = span.enter();
/// // ... provider request logic ...
/// ```
// Span names (hierarchical, dot-separated)
/// Root span for provider requests (OpenAI, Anthropic, etc.)
pub const SPAN_PROVIDER_REQUEST: &str = "fae_llm.provider.request";

/// Span for a single agent turn (child of provider request)
pub const SPAN_AGENT_TURN: &str = "fae_llm.agent.turn";

/// Span for tool execution (child of agent turn)
pub const SPAN_TOOL_EXECUTE: &str = "fae_llm.tool.execute";

/// Span for session persistence operations
pub const SPAN_SESSION_OPERATION: &str = "fae_llm.session.operation";

// Field keys for span attributes
/// Provider name field (e.g., "openai", "anthropic", "local")
pub const FIELD_PROVIDER: &str = "provider";

/// Model identifier field (e.g., "gpt-4", "claude-3-5-sonnet-20241022")
pub const FIELD_MODEL: &str = "model";

/// Endpoint type field (e.g., "completions", "messages", "responses")
pub const FIELD_ENDPOINT_TYPE: &str = "endpoint_type";

/// Turn number within agent loop (1-indexed)
pub const FIELD_TURN_NUMBER: &str = "turn_number";

/// Maximum allowed turns in agent loop
pub const FIELD_MAX_TURNS: &str = "max_turns";

/// Tool name field (e.g., "read", "bash", "edit", "write")
pub const FIELD_TOOL_NAME: &str = "tool_name";

/// Tool execution mode field ("read_only" or "full")
pub const FIELD_TOOL_MODE: &str = "mode";

/// Session identifier field
pub const FIELD_SESSION_ID: &str = "session_id";

/// Session operation type field (e.g., "save", "load", "delete")
pub const FIELD_OPERATION: &str = "operation";

/// Request identifier field (UUID or similar)
pub const FIELD_REQUEST_ID: &str = "request_id";

/// Error type field (for error spans)
pub const FIELD_ERROR_TYPE: &str = "error_type";

/// Helper macro for creating provider request spans.
///
/// # Example
///
/// ```rust,ignore
/// use fae_llm::provider_request_span;
///
/// let span = provider_request_span!("openai", "gpt-4", "completions");
/// let _enter = span.enter();
/// ```
#[macro_export]
macro_rules! provider_request_span {
    ($provider:expr, $model:expr, $endpoint_type:expr) => {
        tracing::info_span!(
            $crate::observability::spans::SPAN_PROVIDER_REQUEST,
            { $crate::observability::spans::FIELD_PROVIDER } = $provider,
            { $crate::observability::spans::FIELD_MODEL } = $model,
            { $crate::observability::spans::FIELD_ENDPOINT_TYPE } = $endpoint_type,
        )
    };
    ($provider:expr, $model:expr, $endpoint_type:expr, $request_id:expr) => {
        tracing::info_span!(
            $crate::observability::spans::SPAN_PROVIDER_REQUEST,
            { $crate::observability::spans::FIELD_PROVIDER } = $provider,
            { $crate::observability::spans::FIELD_MODEL } = $model,
            { $crate::observability::spans::FIELD_ENDPOINT_TYPE } = $endpoint_type,
            { $crate::observability::spans::FIELD_REQUEST_ID } = $request_id,
        )
    };
}

/// Helper macro for creating agent turn spans.
///
/// # Example
///
/// ```rust,ignore
/// use fae_llm::agent_turn_span;
///
/// let span = agent_turn_span!(1, 10);
/// let _enter = span.enter();
/// ```
#[macro_export]
macro_rules! agent_turn_span {
    ($turn_number:expr, $max_turns:expr) => {
        tracing::info_span!(
            $crate::observability::spans::SPAN_AGENT_TURN,
            { $crate::observability::spans::FIELD_TURN_NUMBER } = $turn_number,
            { $crate::observability::spans::FIELD_MAX_TURNS } = $max_turns,
        )
    };
}

/// Helper macro for creating tool execution spans.
///
/// # Example
///
/// ```rust,ignore
/// use fae_llm::tool_execute_span;
///
/// let span = tool_execute_span!("read", "read_only");
/// let _enter = span.enter();
/// ```
#[macro_export]
macro_rules! tool_execute_span {
    ($tool_name:expr, $mode:expr) => {
        tracing::info_span!(
            $crate::observability::spans::SPAN_TOOL_EXECUTE,
            { $crate::observability::spans::FIELD_TOOL_NAME } = $tool_name,
            { $crate::observability::spans::FIELD_TOOL_MODE } = $mode,
        )
    };
}

/// Helper macro for creating session operation spans.
///
/// # Example
///
/// ```rust,ignore
/// use fae_llm::session_operation_span;
///
/// let span = session_operation_span!("session_123", "save");
/// let _enter = span.enter();
/// ```
#[macro_export]
macro_rules! session_operation_span {
    ($session_id:expr, $operation:expr) => {
        tracing::info_span!(
            $crate::observability::spans::SPAN_SESSION_OPERATION,
            { $crate::observability::spans::FIELD_SESSION_ID } = $session_id,
            { $crate::observability::spans::FIELD_OPERATION } = $operation,
        )
    };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn span_constants_are_hierarchical() {
        assert!(SPAN_PROVIDER_REQUEST.starts_with("fae_llm."));
        assert!(SPAN_AGENT_TURN.starts_with("fae_llm."));
        assert!(SPAN_TOOL_EXECUTE.starts_with("fae_llm."));
        assert!(SPAN_SESSION_OPERATION.starts_with("fae_llm."));
    }

    #[test]
    fn field_constants_are_snake_case() {
        assert_eq!(FIELD_PROVIDER, "provider");
        assert_eq!(FIELD_MODEL, "model");
        assert_eq!(FIELD_ENDPOINT_TYPE, "endpoint_type");
        assert_eq!(FIELD_TURN_NUMBER, "turn_number");
        assert_eq!(FIELD_MAX_TURNS, "max_turns");
        assert_eq!(FIELD_TOOL_NAME, "tool_name");
        assert_eq!(FIELD_TOOL_MODE, "mode");
        assert_eq!(FIELD_SESSION_ID, "session_id");
        assert_eq!(FIELD_OPERATION, "operation");
    }

    #[test]
    fn span_names_are_unique() {
        let spans = [
            SPAN_PROVIDER_REQUEST,
            SPAN_AGENT_TURN,
            SPAN_TOOL_EXECUTE,
            SPAN_SESSION_OPERATION,
        ];
        let unique: std::collections::HashSet<_> = spans.iter().collect();
        assert_eq!(spans.len(), unique.len(), "Span names must be unique");
    }
}
