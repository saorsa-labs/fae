//! # fae-search
//!
//! Zero-configuration, embedded web search for Fae.
//!
//! This crate provides web search capabilities by scraping public search engines
//! directly — no API keys, no external services, no user setup required. It compiles
//! into Fae's binary as a library dependency.
//!
//! ## Design
//!
//! - Scrapes DuckDuckGo, Brave, Google, and Bing using CSS selectors on HTML responses
//! - Queries multiple engines concurrently and merges/ranks results
//! - In-memory LRU cache with configurable TTL
//! - User-Agent rotation and request jitter for reliability
//! - Graceful degradation: if some engines fail, others still return results
//!
//! ## Security
//!
//! - No API keys or secrets to leak
//! - No network listeners — this is a library, not a server
//! - Search queries are logged only at trace level
//! - Result snippets are sanitised before returning

pub mod config;
pub mod engine;
pub mod engines;
pub mod error;
pub mod http;
pub mod orchestrator;
pub mod types;

pub use config::SearchConfig;
pub use engine::SearchEngineTrait;
pub use error::{Result, SearchError};
pub use types::{PageContent, SearchEngine, SearchResult};

/// Search the web using multiple engines concurrently.
///
/// Queries all engines specified in `config`, merges and ranks results
/// by weighted score, deduplicates by URL, and returns up to
/// `config.max_results` results.
///
/// # Errors
///
/// Returns [`SearchError::AllEnginesFailed`] if every enabled engine fails.
/// Individual engine failures are logged but do not cause the overall
/// search to fail as long as at least one engine returns results.
///
/// # Examples
///
/// ```no_run
/// # async fn example() -> fae_search::Result<()> {
/// let config = fae_search::SearchConfig::default();
/// let results = fae_search::search("rust programming", &config).await?;
/// for result in &results {
///     println!("{}: {}", result.title, result.url);
/// }
/// # Ok(())
/// # }
/// ```
pub async fn search(query: &str, config: &SearchConfig) -> Result<Vec<SearchResult>> {
    config.validate()?;
    orchestrator::search::orchestrate_search(query, config).await
}

/// Search the web with sensible default configuration.
///
/// Convenience wrapper around [`search`] using [`SearchConfig::default()`].
///
/// # Errors
///
/// Same as [`search`].
///
/// # Examples
///
/// ```no_run
/// # async fn example() -> fae_search::Result<()> {
/// let results = fae_search::search_default("weather today").await?;
/// for result in &results {
///     println!("{}: {}", result.title, result.url);
/// }
/// # Ok(())
/// # }
/// ```
pub async fn search_default(query: &str) -> Result<Vec<SearchResult>> {
    search(query, &SearchConfig::default()).await
}

/// Fetch and extract readable text content from a web page.
///
/// Downloads the page at `url`, parses the HTML, strips boilerplate
/// (navigation, ads, footers, scripts), and returns the main content
/// as clean text.
///
/// # Errors
///
/// Returns [`SearchError::Http`] if the page cannot be fetched, or
/// [`SearchError::Parse`] if the HTML cannot be meaningfully extracted.
///
/// # Examples
///
/// ```no_run
/// # async fn example() -> fae_search::Result<()> {
/// let page = fae_search::fetch_page_content("https://example.com").await?;
/// println!("Title: {}", page.title);
/// println!("Words: {}", page.word_count);
/// # Ok(())
/// # }
/// ```
pub async fn fetch_page_content(url: &str) -> Result<PageContent> {
    let _ = url;
    Err(SearchError::Http(
        "content extraction not yet implemented".into(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn search_validates_config_zero_max_results() {
        let config = SearchConfig {
            max_results: 0,
            ..Default::default()
        };
        let result = search("test", &config).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("max_results"));
    }

    #[tokio::test]
    async fn search_validates_config_empty_engines() {
        let config = SearchConfig {
            engines: vec![],
            ..Default::default()
        };
        let result = search("test", &config).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("engine"));
    }

    #[tokio::test]
    async fn search_validates_config_zero_timeout() {
        let config = SearchConfig {
            timeout_seconds: 0,
            ..Default::default()
        };
        let result = search("test", &config).await;
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("timeout"));
    }

    #[tokio::test]
    async fn fetch_page_content_returns_error_for_stub() {
        let result = fetch_page_content("https://example.com").await;
        assert!(result.is_err());
        let err = result.unwrap_err();
        assert!(err.to_string().contains("not yet implemented"));
    }
}
