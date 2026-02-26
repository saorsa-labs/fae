//! Heuristic sentiment classifier for orb emotional state.
//!
//! Analyses assistant response text and maps it to one of 8 orb feelings
//! with an optional palette override. Two classification layers:
//!
//! 1. **Explicit tag** — the LLM can prefix a response with `[feeling:warmth]`
//!    for deterministic classification.
//! 2. **Keyword heuristic** — fast pattern scan (~1 ms) over the text when no
//!    explicit tag is present.
//!
//! The classifier is designed to run as a fire-and-forget `tokio::spawn` task
//! after each LLM turn with zero impact on response latency.

/// Result of sentiment classification.
#[derive(Debug, Clone, PartialEq)]
pub struct SentimentResult {
    /// One of the 8 `OrbFeeling` values:
    /// `neutral`, `calm`, `curiosity`, `warmth`, `concern`, `delight`,
    /// `focus`, `playful`.
    pub feeling: String,
    /// Optional palette override mapped from the detected feeling.
    pub palette: Option<String>,
    /// Classification confidence in the range `0.0..=1.0`.
    pub confidence: f32,
}

/// Minimum confidence required to act on a sentiment result.
///
/// Below this threshold the orb feeling should not change, preventing noise
/// from short or ambiguous responses.
pub const CONFIDENCE_THRESHOLD: f32 = 0.3;

// ── Keyword tables ──────────────────────────────────────────────────────

/// (feeling, keywords, palette)
const FEELING_TABLE: &[(&str, &[&str], &str)] = &[
    (
        "warmth",
        &[
            "understand",
            "care",
            "sorry to hear",
            "here for you",
            "empathy",
            "compassion",
            "appreciate",
            "thinking of you",
            "support",
            "comfort",
        ],
        "autumn-bracken",
    ),
    (
        "delight",
        &[
            "great",
            "wonderful",
            "exciting",
            "love",
            "fantastic",
            "amazing",
            "excellent",
            "awesome",
            "brilliant",
            "thrilled",
        ],
        "dawn-light",
    ),
    (
        "curiosity",
        &[
            "interesting",
            "tell me more",
            "wonder",
            "fascinating",
            "curious",
            "explore",
            "what if",
            "how does",
            "intriguing",
            "dig deeper",
        ],
        "glen-green",
    ),
    (
        "concern",
        &[
            "careful",
            "warning",
            "unfortunately",
            "be aware",
            "caution",
            "risk",
            "danger",
            "worried",
            "issue",
            "problem",
        ],
        "rowan-berry",
    ),
    (
        "focus",
        &[
            "specifically",
            "exactly",
            "precisely",
            "step by step",
            "in detail",
            "technically",
            "let me break",
            "the key point",
            "to clarify",
            "implementation",
        ],
        "silver-mist",
    ),
    (
        "calm",
        &[
            "relax",
            "take your time",
            "no rush",
            "peaceful",
            "gently",
            "easy",
            "breathe",
            "settle",
            "steady",
            "quietly",
        ],
        "heather-mist",
    ),
    (
        "playful",
        &[
            "haha", "fun", "joke", "silly", "laugh", "pun", "whimsy", "goofy", "playful", "cheeky",
        ],
        "loch-grey-green",
    ),
];

/// Classify the emotional tone of assistant response text.
///
/// Returns a [`SentimentResult`] with the detected feeling, optional palette,
/// and confidence score. The caller should check
/// [`confidence >= CONFIDENCE_THRESHOLD`](CONFIDENCE_THRESHOLD) before acting
/// on the result.
///
/// # Priority
///
/// 1. Explicit `[feeling:X]` tag at the start of the text → confidence 1.0.
/// 2. Keyword heuristic scan → confidence proportional to match density.
/// 3. Fallback → `neutral` with confidence 0.0.
pub fn classify(text: &str) -> SentimentResult {
    // ── Layer 1: explicit tag ───────────────────────────────────────────
    if let Some(result) = try_parse_explicit_tag(text) {
        return result;
    }

    // ── Layer 2: keyword heuristic ──────────────────────────────────────
    let lower = text.to_lowercase();

    let mut best_feeling = "neutral";
    let mut best_palette: Option<&str> = None;
    let mut best_score: usize = 0;

    for &(feeling, keywords, palette) in FEELING_TABLE {
        let score: usize = keywords.iter().filter(|kw| lower.contains(*kw)).count();
        if score > best_score {
            best_score = score;
            best_feeling = feeling;
            best_palette = Some(palette);
        }
    }

    if best_score == 0 {
        return SentimentResult {
            feeling: "neutral".to_owned(),
            palette: None,
            confidence: 0.0,
        };
    }

    // Confidence: scale by hit count with diminishing returns.
    // 1 hit → 0.35, 2 → 0.55, 3 → 0.70, 4+ → capped at 0.90.
    let confidence = match best_score {
        1 => 0.35,
        2 => 0.55,
        3 => 0.70,
        _ => (0.70 + 0.05 * (best_score as f32 - 3.0)).min(0.90),
    };

    SentimentResult {
        feeling: best_feeling.to_owned(),
        palette: best_palette.map(|s| s.to_owned()),
        confidence,
    }
}

