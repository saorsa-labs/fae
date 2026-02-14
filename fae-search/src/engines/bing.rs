//! Bing search engine — decent fallback with Microsoft's index.
//!
//! Bing has unique URL encoding (sometimes base64-encoded redirect URLs)
//! that requires special handling during result parsing.

use crate::config::SearchConfig;
use crate::engine::SearchEngineTrait;
use crate::error::SearchError;
use crate::http;
use crate::types::{SearchEngine, SearchResult};
use scraper::{Html, Selector};

/// Bing HTML search scraper.
///
/// Priority 4 engine — decent fallback with a different index
/// from Google. Requires URL parameter decoding for clean result URLs.
pub struct BingEngine;

impl SearchEngineTrait for BingEngine {
    async fn search(
        &self,
        query: &str,
        config: &SearchConfig,
    ) -> Result<Vec<SearchResult>, SearchError> {
        tracing::trace!(query, "Bing search");

        let client = http::build_client(config)?;

        let safesearch_val = if config.safe_search { "Strict" } else { "Off" };

        let response = client
            .get("https://www.bing.com/search")
            .query(&[
                ("q", query),
                ("setlang", "en"),
                ("safeSearch", safesearch_val),
            ])
            .header("Accept", "text/html,application/xhtml+xml")
            .header("Accept-Language", "en-US,en;q=0.9")
            .send()
            .await
            .map_err(|e| SearchError::Http(format!("Bing request failed: {e}")))?
            .error_for_status()
            .map_err(|e| SearchError::Http(format!("Bing HTTP error: {e}")))?;

        let html = response
            .text()
            .await
            .map_err(|e| SearchError::Http(format!("Bing response read failed: {e}")))?;

        tracing::trace!(bytes = html.len(), "Bing response received");

        parse_bing_html(&html, config.max_results)
    }

    fn engine_type(&self) -> SearchEngine {
        SearchEngine::Bing
    }
}

/// Parse Bing HTML response into search results.
///
/// Extracted as a separate function for testability with mock HTML.
fn parse_bing_html(html: &str, max_results: usize) -> Result<Vec<SearchResult>, SearchError> {
    let document = Html::parse_document(html);

    // Bing uses li.b_algo containers for organic search results
    let result_sel = Selector::parse("li.b_algo")
        .map_err(|e| SearchError::Parse(format!("invalid result selector: {e:?}")))?;
    let title_sel = Selector::parse("h2")
        .map_err(|e| SearchError::Parse(format!("invalid title selector: {e:?}")))?;
    let link_sel = Selector::parse("a")
        .map_err(|e| SearchError::Parse(format!("invalid link selector: {e:?}")))?;
    let snippet_sel = Selector::parse(".b_caption p, .b_lineclamp2")
        .map_err(|e| SearchError::Parse(format!("invalid snippet selector: {e:?}")))?;

    let mut results = Vec::new();

    for element in document.select(&result_sel) {
        // Find title in h2 element
        let title_el = match element.select(&title_sel).next() {
            Some(el) => el,
            None => continue,
        };

        let title = title_el.text().collect::<String>().trim().to_string();
        if title.is_empty() {
            continue;
        }

        // Extract URL from h2 > a[href]
        let url = title_el
            .select(&link_sel)
            .next()
            .and_then(|a| a.value().attr("href"))
            .map(|h| h.to_string());

        let url = match url {
            Some(u) if !u.is_empty() => u,
            _ => continue,
        };

        // Extract snippet from .b_caption p or .b_lineclamp2
        let snippet = element
            .select(&snippet_sel)
            .next()
            .map(|el| el.text().collect::<String>().trim().to_string())
            .unwrap_or_default();

        results.push(SearchResult {
            title,
            url,
            snippet,
            engine: SearchEngine::Bing.name().to_string(),
            score: 0.0,
        });

        if results.len() >= max_results {
            break;
        }
    }

    tracing::debug!(count = results.len(), "Bing results parsed");
    Ok(results)
}

#[cfg(test)]
mod tests {
    use super::*;

    const MOCK_BING_HTML: &str = r#"<!DOCTYPE html>
<html>
<body>
<ol id="b_results">
<li class="b_algo">
  <h2><a href="https://www.rust-lang.org/" h="ID=SERP">Rust Programming Language</a></h2>
  <div class="b_caption"><p>A language empowering everyone to build reliable and efficient software.</p></div>
</li>
<li class="b_algo">
  <h2><a href="https://doc.rust-lang.org/book/" h="ID=SERP">The Rust Programming Language Book</a></h2>
  <div class="b_caption"><p>An introductory book about Rust.</p></div>
</li>
<li class="b_algo">
  <h2><a href="https://en.wikipedia.org/wiki/Rust_(programming_language)" h="ID=SERP">Rust (programming language) - Wikipedia</a></h2>
  <div class="b_caption"><p>Rust is a multi-paradigm programming language.</p></div>
</li>
</ol>
</body>
</html>"#;

    #[test]
    fn parse_mock_html_returns_results() {
        let results = parse_bing_html(MOCK_BING_HTML, 10);
        assert!(results.is_ok());
        let results = results.expect("should parse");
        assert_eq!(results.len(), 3);

        assert_eq!(results[0].title, "Rust Programming Language");
        assert_eq!(results[0].url, "https://www.rust-lang.org/");
        assert!(results[0]
            .snippet
            .contains("reliable and efficient software"));
        assert_eq!(results[0].engine, "Bing");

        assert_eq!(results[1].url, "https://doc.rust-lang.org/book/");

        assert!(results[2].url.contains("wikipedia.org"));
    }

    #[test]
    fn parse_respects_max_results() {
        let results = parse_bing_html(MOCK_BING_HTML, 2);
        assert!(results.is_ok());
        assert_eq!(results.expect("should parse").len(), 2);
    }

    #[test]
    fn parse_empty_html_returns_empty() {
        let results = parse_bing_html("<html><body></body></html>", 10);
        assert!(results.is_ok());
        assert!(results.expect("should parse").is_empty());
    }

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
    #[ignore] // Live test — run with `cargo test -- --ignored`
    async fn live_bing_search() {
        let engine = BingEngine;
        let config = SearchConfig::default();
        let results = engine.search("rust programming", &config).await;
        assert!(results.is_ok());
        let results = results.expect("live search should work");
        assert!(!results.is_empty());
        for r in &results {
            assert!(!r.title.is_empty());
            assert!(!r.url.is_empty());
        }
    }
}
