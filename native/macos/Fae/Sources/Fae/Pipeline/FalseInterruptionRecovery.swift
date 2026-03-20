import Foundation

/// Tracks interruption outcomes and detects false interruptions.
///
/// A false interruption occurs when the user didn't actually intend to interrupt
/// (e.g., short noise burst, backchannel "yeah" that triggered barge-in).
/// Detection: after interruption fires, if no meaningful continued speech appears
/// within the timeout window, it's classified as a false interrupt.
///
/// Recovery strategy (ordered by preference):
/// 1. **Resume** — if playback was paused (not stopped), resume from exact position.
/// 2. **Repair utterance** — speak a short contextual message referencing what Fae
///    was saying. Used when pause/resume is not available (e.g., TTS was cancelled).
struct FalseInterruptionRecovery: Sendable {
    private let timeoutMs: Int
    private let enabled: Bool

    /// The most recent interruption outcome, if any.
    private(set) var lastInterruption: InterruptionOutcome?

    /// Whether we're in the recovery observation window.
    private(set) var observing: Bool = false

    /// When the observation window started.
    private var observationStartedAt: Date?

    /// Whether meaningful follow-up speech was detected during observation.
    private var followUpDetected: Bool = false

    /// Whether playback was paused (not stopped) at interruption —
    /// indicates resume is possible instead of repair utterance.
    private(set) var playbackWasPaused: Bool = false

    init(timeoutMs: Int = 1800, enabled: Bool = true) {
        self.timeoutMs = timeoutMs
        self.enabled = enabled
    }

    /// Record that an interruption just fired.
    ///
    /// - Parameters:
    ///   - outcome: The interruption outcome with context about what was interrupted.
    ///   - paused: Whether playback was paused (true) or stopped (false). When paused,
    ///     recovery will attempt resume instead of speaking a repair utterance.
    mutating func recordInterruption(outcome: InterruptionOutcome, paused: Bool = false) {
        guard enabled else { return }
        lastInterruption = outcome
        observing = true
        observationStartedAt = Date()
        followUpDetected = false
        playbackWasPaused = paused
    }

    /// Called when meaningful speech is detected after the interruption.
    /// This confirms the interruption was intentional.
    mutating func recordFollowUpSpeech() {
        followUpDetected = true
        observing = false
        observationStartedAt = nil
        playbackWasPaused = false
    }

    /// Check whether the observation window has expired without follow-up.
    /// Returns a recovery action if this was a false interruption.
    mutating func checkTimeout(now: Date = Date()) -> FalseInterruptionResult {
        guard enabled, observing else { return .noAction }
        guard let startedAt = observationStartedAt else {
            observing = false
            return .noAction
        }

        let elapsedMs = Int(now.timeIntervalSince(startedAt) * 1000)
        if elapsedMs < timeoutMs {
            return .stillObserving
        }

        // Observation window expired.
        observing = false
        observationStartedAt = nil

        if followUpDetected {
            playbackWasPaused = false
            return .noAction
        }

        // False interruption detected — choose recovery strategy.
        if playbackWasPaused {
            playbackWasPaused = false
            return .resumePlayback
        }

        guard let interrupted = lastInterruption else {
            playbackWasPaused = false
            return .noAction
        }
        let repair = Self.buildRepairUtterance(interruptedText: interrupted.interruptedText)
        playbackWasPaused = false
        return .falseInterruption(repair: repair)
    }

    /// Cancel observation (e.g., pipeline reset).
    mutating func cancel() {
        observing = false
        observationStartedAt = nil
        followUpDetected = false
        playbackWasPaused = false
    }

    // MARK: - Repair Utterance

    /// Build a short repair message based on what was interrupted.
    static func buildRepairUtterance(interruptedText: String?) -> String {
        guard let text = interruptedText, !text.isEmpty else {
            return "Sorry, I thought you were jumping in. What were you going to say?"
        }

        // Extract the last meaningful clause for context.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(separator: " ")

        if words.count <= 5 {
            return "I thought you were jumping in — I was saying: \(trimmed)"
        }

        // Take the last ~8 words for a brief recap.
        let tail = words.suffix(8).joined(separator: " ")
        return "I thought you were jumping in — I was saying: …\(tail)"
    }
}

/// Result of a false-interruption recovery check.
enum FalseInterruptionResult: Sendable, Equatable {
    /// No action needed (not observing, or follow-up confirmed).
    case noAction
    /// Still within the observation window.
    case stillObserving
    /// False interruption detected — resume paused playback from exact position.
    case resumePlayback
    /// False interruption detected — speak the repair utterance (pause unavailable).
    case falseInterruption(repair: String)
}
