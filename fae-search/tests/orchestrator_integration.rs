//! Integration tests for the search orchestrator pipeline.
//!
//! These tests exercise the full dedup → score → boost → sort → truncate
//! pipeline using synthetic results (no network calls). Live engine tests
//! are marked `#[ignore]` for manual/periodic validation.

use fae_search::orchestrator::dedup::deduplicate;
use fae_search::orchestrator::scoring::{apply_cross_engine_boost, score_results};
use fae_search::types::SearchResult;
use fae_search::{SearchConfig, SearchEngine};

fn make_result(url: &str, engine: &str, title: &str) -> SearchResult {
    SearchResult {
        title: title.to_string(),
        url: url.to_string(),
        snippet: format!("Snippet from {engine} for {title}"),
        engine: engine.to_string(),
        score: 0.0,
    }
}

/// Simulate the full orchestrator pipeline without network calls.
fn run_pipeline(
    engine_results: Vec<(SearchEngine, Vec<SearchResult>)>,
    max_results: usize,
) -> Vec<SearchResult> {
    // 1. Score each engine's results by position.
    let mut all_results: Vec<SearchResult> = Vec::new();
    for (_engine, results) in engine_results {
        let scored = score_results(results);
        all_results.extend(scored);
    }

    // 2. Deduplicate by normalised URL.
    let deduped = deduplicate(all_results);

    // 3. Apply cross-engine boost.
    let mut final_results: Vec<SearchResult> = deduped
        .into_iter()
        .map(|dr| {
            let count = dr.engines.len();
            let mut result = dr.result;
            result.score = apply_cross_engine_boost(result.score, count);
            result
        })
        .collect();

    // 4. Sort by score descending.
    final_results.sort_by(|a, b| {
        b.score
            .partial_cmp(&a.score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    // 5. Truncate to max_results.
    final_results.truncate(max_results);

    final_results
}

#[test]
fn full_pipeline_4_engines_dedup_score_boost_sort() {
    let google_results = vec![
        make_result("https://example.com", "Google", "Example"),
        make_result("https://google-only.com", "Google", "Google Only"),
        make_result("https://shared-2.com", "Google", "Shared 2"),
    ];
    let ddg_results = vec![
        make_result("https://example.com", "DuckDuckGo", "Example DDG"),
        make_result("https://ddg-only.com", "DuckDuckGo", "DDG Only"),
    ];
    let brave_results = vec![
        make_result("https://example.com", "Brave", "Example Brave"),
        make_result("https://shared-2.com", "Brave", "Shared 2 Brave"),
        make_result("https://brave-only.com", "Brave", "Brave Only"),
    ];
    let bing_results = vec![
        make_result("https://example.com", "Bing", "Example Bing"),
        make_result("https://bing-only.com", "Bing", "Bing Only"),
    ];

    let results = run_pipeline(
        vec![
            (SearchEngine::Google, google_results),
            (SearchEngine::DuckDuckGo, ddg_results),
            (SearchEngine::Brave, brave_results),
            (SearchEngine::Bing, bing_results),
        ],
        10,
    );

    // Should have 6 unique URLs: example.com, google-only, shared-2, ddg-only, brave-only, bing-only
    assert_eq!(results.len(), 6);

    // Results should be sorted by score descending
    for i in 1..results.len() {
        assert!(
            results[i - 1].score >= results[i].score,
            "results not sorted: {} ({}) >= {} ({})",
            results[i - 1].score,
            results[i - 1].url,
            results[i].score,
            results[i].url
        );
    }

    // example.com appeared in 4 engines → should have highest boost (1.6x)
    let example = results
        .iter()
        .find(|r| r.url == "https://example.com")
        .expect("example.com should be in results");
    assert!(
        example.score > 1.5,
        "example.com should have high boosted score, got {}",
        example.score
    );

    // shared-2.com appeared in 2 engines (Google + Brave) → 1.2x boost
    let shared = results
        .iter()
        .find(|r| r.url == "https://shared-2.com")
        .expect("shared-2.com should be in results");
    // Google pos 2 base = 1.2 * (1/1.2) = 1.0, boosted 1.2x = 1.2
    assert!(
        shared.score > 1.0,
        "shared-2.com should have boosted score > 1.0, got {}",
        shared.score
    );
}

#[test]
fn single_engine_mode_returns_results() {
    let results = vec![
        make_result("https://a.com", "DuckDuckGo", "Page A"),
        make_result("https://b.com", "DuckDuckGo", "Page B"),
        make_result("https://c.com", "DuckDuckGo", "Page C"),
    ];

    let final_results = run_pipeline(vec![(SearchEngine::DuckDuckGo, results)], 10);

    assert_eq!(final_results.len(), 3);
    // No cross-engine boost (all from same engine)
    // Position 0 should score highest
    assert!(final_results[0].score > final_results[1].score);
    assert!(final_results[1].score > final_results[2].score);
}

#[test]
fn score_ordering_verified() {
    let google_results: Vec<SearchResult> = (0..5)
        .map(|i| make_result(&format!("https://g{i}.com"), "Google", &format!("G{i}")))
        .collect();
    let bing_results: Vec<SearchResult> = (0..5)
        .map(|i| make_result(&format!("https://b{i}.com"), "Bing", &format!("B{i}")))
        .collect();

    let final_results = run_pipeline(
        vec![
            (SearchEngine::Google, google_results),
            (SearchEngine::Bing, bing_results),
        ],
        10,
    );

    // All URLs are unique so no boost; verify strict descending order
    for i in 1..final_results.len() {
        assert!(
            final_results[i - 1].score >= final_results[i].score,
            "score ordering violated at position {i}"
        );
    }
}

#[test]
fn max_results_truncation() {
    let results: Vec<SearchResult> = (0..20)
        .map(|i| {
            make_result(
                &format!("https://page{i}.com"),
                "Google",
                &format!("Page {i}"),
            )
        })
        .collect();

    let final_results = run_pipeline(vec![(SearchEngine::Google, results)], 5);
    assert_eq!(final_results.len(), 5);

    // Should keep the top 5 by score (position 0-4)
    assert!(final_results[0].score > final_results[4].score);
}

#[test]
fn cross_engine_url_boosted_above_single_engine() {
    // URL A appears in Google and DDG
    // URL B appears only in Google at position 0
    let google_results = vec![
        make_result("https://b.com", "Google", "B Only"),
        make_result("https://a.com", "Google", "A Shared"),
    ];
    let ddg_results = vec![make_result("https://a.com", "DuckDuckGo", "A Shared DDG")];

    let final_results = run_pipeline(
        vec![
            (SearchEngine::Google, google_results),
            (SearchEngine::DuckDuckGo, ddg_results),
        ],
        10,
    );

    let a = final_results
        .iter()
        .find(|r| r.url == "https://a.com")
        .expect("a.com");
    let b = final_results
        .iter()
        .find(|r| r.url == "https://b.com")
        .expect("b.com");

    // a.com: Google pos 1 base = 1.2/1.1 ≈ 1.09, boosted 1.2x ≈ 1.31
    // b.com: Google pos 0 base = 1.2, no boost = 1.2
    // So a.com (boosted) should beat b.com (unboosted)
    assert!(
        a.score > b.score,
        "cross-engine URL ({}) should score higher than single-engine URL ({})",
        a.score,
        b.score
    );
}

#[test]
fn empty_engine_results_returns_empty() {
    let final_results = run_pipeline(vec![(SearchEngine::Google, vec![])], 10);
    assert!(final_results.is_empty());
}

#[test]
fn config_validation_rejects_invalid() {
    let config = SearchConfig {
        max_results: 0,
        ..Default::default()
    };
    assert!(config.validate().is_err());

    let config = SearchConfig {
        engines: vec![],
        ..Default::default()
    };
    assert!(config.validate().is_err());
}

/// Live integration test — runs actual network queries.
/// Only run manually: `cargo test -p fae-search --test orchestrator_integration live_ -- --ignored`
#[tokio::test]
#[ignore]
async fn live_search_returns_results() {
    let config = SearchConfig {
        engines: vec![SearchEngine::DuckDuckGo],
        max_results: 5,
        timeout_seconds: 10,
        safe_search: true,
        cache_ttl_seconds: 0,
        request_delay_ms: (0, 0),
        user_agent: None,
    };

    let results = fae_search::search("rust programming language", &config).await;
    match results {
        Ok(results) => {
            assert!(!results.is_empty(), "live search should return results");
            for r in &results {
                assert!(!r.title.is_empty(), "result title should not be empty");
                assert!(!r.url.is_empty(), "result URL should not be empty");
                assert!(r.score > 0.0, "result score should be positive");
            }
        }
        Err(e) => {
            // Network failures are acceptable in CI; just log
            eprintln!("Live search failed (acceptable in CI): {e}");
        }
    }
}
