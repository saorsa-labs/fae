import Foundation

/// Builds and applies dynamic post-ASR corrections from the user's known vocabulary.
///
/// Fae's STT engine (Qwen3-ASR) has no prompt conditioning or hot-word biasing,
/// so all name/vocabulary corrections happen post-transcription. This corrector
/// supplements the static "Fae" name corrections in `TextProcessing` with
/// dynamic entries sourced from:
///
/// - Owner/user name (from config + memory)
/// - Entity graph (persons, organisations, locations from memory)
/// - Speaker profiles (enrolled voice identities)
///
/// The corrector generates phonetic variants for each known name and applies
/// word-boundary-aware replacement after ASR output, before the LLM sees the text.
///
/// Thread-safe via actor isolation. Rebuilt periodically or on memory changes.
actor DynamicVocabularyCorrector {

    struct CorrectionEntry: Sendable {
        let pattern: String          // lowercased ASR garble to match
        let replacement: String      // correct form
        let source: String           // "owner", "entity", "speaker", "contact"
    }

    private var corrections: [CorrectionEntry] = []
    private var lastRebuildAt: Date?

    // MARK: - Public API

    /// Apply dynamic corrections to ASR output text.
    ///
    /// Runs after `TextProcessing.correctNameRecognition()` (which handles "Fae")
    /// and fixes other proper names the ASR model doesn't know about.
    func correct(_ text: String) -> String {
        guard !corrections.isEmpty else { return text }

        var result = text
        let lower = result.lowercased()

        for entry in corrections {
            guard let lowerRange = lower.range(of: entry.pattern) else { continue }

            // Verify word boundaries on the lowercased string.
            if lowerRange.lowerBound != lower.startIndex {
                let before = lower[lower.index(before: lowerRange.lowerBound)]
                if before.isLetter || before.isNumber { continue }
            }
            if lowerRange.upperBound != lower.endIndex {
                let after = lower[lowerRange.upperBound]
                if after.isLetter || after.isNumber { continue }
            }

            // Map the match range from `lower` back to `result` using position
            // correspondence (lowercasing preserves character positions and length).
            // We do this before any mutation so indices remain valid.
            let resultStart = result.index(
                result.startIndex,
                offsetBy: lower.distance(from: lower.startIndex, to: lowerRange.lowerBound)
            )
            let resultEnd = result.index(
                result.startIndex,
                offsetBy: lower.distance(from: lower.startIndex, to: lowerRange.upperBound)
            )
            let originalRange = resultStart..<resultEnd

            // Verify the characters at result's positions match what we found in
            // lower (defensive: handles any edge-case Unicode normalisation).
            guard result[originalRange].lowercased() == entry.pattern else { continue }

            result.replaceSubrange(originalRange, with: entry.replacement)
            break
        }

        return result
    }

    /// Rebuild the correction table from all available vocabulary sources.
    func rebuild(
        ownerName: String?,
        entityNames: [(canonical: String, aliases: [String], type: String)],
        speakerNames: [(label: String, displayName: String)]
    ) {
        var entries: [CorrectionEntry] = []

        // Owner name corrections.
        if let name = ownerName, !name.isEmpty {
            for variant in Self.phoneticVariants(of: name) {
                entries.append(CorrectionEntry(
                    pattern: variant,
                    replacement: name,
                    source: "owner"
                ))
            }
        }

        // Entity name corrections (persons, orgs, locations).
        for entity in entityNames {
            let canonical = entity.canonical
            guard canonical.count >= 3 else { continue } // Skip very short names

            for variant in Self.phoneticVariants(of: canonical) {
                entries.append(CorrectionEntry(
                    pattern: variant,
                    replacement: canonical,
                    source: "entity:\(entity.type)"
                ))
            }

            // Aliases are already known alternative spellings — add them directly.
            for alias in entity.aliases where alias.lowercased() != canonical.lowercased() {
                entries.append(CorrectionEntry(
                    pattern: alias.lowercased(),
                    replacement: canonical,
                    source: "entity:\(entity.type)"
                ))
            }
        }

        // Speaker profile names.
        for speaker in speakerNames {
            let name = speaker.displayName
            guard name.count >= 3 else { continue }
            guard name.lowercased() != "owner" && name.lowercased() != "fae" else { continue }

            for variant in Self.phoneticVariants(of: name) {
                entries.append(CorrectionEntry(
                    pattern: variant,
                    replacement: name,
                    source: "speaker"
                ))
            }
        }

        // Deduplicate: keep first entry per pattern (earlier sources have priority).
        var seen: Set<String> = []
        corrections = entries.filter { entry in
            guard !seen.contains(entry.pattern) else { return false }
            seen.insert(entry.pattern)
            return true
        }

        // Sort longest patterns first for greedy matching.
        corrections.sort { $0.pattern.count > $1.pattern.count }

        lastRebuildAt = Date()
        if !corrections.isEmpty {
            NSLog("DynamicVocabularyCorrector: rebuilt with %d corrections from %d entities + %d speakers",
                  corrections.count, entityNames.count, speakerNames.count)
        }
    }

    /// Whether the cache needs rebuilding (stale after 10 minutes).
    var needsRebuild: Bool {
        guard let last = lastRebuildAt else { return true }
        return Date().timeIntervalSince(last) > 600
    }

    /// Number of active correction entries.
    var correctionCount: Int { corrections.count }

    // MARK: - Phonetic Variant Generation

    /// Generate common ASR misrecognition variants for a proper name.
    ///
    /// ASR models mishear proper names in predictable ways based on phonetic
    /// similarity. This generates lowercase patterns that the ASR might produce
    /// instead of the correct name.
    static func phoneticVariants(of name: String) -> [String] {
        let lower = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return [] }

        var variants: Set<String> = []

        // The name itself (handles case normalization).
        variants.insert(lower)

        // Single-word names: generate common substitutions.
        let words = lower.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        for word in words where word.count >= 3 {
            // Vowel confusion: a↔e, i↔e, o↔u, etc.
            let vowelSwaps: [(String, String)] = [
                ("a", "e"), ("e", "a"), ("i", "e"), ("e", "i"),
                ("o", "u"), ("u", "o"), ("a", "o"), ("o", "a"),
                ("ai", "ay"), ("ay", "ai"), ("ei", "ey"), ("ey", "ei"),
                ("ee", "ea"), ("ea", "ee"), ("ie", "ei"),
            ]
            for (from, to) in vowelSwaps {
                let swapped = word.replacingOccurrences(of: from, with: to)
                if swapped != word { variants.insert(swapped) }
            }

            // Common consonant confusion.
            let consonantSwaps: [(String, String)] = [
                ("th", "t"), ("t", "th"),
                ("ph", "f"), ("f", "ph"),
                ("ck", "k"), ("k", "ck"),
                ("ch", "sh"), ("sh", "ch"),
                ("s", "z"), ("z", "s"),
                ("d", "t"), ("t", "d"),
                ("b", "p"), ("p", "b"),
                ("v", "w"), ("w", "v"),
                ("n", "m"), ("m", "n"),
            ]
            for (from, to) in consonantSwaps {
                let swapped = word.replacingOccurrences(of: from, with: to)
                if swapped != word { variants.insert(swapped) }
            }

            // Dropped/added trailing letters.
            if word.count > 3 {
                variants.insert(String(word.dropLast()))         // "edinburgh" → "edinburg"
                variants.insert(word + "h")                       // "edinburg" → "edinburgh"
                variants.insert(word + "e")                       // "saors" → "saorse"
                if word.hasSuffix("e") {
                    variants.insert(String(word.dropLast()))      // "saorse" → "saors"
                }
            }
        }

        // Multi-word names: add the full phrase as a variant too.
        if words.count > 1 {
            variants.insert(words.joined(separator: " "))
        }

        // Remove the canonical form (we don't need to "correct" correct spelling).
        variants.remove(lower)

        return Array(variants)
    }
}
