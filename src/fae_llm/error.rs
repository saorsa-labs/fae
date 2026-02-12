//! Error types for the fae_llm module.
//!
//! Each error variant carries a stable error code (SCREAMING_SNAKE_CASE)
//! that is included in the Display output and accessible via [`FaeLlmError::code()`].
//! Codes are part of the public API contract and will not change.

/// Stable error codes for programmatic error handling.
///
/// These codes never change and form part of the public API contract.
/// Use these for distinguishing errors rather than parsing Display output.
pub mod error_codes {
    /// Invalid or missing configuration.
    pub const CONFIG_INVALID: &str = "CONFIG_INVALID";

    /// Authentication failed (invalid/missing API key).
    pub const AUTH_FAILED: &str = "AUTH_FAILED";

    /// Request to the LLM provider failed.
    pub const REQUEST_FAILED: &str = "REQUEST_FAILED";

    /// Streaming response encountered an error.
    pub const STREAM_FAILED: &str = "STREAM_FAILED";

    /// Tool execution failed.
    pub const TOOL_FAILED: &str = "TOOL_FAILED";

    /// Request or operation timed out.
    pub const TIMEOUT_ERROR: &str = "TIMEOUT_ERROR";

    /// Provider-specific error not covered by other variants.
    pub const PROVIDER_ERROR: &str = "PROVIDER_ERROR";

    /// Session persistence or resume error.
    pub const SESSION_ERROR: &str = "SESSION_ERROR";
}

/// Errors produced by the fae_llm module.
///
/// Each variant includes a stable error code accessible via [`FaeLlmError::code()`].
/// The Display impl formats as `[CODE] message`.
#[derive(Debug, thiserror::Error)]
pub enum FaeLlmError {
    /// Invalid or missing configuration.
    #[error("[{}] {}", error_codes::CONFIG_INVALID, .0)]
    ConfigError(String),

    /// Authentication failed (invalid/missing API key).
    #[error("[{}] {}", error_codes::AUTH_FAILED, .0)]
    AuthError(String),

    /// Request to the LLM provider failed.
    #[error("[{}] {}", error_codes::REQUEST_FAILED, .0)]
    RequestError(String),

    /// Streaming response encountered an error.
    #[error("[{}] {}", error_codes::STREAM_FAILED, .0)]
    StreamError(String),

    /// Tool execution failed.
    #[error("[{}] {}", error_codes::TOOL_FAILED, .0)]
    ToolError(String),

    /// Request or operation timed out.
    #[error("[{}] {}", error_codes::TIMEOUT_ERROR, .0)]
    TimeoutError(String),

    /// Provider-specific error not covered by other variants.
    #[error("[{}] {}", error_codes::PROVIDER_ERROR, .0)]
    ProviderError(String),

    /// Session persistence or resume error.
    #[error("[{}] {}", error_codes::SESSION_ERROR, .0)]
    SessionError(String),
}

impl FaeLlmError {
    /// Returns the stable error code for this error.
    ///
    /// Codes are SCREAMING_SNAKE_CASE strings that remain stable across releases.
    /// Use these for programmatic error handling rather than parsing Display output.
    pub fn code(&self) -> &'static str {
        match self {
            Self::ConfigError(_) => error_codes::CONFIG_INVALID,
            Self::AuthError(_) => error_codes::AUTH_FAILED,
            Self::RequestError(_) => error_codes::REQUEST_FAILED,
            Self::StreamError(_) => error_codes::STREAM_FAILED,
            Self::ToolError(_) => error_codes::TOOL_FAILED,
            Self::TimeoutError(_) => error_codes::TIMEOUT_ERROR,
            Self::ProviderError(_) => error_codes::PROVIDER_ERROR,
            Self::SessionError(_) => error_codes::SESSION_ERROR,
        }
    }

    /// Returns the inner message without the code prefix.
    pub fn message(&self) -> &str {
        match self {
            Self::ConfigError(m)
            | Self::AuthError(m)
            | Self::RequestError(m)
            | Self::StreamError(m)
            | Self::ToolError(m)
            | Self::TimeoutError(m)
            | Self::ProviderError(m)
            | Self::SessionError(m) => m,
        }
    }

    /// Returns true if this error represents a transient failure that can be retried.
    ///
    /// Retryable errors include:
    /// - Network errors (connection refused, timeouts, etc.)
    /// - Rate limits (429)
    /// - Server errors (5xx)
    /// - Stream interruptions
    ///
    /// Non-retryable errors include:
    /// - Authentication failures (401, 403)
    /// - Bad requests (400)
    /// - Configuration errors
    /// - Tool execution failures
    pub fn is_retryable(&self) -> bool {
        match self {
            // Configuration and auth errors are not retryable
            Self::ConfigError(_) | Self::AuthError(_) => false,
            // Tool failures are not retryable (need code fix, not retry)
            Self::ToolError(_) => false,
            // Request, stream, and timeout errors are typically transient
            Self::RequestError(_) | Self::StreamError(_) | Self::TimeoutError(_) => true,
            // Provider errors may be rate limits (429) or server errors (5xx) - retryable
            Self::ProviderError(_) => true,
            // Session errors are not retryable
            Self::SessionError(_) => false,
        }
    }
}

