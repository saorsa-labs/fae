//! Weighted scoring with position-decay for search results.
//!
//! Assigns scores based on:
//! - Engine reliability/quality weight (from `SearchEngine::weight()`)
//! - Position decay (earlier results score higher)
//!
//! Formula: `score = engine_weight * position_decay`
//! where `position_decay = 1.0 / (1.0 + position_index * 0.1)`

use crate::types::SearchResult;

/// Calculate score for a search result based on its position and engine weight.
///
/// # Scoring Formula
///
/// ```text
/// score = engine_weight * position_decay
/// position_decay = 1.0 / (1.0 + position_index * 0.1)
/// ```
///
/// - Result at position 0 gets decay factor 1.0
/// - Result at position 9 gets decay factor ~0.5
/// - Engine weights from `SearchEngine::weight()`:
///   - Google: 1.2
///   - DuckDuckGo: 1.0
///   - Brave: 1.0
///   - Startpage: 0.9
///   - Bing: 0.8
///
/// # Arguments
///
/// * `result` - The search result to score
/// * `position` - The 0-based index of this result in the engine's result list
///
/// # Returns
///
/// The calculated score as `f64`.
pub fn calculate_score(result: &SearchResult, position: usize) -> f64 {
    let engine_weight = parse_engine_weight(&result.engine);
    let position_decay = 1.0 / (1.0 + position as f64 * 0.1);
    engine_weight * position_decay
}

/// Apply scoring to a list of results from a single engine.
///
/// Returns a new vector with the `score` field updated for each result.
pub fn score_results(mut results: Vec<SearchResult>) -> Vec<SearchResult> {
    for (position, result) in results.iter_mut().enumerate() {
        result.score = calculate_score(result, position);
    }
    results
}

/// Parse engine weight from engine name string.
///
/// Falls back to 1.0 for unknown engines.
fn parse_engine_weight(engine_name: &str) -> f64 {
    match engine_name {
        "Google" => 1.2,
        "DuckDuckGo" => 1.0,
        "Brave" => 1.0,
        "Startpage" => 0.9,
        "Bing" => 0.8,
        _ => 1.0, // default weight for unknown engines
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_result(url: &str, engine: &str) -> SearchResult {
        SearchResult {
            title: format!("Title from {engine}"),
            url: url.to_string(),
            snippet: format!("Snippet from {engine}"),
            engine: engine.to_string(),
            score: 0.0, // Will be calculated
        }
    }

    #[test]
    fn google_at_position_0_scores_higher_than_bing_at_position_0() {
        let google = make_result("https://example.com", "Google");
        let bing = make_result("https://example.com", "Bing");

        let google_score = calculate_score(&google, 0);
        let bing_score = calculate_score(&bing, 0);

        // Google weight 1.2 > Bing weight 0.8
        assert!(google_score > bing_score);
        assert!((google_score - 1.2).abs() < f64::EPSILON);
        assert!((bing_score - 0.8).abs() < f64::EPSILON);
    }

    #[test]
    fn position_0_scores_higher_than_position_5_same_engine() {
        let result = make_result("https://example.com", "DuckDuckGo");

        let score_0 = calculate_score(&result, 0);
        let score_5 = calculate_score(&result, 5);

        assert!(score_0 > score_5);
        // Position 0: 1.0 * 1.0 = 1.0
        assert!((score_0 - 1.0).abs() < f64::EPSILON);
        // Position 5: 1.0 * (1.0 / (1.0 + 0.5)) ≈ 0.6667
        let expected_5 = 1.0 / (1.0 + 5.0 * 0.1);
        assert!((score_5 - expected_5).abs() < f64::EPSILON);
    }

    #[test]
    fn scoring_is_deterministic() {
        let result = make_result("https://example.com", "Brave");

        let score_1 = calculate_score(&result, 3);
        let score_2 = calculate_score(&result, 3);

        assert!((score_1 - score_2).abs() < f64::EPSILON);
    }

    #[test]
    fn position_decay_formula_correctness() {
        let result = make_result("https://example.com", "DuckDuckGo"); // weight 1.0

        // Position 0: 1.0 / (1.0 + 0.0) = 1.0
        let score_0 = calculate_score(&result, 0);
        assert!((score_0 - 1.0).abs() < f64::EPSILON);

        // Position 9: 1.0 / (1.0 + 0.9) = 1.0 / 1.9 ≈ 0.526
        let score_9 = calculate_score(&result, 9);
        let expected_9 = 1.0 / (1.0 + 9.0 * 0.1);
        assert!((score_9 - expected_9).abs() < f64::EPSILON);
        assert!(score_9 < 0.53 && score_9 > 0.52);
    }

    #[test]
    fn score_results_updates_all_scores() {
        let results = vec![
            make_result("https://a.com", "Google"),
            make_result("https://b.com", "Google"),
            make_result("https://c.com", "Google"),
        ];

        let scored = score_results(results);

        // Position 0: 1.2 * 1.0
        assert!((scored[0].score - 1.2).abs() < f64::EPSILON);
        // Position 1: 1.2 * (1.0 / 1.1)
        assert!((scored[1].score - 1.2 / 1.1).abs() < f64::EPSILON);
        // Position 2: 1.2 * (1.0 / 1.2)
        assert!((scored[2].score - 1.2 / 1.2).abs() < f64::EPSILON);
    }

    #[test]
    fn empty_results_return_empty() {
        let scored = score_results(vec![]);
        assert!(scored.is_empty());
    }

    #[test]
    fn single_result_scored_correctly() {
        let results = vec![make_result("https://solo.com", "Startpage")];
        let scored = score_results(results);

        assert_eq!(scored.len(), 1);
        // Startpage weight 0.9 * position 0 decay 1.0
        assert!((scored[0].score - 0.9).abs() < f64::EPSILON);
    }

    #[test]
    fn unknown_engine_defaults_to_weight_1_0() {
        let result = make_result("https://example.com", "UnknownEngine");
        let score = calculate_score(&result, 0);

        assert!((score - 1.0).abs() < f64::EPSILON);
    }

    #[test]
    fn engine_weights_match_spec() {
        let google = make_result("https://x.com", "Google");
        let ddg = make_result("https://x.com", "DuckDuckGo");
        let brave = make_result("https://x.com", "Brave");
        let startpage = make_result("https://x.com", "Startpage");
        let bing = make_result("https://x.com", "Bing");

        assert!((calculate_score(&google, 0) - 1.2).abs() < f64::EPSILON);
        assert!((calculate_score(&ddg, 0) - 1.0).abs() < f64::EPSILON);
        assert!((calculate_score(&brave, 0) - 1.0).abs() < f64::EPSILON);
        assert!((calculate_score(&startpage, 0) - 0.9).abs() < f64::EPSILON);
        assert!((calculate_score(&bing, 0) - 0.8).abs() < f64::EPSILON);
    }

    #[test]
    fn position_decay_reduces_score_progressively() {
        let result = make_result("https://x.com", "DuckDuckGo");

        let scores: Vec<f64> = (0..10).map(|pos| calculate_score(&result, pos)).collect();

        // Each subsequent position should have lower score
        for i in 1..scores.len() {
            assert!(scores[i] < scores[i - 1]);
        }
    }
}
