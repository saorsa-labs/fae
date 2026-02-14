//! Brave Search engine — independent index, good quality results.
//!
//! Brave Search has its own web crawler and index, making it a
//! valuable source of diverse results independent from Google/Bing.
//! Uses a GET request to `https://search.brave.com/search`.

use crate::config::SearchConfig;
use crate::engine::SearchEngineTrait;
use crate::error::SearchError;
use crate::http;
use crate::types::{SearchEngine, SearchResult};
use scraper::{Html, Selector};

/// Brave Search HTML scraper.
///
/// Priority 2 engine — independent index with good quality results
/// and generally tolerant of automated requests.
pub struct BraveEngine;

impl SearchEngineTrait for BraveEngine {
    async fn search(
        &self,
        query: &str,
        config: &SearchConfig,
    ) -> Result<Vec<SearchResult>, SearchError> {
        tracing::trace!(query, "Brave search");

        let client = http::build_client(config)?;

        let safesearch_val = if config.safe_search { "strict" } else { "off" };

        let response = client
            .get("https://search.brave.com/search")
            .query(&[("q", query), ("safesearch", safesearch_val)])
            .header("Accept", "text/html,application/xhtml+xml")
            .header("Accept-Language", "en-US,en;q=0.9")
            .send()
            .await
            .map_err(|e| SearchError::Http(format!("Brave request failed: {e}")))?
            .error_for_status()
            .map_err(|e| SearchError::Http(format!("Brave HTTP error: {e}")))?;

        let html = response
            .text()
            .await
            .map_err(|e| SearchError::Http(format!("Brave response read failed: {e}")))?;

        tracing::trace!(bytes = html.len(), "Brave response received");

        parse_brave_html(&html, config.max_results)
    }

    fn engine_type(&self) -> SearchEngine {
        SearchEngine::Brave
    }
}

/// Parse Brave Search HTML response into search results.
///
/// Extracted as a separate function for testability with mock HTML.
pub(crate) fn parse_brave_html(
    html: &str,
    max_results: usize,
) -> Result<Vec<SearchResult>, SearchError> {
    let document = Html::parse_document(html);

    // Brave uses .snippet containers with data-pos attribute for organic results.
    // The :not(.standalone) filter excludes featured snippets / info boxes.
    let result_sel = Selector::parse(".snippet[data-pos]:not(.standalone)")
        .map_err(|e| SearchError::Parse(format!("invalid result selector: {e:?}")))?;
    let title_sel = Selector::parse(".snippet-title")
        .map_err(|e| SearchError::Parse(format!("invalid title selector: {e:?}")))?;
    let desc_sel = Selector::parse(".snippet-description")
        .map_err(|e| SearchError::Parse(format!("invalid description selector: {e:?}")))?;
    let link_sel = Selector::parse("a")
        .map_err(|e| SearchError::Parse(format!("invalid link selector: {e:?}")))?;

    let mut results = Vec::new();

    for element in document.select(&result_sel) {
        let title_el = match element.select(&title_sel).next() {
            Some(el) => el,
            None => continue,
        };

        let title = title_el.text().collect::<String>().trim().to_string();
        if title.is_empty() {
            continue;
        }

        // The URL is in the first <a> within the snippet-title, or on the title element itself.
        let url = title_el
            .select(&link_sel)
            .next()
            .and_then(|a| a.value().attr("href"))
            .or_else(|| title_el.value().attr("href"))
            .map(|h| h.to_string());

        let url = match url {
            Some(u) if !u.is_empty() => u,
            _ => continue,
        };

        let snippet = element
            .select(&desc_sel)
            .next()
            .map(|el| el.text().collect::<String>().trim().to_string())
            .unwrap_or_default();

        results.push(SearchResult {
            title,
            url,
            snippet,
            engine: SearchEngine::Brave.name().to_string(),
            score: 0.0,
        });

        if results.len() >= max_results {
            break;
        }
    }

    tracing::debug!(count = results.len(), "Brave results parsed");
    Ok(results)
}

#[cfg(test)]
mod tests {
    use super::*;

