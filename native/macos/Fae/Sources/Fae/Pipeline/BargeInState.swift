import Foundation

/// Consolidated barge-in state for the voice pipeline.
///
/// Groups all barge-in related state variables that were previously scattered
/// across PipelineCoordinator. The coordinator delegates state tracking to this
/// struct while keeping side-effect methods (playback control, echo suppression)
/// in the coordinator itself.
///
/// Covers three interrupt paths:
/// - **Path A**: Playback barge-in (identity-based, during active TTS)
/// - **Path B**: Echo-gated barge-in (post-playback, threshold-based)
/// - **Path C**: Generation takeover (during silent LLM generation)
struct BargeInState {

    // MARK: - Path B: Echo-Gated Barge-In

    /// Pending barge-in candidate accumulated from VAD speech chunks.
    var pendingBargeIn: PendingBargeIn?

    /// When true, barge-in is suppressed. Set during short non-interruptible
    /// utterances (speakDirect) to prevent background noise from interrupting
    /// command acknowledgments and approval responses.
    var isSuppressed: Bool = false

    // MARK: - Path A: Playback Barge-In

    /// Candidate for barge-in during active playback.
    var playbackCandidate: PlaybackBargeInCandidate?

    /// Whether a wake word was detected during current playback session.
    var playbackWakeWordDetected: Bool = false

    /// Whether an interrupt keyword (for example "stop") was detected during
    /// the current playback session.
    var playbackInterruptKeywordDetected: Bool = false

    /// Cooldown after non-owner barge-in denial — prevents repeated embedding
    /// churn from TV/noise.
    var denyCooldownUntil: Date?

    /// Duration of the deny cooldown window.
    static let denyCooldownSeconds: TimeInterval = 2.0

    // MARK: - Interruption Strategy

    /// Interruption decider — strategy pattern for barge-in decisions.
    var interruptionDecider: any InterruptionDeciding

    /// False-interruption recovery tracker.
    var falseInterruptionRecovery: FalseInterruptionRecovery

    /// Buffer of assistant text at the point of interruption (for recovery).
    var lastAssistantTextBuffer: String = ""

    // MARK: - Path C: Generation Takeover

    /// Tracks user speech energy during silent generation. When the user speaks
    /// strongly enough (sustained energy or interrupt keyword), the current
    /// generation is cancelled and the segment flows through normally.
    var generationTakeoverCandidate: GenerationTakeoverCandidate?

    // MARK: - Initialization

    /// Create barge-in state with the required strategy components.
    /// All other state starts at its default (nil/false/empty).
    init(
        interruptionDecider: any InterruptionDeciding,
        falseInterruptionRecovery: FalseInterruptionRecovery
    ) {
        self.interruptionDecider = interruptionDecider
        self.falseInterruptionRecovery = falseInterruptionRecovery
    }

    // MARK: - Convenience

    /// Whether the deny cooldown is currently active.
    var isInDenyCooldown: Bool {
        guard let until = denyCooldownUntil else { return false }
        return Date() < until
    }

    /// Start a deny cooldown after a non-owner barge-in rejection.
    mutating func startDenyCooldown() {
        denyCooldownUntil = Date().addingTimeInterval(Self.denyCooldownSeconds)
    }

    /// Reset all playback barge-in state for a new playback session.
    mutating func resetPlaybackState() {
        playbackCandidate = nil
        playbackWakeWordDetected = false
        playbackInterruptKeywordDetected = false
    }

    /// Record an interruption for false-interruption recovery.
    mutating func recordInterruption(outcome: InterruptionOutcome, paused: Bool) {
        falseInterruptionRecovery.recordInterruption(outcome: outcome, paused: paused)
    }

    /// Clear all barge-in state on pipeline stop or reset.
    mutating func clearAll() {
        pendingBargeIn = nil
        isSuppressed = false
        playbackCandidate = nil
        playbackWakeWordDetected = false
        playbackInterruptKeywordDetected = false
        denyCooldownUntil = nil
        generationTakeoverCandidate = nil
        lastAssistantTextBuffer = ""
    }
}
