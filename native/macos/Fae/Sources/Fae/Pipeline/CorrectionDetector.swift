import Foundation

/// Detects when a user is correcting Fae in natural speech.
///
/// All pattern matching is generic — no personal data in source.
/// Detected corrections are stored as memory records via ``MemoryOrchestrator``.
///
/// Patterns recognised:
/// - **Name errors**: "my name is X not Y", "it's X not Y", "wrong name"
/// - **Mishearings**: "I said X", "no I said", "you misheard"
/// - **Interruptions**: "you interrupted me", "I wasn't finished", "let me finish"
/// - **Wrong actions**: "that was wrong", "that's not what I meant", "undo that"
enum CorrectionDetector {

    /// The kind of correction the user is making.
    enum CorrectionKind: String, Sendable, Equatable {
        case nameError
        case interruption
        case mishearing
        case wrongAction
    }

    /// A detected correction from user speech.
    struct Correction: Sendable, Equatable {
        /// What type of correction this is.
        let kind: CorrectionKind
        /// The value the user is correcting TO (e.g. the correct name), if parseable.
        let correctedValue: String?
        /// The value the user is correcting FROM (e.g. the wrong name), if parseable.
        let originalValue: String?
        /// The raw transcription text that triggered detection.
        let rawText: String
    }

    /// Detect a correction in the user's transcription.
    ///
    /// - Parameters:
    ///   - text: The user's transcription.
    ///   - lastAssistantText: The most recent assistant response (for context correlation).
    /// - Returns: A ``Correction`` if one is detected, or `nil`.
    static func detect(in text: String, lastAssistantText: String? = nil) -> Correction? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Very short text is unlikely to be a meaningful correction.
        guard lower.count >= 5 else { return nil }

        // --- Name error patterns ---

        // "my name is X not Y" / "my name is X, not Y"
        if let match = nameIsNotPattern(lower) {
            return Correction(
                kind: .nameError,
                correctedValue: match.correct,
                originalValue: match.wrong,
                rawText: text
            )
        }

        // "it's X not Y" / "it's X, not Y"
        if let match = itsNotPattern(lower) {
            return Correction(
                kind: .nameError,
                correctedValue: match.correct,
                originalValue: match.wrong,
                rawText: text
            )
        }

        // "wrong name" / "you got my name wrong"
        let wrongNamePhrases = ["wrong name", "got my name wrong", "that's not my name",
                                "that is not my name"]
        for phrase in wrongNamePhrases {
            if lower.contains(phrase) {
                return Correction(kind: .nameError, correctedValue: nil,
                                  originalValue: nil, rawText: text)
            }
        }

        // --- Mishearing patterns ---

        // "no I said X" / "I said X not Y"
        if let match = iSaidPattern(lower) {
            return Correction(
                kind: .mishearing,
                correctedValue: match.correct,
                originalValue: match.wrong,
                rawText: text
            )
        }

        let mishearingPhrases = ["you misheard", "you heard wrong", "that's not what i said",
                                 "that is not what i said", "listen more carefully"]
        for phrase in mishearingPhrases {
            if lower.contains(phrase) {
                return Correction(kind: .mishearing, correctedValue: nil,
                                  originalValue: nil, rawText: text)
            }
        }

        // --- Interruption patterns ---

        let interruptionPhrases = ["you interrupted me", "i wasn't finished",
                                    "i was not finished", "let me finish",
                                    "don't interrupt", "do not interrupt",
                                    "i wasn't done", "i was not done",
                                    "stop interrupting"]
        for phrase in interruptionPhrases {
            if lower.contains(phrase) {
                return Correction(kind: .interruption, correctedValue: nil,
                                  originalValue: nil, rawText: text)
            }
        }

        // --- Wrong action patterns ---

        let wrongActionPhrases = ["that was wrong", "that's not what i meant",
                                   "that is not what i meant", "not what i asked",
                                   "undo that", "that's not right", "that is not right",
                                   "you did the wrong thing", "that's incorrect",
                                   "that is incorrect"]
        for phrase in wrongActionPhrases {
            if lower.contains(phrase) {
                return Correction(kind: .wrongAction, correctedValue: nil,
                                  originalValue: nil, rawText: text)
            }
        }

