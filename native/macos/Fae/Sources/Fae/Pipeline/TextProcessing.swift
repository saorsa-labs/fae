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

    private static func firstSentenceBoundary(in text: String) -> String.Index {
        var index = text.startIndex

        while index < text.endIndex {
            if sentenceTerminators.contains(text[index]) {
                return text.index(after: index)
            }
            index = text.index(after: index)
        }

        return text.endIndex
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
            // UI self-narration — model describing its own interface
            "the speech bubble",
            "the thought bubble",
            "the text bubble",
            "what's in the bubble",
            "in the bubble",
            "the orb is",
            "my orb is",
            "the status bar",
            "the subtitle",
            "on screen it shows",
            "on the screen it",
            "the display shows",
            "i can see my",
            "looking at my interface",
        ]
        return patterns.contains { lower.hasPrefix($0) || lower.contains($0) }
    }

    /// Removes leading reasoning-preface sentences that should stay in the
    /// thinking crawl instead of becoming visible assistant speech.
    static func stripReasoningPreface(_ text: String) -> String {
        var remaining = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remaining.isEmpty else { return remaining }

        while !remaining.isEmpty {
            let boundary = firstSentenceBoundary(in: remaining)
            let sentence = String(remaining[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sentence.isEmpty else { break }
            guard isReasoningPreface(sentence) || isMetaCommentary(sentence) else { break }
            remaining = String(remaining[boundary...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return remaining
    }

    static func isReasoningPreface(_ text: String) -> Bool {
        let lower = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let prefixPatterns = [
            "let me think",
            "let's think",
            "let me break this down",
            "let me walk through",
            "let me work through",
            "i'll analyze",
            "i will analyze",
            "i'm going to analyze",
            "i need to think",
            "i'm going to think",
            "first, i need to",
            "let me compare",
        ]
        if prefixPatterns.contains(where: { lower.hasPrefix($0) }) {
            return true
        }

        if (lower.hasPrefix("i'll compare") || lower.hasPrefix("i will compare"))
            && (lower.contains("deliberately") || lower.contains("systematically"))
        {
            return true
        }

        let containedPatterns = [
            "the user's request",
            "let me think through",
            "break this down systematically",
            "walk through this systematically",
            "think this through",
            "reason through this",
        ]
        return containedPatterns.contains(where: { lower.contains($0) })
    }

    /// Returns true if the text contains UI self-narration — the model describing
    /// its own interface elements. Always suppressed regardless of sentence position.
    static func isUISelfNarration(_ text: String) -> Bool {
        let lower = text.lowercased()
        let patterns = [
            "the speech bubble",
            "the thought bubble",
            "the text bubble",
            "what's in the bubble",
            "in the bubble",
            "the orb is",
            "my orb is",
            "the status bar shows",
            "the subtitle shows",
            "on screen it shows",
            "on the screen it",
            "the display shows",
            "looking at my interface",
        ]
        return patterns.contains { lower.contains($0) }
    }

    // MARK: - Non-Prose Detection

    /// Returns true if the text looks like tool payload markup or machine-oriented
    /// blobs (JSON envelopes, XML tool tags) that should not be sent to TTS.
    static func looksLikeNonProse(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 10 else { return false }

        let lower = trimmed.lowercased()

        // Explicit tool-call / tool-result markers.
        if lower.contains("<tool_call>") || lower.contains("</tool_call>")
            || lower.contains("<function=") || lower.contains("<parameter=")
            || lower.contains("\"tool_call\"") || lower.contains("\"tool_result\"")
        {
            return true
        }

        // Parseable JSON wrappers are non-prose if they look like machine payloads.
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}"))
            || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]"))
        {
            if let data = trimmed.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data)
            {
                if let dict = json as? [String: Any] {
                    let keys = Set(dict.keys.map { $0.lowercased() })
                    let toolish: Set<String> = [
                        "name", "arguments", "result", "tool", "tool_call", "tool_result", "function",
                    ]
                    if !keys.intersection(toolish).isEmpty {
                        return true
                    }
                } else {
                    // Arrays / scalar-only JSON blobs are usually not conversational prose.
                    return true
                }
            }
        }

        // High density of symbols plus very low lexical content indicates code-like output.
        let specialChars = CharacterSet(charactersIn: "{}[]<>=;|\\&%$@#~^")
        let specialCount = trimmed.unicodeScalars.filter { specialChars.contains($0) }.count
        let ratio = Double(specialCount) / Double(trimmed.count)
        let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace }).count
        if ratio > 0.18 && wordCount < 5 && trimmed.count > 24 {
            return true
        }

        return false
    }

    // MARK: - Self-Introduction Stripping

    /// Patterns that look like the model (or TTS refText bleed) self-introducing.
    /// These should never be spoken — the SOUL.md says "never opens with a self-introduction".
    /// Regex patterns matched case-insensitively against the text. Order matters: longest first.
    private static let selfIntroRegexes: [(pattern: String, regex: NSRegularExpression?)] = [
        // Full self-intro with optional commas: "Hello, I'm Fae, your personal voice assistant"
        (pattern: "(?:hello|hi|hey)[,.]?\\s+i(?:'m| am) fae[,.]?\\s+(?:your |a )?personal voice assistant",
         regex: try? NSRegularExpression(pattern: "(?:hello|hi|hey)[,.]?\\s+i(?:'m| am) fae[,.]?\\s+(?:your |a )?personal voice assistant", options: .caseInsensitive)),
        // "I'm Fae, your personal voice assistant" without greeting
        (pattern: "i(?:'m| am) fae[,.]?\\s+(?:your |a )?personal voice assistant",
         regex: try? NSRegularExpression(pattern: "i(?:'m| am) fae[,.]?\\s+(?:your |a )?personal voice assistant", options: .caseInsensitive)),
        // "Fae, your personal voice assistant" or "Fae personal voice assistant"
        (pattern: "fae[,.]?\\s+(?:your |a )?personal voice assistant",
         regex: try? NSRegularExpression(pattern: "fae[,.]?\\s+(?:your |a )?personal voice assistant", options: .caseInsensitive)),
        // Standalone "your personal voice assistant" or "personal voice assistant"
        (pattern: "(?:your )?personal voice assistant",
         regex: try? NSRegularExpression(pattern: "(?:your )?personal voice assistant", options: .caseInsensitive)),
        // "Hello, I'm Fae." or "Hi, I am Fae." as a standalone opener (with period/comma after)
        (pattern: "^(?:hello|hi|hey)[,.]?\\s+i(?:'m| am) fae[.,!]?\\s*",
         regex: try? NSRegularExpression(pattern: "^(?:hello|hi|hey)[,.]?\\s+i(?:'m| am) fae[.,!]?\\s*", options: .caseInsensitive)),
    ]

    /// Strip self-introduction prefixes from text before TTS.
    /// Catches both LLM-generated self-introductions and TTS refText bleed.
    static func stripSelfIntroductions(_ text: String) -> String {
        var result = text
        for (_, regex) in selfIntroRegexes {
            guard let regex = regex else { continue }
            let range = NSRange(result.startIndex..., in: result)
            let stripped = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
            if stripped != result {
                result = stripped
                break  // Only strip the first match.
            }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Non-Speech Character Stripping

    /// Remove characters that shouldn't be spoken by TTS and normalize for clean speech.
    static func stripNonSpeechChars(_ text: String) -> String {
        var result = text

        // Strip self-introductions (TTS refText bleed or LLM-generated).
        result = stripSelfIntroductions(result)

        // Strip file paths that leak from tool results (/Users/..., ~/...).
        if let pathRegex = try? NSRegularExpression(
            pattern: #"(?:~/|/(?:Users|Library|Applications|System|Volumes|tmp|var|etc|opt|usr|private)/)[^\s,;:!?"'()\[\]{}]+"#
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = pathRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        // Strip bare URL fragments that leak from web search results.
        // Matches "word.tld" patterns (bbc.co, weather25.com, etc.) and full URLs.
        if let urlRegex = try? NSRegularExpression(
            pattern: #"(?:https?://)?(?:www\.)?[a-zA-Z0-9][-a-zA-Z0-9]*\.(?:com|co|org|net|io|uk|gov|edu|info)[^\s]*"#
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = urlRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        // Strip spaced-out domain fragments (LLM artifact: "bbc. co. uk" instead of "bbc.co.uk").
        if let spacedUrlRegex = try? NSRegularExpression(
            pattern: #"[a-zA-Z0-9]+\.\s+(?:com|co|org|net|io|uk|gov|edu)(?:\.\s*\w+)*\.?\s*"#
        ) {
            let range = NSRange(result.startIndex..., in: result)
            result = spacedUrlRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        // Strip any leaked XML-style tags (voice, think, tool_call, etc.).
        if let regex = try? NSRegularExpression(pattern: "</?[a-zA-Z_][a-zA-Z0-9_]*[^>]*>") {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        // Strip JSON-like fragments that may leak from tool call/result content.
        // Matches {...} blocks containing colons (JSON key-value syntax).
        if let jsonRegex = try? NSRegularExpression(pattern: "\\{[^}]*:[^}]*\\}") {
            let range = NSRange(result.startIndex..., in: result)
            result = jsonRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        // Strip inline code patterns: variable_names, function_calls(), file.paths.
        // Camelcase/snake_case identifiers with 2+ underscores or dots (not normal prose).
        if let codeIdRegex = try? NSRegularExpression(pattern: "\\b\\w+(?:[_.]{1}\\w+){2,}\\b") {
            let range = NSRange(result.startIndex..., in: result)
            result = codeIdRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        // Remove markdown-style formatting.
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "__", with: "")
        result = result.replacingOccurrences(of: "```", with: "")
        result = result.replacingOccurrences(of: "`", with: "")
        result = result.replacingOccurrences(of: "---", with: "")

        // Remove markdown heading markers at line starts (# Heading).
        if let headingRegex = try? NSRegularExpression(pattern: "(?m)^#{1,6}\\s+") {
            let range = NSRange(result.startIndex..., in: result)
            result = headingRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        // Remove markdown list markers at line starts (- item, * item, 1. item).
        // Only match 1-2 digit numbers (e.g. "1." "99.") — not 3+ digit numbers like "579."
        // which are actual numeric answers, not list markers.
        if let listRegex = try? NSRegularExpression(pattern: "(?m)^\\s*(?:[-*•]|\\d{1,2}\\.)\\s+") {
            let range = NSRange(result.startIndex..., in: result)
            result = listRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        // Remove bare URLs (https://... or http://...) — they sound terrible when spoken.
        if let urlRegex = try? NSRegularExpression(pattern: "https?://\\S+") {
            let range = NSRange(result.startIndex..., in: result)
            result = urlRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "")
        }

        // Remove square brackets (markdown link syntax remnants like [text]).
        result = result.replacingOccurrences(of: "[", with: "")
        result = result.replacingOccurrences(of: "]", with: "")

        // Remove parentheses (markdown link remnants, citations).
        result = result.replacingOccurrences(of: "(", with: "")
        result = result.replacingOccurrences(of: ")", with: "")

        // Normalize keyboard shortcut notation to spoken-friendly text.
        // Example: "Command+W" -> "Command plus W".
        result = result.replacingOccurrences(of: "+", with: " plus ")

        // Normalize punctuation that confuses TTS.
        // Replace ellipsis character and multi-dot with single period.
        result = result.replacingOccurrences(of: "…", with: ".")
        result = result.replacingOccurrences(of: "...", with: ".")

        // Replace em-dash and en-dash with comma (natural pause).
        result = result.replacingOccurrences(of: "—", with: ",")
        result = result.replacingOccurrences(of: "–", with: ",")

        // Remove asterisks (emphasis remnants).
        result = result.replacingOccurrences(of: "*", with: "")

        // Collapse repeated punctuation (e.g. "!!" → "!", ",," → ",").
        if let dupPunct = try? NSRegularExpression(pattern: "([.!?,;:])\\1+") {
            let range = NSRange(result.startIndex..., in: result)
            result = dupPunct.stringByReplacingMatches(in: result, range: range, withTemplate: "$1")
        }

        // Remove quotes (TTS reads them as "quote" sometimes).
        result = result.replacingOccurrences(of: "\"", with: "")
        result = result.replacingOccurrences(of: "\u{201C}", with: "") // left double
        result = result.replacingOccurrences(of: "\u{201D}", with: "") // right double
        result = result.replacingOccurrences(of: "\u{2018}", with: "") // left single
        result = result.replacingOccurrences(of: "\u{2019}", with: "'") // right single → apostrophe

        // Remove spaces before punctuation that often appear in token-stream joins.
        if let spaceBeforePunct = try? NSRegularExpression(pattern: "\\s+([,.;:!?])") {
            let range = NSRange(result.startIndex..., in: result)
            result = spaceBeforePunct.stringByReplacingMatches(in: result, range: range, withTemplate: "$1")
        }

        // Collapse all whitespace (spaces, tabs, newlines) into single spaces.
        if let wsRegex = try? NSRegularExpression(pattern: "\\s+") {
            let range = NSRange(result.startIndex..., in: result)
            result = wsRegex.stringByReplacingMatches(in: result, range: range, withTemplate: " ")
        }

        // Trim leading/trailing whitespace.
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        // Final pass: normalize token-stream artifacts for natural speech.
        result = normalizeForSpeechOutput(result)

        return result
    }

    /// Normalize common token-stream artifacts into more natural spoken text.
    private static func normalizeForSpeechOutput(_ text: String) -> String {
        var result = text

        // Historical-token merge fixes observed in streamed generations.
        result = result.replacingOccurrences(of: "Mes opot amia", with: "Mesopotamia")
        result = result.replacingOccurrences(of: "mes opot amia", with: "mesopotamia")
        result = result.replacingOccurrences(of: "ab acus", with: "abacus")
        result = result.replacingOccurrences(of: "be ads", with: "beads")
        result = result.replacingOccurrences(of: "gro oves", with: "grooves")

        // Collapse digit sequences that arrive as spaced tokens: "3 0 0 0" -> "3000".
        if let spacedDigits = try? NSRegularExpression(pattern: "(?<!\\d)(\\d(?:\\s+\\d){1,})(?!\\d)") {
            while true {
                let fullRange = NSRange(result.startIndex..., in: result)
                guard let match = spacedDigits.firstMatch(in: result, range: fullRange),
                      let digitsRange = Range(match.range(at: 1), in: result)
                else { break }

                let collapsed = result[digitsRange].replacingOccurrences(of: " ", with: "")
                result.replaceSubrange(digitsRange, with: collapsed)
            }
        }

        // Convert compact date forms to spoken-friendly month/day/year.
        result = verbalizeDates(result)

        // Speak numeric ranges naturally: "3000-2500" -> "3000 to 2500".
        if let numericRange = try? NSRegularExpression(pattern: "(?<=\\d)\\s*[-–—]\\s*(?=\\d)") {
            let fullRange = NSRange(result.startIndex..., in: result)
            result = numericRange.stringByReplacingMatches(in: result, range: fullRange, withTemplate: " to ")
        }

        // Convert historical era abbreviations to letter-by-letter pronunciation.
        result = replaceRegexMatches(
            in: result,
            pattern: "\\b(BCE|BC|CE|AD)\\b"
        ) { match, source in
            guard let range = Range(match.range(at: 1), in: source) else { return nil }
            let token = String(source[range])
            return token.map { String($0) }.joined(separator: " ")
        }

        // Convert semicolons and non-time colons to commas for softer pauses.
        result = result.replacingOccurrences(of: ";", with: ",")
        if let colonPause = try? NSRegularExpression(pattern: "(?<!\\d):(?!\\d)") {
            let fullRange = NSRange(result.startIndex..., in: result)
            result = colonPause.stringByReplacingMatches(in: result, range: fullRange, withTemplate: ",")
        }

        // Re-collapse whitespace after normalization passes.
        if let wsRegex = try? NSRegularExpression(pattern: "\\s+") {
            let fullRange = NSRange(result.startIndex..., in: result)
            result = wsRegex.stringByReplacingMatches(in: result, range: fullRange, withTemplate: " ")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func verbalizeDates(_ text: String) -> String {
        var result = text

        // US style dates: MM/DD/YYYY
        result = replaceRegexMatches(
            in: result,
            pattern: "\\b(0?[1-9]|1[0-2])/(0?[1-9]|[12]\\d|3[01])/(\\d{2,4})\\b"
        ) { match, source in
            guard let monthRange = Range(match.range(at: 1), in: source),
                  let dayRange = Range(match.range(at: 2), in: source),
                  let yearRange = Range(match.range(at: 3), in: source),
                  let month = Int(source[monthRange]),
                  let day = Int(source[dayRange]),
                  let year = Int(source[yearRange]),
                  (1...12).contains(month),
                  (1...31).contains(day)
            else { return nil }

            let spokenYear = year < 100 ? 2000 + year : year
            return "\(monthName(month)) \(day), \(spokenYear)"
        }

        // ISO style dates: YYYY-MM-DD
        result = replaceRegexMatches(
            in: result,
            pattern: "\\b(\\d{4})-(0?[1-9]|1[0-2])-(0?[1-9]|[12]\\d|3[01])\\b"
        ) { match, source in
            guard let yearRange = Range(match.range(at: 1), in: source),
                  let monthRange = Range(match.range(at: 2), in: source),
                  let dayRange = Range(match.range(at: 3), in: source),
                  let year = Int(source[yearRange]),
                  let month = Int(source[monthRange]),
                  let day = Int(source[dayRange]),
                  (1...12).contains(month),
                  (1...31).contains(day)
            else { return nil }

            return "\(monthName(month)) \(day), \(year)"
        }

        return result
    }

    static func monthName(_ month: Int) -> String {
        let months = [
            "January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December",
        ]
        if (1...12).contains(month) {
            return months[month - 1]
        }
        return "month \(month)"
    }

    private static func replaceRegexMatches(
        in text: String,
        pattern: String,
        transform: (NSTextCheckingResult, String) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result),
                  let replacement = transform(match, result)
            else { continue }
            result.replaceSubrange(range, with: replacement)
        }

        return result
    }

    // MARK: - Think Tag Stripping

    /// Strips `<think>...</think>` tags from streaming LLM output.
    ///
    /// The LLM may emit reasoning in think tags that should not be spoken.
    /// This processes incrementally as tokens arrive.
    ///
    /// Supported formats:
    /// - Qwen: `<think>reasoning</think>` (response follows immediately)
    /// - Gemma 4: `<|channel>thought\nreasoning\n<|channel>response\n` (visible text follows)
    struct ThinkTagStripper {
        private var buffer: String = ""
        private var insideThink: Bool = false
        private var tagBuffer: String = ""

        /// The open tag that entered the current think block. Used to match the
        /// correct closing tag (Qwen vs Gemma format).
        private var activeOpenTag: String = ""

        // Qwen format tags.
        private static let qwenOpen = "<think>"
        private static let qwenClose = "</think>"

        // Gemma 4 format tags.
        private static let gemmaThinkOpen = "<|channel>thought"
        private static let gemmaResponseOpen = "<|channel>response"

        /// All possible open tags — used for prefix matching in the tag buffer.
        /// Ordered longest-first so the buffer is kept when it could still match either.
        private static let openTags = [gemmaThinkOpen, qwenOpen]

        /// Set to `true` on the call to `process(_:)` that transitions out of a think block.
        ///
        /// Use this in `PipelineCoordinator` to detect when the model has finished
        /// its reasoning block.  The coordinator sets `thinkEndSeen = true` so that
        /// subsequent response tokens flow to TTS.
        private(set) var hasExitedThinkBlock: Bool = false

        /// New think content captured during this `process(_:)` call.
        ///
        /// Populated while inside a think block; reset to `""` on each call.
        /// The closing tag is excluded.  Use this in `PipelineCoordinator`
        /// to stream live think text to the UI without buffering the whole block.
        private(set) var thinkChunk: String = ""

        /// Process a new token and return any visible (non-think) text.
        ///
        /// Only characters starting with `<` are buffered (as potential tag prefixes).
        /// All other characters are emitted immediately, fixing the edge case where
        /// text like `"world<think>"` would flush the buffer before the tag was matched.
        mutating func process(_ token: String) -> String {
            var visible = ""
            hasExitedThinkBlock = false
            thinkChunk = ""

            for ch in token {
                if insideThink {
                    tagBuffer.append(ch)

                    // Check for the matching close tag.
                    let exited: Bool
                    if activeOpenTag == Self.qwenOpen {
                        exited = tagBuffer.hasSuffix(Self.qwenClose)
                        if exited {
                            let closeTag = Self.qwenClose
                            if thinkChunk.hasSuffix(closeTag) {
                                thinkChunk.removeLast(closeTag.count)
                            }
                        }
                    } else {
                        // Gemma: thinking ends when <|channel>response appears.
                        exited = tagBuffer.hasSuffix(Self.gemmaResponseOpen)
                        if exited {
                            let closeTag = Self.gemmaResponseOpen
                            if thinkChunk.hasSuffix(closeTag) {
                                thinkChunk.removeLast(closeTag.count)
                            }
                        }
                    }

                    if exited {
                        insideThink = false
                        tagBuffer = ""
                        activeOpenTag = ""
                        hasExitedThinkBlock = true
                    } else {
                        thinkChunk.append(ch)
                    }
                } else if tagBuffer.isEmpty {
                    if ch == "<" {
                        tagBuffer.append(ch)
                    } else {
                        visible.append(ch)
                    }
                } else {
                    // tagBuffer starts with '<' — building a potential open tag.
                    tagBuffer.append(ch)

                    // Check if the buffer exactly matches any open tag.
                    if let matchedTag = Self.openTags.first(where: { tagBuffer == $0 }) {
                        insideThink = true
                        activeOpenTag = matchedTag
                        tagBuffer = ""
                    } else if !Self.openTags.contains(where: { $0.hasPrefix(tagBuffer) }) {
                        // Can't match any open tag — flush buffer to visible.
                        visible += tagBuffer
                        tagBuffer = ""
                    }
                }
            }

            // Flush anything that provably can't start any open tag.
            if !insideThink && !tagBuffer.isEmpty
                && !Self.openTags.contains(where: { $0.hasPrefix(tagBuffer) })
            {
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
            activeOpenTag = ""
            return remaining
        }
    }

    // MARK: - STT Repetition Guard

    /// Detect pathologically repetitive STT output (degenerate ASR loop).
    ///
    /// Qwen3-ASR (and Whisper-family models) can enter a repetition loop on
    /// short, ambiguous, or low-energy audio segments, producing thousands of
    /// repeated tokens like "oh, oh, oh, oh...". This wastes LLM context and
    /// confuses the user.
    ///
    /// Heuristic: split on whitespace, count unique words. If:
    /// - total words > 20 AND unique/total ratio < 0.1 → hallucination
    /// - OR a single 1-3 word pattern repeats 20+ consecutive times
    static func isRepetitiveHallucination(_ text: String) -> Bool {
        let words = text.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }

        guard words.count > 20 else { return false }

        // Fast path: unique word ratio check.
        let unique = Set(words)
        let ratio = Double(unique.count) / Double(words.count)
        if ratio < 0.1 {
            return true
        }

        // Slower path: detect a short repeating pattern (1-3 words).
        for patternLen in 1...min(3, words.count / 20) {
            let pattern = Array(words.prefix(patternLen))
            var consecutiveRepeats = 0
            var i = 0
            while i + patternLen <= words.count {
                let slice = Array(words[i..<(i + patternLen)])
                if slice == pattern {
                    consecutiveRepeats += 1
                    if consecutiveRepeats >= 20 {
                        return true
                    }
                    i += patternLen
                } else {
                    break
                }
            }
        }

        return false
    }

    // MARK: - STT Post-Processing

    /// Common ASR misrecognitions of "Fae" mapped to their corrections.
    /// The ASR model doesn't know the name "Fae" and frequently garbles it
    /// into phonetically similar words. We fix these at word boundaries.
    private static let nameCorrections: [(pattern: String, replacement: String)] = [
        // Sentence-initial "Hey, [command]" → "Fae, [command]"
        // The most common STT garble through speakers.
        ("hey, check", "Fae, check"),
        ("hey, tell", "Fae, tell"),
        ("hey, what", "Fae, what"),
        ("hey, who", "Fae, who"),
        ("hey, when", "Fae, when"),
        ("hey, where", "Fae, where"),
        ("hey, show", "Fae, show"),
        ("hey, set", "Fae, set"),
        ("hey, remind", "Fae, remind"),
        ("hey, remember", "Fae, remember"),
        ("hey, search", "Fae, search"),
        ("hey, create", "Fae, create"),
        ("hey, make", "Fae, make"),
        ("hey, run", "Fae, run"),
        ("hey, hello", "Fae, hello"),
        ("hey, good", "Fae, good"),
        ("hey, how", "Fae, how"),
        // Multi-word garbles (check first — longer patterns before shorter).
        ("hi fae", "Hi Fae"),
        ("hey fae", "Hey Fae"),
        ("high fay", "Hi Fae"),
        ("high fae", "Hi Fae"),
        ("high faith", "Hi Fae"),
        ("hi faith", "Hi Fae"),
        ("hey faith", "Hey Fae"),
        ("hi phase", "Hi Fae"),
        ("hey phase", "Hey Fae"),
        ("hi faye", "Hi Fae"),
        ("hey faye", "Hey Fae"),
        ("hi fay", "Hi Fae"),
        ("hey fay", "Hey Fae"),
        ("hey fag", "Hey Fae"),
        ("hi fag", "Hi Fae"),
        ("i fae", "Hi Fae"),
        ("i fay", "Hi Fae"),
        ("i faye", "Hi Fae"),
        // Single-word garbles at word boundaries.
        // NOTE: "faith", "ivy", and "fee" removed — common English words
        // that cause false corrections in normal conversation.
        ("fag", "Fae"),
        ("ife", "Fae"),
        ("ifae", "Fae"),
        ("ifay", "Fae"),
        ("phase", "Fae"),
        ("faye", "Fae"),
        ("fay", "Fae"),
        ("fey", "Fae"),
        ("fea", "Fae"),
        ("fah", "Fae"),
        ("feh", "Fae"),
        ("fei", "Fae"),
        ("fae's", "Fae's"),
        ("ivie", "Fae"),
        ("fay.", "Fae."),
        ("fey.", "Fae."),
    ]

    /// Common ASR command-phrase misrecognitions. Qwen3-ASR garbles common
    /// task management phrases into phonetically similar but nonsensical text.
    /// These are applied after name corrections, before the LLM sees the text.
    ///
    /// Discovered empirically from real conversations — add new patterns as
    /// they appear in production logs.
    private static let commandCorrections: [(pattern: String, replacement: String)] = [
        // "clear all" garbles — Qwen3-ASR hears "the law" / "de la" / "dealer"
        ("the law reminds us", "clear all reminders"),
        ("the law reminders", "clear all reminders"),
        ("the law remind us", "clear all reminders"),
        ("dealer reminders", "clear all reminders"),
        ("de la reminders", "clear all reminders"),
        ("dealer reminds", "clear all reminders"),
        // "mark all" garbles — Qwen3-ASR hears "Marco" / "mark or"
        ("marco, my reminder", "mark all my reminders"),
        ("marco my reminder", "mark all my reminders"),
        ("marco, my reminders", "mark all my reminders"),
        ("marco my reminders", "mark all my reminders"),
        ("marco reminders", "mark all reminders"),
        ("marco, reminder", "mark all reminders"),
        ("marco reminder", "mark all reminders"),
        ("mark or my reminder", "mark all my reminders"),
        ("mark or reminders", "mark all reminders"),
    ]

    /// Returns true when a transcript strongly suggests the user has not finished
    /// their turn yet and the pipeline should briefly wait for continuation.
    ///
    /// This is intentionally conservative: it only fires for clearly unfinished
    /// phrasing, hesitations, or clipped follow-up fragments.
    static func isLikelyIncompleteTurn(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        if let last = trimmed.last, [".", "!", "?"].contains(last) {
            return false
        }

        if trimmed.hasSuffix("...")
            || trimmed.hasSuffix(",")
            || trimmed.hasSuffix(":")
            || trimmed.hasSuffix(";")
            || trimmed.hasSuffix(" -")
            || trimmed.hasSuffix(" —")
            || trimmed.hasSuffix(" –")
        {
            return true
        }

        let normalized = normalizeWakeAlias(trimmed)
        let tokens = normalized.split(separator: " ").map(String.init)
        guard let lastToken = tokens.last else { return false }

        let trailingFunctionWords: Set<String> = [
            "and", "or", "but", "so", "because", "if", "when", "while", "then",
            "that", "which", "who", "where", "with", "without", "for", "from",
            "to", "into", "onto", "at", "in", "on", "of", "about", "like",
            "as", "after", "before", "until", "unless", "since", "than", "by",
            "around", "through", "over", "under", "between", "during", "per",
            "plus", "minus", "versus", "vs", "uh", "um"
        ]
        if trailingFunctionWords.contains(lastToken) {
            return true
        }

        let trailingDeterminers: Set<String> = [
            "a", "an", "the", "this", "that", "these", "those",
            "my", "your", "our", "his", "her", "their"
        ]
        if trailingDeterminers.contains(lastToken) {
            return true
        }

        let continuationPhrases: Set<String> = [
            "wait",
            "hang on",
            "hold on",
            "one sec",
            "one second",
            "just a sec",
            "just a second",
            "give me a sec",
            "give me a second",
            "let me think",
            "let me check",
            "i mean",
            "you know",
        ]
        if continuationPhrases.contains(normalized) {
            return true
        }

        if tokens.count >= 2 {
            let trailingBigram = tokens.suffix(2).joined(separator: " ")
            let trailingContinuationBigrams: Set<String> = [
                "kind of",
                "sort of",
                "let me",
                "hold on",
                "hang on",
                "you know",
                "i mean",
            ]
            if trailingContinuationBigrams.contains(trailingBigram) {
                return true
            }
        }

        // Unclosed subordinate clause: a leading subordinating conjunction
        // with no terminal punctuation suggests the user opened a clause
        // they haven't closed yet.  E.g., "if it rains" (no main clause).
        // Only fires when the first token is the subordinator — avoids false
        // positives like "since yesterday morning" (temporal, not conditional).
        let clauseOpeners: Set<String> = [
            "if", "unless", "although", "though", "because", "whereas",
        ]
        if let first = tokens.first,
           clauseOpeners.contains(first),
           tokens.count >= 3
        {
            return true
        }

        return false
    }

    /// Returns true for short conversational cues that usually mean
    /// "don't take the turn yet, I'm continuing".
    static func isLikelyContinuationCue(_ text: String) -> Bool {
        let normalized = normalizeWakeAlias(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !normalized.isEmpty else { return false }

        let cues: Set<String> = [
            "wait",
            "no wait",
            "hang on",
            "hold on",
            "one sec",
            "one second",
            "just a sec",
            "just a second",
            "give me a sec",
            "give me a second",
            "let me think",
            "let me check",
            "and then",
            "okay so",
            "go on",
            "carry on",
        ]
        return cues.contains(normalized)
    }

    /// Correct common ASR misrecognitions of "Fae" and command phrases in transcribed text.
    static func correctNameRecognition(_ text: String) -> String {
        var result = text

        // Command corrections first — longer, more specific phrase patterns.
        result = applyCommandCorrections(result)

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

    /// Apply command-phrase corrections to ASR output.
    /// Uses case-insensitive substring matching — these are multi-word phrases
    /// unlikely to appear as false positives in normal speech.
    private static func applyCommandCorrections(_ text: String) -> String {
        var result = text
        let lower = result.lowercased()

        for (pattern, replacement) in commandCorrections {
            guard let range = lower.range(of: pattern) else { continue }
            let originalRange = result.index(result.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.lowerBound))
                ..< result.index(result.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
            result.replaceSubrange(originalRange, with: replacement)
            break  // One correction per call.
        }

        return result
    }

    // MARK: - Command Tense Normalization

    /// Known command verbs that Fae responds to. Used to detect and fix
    /// ASR tense/pronoun errors like "I checked my calendar" → "check my calendar".
    private static let commandVerbs: Set<String> = [
        "check", "tell", "make", "show", "set", "remind", "search",
        "open", "close", "play", "stop", "find", "read", "write",
        "call", "send", "create", "list", "get", "run", "activate",
    ]

    /// Replace a garbled sentence-initial word before a command with "Fae".
    /// Pattern: "[single word], [command verb] ..." → "Fae, [command verb] ..."
    /// The STT garbles "Fae" into many words (Hey, To, Say, They, etc.)
    /// but the comma + command verb pattern is distinctive.
    static func fixGarbledWakeWord(_ text: String) -> String {
        let lower = text.lowercased()
        // Look for pattern: single word + comma + space + command verb
        guard let commaIdx = lower.firstIndex(of: ","),
              commaIdx > lower.startIndex,
              commaIdx < lower.index(lower.endIndex, offsetBy: -3)
        else { return text }

        let prefix = String(lower[lower.startIndex..<commaIdx])
        // Must be a single short word (1-5 chars, no spaces)
        guard prefix.count <= 5, !prefix.contains(" ") else { return text }

        let afterComma = String(lower[lower.index(after: commaIdx)...])
            .trimmingCharacters(in: .whitespaces)
        let firstWord = String(afterComma.split(separator: " ").first ?? "")
            .trimmingCharacters(in: .punctuationCharacters)

        if commandVerbs.contains(firstWord) || ["hello", "good", "how", "what", "who", "when", "where"].contains(firstWord) {
            let rest = String(text[text.index(after: text.firstIndex(of: ",")!)...])
            return "Fae," + rest
        }
        return text
    }

    /// Strip inserted pronouns and fix past tense on command verbs.
    /// ASR through speakers often garbles imperative commands:
    /// - "check my calendar" → "I checked my calendar"
    /// - "tell me a joke" → "they tell me a joke"
    /// - "remind me" → "they remind me"
    static func normalizeCommandTense(_ text: String) -> String {
        let words = text.split(separator: " ", maxSplits: 3)
        guard words.count >= 2 else { return text }

        let pronouns: Set<String> = ["i", "they", "he", "she", "we", "it", "you"]
        let first = String(words[0]).lowercased()
            .trimmingCharacters(in: .punctuationCharacters)

        guard pronouns.contains(first) else { return text }

        var verb = String(words[1]).lowercased()
            .trimmingCharacters(in: .punctuationCharacters)

        // Fix past tense: "checked" → "check", "reminded" → "remind"
        if verb.hasSuffix("ed"), verb.count > 4 {
            let root = String(verb.dropLast(2))
            if commandVerbs.contains(root) {
                verb = root
            } else if verb.hasSuffix("ked") {
                let altRoot = String(verb.dropLast(3)) + "k"
                if commandVerbs.contains(String(verb.dropLast(3))) {
                    verb = String(verb.dropLast(3))
                } else if commandVerbs.contains(altRoot) {
                    verb = altRoot
                }
            }
        }

        // Only strip the pronoun if the remaining verb is a known command
        if commandVerbs.contains(verb) {
            let rest = words.dropFirst().joined(separator: " ")
            // Replace the original verb with the corrected one
            let restWords = rest.split(separator: " ", maxSplits: 1)
            if restWords.count > 1 {
                return verb.capitalized + " " + String(restWords[1])
            }
            return verb.capitalized
        }

        return text
    }

    // MARK: - Name Detection

    /// Name variants for wake-word / direct-address detection.
    /// Ordered longest-first for greedy matching.
    static let nameVariants = ["faye", "fae", "phase", "fea", "fay", "fey", "fah", "feh", "fei"]

    struct WakeAddressMatch {
        enum MatchKind: String {
            case exact
            case fuzzy
        }

        let range: Range<String.Index>
        let matchedAlias: String
        let matchedToken: String
        let confidence: Float
        let kind: MatchKind
    }

    private struct WordToken {
        let text: String
        let range: Range<String.Index>
        let index: Int
    }

    /// Find the first mention of a Fae name variant in lowercased text.
    ///
    /// Returns `(range, matchedVariant)` or nil if not found.
    /// Only matches at word boundaries (not mid-word).
    static func findNameMention(in text: String, aliases: [String]? = nil) -> (Range<String.Index>, String)? {
        let lower = text.lowercased()
        let variants = (aliases ?? nameVariants)
            .map { normalizeWakeAlias($0) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }

        for variant in variants {
            var searchStart = lower.startIndex
            while searchStart < lower.endIndex,
                  let range = lower.range(of: variant, range: searchStart..<lower.endIndex)
            {
                if isBoundary(range.lowerBound, in: lower, before: true),
                   isBoundary(range.upperBound, in: lower, before: false)
                {
                    return (range, variant)
                }
                searchStart = range.upperBound
            }
        }

        return nil
    }

    /// Find the best direct-address wake match (exact first, then fuzzy near-match).
    static func findWakeAddressMatch(
        in text: String,
        aliases: [String],
        wakeWord: String?
    ) -> WakeAddressMatch? {
        var mergedAliases = aliases
        if let wakeWord {
            let normalizedWakeWord = normalizeWakeAlias(wakeWord)
            if !normalizedWakeWord.isEmpty {
                mergedAliases.append(normalizedWakeWord)
                if let trailing = normalizedWakeWord.split(separator: " ").last {
                    mergedAliases.append(String(trailing))
                }
            }
        }

        let dedupedAliases = Array(Set(mergedAliases.map { normalizeWakeAlias($0) })).filter { !$0.isEmpty }

        if let (range, variant) = findNameMention(in: text, aliases: dedupedAliases) {
            let token = String(text[range]).lowercased()
            return WakeAddressMatch(
                range: range,
                matchedAlias: variant,
                matchedToken: token,
                confidence: 0.98,
                kind: .exact
            )
        }

        // Fuzzy match: short near-miss spellings in early/greeting context.
        let lower = text.lowercased()
        let tokens = tokenizeWords(in: lower)
        guard !tokens.isEmpty else { return nil }

        let greetingTokens: Set<String> = ["hey", "hi", "hello", "yo", "ok", "okay"]
        let singleWordAliases = dedupedAliases.filter { !$0.contains(" ") }

        var best: WakeAddressMatch?
        for token in tokens {
            guard token.text.count >= 3 else { continue }
            for alias in singleWordAliases {
                // For very short aliases (≤3 chars, e.g. "fae"), require exact match only.
                // Common English words like "far", "fan", "fee", "few" are all within
                // edit distance 1 and cause false wake-word triggers.
                let maxDist = alias.count <= 3 ? 0 : (alias.count <= 4 ? 1 : 2)
                let distance = editDistance(token.text, alias)
                guard distance <= maxDist else { continue }

                let firstCharacterMatches = token.text.first == alias.first
                let looksLikeWakeStem = token.text.hasPrefix("fa") || token.text.hasPrefix("fe")
                guard firstCharacterMatches || looksLikeWakeStem else { continue }

                var score = 1.0 - (Float(distance) / Float(max(alias.count, token.text.count)))
                if firstCharacterMatches {
                    score += 0.12
                }
                if token.index <= 1 {
                    score += 0.08
                }
                if token.text.hasPrefix("fa") || token.text.hasPrefix("fe") {
                    score += 0.05
                }

                let hasGreetingPrefix = token.index > 0 && greetingTokens.contains(tokens[token.index - 1].text)
                if hasGreetingPrefix {
                    score += 0.16
                }

                let threshold: Float = (hasGreetingPrefix || token.index <= 1) ? 0.62 : 0.82
                guard score >= threshold else { continue }

                if best == nil || score > (best?.confidence ?? 0) {
                    best = WakeAddressMatch(
                        range: token.range,
                        matchedAlias: alias,
                        matchedToken: token.text,
                        confidence: score,
                        kind: .fuzzy
                    )
                }
            }
        }

        return best
    }

    /// Extract a likely wake-name alias from transcript text.
    ///
    /// Examples:
    /// - "Hey Faeye can you..." -> "faeye"
    /// - "Faye, open settings" -> "faye"
    static func extractWakeAliasCandidate(from text: String) -> String? {
        let lower = text.lowercased()
        let tokens = tokenizeWords(in: lower)
        guard !tokens.isEmpty else { return nil }

        let greetings: Set<String> = ["hey", "hi", "hello", "yo", "ok", "okay"]
        let candidate: String

        if greetings.contains(tokens[0].text), tokens.count > 1 {
            candidate = tokens[1].text
        } else {
            candidate = tokens[0].text
        }

        guard isAliasCandidate(candidate) else { return nil }
        return candidate
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

        return ""
    }

    private static func normalizeWakeAlias(_ text: String) -> String {
        let lower = text.lowercased()
        let mapped = lower.map { ch -> Character in
            if ch.isLetter || ch.isNumber {
                return ch
            }
            return " "
        }
        return String(mapped)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func isBoundary(_ index: String.Index, in text: String, before: Bool) -> Bool {
        if before {
            guard index != text.startIndex else { return true }
            let ch = text[text.index(before: index)]
            return !(ch.isLetter || ch.isNumber)
        }

        guard index != text.endIndex else { return true }
        let ch = text[index]
        return !(ch.isLetter || ch.isNumber)
    }

    private static func tokenizeWords(in text: String) -> [WordToken] {
        var tokens: [WordToken] = []
        var index = text.startIndex
        var currentStart: String.Index?
        var tokenIndex = 0

        while index < text.endIndex {
            let ch = text[index]
            if ch.isLetter || ch.isNumber {
                if currentStart == nil {
                    currentStart = index
                }
            } else if let start = currentStart {
                let range = start..<index
                tokens.append(WordToken(text: String(text[range]), range: range, index: tokenIndex))
                tokenIndex += 1
                currentStart = nil
            }
            index = text.index(after: index)
        }

        if let start = currentStart {
            let range = start..<text.endIndex
            tokens.append(WordToken(text: String(text[range]), range: range, index: tokenIndex))
        }

        return tokens
    }

    static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }

        return previous[b.count]
    }

    private static func isAliasCandidate(_ candidate: String) -> Bool {
        let normalized = normalizeWakeAlias(candidate)
        guard normalized.count >= 2, normalized.count <= 8, !normalized.contains(" ") else {
            return false
        }
        guard normalized.first == "f" else { return false }
        return true
    }
}
