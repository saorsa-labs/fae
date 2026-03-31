import Foundation

/// Detects low-confidence ASR transcriptions by tracking spelling divergence
/// across recent utterances.
///
/// When the ASR transcribes the same word differently in successive utterances
/// (e.g. "Seamus" then "Shaimus" then "Shamus"), this signals the model is
/// uncertain about the correct spelling. The detector flags these for potential
/// correction prompts ("Could you type that name for me?").
///
/// Thread-safe via actor isolation.
actor ASRConfidenceDetector {

    /// A word that the ASR is uncertain about.
    struct UncertainWord: Sendable, Equatable {
        /// The various spellings the ASR has produced.
        let variants: [String]
        /// The approximate phonetic cluster these belong to.
        let cluster: String
        /// How many times divergent spellings appeared.
        let divergenceCount: Int
    }

    /// Recent transcriptions for divergence analysis (circular buffer).
    private var recentTranscriptions: [String] = []
    private let maxRecent = 20

    /// Words already flagged in this conversation (max once per conversation per cluster).
    private var flaggedClusters: Set<String> = []

    /// Maximum number of correction prompts per conversation.
    private let maxPromptsPerConversation = 1

    /// Number of prompts already issued this conversation.
    private var promptsIssued = 0

    // MARK: - Public API

    /// Record a new transcription and check for spelling divergence.
    ///
    /// - Parameter text: The latest ASR transcription.
    /// - Returns: An uncertain word if divergence is detected and a prompt is warranted, nil otherwise.
    func recordAndDetect(_ text: String) -> UncertainWord? {
        // Add to recent buffer.
        recentTranscriptions.append(text)
        if recentTranscriptions.count > maxRecent {
            recentTranscriptions.removeFirst()
        }

        // Need at least 3 transcriptions to detect divergence.
        guard recentTranscriptions.count >= 3 else { return nil }

        // Don't issue more prompts than allowed per conversation.
        guard promptsIssued < maxPromptsPerConversation else { return nil }

        // Extract words from all recent transcriptions and find divergent clusters.
        let allWords = recentTranscriptions.flatMap { extractWords($0) }
        let clusters = findDivergentClusters(allWords)

        for cluster in clusters {
            let clusterKey = cluster.cluster
            guard !flaggedClusters.contains(clusterKey) else { continue }
            guard cluster.divergenceCount >= 2 else { continue }

            flaggedClusters.insert(clusterKey)
            promptsIssued += 1
            return cluster
        }

        return nil
    }

    /// Reset state for a new conversation.
    func resetForNewConversation() {
        recentTranscriptions.removeAll()
        flaggedClusters.removeAll()
        promptsIssued = 0
    }

    /// Whether a correction prompt can still be issued this conversation.
    var canPrompt: Bool {
        promptsIssued < maxPromptsPerConversation
    }

    // MARK: - Analysis

    /// Extract proper-name-like words (capitalised, 3+ chars) from text.
    private func extractWords(_ text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { word in
                guard word.count >= 3 else { return false }
                guard let first = word.first, first.isUppercase else { return false }
                // Skip common words.
                return !Self.commonWords.contains(word.lowercased())
            }
    }

    /// Find clusters of words that sound similar but are spelled differently.
    private func findDivergentClusters(_ words: [String]) -> [UncertainWord] {
        // Group words by their phonetic key (simplified).
        var clusters: [String: [String]] = [:]

        for word in words {
            let key = phoneticKey(word)
            if clusters[key] == nil {
                clusters[key] = []
            }
            let lower = word.lowercased()
            if clusters[key]?.contains(where: { $0.lowercased() == lower }) == false {
                clusters[key]?.append(word)
            }
        }

        // Clusters with 2+ distinct spellings indicate uncertainty.
        return clusters.compactMap { key, variants in
            guard variants.count >= 2 else { return nil }
            return UncertainWord(
                variants: variants,
                cluster: key,
                divergenceCount: variants.count
            )
        }
        .sorted { $0.divergenceCount > $1.divergenceCount }
    }

    /// Generate a simplified phonetic key for clustering similar-sounding words.
    ///
    /// This is a lightweight phonetic hash — not a full Soundex/Metaphone but
    /// sufficient for detecting ASR spelling divergence.
    private func phoneticKey(_ word: String) -> String {
        var key = word.lowercased()

        // Normalise common phonetic equivalences.
        let replacements: [(String, String)] = [
            ("ph", "f"), ("ck", "k"), ("gh", "g"),
            ("sh", "s"), ("ch", "k"), ("th", "t"),
            ("oo", "u"), ("ee", "i"), ("ea", "i"),
            ("ai", "a"), ("ay", "a"), ("ei", "a"),
            ("ey", "a"), ("ie", "i"), ("oe", "o"),
        ]
        for (from, to) in replacements {
            key = key.replacingOccurrences(of: from, with: to)
        }

        // Remove doubled consonants.
        var deduped = ""
        var lastChar: Character?
        for char in key {
            if char != lastChar || char.isVowel {
                deduped.append(char)
            }
            lastChar = char
        }

        return deduped
    }

    /// Common English words that should not be flagged.
    private static let commonWords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "all", "can",
        "had", "her", "was", "one", "our", "out", "day", "get", "has",
        "him", "his", "how", "its", "let", "may", "new", "now", "old",
        "see", "way", "who", "boy", "did", "got", "just", "too",
        "yes", "say", "she", "use", "hey", "fae", "that", "this",
        "with", "have", "from", "they", "been", "call", "come",
        "could", "make", "like", "look", "what", "when", "will",
    ]
}

private extension Character {
    /// Whether this character is a vowel.
    var isVowel: Bool {
        "aeiou".contains(self.lowercased())
    }
}
