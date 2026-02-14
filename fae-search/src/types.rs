//! Core types for web search results and engine identification.

use serde::{Deserialize, Serialize};
use std::fmt;

/// A single search result returned from a web search engine.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResult {
    /// The title of the search result page.
    pub title: String,
    /// The URL of the search result.
    pub url: String,
    /// A text snippet summarising the page content.
    pub snippet: String,
    /// Which search engine returned this result.
    pub engine: String,
    /// Aggregated relevance score (higher is better). Ranges from 0.0 upward;
    /// results appearing in multiple engines receive a cross-engine boost.
    pub score: f64,
}

/// Supported search engines that fae-search can query.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum SearchEngine {
    /// DuckDuckGo — most scraper-friendly, privacy-aligned.
    DuckDuckGo,
    /// Brave Search — independent index, good quality.
    Brave,
    /// Google — best results but aggressive bot detection.
    Google,
    /// Bing — decent fallback engine.
    Bing,
    /// Startpage — proxied Google results, useful when Google blocks direct scraping.
    Startpage,
}

impl SearchEngine {
    /// Returns the human-readable name of this engine.
    pub fn name(&self) -> &'static str {
        match self {
            Self::DuckDuckGo => "DuckDuckGo",
            Self::Brave => "Brave",
            Self::Google => "Google",
            Self::Bing => "Bing",
            Self::Startpage => "Startpage",
        }
    }

    /// Returns the default weight for this engine in result ranking.
    /// Higher weight means results from this engine are scored higher.
    pub fn weight(&self) -> f64 {
        match self {
            Self::DuckDuckGo => 1.0,
            Self::Brave => 1.0,
            Self::Google => 1.2,
            Self::Bing => 0.8,
            Self::Startpage => 0.9,
        }
    }

    /// Returns all available engine variants.
    pub fn all() -> &'static [SearchEngine] {
        &[
            Self::DuckDuckGo,
            Self::Brave,
            Self::Google,
            Self::Bing,
            Self::Startpage,
        ]
    }
}

impl fmt::Display for SearchEngine {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

/// Extracted readable content from a fetched web page.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PageContent {
    /// The URL that was fetched.
    pub url: String,
    /// The page title extracted from HTML.
    pub title: String,
    /// Cleaned, readable text content with HTML boilerplate stripped.
    pub text: String,
    /// Number of words in the extracted text.
    pub word_count: usize,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_result_construction() {
        let result = SearchResult {
            title: "Example".into(),
            url: "https://example.com".into(),
            snippet: "An example page".into(),
            engine: "DuckDuckGo".into(),
            score: 1.5,
        };
        assert_eq!(result.title, "Example");
        assert_eq!(result.engine, "DuckDuckGo");
        assert!((result.score - 1.5).abs() < f64::EPSILON);
    }

    #[test]
    fn search_result_serde_round_trip() {
        let result = SearchResult {
            title: "Test".into(),
            url: "https://test.com".into(),
            snippet: "snippet".into(),
            engine: "Brave".into(),
            score: 0.9,
        };
        let json = serde_json::to_string(&result).expect("serialize");
        let decoded: SearchResult = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(decoded.title, "Test");
        assert_eq!(decoded.url, "https://test.com");
    }

    #[test]
    fn search_engine_display() {
        assert_eq!(SearchEngine::DuckDuckGo.to_string(), "DuckDuckGo");
        assert_eq!(SearchEngine::Brave.to_string(), "Brave");
        assert_eq!(SearchEngine::Google.to_string(), "Google");
        assert_eq!(SearchEngine::Bing.to_string(), "Bing");
        assert_eq!(SearchEngine::Startpage.to_string(), "Startpage");
    }

    #[test]
    fn search_engine_name() {
        assert_eq!(SearchEngine::DuckDuckGo.name(), "DuckDuckGo");
        assert_eq!(SearchEngine::Google.name(), "Google");
    }

    #[test]
    fn search_engine_weight() {
        assert!((SearchEngine::Google.weight() - 1.2).abs() < f64::EPSILON);
        assert!((SearchEngine::Bing.weight() - 0.8).abs() < f64::EPSILON);
        assert!((SearchEngine::DuckDuckGo.weight() - 1.0).abs() < f64::EPSILON);
    }

    #[test]
    fn search_engine_all() {
        let all = SearchEngine::all();
        assert_eq!(all.len(), 5);
        assert!(all.contains(&SearchEngine::DuckDuckGo));
        assert!(all.contains(&SearchEngine::Startpage));
    }

    #[test]
    fn search_engine_equality_and_hash() {
        use std::collections::HashSet;
        let mut set = HashSet::new();
        set.insert(SearchEngine::DuckDuckGo);
        set.insert(SearchEngine::DuckDuckGo);
        assert_eq!(set.len(), 1);
        set.insert(SearchEngine::Brave);
        assert_eq!(set.len(), 2);
    }

    #[test]
    fn search_engine_serde_round_trip() {
        let engine = SearchEngine::Brave;
        let json = serde_json::to_string(&engine).expect("serialize");
        let decoded: SearchEngine = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(decoded, SearchEngine::Brave);
    }

    #[test]
    fn page_content_construction() {
        let page = PageContent {
            url: "https://example.com".into(),
            title: "Example".into(),
            text: "Hello world".into(),
            word_count: 2,
        };
        assert_eq!(page.word_count, 2);
        assert_eq!(page.title, "Example");
    }

    #[test]
    fn page_content_serde_round_trip() {
        let page = PageContent {
            url: "https://example.com".into(),
            title: "Example".into(),
            text: "content".into(),
            word_count: 1,
        };
        let json = serde_json::to_string(&page).expect("serialize");
        let decoded: PageContent = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(decoded.url, "https://example.com");
    }
}
