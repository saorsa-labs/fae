//! Core search orchestrator: concurrent multi-engine fan-out, dedup, score, rank.
//!
//! Queries all configured engines concurrently, applies weighted scoring
//! with position decay, deduplicates by normalised URL, applies cross-engine
//! boosting, sorts by final score, and truncates to the requested maximum.

use crate::config::SearchConfig;
use crate::engine::SearchEngineTrait;
use crate::engines::{BingEngine, BraveEngine, DuckDuckGoEngine, GoogleEngine};
use crate::error::SearchError;
use crate::types::{SearchEngine, SearchResult};

use super::dedup::deduplicate;
use super::scoring::{apply_cross_engine_boost, score_results};

/// Orchestrate a concurrent search across all enabled engines.
///
/// # Pipeline
///
/// 1. Create engine instances for each [`SearchEngine`] in `config.engines`
/// 2. Fan out queries concurrently with [`futures::future::join_all`]
/// 3. Log per-engine errors at warn level; collect successful results
/// 4. Apply position-decay scoring per engine
/// 5. Merge, deduplicate by normalised URL
/// 6. Apply cross-engine boost for URLs found by multiple engines
/// 7. Sort by final score (descending)
/// 8. Truncate to `config.max_results`
///
/// # Errors
///
/// Returns [`SearchError::AllEnginesFailed`] only if **every** enabled engine
/// fails. Partial failures are logged but do not prevent results from
/// successful engines being returned.
pub async fn orchestrate_search(
    query: &str,
    config: &SearchConfig,
) -> Result<Vec<SearchResult>, SearchError> {
    // 1. Fan out to all engines concurrently.
    let futures: Vec<_> = config
        .engines
        .iter()
        .map(|engine| {
            let q = query.to_string();
            let cfg = config.clone();
            let eng = *engine;
            async move {
                let result = query_engine(eng, &q, &cfg).await;
                (eng, result)
            }
        })
        .collect();

    let outcomes = futures::future::join_all(futures).await;

    // 2. Collect results, logging failures.
    let mut all_results: Vec<SearchResult> = Vec::new();
    let mut errors: Vec<String> = Vec::new();

    for (engine, outcome) in outcomes {
        match outcome {
            Ok(engine_results) => {
                let count = engine_results.len();
                tracing::debug!(%engine, count, "engine returned results");
                // 3. Apply position-decay scoring.
                let scored = score_results(engine_results);
                all_results.extend(scored);
            }
            Err(err) => {
                tracing::warn!(engine = %engine, error = %err, "engine query failed");
                errors.push(format!("{engine}: {err}"));
            }
        }
    }

    // 4. If ALL engines failed, return error.
    if all_results.is_empty() && !errors.is_empty() {
        return Err(SearchError::AllEnginesFailed(errors.join("; ")));
    }

    // 5. Deduplicate by normalised URL.
    let deduped = deduplicate(all_results);

    // 6. Apply cross-engine boost and collect final results.
    let mut final_results: Vec<SearchResult> = deduped
        .into_iter()
        .map(|dr| {
            let engine_count = dr.engines.len();
            let mut result = dr.result;
            result.score = apply_cross_engine_boost(result.score, engine_count);
            result
        })
        .collect();

    // 7. Sort by score descending.
    final_results.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));

    // 8. Truncate to max_results.
    final_results.truncate(config.max_results);

    Ok(final_results)
}

