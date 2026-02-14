//! Startpage search engine — privacy-focused proxy for Google results.
//!
//! Startpage serves Google results without tracking. Uses a GET request
//! to `https://www.startpage.com/do/search` which returns clean HTML.

use crate::config::SearchConfig;
use crate::engine::SearchEngineTrait;
use crate::error::SearchError;
use crate::http;
use crate::types::{SearchEngine, SearchResult};
use scraper::{Html, Selector};

/// Startpage HTML search scraper.
///
/// Priority 5 engine — acts as a fallback for Google since it proxies
/// Google results. Useful when Google blocks direct scraping.
pub struct StartpageEngine;

impl SearchEngineTrait for StartpageEngine {
    async fn search(
        &self,
        query: &str,
        config: &SearchConfig,
    ) -> Result<Vec<SearchResult>, SearchError> {
        tracing::trace!(query, "Startpage search");

        let client = http::build_client(config)?;

        let mut params = vec![("q", query.to_string()), ("cat", "web".to_string())];
        if !config.safe_search {
            params.push(("qadf", "none".to_string()));
        }

        let response = client
            .get("https://www.startpage.com/do/search")
            .query(
                &params
                    .iter()
                    .map(|(k, v)| (*k, v.as_str()))
                    .collect::<Vec<_>>(),
            )
            .header("Accept", "text/html,application/xhtml+xml")
            .header("Accept-Language", "en-US,en;q=0.9")
            .send()
            .await
            .map_err(|e| SearchError::Http(format!("Startpage request failed: {e}")))?
            .error_for_status()
            .map_err(|e| SearchError::Http(format!("Startpage HTTP error: {e}")))?;

        let html = response
            .text()
            .await
            .map_err(|e| SearchError::Http(format!("Startpage response read failed: {e}")))?;

        tracing::trace!(bytes = html.len(), "Startpage response received");

        parse_startpage_html(&html, config.max_results)
    }

    fn engine_type(&self) -> SearchEngine {
        SearchEngine::Startpage
    }
}

/// Parse Startpage HTML response into search results.
///
/// Extracted as a separate function for testability with mock HTML.
pub(crate) fn parse_startpage_html(
    html: &str,
    max_results: usize,
) -> Result<Vec<SearchResult>, SearchError> {
    let document = Html::parse_document(html);

    // Startpage uses .w-gl__result containers for organic results.
    let result_sel = Selector::parse(".w-gl__result")
        .map_err(|e| SearchError::Parse(format!("invalid result selector: {e:?}")))?;
    let title_sel = Selector::parse(".w-gl__result-title")
        .map_err(|e| SearchError::Parse(format!("invalid title selector: {e:?}")))?;
    let desc_sel = Selector::parse(".w-gl__description")
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

        // URL is in an <a> within the title element.
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
            engine: SearchEngine::Startpage.name().to_string(),
            score: 0.0,
        });

        if results.len() >= max_results {
            break;
        }
    }

    tracing::debug!(count = results.len(), "Startpage results parsed");
    Ok(results)
}

#[cfg(test)]
mod tests {
    use super::*;

    const MOCK_STARTPAGE_HTML: &str = r#"<!DOCTYPE html>
<html>
<body>
<div class="w-gl__result">
    <div class="w-gl__result-title">
        <a href="https://www.rust-lang.org/">
            Rust Programming Language
        </a>
    </div>
    <div class="w-gl__description">
        A language empowering everyone to build reliable and efficient software.
    </div>
</div>
<div class="w-gl__result">
    <div class="w-gl__result-title">
        <a href="https://doc.rust-lang.org/book/">
            The Rust Programming Language Book
        </a>
    </div>
    <div class="w-gl__description">
        An introductory book about Rust. The Rust Programming Language.
    </div>
</div>
<div class="w-gl__result">
    <div class="w-gl__result-title">
        <a href="https://en.wikipedia.org/wiki/Rust_(programming_language)">
            Rust (programming language) - Wikipedia
        </a>
    </div>
    <div class="w-gl__description">
        Rust is a multi-paradigm, general-purpose programming language.
    </div>
</div>
</body>
</html>"#;

    #[test]
    fn parse_mock_html_returns_results() {
        let results = parse_startpage_html(MOCK_STARTPAGE_HTML, 10);
        assert!(results.is_ok());
        let results = results.expect("should parse");
        assert_eq!(results.len(), 3);

        assert_eq!(results[0].title, "Rust Programming Language");
        assert_eq!(results[0].url, "https://www.rust-lang.org/");
        assert!(results[0].snippet.contains("reliable and efficient"));
        assert_eq!(results[0].engine, "Startpage");

        assert_eq!(results[1].url, "https://doc.rust-lang.org/book/");

        assert!(results[2].url.contains("wikipedia.org"));
    }

    #[test]
    fn parse_respects_max_results() {
        let results = parse_startpage_html(MOCK_STARTPAGE_HTML, 2);
        assert!(results.is_ok());
        assert_eq!(results.expect("should parse").len(), 2);
    }

    #[test]
    fn parse_empty_html_returns_empty() {
        let results = parse_startpage_html("<html><body></body></html>", 10);
        assert!(results.is_ok());
        assert!(results.expect("should parse").is_empty());
    }

    #[test]
    fn engine_type_is_startpage() {
        let engine = StartpageEngine;
        assert_eq!(engine.engine_type(), SearchEngine::Startpage);
    }

    #[test]
    fn is_send_sync() {
        fn assert_send_sync<T: Send + Sync>() {}
        assert_send_sync::<StartpageEngine>();
    }

    // ── Fixture-based parser tests ──────────────────────────────────────

    const FIXTURE_STARTPAGE_HTML: &str = include_str!("../../test-data/startpage.html");

    #[test]
    fn fixture_extracts_all_organic_results() {
        let results = parse_startpage_html(FIXTURE_STARTPAGE_HTML, 50);
        let results = results.expect("fixture should parse");
        assert!(
            results.len() >= 8,
            "expected 8+ results, got {}",
            results.len()
        );
    }

    #[test]
    fn fixture_results_have_non_empty_fields() {
        let results = parse_startpage_html(FIXTURE_STARTPAGE_HTML, 50).expect("should parse");
        for (i, r) in results.iter().enumerate() {
            assert!(!r.title.is_empty(), "result {i} has empty title");
            assert!(!r.url.is_empty(), "result {i} has empty URL");
            assert!(!r.snippet.is_empty(), "result {i} has empty snippet");
            assert_eq!(r.engine, "Startpage");
        }
    }

    #[test]
    fn fixture_first_result_is_rust_lang() {
        let results = parse_startpage_html(FIXTURE_STARTPAGE_HTML, 50).expect("should parse");
        assert_eq!(results[0].url, "https://www.rust-lang.org/");
    }

    #[test]
    fn fixture_respects_max_results() {
        let results = parse_startpage_html(FIXTURE_STARTPAGE_HTML, 3).expect("should parse");
        assert_eq!(results.len(), 3);
    }

    #[tokio::test]
    #[ignore] // Live test — run with `cargo test -- --ignored`
    async fn live_startpage_search() {
        let engine = StartpageEngine;
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
