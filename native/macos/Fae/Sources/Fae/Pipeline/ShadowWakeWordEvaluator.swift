/// Shadow-mode wake-word evaluator.
///
/// Tracks parallel wake-word detection results from an acoustic detector and
/// a text-based (post-ASR) detector, managing promotion of the acoustic
/// detector to primary status once it proves reliable.
///
/// In shadow mode the text-based detector remains authoritative while the
/// acoustic detector runs alongside. Once the acoustic detector accumulates
/// at least ``minAttemptsForPromotion`` results with a false-positive rate
/// at or below ``maxFPRateForPromotion`` and a false-negative rate at or
/// below ``maxFNRateForPromotion``, it is promoted to primary.
///
/// Post-promotion, if the false-positive rate in a rolling window of
/// ``demotionWindowSize`` utterances exceeds ``demotionFPThreshold``, the
/// acoustic detector is demoted back to shadow mode and evaluation restarts.
actor ShadowWakeWordEvaluator {

    // MARK: - Promotion thresholds

    /// Minimum shadow-mode attempts before promotion is considered.
    static let minAttemptsForPromotion: Int = 200
    /// Maximum false-positive rate allowed for promotion (1%).
    static let maxFPRateForPromotion: Float = 0.01
    /// Maximum false-negative rate allowed for promotion (5%).
    static let maxFNRateForPromotion: Float = 0.05

    // MARK: - Demotion thresholds

    /// False-positive rate threshold that triggers demotion (2%).
    static let demotionFPThreshold: Float = 0.02
    /// Rolling window size used for post-promotion false-positive monitoring.
    static let demotionWindowSize: Int = 50

    // MARK: - Public state

    /// Whether the acoustic detector has been promoted to primary.
    private(set) var isPromoted: Bool = false
    /// Total shadow-mode attempts recorded (both detectors ran).
    private(set) var totalAttempts: Int = 0
    /// Whether shadow-mode evaluation is currently paused.
    private(set) var isPaused: Bool = false

    // MARK: - Shadow-mode counters

    private var truePositives: Int = 0
    private var falsePositives: Int = 0
    private var falseNegatives: Int = 0
    private var trueNegatives: Int = 0

    // MARK: - Post-promotion monitoring

    private var demotionWindow: [Bool] = []

    // MARK: - Recording results

    /// Record a shadow-mode detection result from one utterance.
    ///
    /// Results are silently dropped while ``isPaused`` is `true`.
    /// - Parameters:
    ///   - acousticDetected: Whether the acoustic detector fired.
    ///   - textDetected: Whether the text-based detector fired (ground truth).
    func recordResult(acousticDetected: Bool, textDetected: Bool) {
        guard !isPaused else { return }

        if isPromoted {
            trackPostPromotionResult(acousticDetected: acousticDetected, textDetected: textDetected)
        } else {
            trackShadowModeResult(acousticDetected: acousticDetected, textDetected: textDetected)
        }
    }

    /// Pause shadow-mode evaluation (e.g., during thermal pressure).
    func pause() { isPaused = true }

    /// Resume shadow-mode evaluation after a pause.
    func resume() { isPaused = false }

    /// Current false-positive rate across all shadow-mode attempts.
    var falsePositiveRate: Float {
        let total = truePositives + falsePositives + trueNegatives + falseNegatives
        guard total > 0 else { return 0 }
        return Float(falsePositives) / Float(total)
    }

    /// Current false-negative rate relative to actual positive utterances.
    var falseNegativeRate: Float {
        let actual = truePositives + falseNegatives
        guard actual > 0 else { return 0 }
        return Float(falseNegatives) / Float(actual)
    }

    /// A snapshot of the evaluator's state for the Voice Diagnostics screen.
    struct DiagnosticsSummary {
        /// Whether the acoustic detector has been promoted to primary.
        let isPromoted: Bool
        /// Whether evaluation is currently paused.
        let isPaused: Bool
        /// Total shadow-mode attempts recorded.
        let totalAttempts: Int
        /// False-positive rate across all shadow-mode attempts.
        let falsePositiveRate: Float
        /// False-negative rate relative to actual positive utterances.
        let falseNegativeRate: Float
        /// Count of utterances where both detectors fired.
        let truePositives: Int
        /// Count of utterances where acoustic fired but text did not.
        let falsePositives: Int
        /// Count of utterances where neither detector fired.
        let trueNegatives: Int
        /// Count of utterances where text fired but acoustic did not.
        let falseNegatives: Int
    }

    /// Return a snapshot of current diagnostics.
    var diagnostics: DiagnosticsSummary {
        DiagnosticsSummary(
            isPromoted: isPromoted, isPaused: isPaused,
            totalAttempts: totalAttempts,
            falsePositiveRate: falsePositiveRate, falseNegativeRate: falseNegativeRate,
            truePositives: truePositives, falsePositives: falsePositives,
            trueNegatives: trueNegatives, falseNegatives: falseNegatives
        )
    }

    // MARK: - Private

    private func trackShadowModeResult(acousticDetected: Bool, textDetected: Bool) {
        totalAttempts += 1
        switch (acousticDetected, textDetected) {
        case (true, true):   truePositives += 1
        case (true, false):  falsePositives += 1
        case (false, true):  falseNegatives += 1
        case (false, false): trueNegatives += 1
        }
        checkPromotion()
    }

    private func trackPostPromotionResult(acousticDetected: Bool, textDetected: Bool) {
        let isFP = acousticDetected && !textDetected
        demotionWindow.append(isFP)
        if demotionWindow.count > Self.demotionWindowSize {
            demotionWindow.removeFirst()
        }
        if demotionWindow.count >= Self.demotionWindowSize {
            checkDemotion()
        }
    }

    private func checkPromotion() {
        guard totalAttempts >= Self.minAttemptsForPromotion else { return }
        let fpRate = computePromotionFPRate()
        let fnRate = falseNegativeRate
        if fpRate <= Self.maxFPRateForPromotion && fnRate <= Self.maxFNRateForPromotion {
            isPromoted = true
        }
    }

    private func computePromotionFPRate() -> Float {
        let denominator = falsePositives + trueNegatives + truePositives
        guard denominator > 0 else { return 0 }
        return Float(falsePositives) / Float(denominator)
    }

    private func checkDemotion() {
        let fpCount = demotionWindow.filter { $0 }.count
        let fpRate = Float(fpCount) / Float(demotionWindow.count)
        guard fpRate > Self.demotionFPThreshold else { return }
        isPromoted = false
        demotionWindow.removeAll()
        totalAttempts = 0
        truePositives = 0
        falsePositives = 0
        falseNegatives = 0
        trueNegatives = 0
    }
}
