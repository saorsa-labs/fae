//! Google search engine — best results but aggressive bot detection.
//!
//! Google has the highest quality results but employs aggressive
//! bot detection including CAPTCHAs, cookie consent walls, and
//! IP-based rate limiting.

use crate::config::SearchConfig;
use crate::engine::SearchEngineTrait;
use crate::error::SearchError;
use crate::http;
use crate::types::{SearchEngine, SearchResult};
use scraper::{Html, Selector};
use url::Url;

/// Google HTML search scraper.
///
/// Priority 3 engine — best result quality but most likely to
/// block automated requests. Requires cookie jar support and
/// careful User-Agent rotation.
pub struct GoogleEngine;

impl GoogleEngine {
    /// Extract the actual URL from Google's redirect wrapper.
    ///
    /// Google sometimes wraps URLs like: `/url?q=https%3A%2F%2Fexample.com&sa=U&...`
    /// We parse out the `q` query parameter and URL-decode it.
    fn extract_url(href: &str) -> Option<String> {
        // If it's a Google redirect URL
        if href.starts_with("/url?") {
            let full_url = format!("https://www.google.com{}", href);
            let parsed = Url::parse(&full_url).ok()?;
            parsed
                .query_pairs()
                .find(|(key, _)| key == "q")
                .map(|(_, value)| value.into_owned())
        } else {
            Some(href.to_string())
        }
    }
}

impl SearchEngineTrait for GoogleEngine {
    async fn search(
        &self,
        query: &str,
        config: &SearchConfig,
    ) -> Result<Vec<SearchResult>, SearchError> {
        tracing::trace!(query, "Google search");

        let client = http::build_client(config)?;

        let mut params = vec![("q", query), ("hl", "en")];
        if config.safe_search {
            params.push(("safe", "active"));
        }

        let response = client
            .get("https://www.google.com/search")
            .query(&params)
            .header("Accept", "text/html,application/xhtml+xml")
            .header("Accept-Language", "en-US,en;q=0.9")
            .send()
            .await
            .map_err(|e| SearchError::Http(format!("Google request failed: {e}")))?
            .error_for_status()
            .map_err(|e| SearchError::Http(format!("Google HTTP error: {e}")))?;

        let html = response
            .text()
            .await
            .map_err(|e| SearchError::Http(format!("Google response read failed: {e}")))?;

        tracing::trace!(bytes = html.len(), "Google response received");

        parse_google_html(&html, config.max_results)
    }

    fn engine_type(&self) -> SearchEngine {
        SearchEngine::Google
    }
}

/// Parse Google HTML response into search results.
///
/// Extracted as a separate function for testability with mock HTML.
fn parse_google_html(html: &str, max_results: usize) -> Result<Vec<SearchResult>, SearchError> {
    let document = Html::parse_document(html);

    // Google organic results are in div.g containers
    let result_sel = Selector::parse("div.g")
        .map_err(|e| SearchError::Parse(format!("invalid result selector: {e:?}")))?;
    let title_sel = Selector::parse("h3")
        .map_err(|e| SearchError::Parse(format!("invalid title selector: {e:?}")))?;
    let link_sel = Selector::parse("a")
        .map_err(|e| SearchError::Parse(format!("invalid link selector: {e:?}")))?;
    let snippet_sel = Selector::parse(".VwiC3b, div[data-sncf], .lEBKkf span")
        .map_err(|e| SearchError::Parse(format!("invalid snippet selector: {e:?}")))?;

    let mut results = Vec::new();

    for element in document.select(&result_sel) {
        // Find title
        let title_el = match element.select(&title_sel).next() {
            Some(el) => el,
            None => continue,
        };

        let title = title_el.text().collect::<String>().trim().to_string();
        if title.is_empty() {
            continue;
        }

        // Find URL - it's in an <a> element within the container
        let link_el = match element.select(&link_sel).next() {
            Some(el) => el,
            None => continue,
        };

        let href = match link_el.value().attr("href") {
            Some(h) => h,
            None => continue,
        };

        let url = match GoogleEngine::extract_url(href) {
            Some(u) if !u.is_empty() => u,
            _ => continue,
        };

        // Find snippet
        let snippet = element
            .select(&snippet_sel)
            .next()
            .map(|el| el.text().collect::<String>().trim().to_string())
            .unwrap_or_default();

        results.push(SearchResult {
            title,
            url,
            snippet,
            engine: SearchEngine::Google.name().to_string(),
            score: 0.0,
        });

        if results.len() >= max_results {
            break;
        }
    }

    tracing::debug!(count = results.len(), "Google results parsed");
    Ok(results)
}