/// Convenience alias for fae_llm results.
pub type Result<T> = std::result::Result<T, FaeLlmError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_error_code() {
        let err = FaeLlmError::ConfigError("missing api_url".into());
        assert_eq!(err.code(), "CONFIG_INVALID");
    }

    #[test]
    fn auth_error_code() {
        let err = FaeLlmError::AuthError("invalid key".into());
        assert_eq!(err.code(), "AUTH_FAILED");
    }

    #[test]
    fn request_error_code() {
        let err = FaeLlmError::RequestError("connection refused".into());
        assert_eq!(err.code(), "REQUEST_FAILED");
    }

    #[test]
    fn stream_error_code() {
        let err = FaeLlmError::StreamError("unexpected EOF".into());
        assert_eq!(err.code(), "STREAM_FAILED");
    }

    #[test]
    fn tool_error_code() {
        let err = FaeLlmError::ToolError("bash timed out".into());
        assert_eq!(err.code(), "TOOL_FAILED");
    }

    #[test]
    fn timeout_error_code() {
        let err = FaeLlmError::TimeoutError("30s elapsed".into());
        assert_eq!(err.code(), "TIMEOUT_ERROR");
    }

    #[test]
    fn provider_error_code() {
        let err = FaeLlmError::ProviderError("rate limited".into());
        assert_eq!(err.code(), "PROVIDER_ERROR");
    }

    #[test]
    fn display_includes_code_prefix() {
        let err = FaeLlmError::ConfigError("missing model".into());
        let display = format!("{err}");
        assert!(display.starts_with("[CONFIG_INVALID]"));
        assert!(display.contains("missing model"));
    }

    #[test]
    fn display_auth_includes_prefix() {
        let err = FaeLlmError::AuthError("expired token".into());
        let display = format!("{err}");
        assert!(display.starts_with("[AUTH_FAILED]"));
        assert!(display.contains("expired token"));
    }

    #[test]
    fn message_returns_inner_text() {
        let err = FaeLlmError::RequestError("bad gateway".into());
        assert_eq!(err.message(), "bad gateway");
    }

    #[test]
    fn all_codes_are_screaming_snake_case() {
        let errors: Vec<FaeLlmError> = vec![
            FaeLlmError::ConfigError("x".into()),
            FaeLlmError::AuthError("x".into()),
            FaeLlmError::RequestError("x".into()),
            FaeLlmError::StreamError("x".into()),
            FaeLlmError::ToolError("x".into()),
            FaeLlmError::TimeoutError("x".into()),
            FaeLlmError::ProviderError("x".into()),
            FaeLlmError::SessionError("x".into()),
        ];
        for err in &errors {
            let code = err.code();
            assert!(
                code.chars().all(|c| c.is_ascii_uppercase() || c == '_'),
                "code {code:?} is not SCREAMING_SNAKE_CASE"
            );
        }
    }

    #[test]
    fn session_error_code() {
        let err = FaeLlmError::SessionError("session not found".into());
        assert_eq!(err.code(), "SESSION_ERROR");
    }

    #[test]
    fn session_error_display() {
        let err = FaeLlmError::SessionError("corrupted data".into());
        let display = format!("{err}");
        assert!(display.starts_with("[SESSION_ERROR]"));
        assert!(display.contains("corrupted data"));
    }

    #[test]
    fn session_error_message() {
        let err = FaeLlmError::SessionError("resume failed".into());
        assert_eq!(err.message(), "resume failed");
    }

    #[test]
    fn error_codes_use_constants() {
        // Verify error codes are centrally defined and not duplicated
        assert_eq!(error_codes::CONFIG_INVALID, "CONFIG_INVALID");
        assert_eq!(error_codes::AUTH_FAILED, "AUTH_FAILED");
        assert_eq!(error_codes::REQUEST_FAILED, "REQUEST_FAILED");
        assert_eq!(error_codes::STREAM_FAILED, "STREAM_FAILED");
        assert_eq!(error_codes::TOOL_FAILED, "TOOL_FAILED");
        assert_eq!(error_codes::TIMEOUT_ERROR, "TIMEOUT_ERROR");
        assert_eq!(error_codes::PROVIDER_ERROR, "PROVIDER_ERROR");
        assert_eq!(error_codes::SESSION_ERROR, "SESSION_ERROR");
    }

    #[test]
    fn error_is_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<FaeLlmError>();
    }

    #[test]
    fn is_retryable_config_error() {
        let err = FaeLlmError::ConfigError("missing model".into());
        assert!(!err.is_retryable());
    }

    #[test]
    fn is_retryable_auth_error() {
        let err = FaeLlmError::AuthError("invalid key".into());
        assert!(!err.is_retryable());
    }

    #[test]
    fn is_retryable_request_error() {
        let err = FaeLlmError::RequestError("connection refused".into());
        assert!(err.is_retryable());
    }

    #[test]
    fn is_retryable_stream_error() {
        let err = FaeLlmError::StreamError("unexpected EOF".into());
        assert!(err.is_retryable());
    }

    #[test]
    fn is_retryable_tool_error() {
        let err = FaeLlmError::ToolError("bash failed".into());
        assert!(!err.is_retryable());
    }

    #[test]
    fn is_retryable_timeout_error() {
        let err = FaeLlmError::TimeoutError("30s elapsed".into());
        assert!(err.is_retryable());
    }

    #[test]
    fn is_retryable_provider_error() {
        let err = FaeLlmError::ProviderError("rate limited".into());
        assert!(err.is_retryable());
    }

    #[test]
    fn is_retryable_session_error() {
        let err = FaeLlmError::SessionError("resume failed".into());
        assert!(!err.is_retryable());
    }
}
