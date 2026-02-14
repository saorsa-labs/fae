//! Trait definition for pluggable search engine backends.
//!
//! Each search engine (DuckDuckGo, Brave, Google, Bing, Startpage)
//! implements [`SearchEngineTrait`] to provide a uniform interface for
//! querying and parsing results.

use crate::config::SearchConfig;
use crate::error::SearchError;
use crate::types::{SearchEngine, SearchResult};

/// A pluggable search engine backend.
///
/// Implementors scrape a specific search engine's HTML response and extract
/// structured [`SearchResult`] values. Each engine handles its own:
///
/// - URL construction with query encoding
/// - HTTP request with appropriate headers
/// - HTML parsing via CSS selectors
/// - Error handling for rate limiting, bot detection, or parse failures
///
/// All implementations must be `Send + Sync` for concurrent engine queries.
pub trait SearchEngineTrait: Send + Sync {
    /// Perform a web search and return parsed results.
    ///
    /// # Arguments
    ///
    /// * `query` — The search query string (already URL-safe is not required;
    ///   the implementation handles encoding).
    /// * `config` — Search configuration controlling timeouts, safe search, etc.
    ///
    /// # Errors
    ///
    /// Returns [`SearchError`] if the HTTP request fails, the response cannot
    /// be parsed, or the engine is rate-limiting/blocking requests.
    fn search(
        &self,
        query: &str,
        config: &SearchConfig,
    ) -> impl std::future::Future<Output = Result<Vec<SearchResult>, SearchError>> + Send;

    /// Returns which [`SearchEngine`] variant this implementation represents.
    fn engine_type(&self) -> SearchEngine;

    /// Returns the default weight for ranking results from this engine.
    ///
    /// Higher weight means results from this engine are scored higher
    /// in the aggregated ranking. Typically delegates to
    /// [`SearchEngine::weight()`].
    fn weight(&self) -> f64 {
        self.engine_type().weight()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A mock engine for testing trait bounds and async execution.
    struct MockEngine {
        engine: SearchEngine,
        results: Vec<SearchResult>,
    }

    impl MockEngine {
        fn new(engine: SearchEngine, results: Vec<SearchResult>) -> Self {
            Self { engine, results }
        }

        fn failing(engine: SearchEngine) -> Self {
            Self {
                engine,
                results: vec![],
            }
        }
    }

    impl SearchEngineTrait for MockEngine {
        async fn search(
            &self,
            _query: &str,
            _config: &SearchConfig,
        ) -> Result<Vec<SearchResult>, SearchError> {
            if self.results.is_empty() {
                return Err(SearchError::Parse("mock engine failure".into()));
            }
            Ok(self.results.clone())
        }

        fn engine_type(&self) -> SearchEngine {
            self.engine
        }
    }

    #[test]
    fn mock_engine_is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<MockEngine>();
    }

    #[tokio::test]
    async fn mock_engine_returns_results() {
        let result = SearchResult {
            title: "Test".into(),
            url: "https://test.com".into(),
            snippet: "A test result".into(),
            engine: "DuckDuckGo".into(),
            score: 1.0,
        };
        let engine = MockEngine::new(SearchEngine::DuckDuckGo, vec![result]);
        let config = SearchConfig::default();

        let results = engine.search("test", &config).await;
        assert!(results.is_ok());

        let results = results.expect("should succeed");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].title, "Test");
    }

    #[tokio::test]
    async fn mock_engine_propagates_errors() {
        let engine = MockEngine::failing(SearchEngine::Google);
        let config = SearchConfig::default();

        let result = engine.search("test", &config).await;
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("mock engine failure"));
    }

    #[test]
    fn engine_type_returns_correct_variant() {
        let engine = MockEngine::new(SearchEngine::Brave, vec![]);
        assert_eq!(engine.engine_type(), SearchEngine::Brave);
    }

    #[test]
    fn default_weight_delegates_to_search_engine() {
        let engine = MockEngine::new(SearchEngine::Google, vec![]);
        assert!((engine.weight() - 1.2).abs() < f64::EPSILON);
    }
}
