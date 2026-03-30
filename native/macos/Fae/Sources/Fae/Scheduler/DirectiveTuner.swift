import Foundation

// MARK: - FeedbackPattern

/// A pattern detected in accumulated feedback events.
///
/// Each pattern represents a recurring signal that can be translated into a
/// directive amendment to immediately improve Fae's behaviour.
struct FeedbackPattern: Sendable {
    /// The type of pattern detected.
    let patternType: PatternType

    /// How many times this pattern was observed.
    let frequency: Int

    /// A brief excerpt from the events that evidences this pattern.
    let sampleEvidence: String

    /// The suggested directive amendment text.
    let suggestedAmendment: String

    /// Known pattern categories.
    enum PatternType: String, Sendable {
        /// The same correction was made more than 3 times.
        case repeatedCorrection = "repeated_correction"
        /// The user re-asked similar questions more than 5 times.
        case persistentReask = "persistent_reask"
        /// 3+ abandonments on similar topics.
        case abandonmentCluster = "abandonment_cluster"
        /// Praise patterns indicating preferred style.
        case stylePreference = "style_preference"
    }
}

// MARK: - DirectiveTuner

/// Detects recurring feedback patterns and generates directive amendments.
///
/// This is the "fast tuning" path: instead of training a LoRA adapter (slow, overnight),
/// the tuner writes a directive amendment that takes effect on the next conversation turn.
///
/// ## Usage
/// ```swift
/// let patterns = DirectiveTuner.detectPatterns(events: feedbackEvents)
/// if let amendment = DirectiveTuner.generateAmendment(patterns: patterns) {
///     let updated = DirectiveTuner.applyAmendment(amendment: amendment, currentDirective: existing)
///     // Write `updated` to directive.md
/// }
/// ```
enum DirectiveTuner {

    // MARK: - Configuration

    /// Minimum occurrences of a correction with the same content to form a pattern.
    static let minRepeatedCorrections = 3

    /// Minimum occurrences of re_ask signals to form a pattern.
    static let minPersistentReasks = 5

    /// Minimum abandonment events on similar topics to form a cluster.
    static let minAbandonmentCluster = 3

    /// Minimum praise events to detect a style preference.
    static let minPraiseEvents = 3

    /// Maximum length of the full directive after amendment (characters).
    static let maxDirectiveLength = 2000

    // MARK: - Pattern Detection

    /// Analyze feedback events and return detected patterns.
    ///
    /// Groups events by signal type, then applies pattern-specific heuristics
    /// to identify recurring issues or preferences.
    ///
    /// - Parameter events: Unconsumed feedback events from `ImprovementStore`.
    /// - Returns: Array of detected patterns (may be empty).
    static func detectPatterns(events: [FeedbackEvent]) -> [FeedbackPattern] {
        var patterns: [FeedbackPattern] = []

        let corrections = events.filter { $0.signalType == "correction" }
        let reasks = events.filter { $0.signalType == "re_ask" }
        let abandonments = events.filter { $0.signalType == "abandonment" }
        let praises = events.filter { $0.signalType == "praise" }

        // 1. Repeated corrections — group by user input content.
        let correctionGroups = groupByContent(corrections, keyPath: \.userInput)
        for (key, group) in correctionGroups where group.count >= minRepeatedCorrections {
            let evidence = group.first?.userInput ?? key
            patterns.append(FeedbackPattern(
                patternType: .repeatedCorrection,
                frequency: group.count,
                sampleEvidence: String(evidence.prefix(100)),
                suggestedAmendment: "When the user says something similar to \"\(String(key.prefix(60)))\", pay close attention — this correction has been made \(group.count) times."
            ))
        }

        // 2. Persistent re-asks — group by user input similarity.
        let reaskGroups = groupByContent(reasks, keyPath: \.userInput)
        for (key, group) in reaskGroups where group.count >= minPersistentReasks {
            let evidence = group.first?.userInput ?? key
            patterns.append(FeedbackPattern(
                patternType: .persistentReask,
                frequency: group.count,
                sampleEvidence: String(evidence.prefix(100)),
                suggestedAmendment: "The user frequently re-asks about \"\(String(key.prefix(60)))\". Provide more thorough, complete answers on this topic."
            ))
        }

        // 3. Abandonment clusters — group by assistant output topic.
        let abandonmentGroups = groupByContent(abandonments, keyPath: \.assistantOutput)
        for (key, group) in abandonmentGroups where group.count >= minAbandonmentCluster {
            let evidence = group.first?.assistantOutput ?? key
            patterns.append(FeedbackPattern(
                patternType: .abandonmentCluster,
                frequency: group.count,
                sampleEvidence: String(evidence.prefix(100)),
                suggestedAmendment: "Users tend to disengage when responses are about \"\(String(key.prefix(60)))\". Try a different approach or ask clarifying questions."
            ))
        }

        // 4. Style preferences from praise — extract common praise themes.
        if praises.count >= minPraiseEvents {
            let praiseTexts = praises.compactMap(\.userInput).filter { !$0.isEmpty }
            if !praiseTexts.isEmpty {
                let evidence = praiseTexts.first ?? ""
                patterns.append(FeedbackPattern(
                    patternType: .stylePreference,
                    frequency: praises.count,
                    sampleEvidence: String(evidence.prefix(100)),
                    suggestedAmendment: "The user responds positively to this interaction style. Continue using it."
                ))
            }
        }

        return patterns
    }

