import Foundation

/// Parses the S18 audio-turn transcript contract.
///
/// When a turn carries audio directly to Gemma (push-to-talk), the system
/// prompt instructs the model to begin its reply with one line:
///
///     [heard]: <verbatim transcription of the user's speech>
///
/// That line becomes the user-turn transcript (conversation panel + memory
/// capture) and is never spoken. The remainder — minus any tool-call markup
/// the model leaks into the text channel — is the spoken reply.
enum HeardLineParser {
    /// Split the leading `[heard]:` line from a reply. Returns the heard
    /// transcription (nil when the model did not honour the contract) and the
    /// remainder of the reply.
    static func split(_ text: String) -> (heard: String?, remainder: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = "[heard]:"
        guard trimmed.lowercased().hasPrefix(marker) else {
            return (nil, text)
        }
        let afterMarker = trimmed.dropFirst(marker.count)
        if let newline = afterMarker.firstIndex(of: "\n") {
            let heard = afterMarker[..<newline].trimmingCharacters(in: .whitespacesAndNewlines)
            let remainder = String(afterMarker[afterMarker.index(after: newline)...])
            return (heard.isEmpty ? nil : heard, remainder)
        }
        // Single-line reply: the whole text is the transcription, no spoken
        // remainder (the model heard but had nothing further to add).
        let heard = afterMarker.trimmingCharacters(in: .whitespacesAndNewlines)
        return (heard.isEmpty ? nil : heard, "")
    }

    /// Drop leaked tool-call markup from a reply. Gemma 4 via mistral.rs can
    /// emit raw markup (`<tool_call>` or `<|tool_call>` variants) into the
    /// text channel alongside the parsed structured calls — everything from
    /// the first marker onward is never speakable.
    static func stripToolCallResidue(_ text: String) -> String {
        var cut = text.endIndex
        for marker in ["<tool_call", "<|tool_call"] {
            if let range = text.range(of: marker), range.lowerBound < cut {
                cut = range.lowerBound
            }
        }
        return String(text[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
