//! DuckDuckGo search engine — most scraper-friendly, privacy-aligned.
//!
//! Uses the HTML-only version at `https://html.duckduckgo.com/html/`
//! which requires no JavaScript and is tolerant of automated requests.

use crate::config::SearchConfig;
use crate::engine::SearchEngineTrait;
use crate::error::SearchError;
use crate::http;
use crate::types::{SearchEngine, SearchResult};
use scraper::{Html, Selector};
use url::Url;

/// DuckDuckGo HTML search engine scraper.
///
/// Priority 1 engine — most reliable for automated scraping and
/// aligned with Fae's privacy-first philosophy. Uses a POST request
/// to the HTML-only endpoint which requires no JavaScript.
pub struct DuckDuckGoEngine;

impl DuckDuckGoEngine {
    /// Extract the actual URL from DuckDuckGo's redirect wrapper.
    ///
    /// DDG wraps URLs like: `//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com&rut=...`
    /// We parse out the `uddg` query parameter and URL-decode it.
    fn extract_url(href: &str) -> Option<String> {
        // Handle protocol-relative URLs
        let full_href = if href.starts_with("//") {
            format!("https:{href}")
        } else {
            href.to_string()
        };

        let parsed = Url::parse(&full_href).ok()?;

        // Check if this is a DDG redirect
        if parsed.host_str() == Some("duckduckgo.com") && parsed.path().starts_with("/l/") {
            parsed
                .query_pairs()
                .find(|(key, _)| key == "uddg")
                .map(|(_, value)| value.into_owned())
        } else {
            Some(full_href)
        }
    }
}

impl SearchEngineTrait for DuckDuckGoEngine {
    async fn search(
        &self,
        query: &str,
        config: &SearchConfig,
    ) -> Result<Vec<SearchResult>, SearchError> {
        tracing::trace!(query, "DuckDuckGo search");

        let client = http::build_client(config)?;

        let mut params = vec![("q", query)];
        if config.safe_search {
            params.push(("kp", "1"));
        }

        let response = client
            .post("https://html.duckduckgo.com/html/")
            .form(&params)
            .header("Accept-Language", "en-US,en;q=0.9")
            .send()
            .await
            .map_err(|e| SearchError::Http(format!("DuckDuckGo request failed: {e}")))?
            .error_for_status()
            .map_err(|e| SearchError::Http(format!("DuckDuckGo HTTP error: {e}")))?;

        let html = response
            .text()
            .await
            .map_err(|e| SearchError::Http(format!("DuckDuckGo response read failed: {e}")))?;

        tracing::trace!(bytes = html.len(), "DuckDuckGo response received");

        parse_duckduckgo_html(&html, config.max_results)
    }

    fn engine_type(&self) -> SearchEngine {
        SearchEngine::DuckDuckGo
    }
}

/// Parse DuckDuckGo HTML response into search results.
///
/// Extracted as a separate function for testability with mock HTML.
pub(crate) fn parse_duckduckgo_html(
    html: &str,
    max_results: usize,
) -> Result<Vec<SearchResult>, SearchError> {
    let document = Html::parse_document(html);

    let result_sel = Selector::parse(
        ".result.results_links.results_links_deep:not(.result--ad), .web-result:not(.result--ad)",
    )
    .map_err(|e| SearchError::Parse(format!("invalid result selector: {e:?}")))?;
    let title_sel = Selector::parse(".result__a")
        .map_err(|e| SearchError::Parse(format!("invalid title selector: {e:?}")))?;
    let snippet_sel = Selector::parse(".result__snippet")
        .map_err(|e| SearchError::Parse(format!("invalid snippet selector: {e:?}")))?;

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

        let href = match title_el.value().attr("href") {
            Some(h) => h,
            None => continue,
        };

        let url = match DuckDuckGoEngine::extract_url(href) {
            Some(u) => u,
            None => continue,
        };

        let snippet = element
            .select(&snippet_sel)
            .next()
            .map(|el| el.text().collect::<String>().trim().to_string())
            .unwrap_or_default();

        results.push(SearchResult {
            title,
            url,
            snippet,
            engine: SearchEngine::DuckDuckGo.name().to_string(),
            score: 0.0,
        });

        if results.len() >= max_results {
            break;
        }
    }

    tracing::debug!(count = results.len(), "DuckDuckGo results parsed");
    Ok(results)
}

#[cfg(test)]
mod tests {
    use super::*;

