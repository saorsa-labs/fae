//! Error types for the fae_llm module.
//!
//! Each error variant carries a stable error code (SCREAMING_SNAKE_CASE)
//! that is included in the Display output and accessible via [`FaeLlmError::code()`].
//! Codes are part of the public API contract and will not change.

/// Errors produced by the fae_llm module.
///
/// Each variant includes a stable error code accessible via [`FaeLlmError::code()`].
/// The Display impl formats as `[CODE] message`.
#[derive(Debug, thiserror::Error)]
pub enum FaeLlmError {
    /// Invalid or missing configuration.
    #[error("[CONFIG_INVALID] {0}")]
    ConfigError(String),

    /// Authentication failed (invalid/missing API key).
    #[error("[AUTH_FAILED] {0}")]
    AuthError(String),

    /// Request to the LLM provider failed.
    #[error("[REQUEST_FAILED] {0}")]
    RequestError(String),

    /// Streaming response encountered an error.
    #[error("[STREAM_FAILED] {0}")]
    StreamError(String),

    /// Tool execution failed.
    #[error("[TOOL_FAILED] {0}")]
    ToolError(String),

    /// Request or operation timed out.
    #[error("[TIMEOUT] {0}")]
    Timeout(String),

    /// Provider-specific error not covered by other variants.
    #[error("[PROVIDER_ERROR] {0}")]
    ProviderError(String),
}

impl FaeLlmError {
    /// Returns the stable error code for this error.
    ///
    /// Codes are SCREAMING_SNAKE_CASE strings that remain stable across releases.
    /// Use these for programmatic error handling rather than parsing Display output.
    pub fn code(&self) -> &'static str {
        match self {
            Self::ConfigError(_) => "CONFIG_INVALID",
            Self::AuthError(_) => "AUTH_FAILED",
            Self::RequestError(_) => "REQUEST_FAILED",
            Self::StreamError(_) => "STREAM_FAILED",
            Self::ToolError(_) => "TOOL_FAILED",
            Self::Timeout(_) => "TIMEOUT",
            Self::ProviderError(_) => "PROVIDER_ERROR",
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
            | Self::Timeout(m)
            | Self::ProviderError(m) => m,
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
        let err = FaeLlmError::Timeout("30s elapsed".into());
        assert_eq!(err.code(), "TIMEOUT");
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
            FaeLlmError::Timeout("x".into()),
            FaeLlmError::ProviderError("x".into()),
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
    fn error_is_send_and_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<FaeLlmError>();
    }
}
