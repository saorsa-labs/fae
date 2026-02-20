//! Error types for the fae_llm module.
//!
//! Errors expose stable machine-readable codes via [`FaeLlmError::code`].
//! The module includes legacy variants for backward compatibility and
//! locked taxonomy variants for v1 contract completeness.

/// Stable error codes for programmatic handling.
pub mod error_codes {
    /// Legacy: invalid or missing configuration.
    pub const CONFIG_INVALID: &str = "CONFIG_INVALID";
    /// Locked taxonomy: config parse/shape errors.
    pub const CONFIG_ERROR: &str = "CONFIG_ERROR";
    /// Locked taxonomy: config semantic validation failures.
    pub const CONFIG_VALIDATION_ERROR: &str = "CONFIG_VALIDATION_ERROR";
    /// Locked taxonomy: secret lookup/resolve failures.
    pub const SECRET_RESOLUTION_ERROR: &str = "SECRET_RESOLUTION_ERROR";
    /// Locked taxonomy: invalid provider config.
    pub const PROVIDER_CONFIG_ERROR: &str = "PROVIDER_CONFIG_ERROR";

    /// Legacy/auth taxonomy.
    pub const AUTH_FAILED: &str = "AUTH_FAILED";
    /// Legacy/request taxonomy.
    pub const REQUEST_FAILED: &str = "REQUEST_FAILED";

    /// Legacy: streaming failed.
    pub const STREAM_FAILED: &str = "STREAM_FAILED";
    /// Locked taxonomy: streaming parse/normalize failure.
    pub const STREAMING_PARSE_ERROR: &str = "STREAMING_PARSE_ERROR";

    /// Legacy: generic tool failure.
    pub const TOOL_FAILED: &str = "TOOL_FAILED";
    /// Locked taxonomy: tool argument/schema validation failed.
    pub const TOOL_VALIDATION_ERROR: &str = "TOOL_VALIDATION_ERROR";
    /// Locked taxonomy: tool runtime execution failed.
    pub const TOOL_EXECUTION_ERROR: &str = "TOOL_EXECUTION_ERROR";

    /// Timeout error.
    pub const TIMEOUT_ERROR: &str = "TIMEOUT_ERROR";
    /// Provider API error.
    pub const PROVIDER_ERROR: &str = "PROVIDER_ERROR";
    /// Session persistence/resume error.
    pub const SESSION_ERROR: &str = "SESSION_ERROR";

    /// Locked taxonomy: continuation state error.
    pub const CONTINUATION_ERROR: &str = "CONTINUATION_ERROR";
}

/// A surfaced error payload for API/UI boundaries.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct SurfacedError {
    /// Stable machine code.
    pub code: String,
    /// Human-readable message.
    pub message: String,
    /// Whether retry is recommended.
    pub retryable: bool,
    /// Provider ID when available.
    pub provider_id: Option<String>,
    /// Model ID when available.
    pub model_id: Option<String>,
}

/// Errors produced by the fae_llm module.
#[derive(Debug, thiserror::Error)]
pub enum FaeLlmError {
    /// Legacy configuration error.
    #[error("[{}] {}", error_codes::CONFIG_INVALID, .0)]
    ConfigError(String),

    /// Locked taxonomy: configuration validation error.
    #[error("[{}] {}", error_codes::CONFIG_VALIDATION_ERROR, .0)]
    ConfigValidationError(String),

    /// Locked taxonomy: secret resolution error.
    #[error("[{}] {}", error_codes::SECRET_RESOLUTION_ERROR, .0)]
    SecretResolutionError(String),

    /// Locked taxonomy: provider configuration error.
    #[error("[{}] {}", error_codes::PROVIDER_CONFIG_ERROR, .0)]
    ProviderConfigError(String),

    /// Authentication failure.
    #[error("[{}] {}", error_codes::AUTH_FAILED, .0)]
    AuthError(String),

