import AVFoundation

/// Provides TTS help audio for onboarding permission explanations.
///
/// Uses the macOS built-in `AVSpeechSynthesizer` to speak short privacy
/// reassurance phrases when the user taps a help button on a permission card.
/// This deliberately avoids the Kokoro TTS pipeline so that help audio works
/// immediately on first launch — before any local models have been downloaded.
@MainActor
final class OnboardingTTSHelper: NSObject {

    private let synthesizer = AVSpeechSynthesizer()

    /// Speak the help text for the given permission.
    ///
    /// Calling this while speech is in progress cancels the current utterance
    /// and starts the new one immediately.
    ///
    /// - Parameter permission: One of `"microphone"`, `"contacts"`,
    ///   `"calendar"`, `"mail"`, or `"privacy"` (fallback for unknown values).
    func speak(permission: String) {
        let text = helpText(for: permission)
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.50           // Slightly slower than default for clarity
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0
        synthesizer.speak(utterance)
    }

    /// Stop any in-progress speech immediately.
    func stop() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    // MARK: - Help Text

    private func helpText(for permission: String) -> String {
        switch permission.lowercased().trimmingCharacters(in: .whitespaces) {
        case "microphone":
            return microphoneHelpText
        case "contacts":
            return contactsHelpText
        case "calendar":
            return calendarHelpText
        case "mail":
            return mailHelpText
        default:
            return privacyHelpText
        }
    }

    private let microphoneHelpText = """
        I need to hear your voice so we can have a natural conversation. \
        Your audio is processed entirely on your Mac — nothing is sent to any server. \
        I only listen when you're in a conversation, and you can pause me any time.
        """

    private let contactsHelpText = """
        Your contact card helps me know your name so I can greet you properly. \
        I only read your personal card — not your full contacts list. \
        Everything stays right here on your Mac.
        """

    private let calendarHelpText = """
        I can help manage your schedule — creating reminders, checking appointments, \
        and keeping you organised. \
        Everything stays on your Mac and I never share your calendar data anywhere.
        """

    private let mailHelpText = """
        I can help you find emails and draft messages. \
        I never send anything without you telling me to, \
        and all data stays private on your Mac.
        """

    private let privacyHelpText = """
        Everything I do happens locally on your Mac. \
        Your conversations, memories, and personal details are never sent anywhere. \
        You are always in control.
        """
}
