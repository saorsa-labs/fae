/// Fuses wake-word detection scores from multiple detectors.
///
/// When the MLXKeywordClassifier model is available, combines its score
/// with acoustic template cosine similarity using weighted fusion.
/// When the classifier is unavailable, falls back to template-only detection
/// with a higher confidence threshold.
struct WakeWordScoreFusion {
    /// Weight for the neural classifier score (0.7).
    static let classifierWeight: Float = 0.7
    /// Weight for the template cosine similarity score (0.3).
    static let templateWeight: Float = 0.3
    /// Activation threshold when both detectors are available.
    static let fusedThreshold: Float = 0.6
    /// Activation threshold for template-only mode (no classifier).
    static let templateOnlyThreshold: Float = 0.7

    /// Result of score fusion.
    struct Result {
        /// The fused score (0.0 to 1.0).
        let score: Float
        /// Whether the score exceeds the applicable threshold.
        let isActivated: Bool
        /// Which detectors contributed to the score.
        let mode: DetectionMode
    }

    /// Detection mode indicating which detectors contributed.
    enum DetectionMode {
        /// Both classifier and template contributed.
        case fused
        /// Template only — no classifier model was loaded.
        case templateOnly
        /// Neither detector was available.
        case none
    }

    /// Compute the fused wake-word detection score.
    ///
    /// When a classifier score is provided, the result is a weighted combination:
    /// `score = 0.7 * classifierScore + 0.3 * max(templateSimilarities)`
    /// The fused score activates at 0.6.
    ///
    /// When no classifier score is available and at least one template similarity
    /// is positive, the maximum template similarity is used alone, activating at 0.7.
    ///
    /// When neither input is available, the result is a score of 0 with no activation.
    ///
    /// - Parameters:
    ///   - classifierScore: Score from MLXKeywordClassifier (nil if model not loaded).
    ///   - templateSimilarities: Cosine similarities from WakeWordAcousticDetector templates.
    /// - Returns: A ``Result`` with the fused score, activation status, and detection mode.
    static func fuse(
        classifierScore: Float?,
        templateSimilarities: [Float]
    ) -> Result {
        let maxTemplate = templateSimilarities.max() ?? 0

        if let classifier = classifierScore {
            let score = classifierWeight * classifier + templateWeight * maxTemplate
            return Result(
                score: score,
                isActivated: score >= fusedThreshold,
                mode: .fused
            )
        } else if !templateSimilarities.isEmpty, maxTemplate > 0 {
            return Result(
                score: maxTemplate,
                isActivated: maxTemplate >= templateOnlyThreshold,
                mode: .templateOnly
            )
        } else {
            return Result(score: 0, isActivated: false, mode: .none)
        }
    }
}
