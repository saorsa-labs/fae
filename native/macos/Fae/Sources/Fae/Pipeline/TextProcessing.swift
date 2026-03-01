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

    // MARK: - Meta-Commentary Detection

    /// Returns true if the text looks like the model is narrating/describing what the user
    /// said rather than responding directly. These are leaked reasoning patterns that should
    /// never reach TTS.
    static func isMetaCommentary(_ text: String) -> Bool {
        let lower = text.lowercased()
        let patterns = [
            "the user says",
            "the user said",
            "the user is saying",
            "you said",
            "you're saying",
            "you are saying",
            "this appears to be",
            "this seems to be",
            "this is a brief",
            "this is a short",
            "this is a simple",
            "that sounds like",
            "that seems like",
            "it seems like the user",
            "it appears the user",
            "the message is",
            "the user's message",
            "their statement",
            "the statement",
            "responding to something",
        ]
        return patterns.contains { lower.hasPrefix($0) || lower.contains($0) }
    }

    // MARK: - Non-Speech Character Stripping

    /// Remove characters that shouldn't be spoken by TTS.
    static func stripNonSpeechChars(_ text: String) -> String {
        var result = text
        // Strip any leaked <voice ...> XML tags (keep the text content between them).
        if let regex = try? NSRegularExpression(pattern: "<voice[^>]*>|</voice>") {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }
        // Strip any leaked think tags (should not reach TTS, but belt-and-suspenders).
        result = result.replacingOccurrences(of: "</think>", with: "")
        result = result.replacingOccurrences(of: "<think>", with: "")
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

        /// Set to `true` on the call to `process(_:)` that transitions out of a think block.
        ///
        /// Use this in `PipelineCoordinator` to detect when Qwen3.5-35B-A3B (which emits
        /// `<think>` as literal text) has finished its reasoning block.  The coordinator
        /// sets `thinkEndSeen = true` so that subsequent response tokens flow to TTS.
        private(set) var hasExitedThinkBlock: Bool = false

        /// Process a new token and return any visible (non-think) text.
        ///
        /// Only characters starting with `<` are buffered (as potential `<think>` tags).
        /// All other characters are emitted immediately, fixing the edge case where
        /// text like `"world<think>"` would flush the buffer before the tag was matched.
        mutating func process(_ token: String) -> String {
            var visible = ""
            hasExitedThinkBlock = false

            for ch in token {
                if insideThink {
                    tagBuffer.append(ch)
                    if tagBuffer.hasSuffix("</think>") {
                        insideThink = false
                        tagBuffer = ""
                        hasExitedThinkBlock = true
                    }
                } else if tagBuffer.isEmpty {
                    if ch == "<" {
                        tagBuffer.append(ch)
                    } else {
                        visible.append(ch)
                    }
                } else {
                    // tagBuffer starts with '<' — building potential <think> prefix.
                    tagBuffer.append(ch)
                    if tagBuffer == "<think>" {
                        insideThink = true
                        tagBuffer = ""
                    } else if !"<think>".hasPrefix(tagBuffer) {
                        // Can't be <think> — flush buffer to visible.
                        visible += tagBuffer
                        tagBuffer = ""
                    }
                }
            }

            // Flush anything that provably can't start a <think> tag.
            if !insideThink && !tagBuffer.isEmpty && !"<think>".hasPrefix(tagBuffer) {
                visible += tagBuffer
                tagBuffer = ""
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

    // MARK: - STT Post-Processing

    /// Common ASR misrecognitions of "Fae" mapped to their corrections.
    /// The ASR model doesn't know the name "Fae" and frequently garbles it
    /// into phonetically similar words. We fix these at word boundaries.
    private static let nameCorrections: [(pattern: String, replacement: String)] = [
        // Multi-word garbles (check first — longer patterns before shorter).
        ("hi fae", "Hi Fae"),
        ("hey fae", "Hey Fae"),
        ("high fay", "Hi Fae"),
        ("high fae", "Hi Fae"),
        ("i fae", "Hi Fae"),
        ("i fay", "Hi Fae"),
        // Single-word garbles at word boundaries.
        ("ife", "Fae"),
        ("ifae", "Fae"),
        ("ifay", "Fae"),
        ("faye", "Fae"),
        ("fay", "Fae"),
        ("fey", "Fae"),
        ("fea", "Fae"),
        ("fah", "Fae"),
        ("feh", "Fae"),
        ("fei", "Fae"),
        ("fay.", "Fae."),
        ("fey.", "Fae."),
    ]

    /// Correct common ASR misrecognitions of "Fae" in transcribed text.
    static func correctNameRecognition(_ text: String) -> String {
        var result = text
        let lower = result.lowercased()

        for (pattern, replacement) in nameCorrections {
            // Case-insensitive word-boundary replacement.
            guard let range = lower.range(of: pattern) else { continue }

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

            // Replace in the original (preserving surrounding case).
            let originalRange = result.index(result.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.lowerBound))
                ..< result.index(result.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
            result.replaceSubrange(originalRange, with: replacement)

            // Only fix the first match per call to avoid cascading.
            break
        }

        return result
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
