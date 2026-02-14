//! Bing search engine — decent fallback with Microsoft's index.
//!
//! Bing has unique URL encoding (sometimes base64-encoded redirect URLs)
//! that requires special handling during result parsing.

use crate::config::SearchConfig;
use crate::engine::SearchEngineTrait;
use crate::error::SearchError;
use crate::types::{SearchEngine, SearchResult};

/// Bing HTML search scraper.
///
/// Priority 4 engine — decent fallback with a different index
/// from Google. Requires URL parameter decoding for clean result URLs.
pub struct BingEngine;

impl SearchEngineTrait for BingEngine {
    async fn search(
        &self,
        _query: &str,
        _config: &SearchConfig,
    ) -> Result<Vec<SearchResult>, SearchError> {
        Err(SearchError::Parse("Bing engine not yet implemented".into()))
    }

    fn engine_type(&self) -> SearchEngine {
        SearchEngine::Bing
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_type_is_bing() {
        let engine = BingEngine;
        assert_eq!(engine.engine_type(), SearchEngine::Bing);
    }

    #[test]
    fn is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<BingEngine>();
    }

    #[tokio::test]
    async fn stub_returns_not_implemented() {
        let engine = BingEngine;
        let config = SearchConfig::default();
        let result = engine.search("test", &config).await;
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("not yet implemented"));
    }
}
