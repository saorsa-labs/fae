//! Brave Search engine — independent index, good quality results.
//!
//! Brave Search has its own web crawler and index, making it a
//! valuable source of diverse results independent from Google/Bing.

use crate::config::SearchConfig;
use crate::engine::SearchEngineTrait;
use crate::error::SearchError;
use crate::types::{SearchEngine, SearchResult};

/// Brave Search HTML scraper.
///
/// Priority 2 engine — independent index with good quality results
/// and generally tolerant of automated requests.
pub struct BraveEngine;

impl SearchEngineTrait for BraveEngine {
    async fn search(
        &self,
        _query: &str,
        _config: &SearchConfig,
    ) -> Result<Vec<SearchResult>, SearchError> {
        Err(SearchError::Parse(
            "Brave engine not yet implemented".into(),
        ))
    }

    fn engine_type(&self) -> SearchEngine {
        SearchEngine::Brave
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn engine_type_is_brave() {
        let engine = BraveEngine;
        assert_eq!(engine.engine_type(), SearchEngine::Brave);
    }

    #[test]
    fn is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<BraveEngine>();
    }

    #[tokio::test]
    async fn stub_returns_not_implemented() {
        let engine = BraveEngine;
        let config = SearchConfig::default();
        let result = engine.search("test", &config).await;
        assert!(result.is_err());
        assert!(result
            .unwrap_err()
            .to_string()
            .contains("not yet implemented"));
    }
}
