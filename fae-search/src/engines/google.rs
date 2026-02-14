//! Google search engine — best results but aggressive bot detection.
//!
//! Google has the highest quality results but employs aggressive
//! bot detection including CAPTCHAs, cookie consent walls, and
//! IP-based rate limiting.

use crate::config::SearchConfig;
use crate::engine::SearchEngineTrait;
use crate::error::SearchError;
use crate::types::{SearchEngine, SearchResult};

/// Google HTML search scraper.
///
/// Priority 3 engine — best result quality but most likely to
/// block automated requests. Requires cookie jar support and
/// careful User-Agent rotation.
pub struct GoogleEngine;

impl SearchEngineTrait for GoogleEngine {
    async fn search(
        &self,
        _query: &str,
        _config: &SearchConfig,
    ) -> Result<Vec<SearchResult>, SearchError> {
        Err(SearchError::Parse(
            "Google engine not yet implemented".into(),
        ))
    }

    fn engine_type(&self) -> SearchEngine {
        SearchEngine::Google
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_type_is_google() {
        let engine = GoogleEngine;
        assert_eq!(engine.engine_type(), SearchEngine::Google);
    }

    #[test]
    fn is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<GoogleEngine>();
    }

    #[tokio::test]
    async fn stub_returns_not_implemented() {
        let engine = GoogleEngine;
        let config = SearchConfig::default();
        let result = engine.search("test", &config).await;
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("not yet implemented"));
    }
}