    const MOCK_DDG_HTML: &str = r#"<!DOCTYPE html>
<html>
<body>
<div class="result results_links results_links_deep web-result">
    <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.rust-lang.org%2F&amp;rut=abc123">
        Rust Programming Language
    </a>
    <div class="result__snippet">
        A language empowering everyone to build reliable and efficient software.
    </div>
</div>
<div class="result results_links results_links_deep web-result">
    <a class="result__a" href="https://doc.rust-lang.org/book/">
        The Rust Programming Language Book
    </a>
    <div class="result__snippet">
        An introductory book about Rust. The Rust Programming Language.
    </div>
</div>
<div class="result results_links results_links_deep web-result">
    <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fen.wikipedia.org%2Fwiki%2FRust_(programming_language)&amp;rut=def456">
        Rust (programming language) - Wikipedia
    </a>
    <div class="result__snippet">
        Rust is a multi-paradigm, general-purpose programming language.
    </div>
</div>
</body>
</html>"#;

    #[test]
    fn extract_url_from_ddg_redirect() {
        let href = "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fpage&rut=abc";
        let result = DuckDuckGoEngine::extract_url(href);
        assert_eq!(result, Some("https://example.com/page".to_string()));
    }

    #[test]
    fn extract_url_direct_link() {
        let href = "https://example.com/direct";
        let result = DuckDuckGoEngine::extract_url(href);
        assert_eq!(result, Some("https://example.com/direct".to_string()));
    }

    #[test]
    fn extract_url_invalid() {
        let href = "not-a-url";
        let result = DuckDuckGoEngine::extract_url(href);
        assert!(result.is_none());
    }

    #[test]
    fn parse_mock_html_returns_results() {
        let results = parse_duckduckgo_html(MOCK_DDG_HTML, 10);
        assert!(results.is_ok());
        let results = results.expect("should parse");
        assert_eq!(results.len(), 3);

        assert_eq!(results[0].title, "Rust Programming Language");
        assert_eq!(results[0].url, "https://www.rust-lang.org/");
        assert!(results[0].snippet.contains("reliable and efficient"));
        assert_eq!(results[0].engine, "DuckDuckGo");

        assert_eq!(results[1].url, "https://doc.rust-lang.org/book/");

        assert!(results[2].url.contains("wikipedia.org"));
    }

    #[test]
    fn parse_respects_max_results() {
        let results = parse_duckduckgo_html(MOCK_DDG_HTML, 2);
        assert!(results.is_ok());
        assert_eq!(results.expect("should parse").len(), 2);
    }

    #[test]
    fn parse_empty_html_returns_empty() {
        let results = parse_duckduckgo_html("<html><body></body></html>", 10);
        assert!(results.is_ok());
        assert!(results.expect("should parse").is_empty());
    }

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

    // ── Fixture-based parser tests ──────────────────────────────────────

    const FIXTURE_DDG_HTML: &str = include_str!("../../test-data/duckduckgo.html");

    #[test]
    fn fixture_extracts_all_organic_results() {
        let results = parse_duckduckgo_html(FIXTURE_DDG_HTML, 50);
        let results = results.expect("fixture should parse");
        // Fixture has 12 organic results + 1 ad (ad uses result--ad class, not matched by selector)
        assert!(
            results.len() >= 10,
            "expected 10+ results, got {}",
            results.len()
        );
    }

    #[test]
    fn fixture_results_have_non_empty_fields() {
        let results = parse_duckduckgo_html(FIXTURE_DDG_HTML, 50).expect("should parse");
        for (i, r) in results.iter().enumerate() {
            assert!(!r.title.is_empty(), "result {i} has empty title");
            assert!(!r.url.is_empty(), "result {i} has empty URL");
            assert!(!r.snippet.is_empty(), "result {i} has empty snippet");
            assert_eq!(r.engine, "DuckDuckGo");
        }
    }

    #[test]
    fn fixture_unwraps_ddg_redirect_urls() {
        let results = parse_duckduckgo_html(FIXTURE_DDG_HTML, 50).expect("should parse");
        // First result should have unwrapped URL
        assert_eq!(
            results[0].url, "https://www.rust-lang.org/",
            "redirect URL not unwrapped"
        );
        // No result URL should contain duckduckgo.com/l/
        for r in &results {
            assert!(
                !r.url.contains("duckduckgo.com/l/"),
                "URL still wrapped: {}",
                r.url
            );
        }
    }

    #[test]
    fn fixture_respects_max_results() {
        let results = parse_duckduckgo_html(FIXTURE_DDG_HTML, 3).expect("should parse");
        assert_eq!(results.len(), 3);
    }

    #[test]
    fn fixture_excludes_ads() {
        let results = parse_duckduckgo_html(FIXTURE_DDG_HTML, 50).expect("should parse");
        for r in &results {
            assert!(
                !r.title.contains("(Ad)"),
                "ad result should be excluded: {}",
                r.title
            );
        }
    }

    #[tokio::test]
    #[ignore] // Live test — run with `cargo test -- --ignored`
    async fn live_duckduckgo_search() {
        let engine = DuckDuckGoEngine;
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