/// Strip an explicit `[feeling:X]` tag from the start of the text, returning
/// the cleaned text (without the tag) and the tag value.
///
/// Returns `None` if no tag is found. Only recognises the 8 known feelings.
pub fn strip_feeling_tag(text: &str) -> Option<(String, String)> {
    let trimmed = text.trim_start();
    if !trimmed.starts_with("[feeling:") {
        return None;
    }

    let end = trimmed.find(']')?;
    let tag_value = &trimmed[9..end];

    // Validate it's a known feeling.
    if !is_known_feeling(tag_value) {
        return None;
    }

    let rest = trimmed[end + 1..].trim_start().to_owned();
    Some((rest, tag_value.to_owned()))
}

// ── Internals ───────────────────────────────────────────────────────────

/// Known orb feelings.
const KNOWN_FEELINGS: &[&str] = &[
    "neutral",
    "calm",
    "curiosity",
    "warmth",
    "concern",
    "delight",
    "focus",
    "playful",
];

fn is_known_feeling(s: &str) -> bool {
    KNOWN_FEELINGS.contains(&s)
}

fn try_parse_explicit_tag(text: &str) -> Option<SentimentResult> {
    let trimmed = text.trim_start();
    if !trimmed.starts_with("[feeling:") {
        return None;
    }

    let end = trimmed.find(']')?;
    let tag_value = &trimmed[9..end];

    if !is_known_feeling(tag_value) {
        return None;
    }

    let palette = palette_for_feeling(tag_value).map(|s| s.to_owned());
    Some(SentimentResult {
        feeling: tag_value.to_owned(),
        palette,
        confidence: 1.0,
    })
}

fn palette_for_feeling(feeling: &str) -> Option<&'static str> {
    for &(f, _, p) in FEELING_TABLE {
        if f == feeling {
            return Some(p);
        }
    }
    None
}

