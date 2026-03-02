/// Lightweight keyword-based sentiment classifier that maps LLM response text
/// to an `OrbFeeling`, driving the orb's visual expression.
///
/// Runs on each completed LLM response. Returns `nil` for ambiguous/neutral text,
/// allowing the orb to remain in its current state rather than flickering.
enum SentimentClassifier {

    /// Minimum keyword hits required to return a feeling (avoids false positives).
    private static let threshold: Float = 2.0

    /// Analyze text and return the most likely OrbFeeling.
    static func classify(_ text: String) -> OrbFeeling? {
        let lower = text.lowercased()
        var scores: [OrbFeeling: Float] = [:]

        for (feeling, keywords) in sentimentKeywords {
            let score = keywords.reduce(Float(0)) { sum, keyword in
                sum + (lower.contains(keyword) ? 1.0 : 0.0)
            }
            if score > 0 { scores[feeling] = score }
        }

        // Return highest-scoring feeling if it meets the threshold.
        guard let best = scores.max(by: { $0.value < $1.value }),
              best.value >= threshold else {
            return nil
        }
        return best.key
    }

    private static let sentimentKeywords: [OrbFeeling: [String]] = [
        .warmth: [
            "glad", "happy", "love", "wonderful", "great to hear",
            "appreciate", "thank", "care", "sweet", "kind",
        ],
        .concern: [
            "sorry", "worried", "careful", "unfortunately", "concerning",
            "problem", "issue", "difficult", "struggle", "afraid",
        ],
        .delight: [
            "exciting", "fantastic", "amazing", "brilliant", "excellent",
            "perfect", "incredible", "awesome", "delightful", "wonderful",
        ],
        .curiosity: [
            "interesting", "wonder", "curious", "fascinating", "hmm",
            "explore", "discover", "investigate", "question", "intriguing",
        ],
        .calm: [
            "relax", "peaceful", "gentle", "steady", "quietly",
            "softly", "slowly", "breathe", "serene", "tranquil",
        ],
        .focus: [
            "let me think", "analyzing", "processing", "considering",
            "examining", "working on", "calculating", "reviewing", "checking",
        ],
        .playful: [
            "haha", "funny", "joke", "silly", "laugh",
            "fun", "play", "guess what", "clever", "cheeky",
        ],
    ]
}