    // MARK: - Amendment Generation

    /// Generate a directive amendment from detected patterns.
    ///
    /// Returns `nil` if no patterns are strong enough to warrant a directive change.
    ///
    /// - Parameter patterns: Patterns detected by `detectPatterns`.
    /// - Returns: A formatted directive amendment string, or `nil`.
    static func generateAmendment(patterns: [FeedbackPattern]) -> String? {
        guard !patterns.isEmpty else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]
        let dateStr = iso.string(from: Date())

        var lines: [String] = ["## Auto-tuned (\(dateStr))"]

        // Sort by frequency descending, take top 3 patterns.
        let top = patterns.sorted { $0.frequency > $1.frequency }.prefix(3)

        for pattern in top {
            lines.append("- \(pattern.suggestedAmendment)")
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Amendment Application

    /// Append an amendment to the current directive, respecting the character limit.
    ///
    /// If appending would exceed `maxDirectiveLength`, the amendment is truncated.
    /// A separator line is added between existing content and the amendment.
    ///
    /// - Parameters:
    ///   - amendment: The amendment text to append.
    ///   - currentDirective: The existing directive content (may be `nil` or empty).
    /// - Returns: The updated directive text.
    static func applyAmendment(amendment: String, currentDirective: String?) -> String {
        let current = currentDirective ?? ""

        if current.isEmpty {
            return String(amendment.prefix(maxDirectiveLength))
        }

        let separator = "\n\n"
        let combined = current + separator + amendment

        if combined.count <= maxDirectiveLength {
            return combined
        }

        // Truncate to fit within limit.
        return String(combined.prefix(maxDirectiveLength))
    }

    // MARK: - Helpers

    /// Group events by a normalised key derived from a text field.
    ///
    /// Normalisation: lowercased, trimmed, first 50 characters. This groups
    /// events that are "about the same thing" without requiring semantic similarity.
    private static func groupByContent(
        _ events: [FeedbackEvent],
        keyPath: KeyPath<FeedbackEvent, String?>
    ) -> [String: [FeedbackEvent]] {
        var groups: [String: [FeedbackEvent]] = [:]
        for event in events {
            guard let text = event[keyPath: keyPath], !text.isEmpty else { continue }
            let key = normaliseGroupKey(text)
            groups[key, default: []].append(event)
        }
        return groups
    }

    /// Normalise text to a grouping key.
    static func normaliseGroupKey(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return String(trimmed.prefix(50))
    }
}
