//! Search configuration with sensible defaults.
//!
//! [`SearchConfig`] controls which engines are queried, timeouts, caching,
//! and request behaviour. The defaults are tuned for reliable, polite scraping.

use crate::error::SearchError;
use crate::types::SearchEngine;

/// Configuration for a web search operation.
///
/// Use [`Default::default()`] for sensible defaults, or construct with
/// field overrides for custom behaviour.
#[derive(Debug, Clone)]
pub struct SearchConfig {
    /// Which search engines to query. Queried concurrently; results are merged.
    pub engines: Vec<SearchEngine>,
    /// Maximum number of results to return after deduplication and ranking.
    pub max_results: usize,
    /// Per-engine HTTP request timeout in seconds.
    pub timeout_seconds: u64,
    /// Whether to request safe search filtering from engines that support it.
    pub safe_search: bool,
    /// How long to cache results in seconds. Set to 0 to disable caching.
    pub cache_ttl_seconds: u64,
    /// Random delay range in milliseconds `(min, max)` between engine requests.
    /// Prevents rate limiting by spreading requests over time.
    pub request_delay_ms: (u64, u64),
    /// Custom User-Agent string. If `None`, rotates through a built-in list
    /// of realistic browser User-Agents.
    pub user_agent: Option<String>,
}

impl Default for SearchConfig {
    fn default() -> Self {
        Self {
            engines: vec![
                SearchEngine::DuckDuckGo,
                SearchEngine::Brave,
                SearchEngine::Google,
                SearchEngine::Bing,
            ],
            max_results: 10,
            timeout_seconds: 8,
            safe_search: true,
            cache_ttl_seconds: 600,
            request_delay_ms: (100, 500),
            user_agent: None,
        }
    }
}

impl SearchConfig {
    /// Validates this configuration, returning an error if any field is invalid.
    ///
    /// Checks:
    /// - `max_results` must be greater than 0
    /// - `timeout_seconds` must be greater than 0
    /// - `engines` must not be empty
    /// - `request_delay_ms.0` must be <= `request_delay_ms.1`
    pub fn validate(&self) -> Result<(), SearchError> {
        if self.max_results == 0 {
            return Err(SearchError::Config(
                "max_results must be greater than 0".into(),
            ));
        }
        if self.timeout_seconds == 0 {
            return Err(SearchError::Config(
                "timeout_seconds must be greater than 0".into(),
            ));
        }
        if self.engines.is_empty() {
            return Err(SearchError::Config(
                "at least one engine must be enabled".into(),
            ));
        }
        if self.request_delay_ms.0 > self.request_delay_ms.1 {
            return Err(SearchError::Config(
                "request_delay_ms min must be <= max".into(),
            ));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config_has_sensible_values() {
        let config = SearchConfig::default();
        assert_eq!(config.max_results, 10);
        assert_eq!(config.timeout_seconds, 8);
        assert!(config.safe_search);
        assert_eq!(config.cache_ttl_seconds, 600);
        assert_eq!(config.request_delay_ms, (100, 500));
        assert!(config.user_agent.is_none());
    }

    #[test]
    fn default_engines_include_all_four() {
        let config = SearchConfig::default();
        assert_eq!(config.engines.len(), 4);
        assert!(config.engines.contains(&SearchEngine::DuckDuckGo));
        assert!(config.engines.contains(&SearchEngine::Brave));
        assert!(config.engines.contains(&SearchEngine::Google));
        assert!(config.engines.contains(&SearchEngine::Bing));
    }

    #[test]
    fn valid_config_passes_validation() {
        let config = SearchConfig::default();
        assert!(config.validate().is_ok());
    }

    #[test]
    fn zero_max_results_rejected() {
        let config = SearchConfig {
            max_results: 0,
            ..Default::default()
        };
        let err = config.validate().unwrap_err();
        assert!(err.to_string().contains("max_results"));
    }

    #[test]
    fn zero_timeout_rejected() {
        let config = SearchConfig {
            timeout_seconds: 0,
            ..Default::default()
        };
        let err = config.validate().unwrap_err();
        assert!(err.to_string().contains("timeout_seconds"));
    }

    #[test]
    fn empty_engines_rejected() {
        let config = SearchConfig {
            engines: vec![],
            ..Default::default()
        };
        let err = config.validate().unwrap_err();
        assert!(err.to_string().contains("engine"));
    }

    #[test]
    fn invalid_delay_range_rejected() {
        let config = SearchConfig {
            request_delay_ms: (500, 100),
            ..Default::default()
        };
        let err = config.validate().unwrap_err();
        assert!(err.to_string().contains("delay"));
    }

    #[test]
    fn custom_user_agent() {
        let config = SearchConfig {
            user_agent: Some("CustomBot/1.0".into()),
            ..Default::default()
        };
        assert_eq!(config.user_agent.as_deref(), Some("CustomBot/1.0"));
        assert!(config.validate().is_ok());
    }

    #[test]
    fn single_engine_valid() {
        let config = SearchConfig {
            engines: vec![SearchEngine::DuckDuckGo],
            ..Default::default()
        };
        assert!(config.validate().is_ok());
    }

    #[test]
    fn zero_delay_range_valid() {
        let config = SearchConfig {
            request_delay_ms: (0, 0),
            ..Default::default()
        };
        assert!(config.validate().is_ok());
    }
}
