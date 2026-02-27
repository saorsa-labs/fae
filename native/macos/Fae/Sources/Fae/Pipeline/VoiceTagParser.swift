import Foundation

/// A segment of text annotated with an optional character voice.
struct VoiceSegment: Sendable {
    /// The text content to speak.
    let text: String
    /// Character name, or nil for narrator (Fae's default voice).
    let character: String?
}

/// Streaming parser for `<voice character="Name">dialog</voice>` tags.
///
/// Processes tokens incrementally as they arrive from the LLM, extracting
/// voice-annotated segments for multi-character TTS rendering.
/// Analogous to `TextProcessing.ThinkTagStripper` but for voice tags.
struct VoiceTagStripper {
    private var buffer: String = ""
    private var insideVoice: Bool = false
    private var currentCharacter: String?
    private var voiceContentBuffer: String = ""

    /// Process a chunk of visible text. Returns segments ready for TTS.
    mutating func process(_ text: String) -> [VoiceSegment] {
        buffer += text
        return extractSegments()
    }

    /// Flush remaining buffer at end of generation.
    mutating func flush() -> [VoiceSegment] {
        var segments: [VoiceSegment] = []

        if insideVoice {
            // Unterminated voice tag — emit what we have with the character voice.
            if !voiceContentBuffer.isEmpty {
                segments.append(VoiceSegment(text: voiceContentBuffer, character: currentCharacter))
                voiceContentBuffer = ""
            }
            insideVoice = false
            currentCharacter = nil
        }

        if !buffer.isEmpty {
            segments.append(VoiceSegment(text: buffer, character: nil))
            buffer = ""
        }

        return segments
    }

    // MARK: - Private

    private mutating func extractSegments() -> [VoiceSegment] {
        var segments: [VoiceSegment] = []

        while !buffer.isEmpty {
            if insideVoice {
                // Look for closing </voice> tag.
                if let closeRange = buffer.range(of: "</voice>") {
                    // Text before the close tag belongs to this character.
                    let content = String(buffer[..<closeRange.lowerBound])
                    voiceContentBuffer += content

                    if !voiceContentBuffer.isEmpty {
                        segments.append(VoiceSegment(
                            text: voiceContentBuffer,
                            character: currentCharacter
                        ))
                        voiceContentBuffer = ""
                    }

                    buffer = String(buffer[closeRange.upperBound...])
                    insideVoice = false
                    currentCharacter = nil
                } else if buffer.couldBePartialClosingTag() {
                    // Buffer might end with a partial "</voic" — wait for more tokens.
                    break
                } else {
                    // No closing tag and no partial — accumulate all as voice content.
                    voiceContentBuffer += buffer
                    buffer = ""
                    break
                }
            } else {
                // Look for opening <voice character="Name"> tag.
                if let openRange = buffer.range(of: "<voice ") {
                    // Emit narrator text before the tag.
                    let before = String(buffer[..<openRange.lowerBound])
                    if !before.isEmpty {
                        segments.append(VoiceSegment(text: before, character: nil))
                    }

                    // Find the closing > of the opening tag.
                    let afterOpen = buffer[openRange.upperBound...]
                    if let tagClose = afterOpen.range(of: ">") {
                        let tagContent = String(afterOpen[..<tagClose.lowerBound])
                        currentCharacter = Self.extractCharacterName(from: tagContent)
                        insideVoice = true
                        voiceContentBuffer = ""
                        buffer = String(afterOpen[tagClose.upperBound...])
                    } else {
                        // Partial opening tag — wait for more tokens.
                        buffer = String(buffer[openRange.lowerBound...])
                        break
                    }
                } else if buffer.couldBePartialOpeningTag() {
                    // Buffer might end with a partial "<voice" or "<voi" — wait.
                    // Emit everything before the potential partial tag.
                    if let partialStart = buffer.rangeOfPartialOpeningTag() {
                        let before = String(buffer[..<partialStart.lowerBound])
                        if !before.isEmpty {
                            segments.append(VoiceSegment(text: before, character: nil))
                        }
                        buffer = String(buffer[partialStart.lowerBound...])
                    }
                    break
                } else {
                    // No voice tags — emit everything as narrator.
                    segments.append(VoiceSegment(text: buffer, character: nil))
                    buffer = ""
                }
            }
        }

        return segments
    }

    /// Extract character name from tag attributes like `character="Hamlet"`.
    private static func extractCharacterName(from attributes: String) -> String? {
        // Match character="..." or character='...'
        let patterns = [
            #"character\s*=\s*"([^"]*)""#,
            #"character\s*=\s*'([^']*)'"#,
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(
                   in: attributes,
                   range: NSRange(attributes.startIndex..., in: attributes)
               ),
               let range = Range(match.range(at: 1), in: attributes)
            {
                return String(attributes[range])
            }
        }
        return nil
    }
}

// MARK: - Optional Async Helper

extension Optional {
    /// Async version of flatMap for optional values.
    func asyncFlatMap<U>(_ transform: (Wrapped) async -> U?) async -> U? {
        switch self {
        case .some(let value):
            return await transform(value)
        case .none:
            return nil
        }
    }
}

// MARK: - String Helpers for Partial Tag Detection

private extension String {
    /// Check if the string could end with a partial `</voice>` tag.
    func couldBePartialClosingTag() -> Bool {
        let suffix = "</voice>"
        for len in 1..<suffix.count {
            let partial = String(suffix.prefix(len))
            if self.hasSuffix(partial) {
                return true
            }
        }
        return false
    }

    /// Check if the string could end with a partial `<voice ` opening.
    func couldBePartialOpeningTag() -> Bool {
        let prefix = "<voice "
        for len in 1..<prefix.count {
            let partial = String(prefix.prefix(len))
            if self.hasSuffix(partial) {
                return true
            }
        }
        return false
    }

    /// Find the start of a potential partial opening tag at the end of the string.
    func rangeOfPartialOpeningTag() -> Range<String.Index>? {
        let prefix = "<voice "
        for len in stride(from: prefix.count - 1, through: 1, by: -1) {
            let partial = String(prefix.prefix(len))
            if self.hasSuffix(partial) {
                let start = self.index(self.endIndex, offsetBy: -len)
                return start..<self.endIndex
            }
        }
        return nil
    }
}
