//! Error types for the Python skill runtime.

/// Errors that can occur during Python skill operations.
#[derive(Debug, thiserror::Error)]
pub enum PythonSkillError {
    /// Failed to spawn the Python subprocess.
    #[error("failed to spawn skill process: {0}")]
    SpawnFailed(#[source] std::io::Error),

    /// Operation timed out.
    #[error("skill operation timed out after {timeout_secs}s")]
    Timeout {
        /// The timeout duration in seconds.
        timeout_secs: u64,
    },

    /// JSON-RPC protocol violation.
    #[error("protocol error: {message}")]
    ProtocolError {
        /// Description of the protocol violation.
        message: String,
    },

    /// Skill handshake failed.
    #[error("handshake failed: {reason}")]
    HandshakeFailed {
        /// Why the handshake failed.
        reason: String,
    },

    /// Skill process exited unexpectedly.
    #[error("skill process exited unexpectedly (exit code: {exit_code:?})")]
    ProcessExited {
        /// The exit code, if available.
        exit_code: Option<i32>,
    },

    /// Output exceeded maximum allowed size.
    #[error("skill output exceeded {max_bytes} bytes")]
    OutputTruncated {
        /// The maximum allowed output size.
        max_bytes: usize,
    },

    /// Named skill was not found.
    #[error("skill not found: {name}")]
    SkillNotFound {
        /// The skill name that was looked up.
        name: String,
    },

    /// Exceeded maximum restart attempts.
    #[error("skill exceeded maximum restarts ({count})")]
    MaxRestartsExceeded {
        /// How many restarts were attempted.
        count: u32,
    },

    /// JSON serialization/deserialization error.
    #[error("JSON error: {0}")]
    Json(#[source] serde_json::Error),
}

impl From<serde_json::Error> for PythonSkillError {
    fn from(err: serde_json::Error) -> Self {
        Self::Json(err)
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    #[test]
    fn display_spawn_failed() {
        let io_err = std::io::Error::new(std::io::ErrorKind::NotFound, "uv not found");
        let err = PythonSkillError::SpawnFailed(io_err);
        assert!(err.to_string().contains("failed to spawn skill process"));
        assert!(err.to_string().contains("uv not found"));
    }

    #[test]
    fn display_timeout() {
        let err = PythonSkillError::Timeout { timeout_secs: 30 };
        assert_eq!(err.to_string(), "skill operation timed out after 30s");
    }

    #[test]
    fn display_protocol_error() {
        let err = PythonSkillError::ProtocolError {
            message: "missing jsonrpc field".to_owned(),
        };
        assert!(err.to_string().contains("missing jsonrpc field"));
    }

    #[test]
    fn display_handshake_failed() {
        let err = PythonSkillError::HandshakeFailed {
            reason: "version mismatch".to_owned(),
        };
        assert!(err.to_string().contains("version mismatch"));
    }

    #[test]
    fn display_process_exited_with_code() {
        let err = PythonSkillError::ProcessExited { exit_code: Some(1) };
        assert!(err.to_string().contains("exit code: Some(1)"));
    }

    #[test]
    fn display_process_exited_no_code() {
        let err = PythonSkillError::ProcessExited { exit_code: None };
        assert!(err.to_string().contains("exit code: None"));
    }

    #[test]
    fn display_output_truncated() {
        let err = PythonSkillError::OutputTruncated { max_bytes: 102_400 };
        assert!(err.to_string().contains("102400 bytes"));
    }

    #[test]
    fn display_skill_not_found() {
        let err = PythonSkillError::SkillNotFound {
            name: "discord-bot".to_owned(),
        };
        assert!(err.to_string().contains("discord-bot"));
    }

    #[test]
    fn display_max_restarts_exceeded() {
        let err = PythonSkillError::MaxRestartsExceeded { count: 5 };
        assert!(err.to_string().contains("5"));
    }

    #[test]
    fn json_error_conversion() {
        let json_err = serde_json::from_str::<serde_json::Value>("invalid").unwrap_err();
        let err = PythonSkillError::from(json_err);
        assert!(err.to_string().contains("JSON error"));
    }

    #[test]
    fn error_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<PythonSkillError>();
    }
}
