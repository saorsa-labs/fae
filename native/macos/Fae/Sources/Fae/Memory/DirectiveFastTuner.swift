import Foundation

// MARK: - PatternType

/// The type of behavioral pattern detected in accumulated feedback.
enum PatternType: String, Sendable, CaseIterable {
    /// User frequently asked for shorter responses.
    case verbosityTooHigh
    /// User frequently asked for more detail or expanded explanations.
    case verbosityTooLow
    /// User corrected Fae's tone (too formal, too casual, etc.).
    case toneMismatch
    /// User frequently asked to use a specific tool (e.g., "use the calendar").
    case toolUnderutilized
    /// User frequently re-asked the same type of question.
    case systematicMisunderstanding
}

// MARK: - DetectedPattern

/// A behavioral pattern identified from accumulated feedback events.
struct DetectedPattern: Sendable {
    /// The type of pattern.
    let type: PatternType
    /// Number of feedback events supporting this pattern.
    let evidenceCount: Int
    /// Confidence: 0.0 – 1.0
    let confidence: Double
    /// Brief human-readable description.
    let description: String
    /// Suggested directive amendment to address this pattern.
    let suggestedAmendment: String
}

// MARK: - TuningResult

/// Result of a fast-tuning pass.
struct TuningResult: Sendable {
    /// Patterns detected from feedback analysis.
    let patterns: [DetectedPattern]
    /// Amendments that were appended to directive.md.
    let appliedAmendments: [String]
    /// ISO-8601 timestamp of the tuning pass.
    let tunedAt: String
    /// Previous directive content (for rollback).
    let previousDirective: String?
}

// MARK: - DirectiveFastTunerError

enum DirectiveFastTunerError: Error, Sendable {
    /// No feedback events were available for analysis.
    case noFeedbackData
    /// The directive could not be read or written.
    case directiveIOError(reason: String)
}

// MARK: - DirectiveFastTuner