    /// Request initiation or transport failure.
    #[error("[{}] {}", error_codes::REQUEST_FAILED, .0)]
    RequestError(String),

    /// Legacy stream failure.
    #[error("[{}] {}", error_codes::STREAM_FAILED, .0)]
    StreamError(String),

    /// Locked taxonomy: stream parsing error.
    #[error("[{}] {}", error_codes::STREAMING_PARSE_ERROR, .0)]
    StreamingParseError(String),

    /// Legacy tool failure.
    #[error("[{}] {}", error_codes::TOOL_FAILED, .0)]
    ToolError(String),

    /// Locked taxonomy: tool argument validation error.
    #[error("[{}] {}", error_codes::TOOL_VALIDATION_ERROR, .0)]
    ToolValidationError(String),

    /// Locked taxonomy: tool execution error.
    #[error("[{}] {}", error_codes::TOOL_EXECUTION_ERROR, .0)]
    ToolExecutionError(String),

    /// Timeout error.
    #[error("[{}] {}", error_codes::TIMEOUT_ERROR, .0)]
    TimeoutError(String),

    /// Provider-specific response error.
    #[error("[{}] {}", error_codes::PROVIDER_ERROR, .0)]
    ProviderError(String),

    /// Session store/resume error.
    #[error("[{}] {}", error_codes::SESSION_ERROR, .0)]
    SessionError(String),

    /// Locked taxonomy: continuation state error.
    #[error("[{}] {}", error_codes::CONTINUATION_ERROR, .0)]
    ContinuationError(String),
}

impl FaeLlmError {
    /// Returns the stable code for this error.
    pub fn code(&self) -> &'static str {
        match self {
            Self::ConfigError(_) => error_codes::CONFIG_INVALID,
            Self::ConfigValidationError(_) => error_codes::CONFIG_VALIDATION_ERROR,
            Self::SecretResolutionError(_) => error_codes::SECRET_RESOLUTION_ERROR,
            Self::ProviderConfigError(_) => error_codes::PROVIDER_CONFIG_ERROR,
            Self::AuthError(_) => error_codes::AUTH_FAILED,
            Self::RequestError(_) => error_codes::REQUEST_FAILED,
            Self::StreamError(_) => error_codes::STREAM_FAILED,
            Self::StreamingParseError(_) => error_codes::STREAMING_PARSE_ERROR,
            Self::ToolError(_) => error_codes::TOOL_FAILED,
            Self::ToolValidationError(_) => error_codes::TOOL_VALIDATION_ERROR,
            Self::ToolExecutionError(_) => error_codes::TOOL_EXECUTION_ERROR,
            Self::TimeoutError(_) => error_codes::TIMEOUT_ERROR,
            Self::ProviderError(_) => error_codes::PROVIDER_ERROR,
            Self::SessionError(_) => error_codes::SESSION_ERROR,
            Self::ContinuationError(_) => error_codes::CONTINUATION_ERROR,
        }
    }

    /// Returns the inner human-readable message.
    pub fn message(&self) -> &str {
        match self {
            Self::ConfigError(m)
            | Self::ConfigValidationError(m)
            | Self::SecretResolutionError(m)
            | Self::ProviderConfigError(m)
            | Self::AuthError(m)
            | Self::RequestError(m)
            | Self::StreamError(m)
            | Self::StreamingParseError(m)
            | Self::ToolError(m)
            | Self::ToolValidationError(m)
            | Self::ToolExecutionError(m)
            | Self::TimeoutError(m)
            | Self::ProviderError(m)
            | Self::SessionError(m)
            | Self::ContinuationError(m) => m,
        }
    }

    /// Indicates whether this error class is typically retryable.
    pub fn is_retryable(&self) -> bool {
        match self {
            Self::AuthError(_)
            | Self::ConfigError(_)
            | Self::ConfigValidationError(_)
            | Self::SecretResolutionError(_)
            | Self::ProviderConfigError(_)
            | Self::ToolError(_)
            | Self::ToolValidationError(_)
            | Self::ToolExecutionError(_)
            | Self::SessionError(_)
            | Self::ContinuationError(_) => false,
            Self::RequestError(_)
            | Self::StreamError(_)
            | Self::StreamingParseError(_)
            | Self::TimeoutError(_)
            | Self::ProviderError(_) => true,
        }
    }

    /// Build an API/UI-safe surfaced error with optional provider/model metadata.
    pub fn surfaced(&self, provider_id: Option<&str>, model_id: Option<&str>) -> SurfacedError {
        SurfacedError {
            code: self.code().to_string(),
            message: self.message().to_string(),
            retryable: self.is_retryable(),
            provider_id: provider_id.map(ToString::to_string),
            model_id: model_id.map(ToString::to_string),
        }
    }
}

