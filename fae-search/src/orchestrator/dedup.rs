//! Result deduplication by normalised URL.
//!
//! Groups search results that refer to the same page (after URL
//! normalisation) and keeps only the highest-scored entry per URL.
//! Tracks which engines contributed each URL so that the scoring
//! module can apply a cross-engine boost.

use std::collections::HashMap;

use crate::types::{SearchEngine, SearchResult};

use super::url_normalize::normalize_url;

/// A search result after deduplication, enriched with the set of
/// engines that returned the same URL.
#[derive(Debug, Clone)]
pub struct DeduplicatedResult {
    /// The best (highest-scored) result for this URL.
    pub result: SearchResult,
    /// All engines that returned this URL (including the one on `result`).
    pub engines: Vec<SearchEngine>,
}

/// Deduplicate search results by normalised URL.
///
/// Results sharing the same normalised URL are merged: the entry with
/// the highest `score` is kept, and the full list of contributing
/// engines is recorded in [`DeduplicatedResult::engines`].
///
/// The output order is **not** guaranteed — callers should sort by
/// score after applying any cross-engine boost.
pub fn deduplicate(results: Vec<SearchResult>) -> Vec<DeduplicatedResult> {
    // Map from normalised URL → (best result, engine set).
    let mut groups: HashMap<String, (SearchResult, Vec<SearchEngine>)> = HashMap::new();

    for result in results {
        let key = normalize_url(&result.url);
        let engine = parse_engine_name(&result.engine);

        groups
            .entry(key)
            .and_modify(|(best, engines)| {
                if let Some(eng) = engine {
                    if !engines.contains(&eng) {
                        engines.push(eng);
                    }
                }
                if result.score > best.score {
                    *best = result.clone();
                }
            })
            .or_insert_with(|| {
                let engines = engine.map_or_else(Vec::new, |e| vec![e]);
                (result, engines)
            });
    }

    groups
        .into_values()
        .map(|(result, engines)| DeduplicatedResult { result, engines })
        .collect()
}

/// Best-effort parse of an engine name string back to [`SearchEngine`].
fn parse_engine_name(name: &str) -> Option<SearchEngine> {
    match name {
        "DuckDuckGo" => Some(SearchEngine::DuckDuckGo),
        "Brave" => Some(SearchEngine::Brave),
        "Google" => Some(SearchEngine::Google),
        "Bing" => Some(SearchEngine::Bing),
        "Startpage" => Some(SearchEngine::Startpage),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_result(url: &str, engine: &str, score: f64) -> SearchResult {
        SearchResult {
            title: format!("Title from {engine}"),
            url: url.to_string(),
            snippet: format!("Snippet from {engine}"),
            engine: engine.to_string(),
            score,
        }
    }

    #[test]
    fn unique_urls_pass_through() {
        let results = vec![
            make_result("https://a.com", "Google", 1.0),
            make_result("https://b.com", "Bing", 0.8),
        ];
        let deduped = deduplicate(results);
        assert_eq!(deduped.len(), 2);
    }

    #[test]
    fn duplicate_urls_merged() {
        let results = vec![
            make_result("https://example.com/page", "Google", 1.2),
            make_result("https://example.com/page", "Bing", 0.8),
        ];
        let deduped = deduplicate(results);
        assert_eq!(deduped.len(), 1);
    }

    #[test]
    fn highest_score_kept() {
        let results = vec![
            make_result("https://example.com", "Bing", 0.5),
            make_result("https://example.com", "Google", 1.5),
        ];
        let deduped = deduplicate(results);
        assert_eq!(deduped.len(), 1);
        assert!((deduped[0].result.score - 1.5).abs() < f64::EPSILON);
        assert_eq!(deduped[0].result.engine, "Google");
    }

    #[test]
    fn engines_list_tracks_all_contributors() {
        let results = vec![
            make_result("https://example.com", "Google", 1.2),
            make_result("https://example.com", "Bing", 0.8),
            make_result("https://example.com", "DuckDuckGo", 1.0),
        ];
        let deduped = deduplicate(results);
        assert_eq!(deduped.len(), 1);
        assert_eq!(deduped[0].engines.len(), 3);
        assert!(deduped[0].engines.contains(&SearchEngine::Google));
        assert!(deduped[0].engines.contains(&SearchEngine::Bing));
        assert!(deduped[0].engines.contains(&SearchEngine::DuckDuckGo));
    }

    #[test]
    fn normalisation_merges_equivalent_urls() {
        let results = vec![
            make_result("https://Example.COM/path/", "Google", 1.0),
            make_result("https://example.com/path", "Bing", 0.9),
        ];
        let deduped = deduplicate(results);
        assert_eq!(deduped.len(), 1);
        assert_eq!(deduped[0].engines.len(), 2);
    }

    #[test]
    fn tracking_params_ignored_for_dedup() {
        let results = vec![
            make_result("https://example.com/page?q=rust", "Google", 1.0),
            make_result(
                "https://example.com/page?q=rust&utm_source=twitter",
                "Brave",
                0.9,
            ),
        ];
        let deduped = deduplicate(results);
        assert_eq!(deduped.len(), 1);
        assert_eq!(deduped[0].engines.len(), 2);
    }

    #[test]
    fn empty_input_returns_empty() {
        let deduped = deduplicate(vec![]);
        assert!(deduped.is_empty());
    }

    #[test]
    fn single_result_passes_through() {
        let results = vec![make_result("https://solo.com", "DuckDuckGo", 1.0)];
        let deduped = deduplicate(results);
        assert_eq!(deduped.len(), 1);
        assert_eq!(deduped[0].engines.len(), 1);
        assert_eq!(deduped[0].engines[0], SearchEngine::DuckDuckGo);
    }

    #[test]
    fn same_engine_duplicate_not_listed_twice() {
        let results = vec![
            make_result("https://example.com", "Google", 1.0),
            make_result("https://example.com", "Google", 0.9),
        ];
        let deduped = deduplicate(results);
        assert_eq!(deduped.len(), 1);
        // Google should appear only once in the engines list.
        assert_eq!(deduped[0].engines.len(), 1);
        assert_eq!(deduped[0].engines[0], SearchEngine::Google);
    }

    #[test]
    fn unknown_engine_name_still_deduplicates() {
        let results = vec![
            make_result("https://example.com", "UnknownEngine", 1.0),
            make_result("https://example.com", "Google", 0.8),
        ];
        let deduped = deduplicate(results);
        assert_eq!(deduped.len(), 1);
        // UnknownEngine yields None, so only Google in the engines list.
        assert_eq!(deduped[0].engines.len(), 1);
        assert_eq!(deduped[0].engines[0], SearchEngine::Google);
    }
}
