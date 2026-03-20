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

// MARK: - Pure Decision Functions

/// Namespace for pure (static) barge-in decision functions.
///
/// These functions have no side effects and depend only on their parameters.
/// Extracted from PipelineCoordinator to reduce coordinator complexity.
/// PipelineCoordinator retains forwarding static methods for API compatibility.
enum BargeInDecisions {

    /// Whether barge-in tracking should be active (only during audible speech).
    static func shouldTrackBargeIn(assistantSpeaking: Bool) -> Bool {
        assistantSpeaking
    }

    /// Whether PATH C (generation takeover) should be active.
    /// True only when the LLM is generating silently (no TTS playing).
    static func shouldTrackGenerationTakeover(
        assistantSpeaking: Bool,
        assistantGenerating: Bool
    ) -> Bool {
        assistantGenerating && !assistantSpeaking
    }

    /// Advance the pending barge-in candidate with the latest audio chunk.
    ///
    /// Echo suppression gates candidate **creation** — prevents Fae from hearing
    /// her own TTS output as a barge-in attempt. Once playback stops and the
    /// echo tail expires, candidates are created normally.
    static func advancePendingBargeIn(
        pending: PendingBargeIn?,
        speechStarted: Bool,
        isSpeech: Bool,
        chunkSamples: [Float],
        rms: Float,
        echoSuppression: Bool,
        bargeInSuppressed: Bool,
        inDenyCooldown: Bool
    ) -> PendingBargeIn? {
        var next = pending
        if speechStarted && !echoSuppression && !bargeInSuppressed && !inDenyCooldown {
            next = PendingBargeIn(capturedAt: Date(), lastRms: rms, peakRms: rms)
        } else if speechStarted && (echoSuppression || bargeInSuppressed || inDenyCooldown) {
            return nil
        }

        if isSpeech, next != nil {
            next?.speechSamples += chunkSamples.count
            next?.lastRms = rms
            let currentPeak = next?.peakRms ?? 0
            next?.peakRms = max(currentPeak, rms)
            next?.consecutiveSpeechChunks += 1
            let remainingCapacity = max(0, 16_000 - (next?.audioSamples.count ?? 0))
            if remainingCapacity > 0 {
                next?.audioSamples.append(contentsOf: chunkSamples.prefix(remainingCapacity))
            }
        } else if !isSpeech, next != nil {
            next?.consecutiveSpeechChunks = 0
        }

        return next
    }

    /// Whether barge-in interruption should be allowed.
    /// Only allows interruption during audible speech — not during silent generation.
    static func shouldAllowBargeInInterrupt(
        assistantSpeaking: Bool,
        assistantGenerating: Bool
    ) -> Bool {
        assistantSpeaking
    }

    /// Whether a deferred follow-up should start.
    /// Blocked while assistant is speaking or generating. Checks turn ID match.
    static func shouldStartDeferredFollowUp(
        originTurnID: String?,
        currentTurnID: String?,
        assistantSpeaking: Bool,
        assistantGenerating: Bool
    ) -> Bool {
        guard !assistantSpeaking, !assistantGenerating else { return false }
        guard let originTurnID else { return true }
        return originTurnID == currentTurnID
    }

    /// Coalesce deferred proactive task IDs, deduplicating the incoming task.
    static func coalescedDeferredProactiveTaskIDs(
        existing: [String],
        incomingTaskID: String
    ) -> [String] {
        var next = existing.filter { $0 != incomingTaskID }
        next.append(incomingTaskID)
        return next
    }
}
