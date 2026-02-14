//! DuckDuckGo search engine — most scraper-friendly, privacy-aligned.
//!
//! Uses the HTML-only version at `https://html.duckduckgo.com/html/`
//! which requires no JavaScript and is tolerant of automated requests.

use crate::config::SearchConfig;
use crate::engine::SearchEngineTrait;
use crate::error::SearchError;
use crate::types::{SearchEngine, SearchResult};

/// DuckDuckGo HTML search engine scraper.
///
/// Priority 1 engine — most reliable for automated scraping and
/// aligned with Fae's privacy-first philosophy.
pub struct DuckDuckGoEngine;

impl SearchEngineTrait for DuckDuckGoEngine {
    async fn search(
        &self,
        _query: &str,
        _config: &SearchConfig,
    ) -> Result<Vec<SearchResult>, SearchError> {
        Err(SearchError::Parse(
            "DuckDuckGo engine not yet implemented".into(),
        ))
    }

    fn engine_type(&self) -> SearchEngine {
        SearchEngine::DuckDuckGo
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_type_is_duckduckgo() {
        let engine = DuckDuckGoEngine;
        assert_eq!(engine.engine_type(), SearchEngine::DuckDuckGo);
    }

    #[test]
    fn is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<DuckDuckGoEngine>();
    }

    #[tokio::test]
    async fn stub_returns_not_implemented() {
        let engine = DuckDuckGoEngine;
        let config = SearchConfig::default();
        let result = engine.search("test", &config).await;
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("not yet implemented"));
    }
}
