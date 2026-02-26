import Foundation

/// Text processing utilities for the voice pipeline.
///
/// Includes sentence/clause boundary detection for TTS streaming,
/// think-tag stripping, and speech-character cleanup.
///
/// Replaces: `src/pipeline/text_processing.rs` and `ThinkTagStripper`
enum TextProcessing {

    // MARK: - Sentence Boundary Detection

    /// Sentence-ending punctuation characters.
    private static let sentenceTerminators: Set<Character> = [".", "!", "?"]

    /// Clause-ending punctuation for early TTS streaming.
    private static let clauseTerminators: Set<Character> = [",", ";", ":", "—", "–"]

    /// Find the last sentence boundary in the accumulated text.
    ///
    /// Returns the byte offset after the terminator (split point), or nil
    /// if no complete sentence is found.
    static func findSentenceBoundary(in text: String) -> String.Index? {
        // Search backwards for sentence terminators.
        var lastBoundary: String.Index?
        var index = text.endIndex

        while index > text.startIndex {
            let prev = text.index(before: index)
            let ch = text[prev]

            if sentenceTerminators.contains(ch) {
                // Check it's not mid-abbreviation (e.g. "Dr." or "3.14").
                if prev > text.startIndex {
                    let beforePrev = text.index(before: prev)
                    let beforeChar = text[beforePrev]
                    // If preceded by a single uppercase letter, likely abbreviation.
                    if beforeChar.isUppercase {
                        if beforePrev == text.startIndex || !text[text.index(before: beforePrev)].isLetter {
                            index = prev
                            continue
                        }
                    }
                    // If preceded by a digit, likely decimal number.
                    if beforeChar.isNumber {
                        index = prev
                        continue
                    }
                }
                lastBoundary = index
                break
            }
            index = prev
        }

        return lastBoundary
    }

    /// Find the last clause boundary (comma, semicolon, colon, dash).
    ///
    /// Returns the index after the terminator, or nil if none found.
    static func findClauseBoundary(in text: String) -> String.Index? {
        var index = text.endIndex

        while index > text.startIndex {
            let prev = text.index(before: index)
            let ch = text[prev]

            if clauseTerminators.contains(ch) {
                return index
            }
            index = prev
        }

        return nil
    }

    // MARK: - Non-Speech Character Stripping

    /// Remove characters that shouldn't be spoken by TTS.
    static func stripNonSpeechChars(_ text: String) -> String {
        var result = text
        // Remove markdown-style formatting.
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "__", with: "")
        result = result.replacingOccurrences(of: "```", with: "")
        result = result.replacingOccurrences(of: "`", with: "")
        // Remove code block markers.
        result = result.replacingOccurrences(of: "---", with: "")
        // Trim whitespace.
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    // MARK: - Think Tag Stripping

    /// Strips `<think>...</think>` tags from streaming LLM output.
    ///
    /// The LLM may emit reasoning in think tags that should not be spoken.
    /// This processes incrementally as tokens arrive.
    struct ThinkTagStripper {
        private var buffer: String = ""
        private var insideThink: Bool = false
        private var tagBuffer: String = ""

        /// Process a new token and return any visible (non-think) text.
        mutating func process(_ token: String) -> String {
            var visible = ""

            for ch in token {
                if insideThink {
                    tagBuffer.append(ch)
                    // Check for closing tag.
                    if tagBuffer.hasSuffix("</think>") {
                        insideThink = false
                        tagBuffer = ""
                    }
                } else {
                    tagBuffer.append(ch)
                    if tagBuffer.hasSuffix("<think>") {
                        // Entered think block — remove the tag from visible output.
                        let tagLen = "<think>".count
                        if visible.count >= tagLen {
                            visible.removeLast(tagLen)
                        } else {
                            visible = ""
                        }
                        insideThink = true
                        tagBuffer = ""
                    } else if tagBuffer.count > 7 {
                        // Not a tag — flush tagBuffer to visible.
                        visible += tagBuffer
                        tagBuffer = ""
                    }
                }
            }

            // If not in a tag and have accumulated text, flush it.
            if !insideThink && !tagBuffer.isEmpty {
                // Keep tagBuffer — might be partial tag like "<thi"
                // Only flush if it can't be a prefix of "<think>"
                if !("<think>".hasPrefix(tagBuffer)) {
                    visible += tagBuffer
                    tagBuffer = ""
                }
            }

            return visible
        }

        /// Flush any remaining buffered text.
        mutating func flush() -> String {
            let remaining = insideThink ? "" : tagBuffer
            tagBuffer = ""
            insideThink = false
            return remaining
        }
    }

    // MARK: - Name Detection

    /// Name variants for wake-word / direct-address detection.
    /// Ordered longest-first for greedy matching.
    static let nameVariants = ["faye", "fae", "fea", "fee", "fay", "fey", "fah", "feh"]

    /// Find the first mention of a Fae name variant in lowercased text.
    ///
    /// Returns `(range, matchedVariant)` or nil if not found.
    /// Only matches at word boundaries (not mid-word).
    static func findNameMention(in text: String) -> (Range<String.Index>, String)? {
        let lower = text.lowercased()

        for variant in nameVariants {
            guard let range = lower.range(of: variant) else { continue }

            // Check word boundary before.
            if range.lowerBound != lower.startIndex {
                let before = lower[lower.index(before: range.lowerBound)]
                if before.isLetter || before.isNumber { continue }
            }

            // Check word boundary after.
            if range.upperBound != lower.endIndex {
                let after = lower[range.upperBound]
                if after.isLetter || after.isNumber { continue }
            }

            return (range, variant)
        }

        return nil
    }

    /// Extract the query portion after/before the name mention.
    static func extractQueryAroundName(in text: String, nameRange: Range<String.Index>) -> String {
        // Prefer text after name.
        let after = String(text[nameRange.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.!?: ").union(.whitespacesAndNewlines))
        if !after.isEmpty { return after }

        // Fall back to text before name.
        let before = String(text[..<nameRange.lowerBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.!?: ").union(.whitespacesAndNewlines))
        if !before.isEmpty { return before }

        return "Hello"
    }
}