/// Performs directive-based fast tuning from accumulated feedback patterns.
///
/// `DirectiveFastTuner` runs as a weekly sub-phase of the improvement cycle
/// (every 7th nightly cycle). Rather than triggering a full mlx-tune training
/// run, it analyses feedback patterns and generates targeted amendments to
/// `directive.md` that take effect immediately on the next conversation.
///
/// ## Process
/// 1. Load consumed and unconsumed feedback events from `ImprovementStore`.
/// 2. Run pattern detectors to find behavioral issues.
/// 3. Generate directive amendments for each high-confidence pattern.
/// 4. Append amendments to `directive.md` via the provided writer closure.
/// 5. Store the previous directive for rollback.
///
/// ## Rollback
/// Call `rollback(to:)` with the `previousDirective` from a `TuningResult`
/// to restore the directive to its pre-tuning state.
///
/// ## Testing
/// Inject a `directiveReader` and `directiveWriter` that operate on a temp
/// file, and a `feedbackLoader` that returns mock events.
actor DirectiveFastTuner {

    // MARK: - Configuration

    /// Minimum number of feedback events required to run a pattern analysis.
    static let minimumFeedbackEvents = 10

    /// Minimum confidence threshold for applying a directive amendment.
    static let minimumConfidenceForApplication: Double = 0.70

    /// Minimum evidence count for a pattern to be considered significant.
    static let minimumEvidenceCount = 3

    // MARK: - Dependencies (injectable for testing)

    /// Reads the current directive.md content.
    var directiveReader: (() throws -> String?)?

    /// Writes/appends content to directive.md.
    var directiveWriter: ((_ content: String, _ append: Bool) throws -> Void)?

    /// Loads feedback events for analysis.
    var feedbackLoader: (() throws -> [FeedbackEvent])?

    // MARK: - Init / Configuration

    /// Set the directive reader. Called by tests or FaeCore.
    func setDirectiveReader(_ reader: @escaping () throws -> String?) {
        directiveReader = reader
    }

    /// Set the directive writer. Called by tests or FaeCore.
    func setDirectiveWriter(_ writer: @escaping (_ content: String, _ append: Bool) throws -> Void) {
        directiveWriter = writer
    }

    /// Set the feedback loader. Called by tests or FaeCore.
    func setFeedbackLoader(_ loader: @escaping () throws -> [FeedbackEvent]) {
        feedbackLoader = loader
    }

    // MARK: - Main Entry Point

    /// Run a directive fast-tuning pass.
    ///
    /// Analyses recent feedback events, detects behavioral patterns, and applies
    /// directive amendments for high-confidence patterns.
    ///
    /// - Returns: A `TuningResult` with detected patterns and applied amendments.
    /// - Throws: `DirectiveFastTunerError.noFeedbackData` if there are fewer than
    ///   `minimumFeedbackEvents` events available.
    func runFastTuning() throws -> TuningResult {
        guard let loader = feedbackLoader else {
            throw DirectiveFastTunerError.noFeedbackData
        }

        let events = try loader()
        guard events.count >= Self.minimumFeedbackEvents else {
            throw DirectiveFastTunerError.noFeedbackData
        }

        // Detect patterns.
        let patterns = detectPatterns(from: events)

        // Read current directive for rollback.
        let previousDirective = try directiveReader?()

        // Apply high-confidence amendments.
        var appliedAmendments: [String] = []
        for pattern in patterns where
            pattern.confidence >= Self.minimumConfidenceForApplication &&
            pattern.evidenceCount >= Self.minimumEvidenceCount
        {
            let amendment = pattern.suggestedAmendment
            try directiveWriter?(amendment, true) // append = true
            appliedAmendments.append(amendment)
            NSLog(
                "DirectiveFastTuner: applied amendment for %@ (confidence: %.2f)",
                pattern.type.rawValue, pattern.confidence
            )
        }

        NSLog(
            "DirectiveFastTuner: analysed %d events, detected %d patterns, applied %d amendments",
            events.count, patterns.count, appliedAmendments.count
        )

        return TuningResult(
            patterns: patterns,
            appliedAmendments: appliedAmendments,
            tunedAt: ISO8601DateFormatter().string(from: Date()),
            previousDirective: previousDirective
        )
    }

    /// Roll back directive to a previous state.
    ///
    /// - Parameter previous: The directive content to restore (from `TuningResult.previousDirective`).
    func rollback(to previous: String?) throws {
        let content = previous ?? ""
        try directiveWriter?(content, false) // append = false (overwrite)
        NSLog("DirectiveFastTuner: directive rolled back to previous state (%d chars)", content.count)
    }

    // MARK: - Pattern Detection

    /// Detect behavioral patterns from feedback events.
    func detectPatterns(from events: [FeedbackEvent]) -> [DetectedPattern] {
        var patterns: [DetectedPattern] = []

        // 1. Verbosity too high: repeated re-asks suggesting response was too long/complex.
        let reasks = events.filter { $0.signalType == "re_ask" }
        if reasks.count >= 2 {
            let confidence = min(Double(reasks.count) / 10.0, 0.95)
            patterns.append(DetectedPattern(
                type: .verbosityTooHigh,
                evidenceCount: reasks.count,
                confidence: confidence,
                description: "User re-asked \(reasks.count) times — responses may be too complex",
                suggestedAmendment: "\n[auto-tuned: be more concise, prefer short direct answers over lengthy explanations]"
            ))
        }

        // 2. Interruptions: user consistently barged-in.
        let interruptions = events.filter { $0.signalType == "interruption" }
        if interruptions.count >= 2 {
            let confidence = min(Double(interruptions.count) / 8.0, 0.90)
            patterns.append(DetectedPattern(
                type: .verbosityTooHigh,
                evidenceCount: interruptions.count,
                confidence: confidence,
                description: "User interrupted \(interruptions.count) times — responses may be too long",
                suggestedAmendment: "\n[auto-tuned: keep responses shorter, user prefers concise replies]"
            ))
        }

        // 3. Systematic corrections: user frequently corrected Fae.
        let corrections = events.filter { $0.signalType == "correction" }
        if corrections.count >= 3 {
            let confidence = min(Double(corrections.count) / 8.0, 0.85)
            patterns.append(DetectedPattern(
                type: .systematicMisunderstanding,
                evidenceCount: corrections.count,
                confidence: confidence,
                description: "User corrected Fae \(corrections.count) times — recurring misunderstanding",
                suggestedAmendment: "\n[auto-tuned: pay closer attention to user phrasing, confirm understanding before acting]"
            ))
        }

        // 4. Topic abandonment: user frequently dropped topics.
        let abandonments = events.filter { $0.signalType == "abandonment" }
        if abandonments.count >= 2 {
            let confidence = min(Double(abandonments.count) / 6.0, 0.80)
            patterns.append(DetectedPattern(
                type: .toneMismatch,
                evidenceCount: abandonments.count,
                confidence: confidence,
                description: "User abandoned \(abandonments.count) topics — responses may not address user's actual need",
                suggestedAmendment: "\n[auto-tuned: clarify ambiguous requests before responding at length]"
            ))
        }

        return patterns
    }
}
