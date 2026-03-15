import Foundation

/// Parses voice commands and approval responses from transcriptions.
///
/// Replaces: `src/voice_command.rs`
enum VoiceCommandParser {

    /// Progressive approval decisions from voice or button UI.
    enum ApprovalDecision: String, Sendable, Equatable {
        case yes                  // Approve this request only
        case no                   // Deny this request
        case always               // Auto-approve this tool name forever
    }

    /// Voice command types that Fae recognizes.
    enum VoiceCommand: Sendable, Equatable {
        case showCanvas
        case hideCanvas
        case showConversation
        case hideConversation
        case showSettings
        case hideSettings
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

        // Canvas commands — word-level matching handles "the" variants.
        if (lower.contains("show") || lower.contains("open")) && lower.contains("canvas") {
            return .showCanvas
        }
        if (lower.contains("hide") || lower.contains("close")) && lower.contains("canvas") {
            return .hideCanvas
        }

        // Conversation panel commands.
        if (lower.contains("show") || lower.contains("open")) && lower.contains("conversation") {
            return .showConversation
        }
        if (lower.contains("hide") || lower.contains("close")) && lower.contains("conversation") {
            return .hideConversation
        }

        // Settings window commands.
        if lower.contains("show settings") || lower.contains("open settings")
            || lower.contains("go to settings") || lower.contains("settings window")
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
            || lower.contains("switch to") || lower.contains("go read")
            || lower.contains("enable full") || lower.contains("full access")
            || lower.contains("assistant mode")
        {
            if lower.contains("assistant") || lower.contains("read only") || lower.contains("read-only")
                || lower.contains("safe mode")
            {
                return .setToolMode("assistant")
            }
            if lower.contains("full") {
                return .setToolMode("full")
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
            // Check disable phrases first — "don't let me" must win over the "let me" substring.
            if lower.contains("disable") || lower.contains("turn off") || lower.contains("don't let me") || lower.contains("stop letting") {
                return .setBargeIn(false)
            }
            if lower.contains("enable") || lower.contains("turn on") || lower.contains("let me") {
                return .setBargeIn(true)
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
    /// Returns an `ApprovalDecision` or `nil` for ambiguous input.
    /// Checks "always" phrases first (most-specific wins).
    static func parseApprovalResponse(_ text: String) -> ApprovalDecision? {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        let alwaysPhrases = ["always allow", "always approve", "trust this tool",
                             "always trust"]
        for phrase in alwaysPhrases {
            if lower.contains(phrase) { return .always }
        }
        // Bare "always" — match only when no deny indicators are present.
        // Prevents "always deny" or "not always" from returning .always.
        if lower.contains("always") {
            let denyIndicators = ["not", "don't", "deny", "denied", "cancel",
                                  "stop", "never", "nah", "nope", "abort"]
            let hasDenyContext = denyIndicators.contains { lower.contains($0) }
            if !hasDenyContext { return .always }
        }

        let denyWords = ["no", "nah", "nope", "don't", "stop", "cancel",
                         "deny", "denied", "negative", "abort"]
        for word in denyWords {
            if lower.contains(word) { return .no }
        }

        let approveWords = ["yes", "yeah", "yep", "yup", "sure", "okay", "ok",
                            "go ahead", "do it", "approve", "confirmed", "affirmative"]
        for word in approveWords {
            if lower.contains(word) { return .yes }
        }

        return nil // Ambiguous
    }
}
