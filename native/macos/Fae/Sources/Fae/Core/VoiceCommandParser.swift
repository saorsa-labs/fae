import Foundation

/// Parses voice commands and approval responses from transcriptions.
///
/// Replaces: `src/voice_command.rs`
enum VoiceCommandParser {

    /// Voice command types that Fae recognizes.
    enum VoiceCommand: Sendable {
        case showConversation
        case hideConversation
        case showCanvas
        case hideCanvas
        case showSettings
        case showPermissionsCanvas
        case switchModel(String)
        case approvalResponse(Bool)
        case none
    }

    /// Parse a transcription into a voice command.
    static func parse(_ text: String) -> VoiceCommand {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Conversation/discussions window commands.
        if lower.contains("show conversation") || lower.contains("open conversation")
            || lower.contains("show discussions") || lower.contains("open discussions")
        {
            return .showConversation
        }
        if lower.contains("hide conversation") || lower.contains("close conversation")
            || lower.contains("hide discussions") || lower.contains("close discussions")
        {
            return .hideConversation
        }

        // Canvas commands.
        if lower.contains("show canvas") || lower.contains("open canvas") {
            return .showCanvas
        }
        if lower.contains("hide canvas") || lower.contains("close canvas") {
            return .hideCanvas
        }

        // Settings commands.
        if lower.contains("show settings") || lower.contains("open settings")
            || lower.contains("open preferences")
        {
            return .showSettings
        }

        // Tool + permission snapshot canvas commands.
        if lower.contains("show permissions") || lower.contains("show tool permissions")
            || lower.contains("show tools I can use") || lower.contains("show available tools")
            || lower.contains("show tools and permissions")
        {
            return .showPermissionsCanvas
        }

        return .none
    }

    /// Parse an approval response from a transcription.
    ///
    /// Returns `true` for approval, `false` for denial, `nil` for ambiguous.
    static func parseApprovalResponse(_ text: String) -> Bool? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let approveWords = ["yes", "yeah", "yep", "yup", "sure", "okay", "ok",
                            "go ahead", "do it", "approve", "confirmed", "affirmative"]
        let denyWords = ["no", "nah", "nope", "don't", "stop", "cancel",
                         "deny", "denied", "negative", "abort"]

        for word in approveWords {
            if lower.contains(word) { return true }
        }
        for word in denyWords {
            if lower.contains(word) { return false }
        }

        return nil // Ambiguous
    }
}