    const MOCK_BRAVE_HTML: &str = r#"<!DOCTYPE html>
<html>
<body>
<div class="snippet" data-pos="0">
    <div class="snippet-title">
        <a href="https://www.rust-lang.org/">
            Rust Programming Language
        </a>
    </div>
    <div class="snippet-description">
        A language empowering everyone to build reliable and efficient software.
    </div>
</div>
<div class="snippet" data-pos="1">
    <div class="snippet-title">
        <a href="https://doc.rust-lang.org/book/">
            The Rust Programming Language Book
        </a>
    </div>
    <div class="snippet-description">
        An introductory book about Rust. The Rust Programming Language.
    </div>
</div>
<div class="snippet standalone" data-pos="2">
    <div class="snippet-title">
        <a href="https://featured.example.com/">
            Featured Snippet (should be excluded)
        </a>
    </div>
    <div class="snippet-description">
        This is a standalone snippet and should not appear.
    </div>
</div>
<div class="snippet" data-pos="3">
    <div class="snippet-title">
        <a href="https://en.wikipedia.org/wiki/Rust_(programming_language)">
            Rust (programming language) - Wikipedia
        </a>
    </div>
    <div class="snippet-description">
        Rust is a multi-paradigm, general-purpose programming language.
    </div>
</div>
</body>
</html>"#;

    #[test]
    fn parse_mock_html_returns_results() {
        let results = parse_brave_html(MOCK_BRAVE_HTML, 10);
        assert!(results.is_ok());
        let results = results.expect("should parse");
        // Should get 3 results (standalone snippet excluded)
        assert_eq!(results.len(), 3);

        assert_eq!(results[0].title, "Rust Programming Language");
        assert_eq!(results[0].url, "https://www.rust-lang.org/");
        assert!(results[0].snippet.contains("reliable and efficient"));
        assert_eq!(results[0].engine, "Brave");

        assert_eq!(results[1].url, "https://doc.rust-lang.org/book/");

        assert!(results[2].url.contains("wikipedia.org"));
    }

    #[test]
    fn parse_excludes_standalone_snippets() {
        let results = parse_brave_html(MOCK_BRAVE_HTML, 10);
        let results = results.expect("should parse");
        for r in &results {
            assert!(
                !r.title.contains("Featured Snippet"),
                "standalone snippet should be excluded"
            );
        }
    }

    #[test]
    fn parse_respects_max_results() {
        let results = parse_brave_html(MOCK_BRAVE_HTML, 2);
        assert!(results.is_ok());
        assert_eq!(results.expect("should parse").len(), 2);
    }

    #[test]
    fn parse_empty_html_returns_empty() {
        let results = parse_brave_html("<html><body></body></html>", 10);
        assert!(results.is_ok());
        assert!(results.expect("should parse").is_empty());
    }

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

    // ── Fixture-based parser tests ──────────────────────────────────────

    const FIXTURE_BRAVE_HTML: &str = include_str!("../../test-data/brave.html");

    #[test]
    fn fixture_extracts_all_organic_results() {
        let results = parse_brave_html(FIXTURE_BRAVE_HTML, 50);
        let results = results.expect("fixture should parse");
        // Fixture has 11 organic + 2 standalone (excluded)
        assert!(
            results.len() >= 10,
            "expected 10+ results, got {}",
            results.len()
        );
    }

    #[test]
    fn fixture_results_have_non_empty_fields() {
        let results = parse_brave_html(FIXTURE_BRAVE_HTML, 50).expect("should parse");
        for (i, r) in results.iter().enumerate() {
            assert!(!r.title.is_empty(), "result {i} has empty title");
            assert!(!r.url.is_empty(), "result {i} has empty URL");
            assert!(!r.snippet.is_empty(), "result {i} has empty snippet");
            assert_eq!(r.engine, "Brave");
        }
    }

    #[test]
    fn fixture_excludes_standalone_snippets() {
        let results = parse_brave_html(FIXTURE_BRAVE_HTML, 50).expect("should parse");
        for r in &results {
            assert!(
                !r.title.contains("Featured Answer"),
                "standalone snippet included: {}",
                r.title
            );
            assert!(
                !r.title.contains("Rust Language Statistics"),
                "standalone infobox included: {}",
                r.title
            );
        }
    }

    #[test]
    fn fixture_respects_max_results() {
        let results = parse_brave_html(FIXTURE_BRAVE_HTML, 3).expect("should parse");
        assert_eq!(results.len(), 3);
    }

    #[test]
    fn fixture_first_result_is_rust_lang() {
        let results = parse_brave_html(FIXTURE_BRAVE_HTML, 50).expect("should parse");
        assert_eq!(results[0].url, "https://www.rust-lang.org/");
    }

    #[tokio::test]
    #[ignore] // Live test — run with `cargo test -- --ignored`
    async fn live_brave_search() {
        let engine = BraveEngine;
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