        return nil
    }

    // MARK: - Pattern Helpers

    /// Match "my name is X not Y" or "my name is X, not Y".
    private static func nameIsNotPattern(_ lower: String) -> (correct: String, wrong: String?)? {
        // Pattern: "my name is <correct> not <wrong>"
        guard let nameIsRange = lower.range(of: "my name is ") else { return nil }
        let afterNameIs = lower[nameIsRange.upperBound...]

        // Look for "not" separator.
        if let notRange = afterNameIs.range(of: " not ") {
            let correct = String(afterNameIs[afterNameIs.startIndex..<notRange.lowerBound])
                .trimmingCharacters(in: .punctuationCharacters)
                .trimmingCharacters(in: .whitespaces)
            let wrong = String(afterNameIs[notRange.upperBound...])
                .trimmingCharacters(in: .punctuationCharacters)
                .trimmingCharacters(in: .whitespaces)
            guard !correct.isEmpty else { return nil }
            let capitalCorrect = capitalizeFirst(correct)
            guard isPlausibleName(capitalCorrect) else { return nil }
            return (correct: capitalCorrect, wrong: wrong.isEmpty ? nil : capitalizeFirst(wrong))
        }

        // No "not" — just "my name is X"
        let correct = String(afterNameIs)
            .trimmingCharacters(in: .punctuationCharacters)
            .trimmingCharacters(in: .whitespaces)
        guard !correct.isEmpty else { return nil }
        let capitalCorrect = capitalizeFirst(correct)
        guard isPlausibleName(capitalCorrect) else { return nil }
        return (correct: capitalCorrect, wrong: nil)
    }

    /// Match "it's X not Y" or "it's X, not Y".
    private static func itsNotPattern(_ lower: String) -> (correct: String, wrong: String?)? {
        let prefixes = ["it's ", "its ", "it is "]
        for prefix in prefixes {
            guard let prefixRange = lower.range(of: prefix) else { continue }
            let afterPrefix = lower[prefixRange.upperBound...]
            guard let notRange = afterPrefix.range(of: " not ") else { continue }

            let correct = String(afterPrefix[afterPrefix.startIndex..<notRange.lowerBound])
                .trimmingCharacters(in: .punctuationCharacters)
                .trimmingCharacters(in: .whitespaces)
            let wrong = String(afterPrefix[notRange.upperBound...])
                .trimmingCharacters(in: .punctuationCharacters)
                .trimmingCharacters(in: .whitespaces)
            guard !correct.isEmpty else { continue }
            let capitalCorrect = capitalizeFirst(correct)
            guard isPlausibleName(capitalCorrect) else { continue }
            return (correct: capitalCorrect, wrong: wrong.isEmpty ? nil : capitalizeFirst(wrong))
        }
        return nil
    }

    /// Match "I said X" / "no I said X" / "I said X not Y".
    private static func iSaidPattern(_ lower: String) -> (correct: String, wrong: String?)? {
        guard let saidRange = lower.range(of: "i said ") else { return nil }
        let afterSaid = lower[saidRange.upperBound...]
        guard !afterSaid.isEmpty else { return nil }

        if let notRange = afterSaid.range(of: " not ") {
            let correct = String(afterSaid[afterSaid.startIndex..<notRange.lowerBound])
                .trimmingCharacters(in: .punctuationCharacters)
                .trimmingCharacters(in: .whitespaces)
            let wrong = String(afterSaid[notRange.upperBound...])
                .trimmingCharacters(in: .punctuationCharacters)
                .trimmingCharacters(in: .whitespaces)
            guard !correct.isEmpty else { return nil }
            let capitalCorrect = capitalizeFirst(correct)
            guard isPlausibleName(capitalCorrect) else { return nil }
            return (correct: capitalCorrect, wrong: wrong.isEmpty ? nil : capitalizeFirst(wrong))
        }

        let correct = String(afterSaid)
            .trimmingCharacters(in: .punctuationCharacters)
            .trimmingCharacters(in: .whitespaces)
        guard !correct.isEmpty else { return nil }
        let capitalCorrect = capitalizeFirst(correct)
        guard isPlausibleName(capitalCorrect) else { return nil }
        return (correct: capitalCorrect, wrong: nil)
    }

    /// Capitalize the first character of a string.
    static func capitalizeFirst(_ str: String) -> String {
        guard let first = str.first else { return str }
        return first.uppercased() + str.dropFirst()
    }

    /// Whether a string looks plausible as a person's name.
    /// Rejects strings that are too long, contain common non-name words,
    /// or have punctuation beyond hyphens and apostrophes.
    static func isPlausibleName(_ candidate: String) -> Bool {
        guard candidate.count >= 2, candidate.count <= 25 else { return false }
        let nonNameWords: Set<String> = [
            "peer", "the", "and", "to", "is", "it", "just", "like",
            "using", "need", "think", "not", "but", "for", "with",
            "this", "that", "what", "how", "why", "when", "where",
            "does", "kind", "really", "actually", "also", "very",
            "about", "right", "wrong", "good", "bad", "here", "there",
        ]
        let words = candidate.lowercased().split(separator: " ").map(String.init)
        for word in words where nonNameWords.contains(word) { return false }
        let allowed = CharacterSet.letters
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "-'"))
        if candidate.unicodeScalars.contains(where: { !allowed.contains($0) }) { return false }
        return true
    }
}

/// A correction record with full context for memory storage.
struct CorrectionRecord: Sendable {
    /// The detected correction.
    let correction: CorrectionDetector.Correction
    /// What Fae last said (may have triggered the correction).
    let lastAssistantText: String?
    /// The speaker label at the time of correction.
    let speakerLabel: String?
    /// When the correction was detected.
    let timestamp: Date

    /// Build a human-readable memory text for this correction.
    var memoryText: String {
        var parts: [String] = []

        switch correction.kind {
        case .nameError:
            if let correct = correction.correctedValue, let wrong = correction.originalValue {
                parts.append("User corrected a name: their name is \(correct), not \(wrong).")
            } else if let correct = correction.correctedValue {
                parts.append("User corrected a name: their name is \(correct).")
            } else {
                parts.append("User indicated a name was incorrect.")
            }
        case .mishearing:
            if let correct = correction.correctedValue {
                parts.append("User corrected a mishearing: they actually said \"\(correct)\".")
            } else {
                parts.append("User indicated they were misheard.")
            }
        case .interruption:
            parts.append("User felt interrupted and asked to be allowed to finish speaking.")
        case .wrongAction:
            parts.append("User indicated the last action or response was wrong.")
        }

        return parts.joined(separator: " ")
    }

    /// The ``MemoryKind`` to use when storing this correction.
    var memoryKind: MemoryKind {
        switch correction.kind {
        case .nameError:
            return .profile
        case .interruption, .mishearing, .wrongAction:
            return .episode
        }
    }

    /// Tags for the memory record.
    var memoryTags: [String] {
        var tags = ["correction", correction.kind.rawValue]
        if correction.correctedValue != nil { tags.append("has_corrected_value") }
        return tags
    }
}
