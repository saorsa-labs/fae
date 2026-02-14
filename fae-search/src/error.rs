//! Error types for the fae-search crate.
//!
//! All errors use stable string messages suitable for display to users
//! and programmatic handling. No API keys or sensitive data appear in
//! error messages.

/// Errors that can occur during web search operations.
#[derive(Debug, thiserror::Error)]
pub enum SearchError {
    /// All enabled search engines failed to return results.
    #[error("all search engines failed: {0}")]
    AllEnginesFailed(String),

    /// A search operation timed out before any engine responded.
    #[error("search timed out: {0}")]
    Timeout(String),

    /// An HTTP request to a search engine failed.
    #[error("HTTP error: {0}")]
    Http(String),

    /// Failed to parse search engine response HTML.
    #[error("parse error: {0}")]
    Parse(String),

    /// Invalid search configuration.
    #[error("config error: {0}")]
    Config(String),
}

/// Convenience type alias for fae-search results.
pub type Result<T> = std::result::Result<T, SearchError>;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_all_engines_failed() {
        let err = SearchError::AllEnginesFailed("no engines configured".into());
        assert_eq!(
            err.to_string(),
            "all search engines failed: no engines configured"
        );
    }

    #[test]
    fn display_timeout() {
        let err = SearchError::Timeout("exceeded 8s limit".into());
        assert_eq!(err.to_string(), "search timed out: exceeded 8s limit");
    }

    #[test]
    fn display_http() {
        let err = SearchError::Http("connection refused".into());
        assert_eq!(err.to_string(), "HTTP error: connection refused");
    }

    #[test]
    fn display_parse() {
        let err = SearchError::Parse("unexpected HTML structure".into());
        assert_eq!(err.to_string(), "parse error: unexpected HTML structure");
    }

    #[test]
    fn display_config() {
        let err = SearchError::Config("max_results must be > 0".into());
        assert_eq!(err.to_string(), "config error: max_results must be > 0");
    }

    #[test]
    fn error_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<SearchError>();
    }
}
