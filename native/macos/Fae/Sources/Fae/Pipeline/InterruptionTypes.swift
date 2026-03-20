import Foundation

/// Snapshot of all signals available for making an interruption decision.
/// Constructed in the pipeline loop from ambient state each time a barge-in
/// candidate accumulates enough speech to evaluate.
struct InterruptionInput: Sendable {
    /// Assistant is audibly speaking (TTS playing).
    let assistantSpeaking: Bool
    /// VAD detected speech onset this chunk.
    let speechStarted: Bool
    /// VAD currently classifies audio as speech.
    let isSpeech: Bool
    /// Current RMS energy level.
    let rms: Float
    /// Raw audio samples for this chunk.
    let chunkSamples: [Float]
    /// Duration of overlap between user speech and assistant speech (ms).
    let overlapDurationMs: Int
    /// Time since assistant started speaking (ms).
    let assistantSpeechElapsedMs: Int
    /// Echo suppressor is currently active.
    let echoSuppression: Bool
    /// Barge-in is suppressed (speakDirect mode).
    let bargeInSuppressed: Bool
    /// In deny cooldown after failed speaker verification.
    let inDenyCooldown: Bool
    /// Peak RMS observed during this barge-in candidate.
    let peakRms: Float
    /// Number of consecutive speech chunks accumulated.
    let consecutiveSpeechChunks: Int

    // MARK: - Semantic signals (Phase 2b)

    /// Partial transcript from streaming STT (nil if unavailable).
    let partialTranscript: String?
    /// Word count in the partial transcript.
    let partialWordCount: Int
    /// Whether an interrupt keyword was detected in the partial transcript.
    let hasInterruptKeyword: Bool
}

/// Decision output from an interruption decider.
enum InterruptionDecision: Sendable, Equatable {
    /// Ignore this overlap — not a real interruption.
    case ignore(reason: String)
    /// Keep collecting — not enough evidence yet.
    case candidate
    /// Fire the interruption immediately.
    case interruptNow(reason: String)

    static func == (lhs: InterruptionDecision, rhs: InterruptionDecision) -> Bool {
        switch (lhs, rhs) {
        case (.candidate, .candidate):
            return true
        case let (.ignore(a), .ignore(b)):
            return a == b
        case let (.interruptNow(a), .interruptNow(b)):
            return a == b
        default:
            return false
        }
    }
}

/// Tracks the outcome of an interruption for false-interruption recovery.
struct InterruptionOutcome: Sendable {
    /// When the interruption fired.
    let interruptedAt: Date
    /// The generation ID that was interrupted.
    let generationID: UUID?
    /// The assistant text buffer at the point of interruption (if available).
    let interruptedText: String?
    /// How much of the response had been spoken (approximate percentage).
    let spokenFraction: Float
}

/// Backchannel detection — short acknowledgment phrases that should not
/// trigger a hard interrupt unless the user continues speaking.
enum BackchannelClassifier {
    /// Phrases that are pure backchannels, fillers, or non-speech sounds
    /// when spoken in isolation. These should not trigger a hard interrupt.
    static let phrases: Set<String> = [
        // Backchannels
        "mm", "mhm", "uh-huh", "uh huh", "yeah", "yep", "yup",
        "right", "okay", "ok", "sure", "wow", "huh", "ah",
        "hmm", "gotcha", "nice", "cool", "great", "interesting",
        // Fillers and hesitations
        "um", "uh", "er", "erm", "eh", "like", "so", "well",
        "you know", "i mean", "let me",
        // Non-speech sounds that STT may transcribe
        "oh", "ooh", "aah", "ha", "hm", "ugh", "phew", "whoa",
        "oops", "whoops", "heh", "huh huh",
    ]

    /// Returns true if the transcript is purely a backchannel phrase.
    static func isBackchannel(_ text: String?) -> Bool {
        guard let text, !text.isEmpty else { return false }
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[.,!?]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return phrases.contains(normalized)
    }
}

/// Configuration for the adaptive interruption system.
struct AdaptiveInterruptionConfig: Codable, Sendable {
    /// Use adaptive interruption instead of legacy threshold.
    var enabled: Bool = true
    /// Minimum overlap duration before considering interruption (ms).
    /// Reduced from 300→150 for more responsive barge-in.
    var minOverlapMs: Int = 150
    /// RMS energy must be sustained above this floor during overlap.
    /// Reduced from 0.06→0.04 to catch softer deliberate speech.
    var rmsSustainFloor: Float = 0.04
    /// Minimum consecutive speech chunks for strong acoustic evidence.
    /// Reduced from 4→2 for faster interrupt detection.
    var minSustainedChunks: Int = 2
    /// Timeout after interruption to detect false-interrupt (ms).
    var falseInterruptionTimeoutMs: Int = 1200
    /// Whether to attempt recovery from false interruptions.
    var recoverFalseInterruptions: Bool = true
    /// RMS ratio threshold: peak must be this much above sustain floor.
    /// Reduced from 1.5→1.2 for more responsive detection.
    var peakRmsRatio: Float = 1.2
}
