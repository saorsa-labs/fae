// KeywordSpotter.swift
// Fae
//
// Monitors streaming STT partial transcripts for interrupt phrases and wake words.
// Designed to run on the fast path of the dual-path STT architecture.

import Foundation

// MARK: - Keyword Match

/// A detected keyword match from the streaming transcript.
public struct KeywordMatch: Sendable {
    public let category: KeywordCategory
    public let matchedPhrase: String
    public let configuredKeyword: String
    public let transcript: String
    public let isFuzzy: Bool
    public let detectedAt: Date

    public init(
        category: KeywordCategory,
        matchedPhrase: String,
        configuredKeyword: String,
        transcript: String,
        isFuzzy: Bool,
        detectedAt: Date = Date()
    ) {
        self.category = category
        self.matchedPhrase = matchedPhrase
        self.configuredKeyword = configuredKeyword
        self.transcript = transcript
        self.isFuzzy = isFuzzy
        self.detectedAt = detectedAt
    }
}

/// Category of detected keyword.
public enum KeywordCategory: String, Sendable {
    case interrupt
    case wake
}

// MARK: - Keyword Spotter

/// Watches streaming partial transcripts for configured keywords.
///
/// The spotter normalises each partial transcript and checks against
/// the configured keyword lists. When a keyword is found, it reports
/// a `KeywordMatch` via the callback.
public actor KeywordSpotter {
    private var config: KeywordBiasConfig
    public var onKeywordDetected: (@Sendable (KeywordMatch) async -> Void)?

    private var lastCheckedTranscript: String = ""
    private var detectedInCurrentSegment: Set<String> = []
    private var normalisedInterruptPhrases: [String] = []
    private var normalisedWakePhrases: [String] = []

    public init(config: KeywordBiasConfig = .default) {
        self.config = config
        self.normalisedInterruptPhrases = config.interruptPhrases.map {
            config.caseInsensitive ? $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.normalisedWakePhrases = config.wakePhrases.map {
            config.caseInsensitive ? $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public func updateConfig(_ config: KeywordBiasConfig) {
        self.config = config
        rebuildNormalisedPhrases()
    }

    /// Check a partial transcript for keywords.
    @discardableResult
    public func check(
        partialTranscript: String,
        confidence: Float? = nil
    ) async -> KeywordMatch? {
        if let confidence, config.minimumConfidence > 0, confidence < config.minimumConfidence {
            return nil
        }

        let normalised = normalise(partialTranscript)
        guard !normalised.isEmpty else { return nil }

        let searchText: String
        if normalised.hasPrefix(lastCheckedTranscript), normalised.count > lastCheckedTranscript.count {
            let startIndex = normalised.index(normalised.startIndex, offsetBy: lastCheckedTranscript.count)
            searchText = String(normalised[startIndex...])
        } else if normalised != lastCheckedTranscript {
            searchText = normalised
            detectedInCurrentSegment.removeAll()
        } else {
            return nil
        }

        lastCheckedTranscript = normalised

        // Check interrupt phrases first (higher priority)
        if let match = findKeyword(
            in: searchText, fullTranscript: normalised,
            keywords: normalisedInterruptPhrases,
            originalKeywords: config.interruptPhrases,
            category: .interrupt
        ) {
            await onKeywordDetected?(match)
            return match
        }

        if let match = findKeyword(
            in: searchText, fullTranscript: normalised,
            keywords: normalisedWakePhrases,
            originalKeywords: config.wakePhrases,
            category: .wake
        ) {
            await onKeywordDetected?(match)
            return match
        }

        return nil
    }

    /// Set the keyword detection callback. Used by tests and pipeline wiring.
    public func setCallback(_ handler: @escaping @Sendable (KeywordMatch) async -> Void) {
        onKeywordDetected = handler
    }

    public func reset() {
        lastCheckedTranscript = ""
        detectedInCurrentSegment.removeAll()
    }

    // MARK: - Private

    private func rebuildNormalisedPhrases() {
        normalisedInterruptPhrases = config.interruptPhrases.map { normalise($0) }
        normalisedWakePhrases = config.wakePhrases.map { normalise($0) }
    }

    private func normalise(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if config.caseInsensitive { result = result.lowercased() }
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return result
    }

    private func findKeyword(
        in searchText: String, fullTranscript: String,
        keywords: [String], originalKeywords: [String],
        category: KeywordCategory
    ) -> KeywordMatch? {
        for (index, keyword) in keywords.enumerated() {
            guard !detectedInCurrentSegment.contains(keyword) else { continue }

            if containsWholePhrase(searchText, phrase: keyword) {
                detectedInCurrentSegment.insert(keyword)
                return KeywordMatch(
                    category: category, matchedPhrase: keyword,
                    configuredKeyword: originalKeywords[index],
                    transcript: fullTranscript, isFuzzy: false
                )
            }

            if config.fuzzyMatching,
               let fuzzyMatch = fuzzyContains(searchText, phrase: keyword, category: category)
            {
                detectedInCurrentSegment.insert(keyword)
                return KeywordMatch(
                    category: category, matchedPhrase: fuzzyMatch,
                    configuredKeyword: originalKeywords[index],
                    transcript: fullTranscript, isFuzzy: true
                )
            }
        }
        return nil
    }

    private func containsWholePhrase(_ text: String, phrase: String) -> Bool {
        if phrase.contains(" ") {
            return text.contains(phrase)
        }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: phrase))\\b"
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private func fuzzyContains(_ text: String, phrase: String, category: KeywordCategory) -> String? {
        // Interrupt phrases use strict fuzzy matching (distance 1 only) because
        // false positives are catastrophic — they reset the conversation.
        // e.g. "channel" was matching "cancel" at distance 2, killing sessions.
        // Wake words can tolerate distance 2 since a false positive just
        // activates attention rather than destroying state.
        let maxDistance: Int
        switch category {
        case .interrupt:
            maxDistance = 1
        case .wake:
            maxDistance = phrase.count <= 5 ? 1 : 2
        }
        guard !phrase.contains(" ") else { return nil }

        let words = text.components(separatedBy: .whitespaces)
        for word in words where !word.isEmpty {
            let distance = levenshteinDistance(word, phrase)
            if distance <= maxDistance && distance > 0 {
                return word
            }
        }
        return nil
    }

    /// Levenshtein edit distance. O(n*m) time, O(min(n,m)) space.
    nonisolated internal func levenshteinDistance(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let n = aChars.count
        let m = bChars.count

        if n == 0 { return m }
        if m == 0 { return n }

        var previousRow = Array(0...m)
        var currentRow = [Int](repeating: 0, count: m + 1)

        for i in 1...n {
            currentRow[0] = i
            for j in 1...m {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                currentRow[j] = min(
                    previousRow[j] + 1,
                    currentRow[j - 1] + 1,
                    previousRow[j - 1] + cost
                )
            }
            swap(&previousRow, &currentRow)
        }
        return previousRow[m]
    }
}
