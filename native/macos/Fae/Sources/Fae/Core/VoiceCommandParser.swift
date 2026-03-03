import Foundation

/// Parses voice commands and approval responses from transcriptions.
///
/// Replaces: `src/voice_command.rs`
enum VoiceCommandParser {

    /// Voice command types that Fae recognizes.
    enum VoiceCommand: Sendable, Equatable {
        case showConversation
        case hideConversation
        case showCanvas
        case hideCanvas
        case showSettings
        case showPermissionsCanvas
        case setToolMode(String)
        case setThinking(Bool)
        case setBargeIn(Bool)
        case setDirectAddress(Bool)
        case setVision(Bool)
        case setVoiceIdentityLock(Bool)
        case requestPermission(String)
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
            || lower.contains("show tools i can use") || lower.contains("show available tools")
            || lower.contains("show tools and permissions")
        {
            return .showPermissionsCanvas
        }

        // Permission requests.
        if lower.contains("request") || lower.contains("grant") || lower.contains("enable") {
            if lower.contains("screen recording") {
                return .requestPermission("screen_recording")
            }
            if lower.contains("camera") {
                return .requestPermission("camera")
            }
            if lower.contains("microphone") || lower.contains("mic") {
                return .requestPermission("microphone")
            }
            if lower.contains("contacts") {
                return .requestPermission("contacts")
            }
            if lower.contains("calendar") {
                return .requestPermission("calendar")
            }
            if lower.contains("reminders") {
                return .requestPermission("reminders")
            }
            if lower.contains("accessibility") || lower.contains("automation") {
                return .requestPermission("desktop_automation")
            }
        }

        // Tool mode changes.
        if lower.contains("set tool mode") || lower.contains("tool mode") || lower.contains("tools mode")
            || lower.contains("set tools to") || lower.contains("use tool mode")
        {
            if lower.contains("no approval") || lower.contains("without approval") || lower.contains("fully autonomous") {
                return .setToolMode("full_no_approval")
            }
            if lower.contains("read write") || lower.contains("read and write") {
                return .setToolMode("read_write")
            }
            if lower.contains("read only") || lower.contains("safe mode") {
                return .setToolMode("read_only")
            }
            if lower.contains("full") {
                return .setToolMode("full")
            }
            if lower.contains("off") || lower.contains("disable tools") {
                return .setToolMode("off")
            }
        }

        if lower.contains("thinking") {
            if lower.contains("enable") || lower.contains("turn on") || lower.contains("with thinking") {
                return .setThinking(true)
            }
            if lower.contains("disable") || lower.contains("turn off") || lower.contains("without thinking") {
                return .setThinking(false)
            }
        }

        if lower.contains("barge") || lower.contains("interrupt") {
            if lower.contains("enable") || lower.contains("turn on") || lower.contains("let me") {
                return .setBargeIn(true)
            }
            if lower.contains("disable") || lower.contains("turn off") || lower.contains("don't let me") {
                return .setBargeIn(false)
            }
        }

        if lower.contains("direct address") || lower.contains("say your name") || lower.contains("say fae") {
            if lower.contains("require") || lower.contains("enable") || lower.contains("turn on") || lower.contains("only respond") {
                return .setDirectAddress(true)
            }
            if lower.contains("disable") || lower.contains("turn off") || lower.contains("don't require") {
                return .setDirectAddress(false)
            }
        }

        if lower.contains("vision") {
            if lower.contains("enable") || lower.contains("turn on") {
                return .setVision(true)
            }
            if lower.contains("disable") || lower.contains("turn off") {
                return .setVision(false)
            }
        }

        if lower.contains("voice lock") || lower.contains("canonical voice") || lower.contains("lock your voice") {
            if lower.contains("disable") || lower.contains("turn off") || lower.contains("allow custom") || lower.contains("unlock") {
                return .setVoiceIdentityLock(false)
            }
            if lower.contains("enable") || lower.contains("turn on") || lower.contains("lock") {
                return .setVoiceIdentityLock(true)
            }
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