/// Convenience alias for fae_llm results.
pub type Result<T> = std::result::Result<T, FaeLlmError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn legacy_error_codes_are_stable() {
        assert_eq!(
            FaeLlmError::ConfigError("x".into()).code(),
            "CONFIG_INVALID"
        );
        assert_eq!(FaeLlmError::AuthError("x".into()).code(), "AUTH_FAILED");
        assert_eq!(
            FaeLlmError::RequestError("x".into()).code(),
            "REQUEST_FAILED"
        );
        assert_eq!(FaeLlmError::StreamError("x".into()).code(), "STREAM_FAILED");
        assert_eq!(FaeLlmError::ToolError("x".into()).code(), "TOOL_FAILED");
        assert_eq!(
            FaeLlmError::TimeoutError("x".into()).code(),
            "TIMEOUT_ERROR"
        );
        assert_eq!(
            FaeLlmError::ProviderError("x".into()).code(),
            "PROVIDER_ERROR"
        );
        assert_eq!(
            FaeLlmError::SessionError("x".into()).code(),
            "SESSION_ERROR"
        );
    }

    #[test]
    fn locked_taxonomy_error_codes_are_available() {
        assert_eq!(
            FaeLlmError::ConfigValidationError("x".into()).code(),
            "CONFIG_VALIDATION_ERROR"
        );
        assert_eq!(
            FaeLlmError::SecretResolutionError("x".into()).code(),
            "SECRET_RESOLUTION_ERROR"
        );
        assert_eq!(
            FaeLlmError::ProviderConfigError("x".into()).code(),
            "PROVIDER_CONFIG_ERROR"
        );
        assert_eq!(
            FaeLlmError::StreamingParseError("x".into()).code(),
            "STREAMING_PARSE_ERROR"
        );
        assert_eq!(
            FaeLlmError::ToolValidationError("x".into()).code(),
            "TOOL_VALIDATION_ERROR"
        );
        assert_eq!(
            FaeLlmError::ToolExecutionError("x".into()).code(),
            "TOOL_EXECUTION_ERROR"
        );
        assert_eq!(
            FaeLlmError::ContinuationError("x".into()).code(),
            "CONTINUATION_ERROR"
        );
    }

    #[test]
    fn surfaced_error_includes_metadata() {
        let err = FaeLlmError::RequestError("temporary outage".into());
        let surfaced = err.surfaced(Some("local"), Some("llama3:8b"));

        assert_eq!(surfaced.code, "REQUEST_FAILED");
        assert_eq!(surfaced.message, "temporary outage");
        assert!(surfaced.retryable);
        assert_eq!(surfaced.provider_id.as_deref(), Some("local"));
        assert_eq!(surfaced.model_id.as_deref(), Some("llama3:8b"));
    }

    #[test]
    fn retryability_defaults_are_reasonable() {
        assert!(!FaeLlmError::AuthError("x".into()).is_retryable());
        assert!(!FaeLlmError::ToolExecutionError("x".into()).is_retryable());
        assert!(FaeLlmError::RequestError("x".into()).is_retryable());
    }
}