/// Query a single engine, dispatching to the concrete implementation.
async fn query_engine(
    engine: SearchEngine,
    query: &str,
    config: &SearchConfig,
) -> Result<Vec<SearchResult>, SearchError> {
    match engine {
        SearchEngine::DuckDuckGo => DuckDuckGoEngine.search(query, config).await,
        SearchEngine::Brave => BraveEngine.search(query, config).await,
        SearchEngine::Google => GoogleEngine.search(query, config).await,
        SearchEngine::Bing => BingEngine.search(query, config).await,
        SearchEngine::Startpage => {
            // Startpage not yet implemented (Phase 3.3).
            Err(SearchError::Parse("Startpage engine not yet implemented".into()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_config(engines: Vec<SearchEngine>, max_results: usize) -> SearchConfig {
        SearchConfig {
            engines,
            max_results,
            timeout_seconds: 5,
            safe_search: false,
            cache_ttl_seconds: 0,
            request_delay_ms: (0, 0),
            user_agent: Some("TestBot/1.0".into()),
        }
    }

    fn make_result(url: &str, engine: &str, score: f64) -> SearchResult {
        SearchResult {
            title: format!("Title from {engine}"),
            url: url.to_string(),
            snippet: format!("Snippet from {engine}"),
            engine: engine.to_string(),
            score,
        }
    }

    // Note: Full integration tests with mock engines are in Task 8.
    // These tests verify the orchestration pipeline components.

    #[test]
    fn results_sorted_by_score_descending() {
        let mut results = vec![
            make_result("https://c.com", "Bing", 0.5),
            make_result("https://a.com", "Google", 1.5),
            make_result("https://b.com", "DuckDuckGo", 1.0),
        ];

        results.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        assert!((results[0].score - 1.5).abs() < f64::EPSILON);
        assert!((results[1].score - 1.0).abs() < f64::EPSILON);
        assert!((results[2].score - 0.5).abs() < f64::EPSILON);
    }

    #[test]
    fn truncation_respects_max_results() {
        let mut results: Vec<SearchResult> = (0..20)
            .map(|i| make_result(&format!("https://example{i}.com"), "Google", 1.0 - i as f64 * 0.01))
            .collect();

        results.truncate(5);
        assert_eq!(results.len(), 5);
    }

    #[test]
    fn config_validation_rejects_zero_max_results() {
        let config = make_config(vec![SearchEngine::DuckDuckGo], 0);
        assert!(config.validate().is_err());
    }

    #[test]
    fn config_validation_rejects_empty_engines() {
        let config = make_config(vec![], 10);
        assert!(config.validate().is_err());
    }

    #[tokio::test]
    async fn all_engines_empty_returns_empty_vec() {
        // When engines return empty results (not errors), we should get Ok(empty)
        // This tests the pipeline logic — actual engine behaviour tested in Task 8
        let results: Vec<SearchResult> = vec![];
        let deduped = deduplicate(results);
        assert!(deduped.is_empty());
    }

    #[test]
    fn dedup_and_boost_pipeline() {
        // Simulate the full pipeline: score → dedup → boost → sort
        let mut engine_a_results = vec![
            make_result("https://example.com", "Google", 0.0),
            make_result("https://unique-a.com", "Google", 0.0),
        ];
        let mut engine_b_results = vec![
            make_result("https://example.com", "DuckDuckGo", 0.0),
            make_result("https://unique-b.com", "DuckDuckGo", 0.0),
        ];

        // Apply scoring
        engine_a_results = score_results(engine_a_results);
        engine_b_results = score_results(engine_b_results);

        // Merge
        let mut all = engine_a_results;
        all.extend(engine_b_results);

        // Dedup
        let deduped = deduplicate(all);
        assert_eq!(deduped.len(), 3); // example.com merged, two unique

        // Boost
        let mut final_results: Vec<SearchResult> = deduped
            .into_iter()
            .map(|dr| {
                let count = dr.engines.len();
                let mut r = dr.result;
                r.score = apply_cross_engine_boost(r.score, count);
                r
            })
            .collect();

        // Sort
        final_results.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        // The cross-engine URL (example.com from 2 engines) should be boosted
        // and likely near the top
        let example_result = final_results
            .iter()
            .find(|r| r.url.contains("example.com"))
            .expect("example.com should be in results");

        // Base score from Google pos 0 = 1.2, boosted by 2 engines = 1.2 * 1.2 = 1.44
        assert!(example_result.score > 1.4);
    }
}
