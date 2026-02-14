//! Shared HTTP client with User-Agent rotation for search engine requests.
//!
//! Provides a configured [`reqwest::Client`] with browser-like headers,
//! cookie support, and rotating User-Agent strings to avoid bot detection.

use crate::config::SearchConfig;
use crate::error::SearchError;
use rand::seq::SliceRandom;
use std::time::Duration;

/// Realistic browser User-Agent strings, rotated per request.
const USER_AGENTS: &[&str] = &[
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:133.0) Gecko/20100101 Firefox/133.0",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:133.0) Gecko/20100101 Firefox/133.0",
];

/// Build a [`reqwest::Client`] configured for search engine scraping.
///
/// The client has:
/// - Cookie store enabled (for Google consent pages, etc.)
/// - Timeout from config
/// - Random User-Agent from built-in rotation list (or custom if configured)
/// - Brotli and gzip decompression
///
/// # Errors
///
/// Returns [`SearchError::Http`] if the client cannot be constructed.
pub fn build_client(config: &SearchConfig) -> Result<reqwest::Client, SearchError> {
    let ua = match config.user_agent {
        Some(ref custom) => custom.clone(),
        None => random_user_agent().to_owned(),
    };

    reqwest::Client::builder()
        .cookie_store(true)
        .timeout(Duration::from_secs(config.timeout_seconds))
        .user_agent(ua)
        .redirect(reqwest::redirect::Policy::limited(10))
        .build()
        .map_err(|e| SearchError::Http(format!("failed to build HTTP client: {e}")))
}

/// Select a random User-Agent string from the rotation list.
pub fn random_user_agent() -> &'static str {
    let mut rng = rand::thread_rng();
    USER_AGENTS
        .choose(&mut rng)
        .copied()
        // SAFETY: USER_AGENTS is a non-empty const array, choose only returns None on empty slices
        .unwrap_or(USER_AGENTS[0])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn random_user_agent_returns_valid_ua() {
        let ua = random_user_agent();
        assert!(USER_AGENTS.contains(&ua));
        assert!(ua.contains("Mozilla/5.0"));
    }

    #[test]
    fn build_client_with_default_config() {
        let config = SearchConfig::default();
        let client = build_client(&config);
        assert!(client.is_ok());
    }

    #[test]
    fn build_client_with_custom_ua() {
        let config = SearchConfig {
            user_agent: Some("CustomBot/1.0".into()),
            ..Default::default()
        };
        let client = build_client(&config);
        assert!(client.is_ok());
    }

    #[test]
    fn user_agents_list_not_empty() {
        assert!(!USER_AGENTS.is_empty());
        assert_eq!(USER_AGENTS.len(), 5);
    }
}