#[cfg(test)]
mod tests {
    use super::*;

    const MOCK_GOOGLE_HTML: &str = r#"<!DOCTYPE html>
<html>
<body>
<div class="g">
  <div class="yuRUbf">
    <div><a href="https://www.rust-lang.org/"><h3>Rust Programming Language</h3></a></div>
  </div>
  <div class="VwiC3b">A language empowering everyone to build reliable and efficient software.</div>
</div>
<div class="g">
  <div class="yuRUbf">
    <div><a href="/url?q=https://doc.rust-lang.org/book/&amp;sa=U"><h3>The Rust Programming Language Book</h3></a></div>
  </div>
  <div class="VwiC3b">An introductory book about Rust.</div>
</div>
<div class="g">
  <div class="yuRUbf">
    <div><a href="https://en.wikipedia.org/wiki/Rust_(programming_language)"><h3>Rust (programming language) - Wikipedia</h3></a></div>
  </div>
  <div class="VwiC3b">Rust is a multi-paradigm programming language.</div>
</div>
</body>
</html>"#;

    #[test]
    fn extract_url_from_google_redirect() {
        let href = "/url?q=https://example.com/page&sa=U&ved=123";
        let result = GoogleEngine::extract_url(href);
        assert_eq!(result, Some("https://example.com/page".to_string()));
    }

    #[test]
    fn extract_url_direct_link() {
        let href = "https://example.com/direct";
        let result = GoogleEngine::extract_url(href);
        assert_eq!(result, Some("https://example.com/direct".to_string()));
    }

    #[test]
    fn parse_mock_html_returns_results() {
        let results = parse_google_html(MOCK_GOOGLE_HTML, 10);
        assert!(results.is_ok());
        let results = results.expect("should parse");
        assert_eq!(results.len(), 3);

        assert_eq!(results[0].title, "Rust Programming Language");
        assert_eq!(results[0].url, "https://www.rust-lang.org/");
        assert!(results[0]
            .snippet
            .contains("reliable and efficient software"));
        assert_eq!(results[0].engine, "Google");

        assert_eq!(results[1].url, "https://doc.rust-lang.org/book/");

        assert!(results[2].url.contains("wikipedia.org"));
    }

    #[test]
    fn parse_respects_max_results() {
        let results = parse_google_html(MOCK_GOOGLE_HTML, 2);
        assert!(results.is_ok());
        assert_eq!(results.expect("should parse").len(), 2);
    }

    #[test]
    fn parse_empty_html_returns_empty() {
        let results = parse_google_html("<html><body></body></html>", 10);
        assert!(results.is_ok());
        assert!(results.expect("should parse").is_empty());
    }

    #[test]
    fn parse_handles_google_redirect_urls() {
        let html = r#"
            <div class="g">
                <a href="/url?q=https://redirected.example.com/&sa=U"><h3>Redirected Link</h3></a>
                <div class="VwiC3b">Snippet text</div>
            </div>
        "#;
        let results = parse_google_html(html, 10);
        assert!(results.is_ok());
        let results = results.expect("should parse");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].url, "https://redirected.example.com/");
    }

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
    #[ignore] // Live test — run with `cargo test -- --ignored`
    async fn live_google_search() {
        let engine = GoogleEngine;
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