// ── Tests ───────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used)]

    use super::*;

    // ── Explicit tag parsing ────────────────────────────────────────────

    #[test]
    fn explicit_tag_warmth() {
        let result = classify("[feeling:warmth] I understand how you feel.");
        assert_eq!(result.feeling, "warmth");
        assert_eq!(result.confidence, 1.0);
        assert_eq!(result.palette.as_deref(), Some("autumn-bracken"));
    }

    #[test]
    fn explicit_tag_delight() {
        let result = classify("[feeling:delight] That's wonderful news!");
        assert_eq!(result.feeling, "delight");
        assert_eq!(result.confidence, 1.0);
        assert_eq!(result.palette.as_deref(), Some("dawn-light"));
    }

    #[test]
    fn explicit_tag_all_known_feelings() {
        for &feeling in KNOWN_FEELINGS {
            let text = format!("[feeling:{feeling}] Some text.");
            let result = classify(&text);
            assert_eq!(result.feeling, feeling, "explicit tag for {feeling}");
            assert_eq!(result.confidence, 1.0);
            // neutral has no palette mapping
            if feeling == "neutral" {
                assert!(result.palette.is_none());
            }
        }
    }

    #[test]
    fn explicit_tag_unknown_feeling_falls_through() {
        let result = classify("[feeling:rage] I am furious!");
        // "rage" is not known, so it should fall through to heuristic
        assert_ne!(result.confidence, 1.0);
    }

    #[test]
    fn explicit_tag_with_leading_whitespace() {
        let result = classify("  [feeling:calm] Take it easy.");
        assert_eq!(result.feeling, "calm");
        assert_eq!(result.confidence, 1.0);
    }

    // ── strip_feeling_tag ───────────────────────────────────────────────

    #[test]
    fn strip_tag_returns_cleaned_text() {
        let (rest, feeling) = strip_feeling_tag("[feeling:warmth] I care about you.").unwrap();
        assert_eq!(feeling, "warmth");
        assert_eq!(rest, "I care about you.");
    }

    #[test]
    fn strip_tag_returns_none_for_no_tag() {
        assert!(strip_feeling_tag("Hello there!").is_none());
    }

    #[test]
    fn strip_tag_returns_none_for_unknown_feeling() {
        assert!(strip_feeling_tag("[feeling:rage] Grr!").is_none());
    }

    // ── Keyword heuristic ───────────────────────────────────────────────

    #[test]
    fn heuristic_warmth() {
        let result = classify("I understand how you feel, and I care about your situation.");
        assert_eq!(result.feeling, "warmth");
        assert!(result.confidence >= CONFIDENCE_THRESHOLD);
    }

    #[test]
    fn heuristic_delight() {
        let result = classify("That's wonderful! What an amazing and exciting opportunity!");
        assert_eq!(result.feeling, "delight");
        assert!(result.confidence >= CONFIDENCE_THRESHOLD);
    }

    #[test]
    fn heuristic_curiosity() {
        let result = classify("That's really interesting! I wonder how it works. Tell me more.");
        assert_eq!(result.feeling, "curiosity");
        assert!(result.confidence >= CONFIDENCE_THRESHOLD);
    }

    #[test]
    fn heuristic_concern() {
        let result = classify("Be careful with that. Unfortunately there's a risk involved.");
        assert_eq!(result.feeling, "concern");
        assert!(result.confidence >= CONFIDENCE_THRESHOLD);
    }

    #[test]
    fn heuristic_focus() {
        let result =
            classify("Let me break this down step by step. Specifically, the implementation...");
        assert_eq!(result.feeling, "focus");
        assert!(result.confidence >= CONFIDENCE_THRESHOLD);
    }

    #[test]
    fn heuristic_calm() {
        let result = classify("Take your time, no rush. Let's settle in and breathe.");
        assert_eq!(result.feeling, "calm");
        assert!(result.confidence >= CONFIDENCE_THRESHOLD);
    }

    #[test]
    fn heuristic_playful() {
        let result = classify("Haha, that's so fun and silly! What a joke!");
        assert_eq!(result.feeling, "playful");
        assert!(result.confidence >= CONFIDENCE_THRESHOLD);
    }

    // ── Edge cases ──────────────────────────────────────────────────────

    #[test]
    fn empty_text_returns_neutral() {
        let result = classify("");
        assert_eq!(result.feeling, "neutral");
        assert_eq!(result.confidence, 0.0);
        assert!(result.palette.is_none());
    }

    #[test]
    fn short_ambiguous_text_returns_neutral() {
        let result = classify("OK.");
        assert_eq!(result.feeling, "neutral");
        assert_eq!(result.confidence, 0.0);
    }

    #[test]
    fn single_keyword_above_threshold() {
        let result = classify("That's really interesting.");
        assert!(
            result.confidence >= CONFIDENCE_THRESHOLD,
            "single keyword hit should meet threshold"
        );
    }

    #[test]
    fn multiple_keywords_increase_confidence() {
        let one_hit = classify("That's interesting.");
        let multi_hit = classify(
            "That's really interesting! I wonder how it works. Tell me more about this fascinating topic.",
        );
        assert!(
            multi_hit.confidence > one_hit.confidence,
            "more keyword hits should increase confidence"
        );
    }

    #[test]
    fn confidence_capped_below_one() {
        // Stuff many keywords into one text.
        let result = classify(
            "great wonderful exciting love fantastic amazing excellent awesome brilliant thrilled",
        );
        assert!(result.confidence <= 0.90);
        assert!(result.confidence > 0.0);
    }

    #[test]
    fn case_insensitive_matching() {
        let result = classify("THAT IS WONDERFUL AND AMAZING!");
        assert_eq!(result.feeling, "delight");
        assert!(result.confidence >= CONFIDENCE_THRESHOLD);
    }

    #[test]
    fn palette_mapping_complete() {
        // Every non-neutral feeling in the table should produce a palette.
        for &(feeling, _, expected_palette) in FEELING_TABLE {
            let pal = palette_for_feeling(feeling);
            assert_eq!(pal, Some(expected_palette), "palette for {feeling}");
        }
    }

    #[test]
    fn neutral_has_no_palette() {
        assert!(palette_for_feeling("neutral").is_none());
    }
}
