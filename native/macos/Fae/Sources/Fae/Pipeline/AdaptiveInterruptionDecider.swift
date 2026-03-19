import Foundation

/// Adaptive interruption decider with acoustic + semantic signals.
///
/// Phase 2a: Acoustic heuristics (RMS persistence, peak ratio, sustained chunks).
/// Phase 2b: Semantic signals (partial transcript, keyword detection, backchannel suppression).
///
/// Design principles:
/// - Echo suppression and barge-in suppression remain hard pre-filters
///   (handled in PipelineCoordinator before the decider sees them).
/// - Owner verification still happens AFTER the decider says `.interruptNow`.
/// - All thresholds are configurable via `AdaptiveInterruptionConfig`.
struct AdaptiveInterruptionDecider: InterruptionDeciding {
    private let config: AdaptiveInterruptionConfig
    private let sampleRate: Int
    private let assistantStartHoldoffMs: Int
    private let minRms: Float

    /// Rolling RMS history for energy persistence detection.
    private var rmsHistory: [Float] = []
    private static let rmsHistoryMaxSize = 20

    init(
        config: AdaptiveInterruptionConfig = AdaptiveInterruptionConfig(),
        sampleRate: Int = 16_000,
        assistantStartHoldoffMs: Int = 500,
        minRms: Float = 0.08
    ) {
        self.config = config
        self.sampleRate = sampleRate
        self.assistantStartHoldoffMs = assistantStartHoldoffMs
        self.minRms = minRms
    }

    mutating func process(_ input: InterruptionInput) -> InterruptionDecision {
        // Hard gates — same as legacy, these are non-negotiable.
        if input.echoSuppression {
            return .ignore(reason: "echo_suppression")
        }
        if input.bargeInSuppressed {
            return .ignore(reason: "barge_in_suppressed")
        }
        if input.inDenyCooldown {
            return .ignore(reason: "deny_cooldown")
        }
        guard input.assistantSpeaking else {
            return .ignore(reason: "not_speaking")
        }

        // Holdoff — don't interrupt immediately after playback starts.
        if input.assistantSpeechElapsedMs < assistantStartHoldoffMs {
            return .ignore(reason: "holdoff_window")
        }

        // RMS noise floor gate — must exceed baseline.
        guard input.rms >= minRms else {
            return .ignore(reason: "below_rms_threshold")
        }

        // Track RMS for persistence analysis.
        rmsHistory.append(input.rms)
        if rmsHistory.count > Self.rmsHistoryMaxSize {
            rmsHistory.removeFirst(rmsHistory.count - Self.rmsHistoryMaxSize)
        }

        // --- Semantic fast paths (Phase 2b) ---

        // Interrupt keyword detected — fire immediately (no overlap minimum).
        if input.hasInterruptKeyword {
            return .interruptNow(reason: "interrupt_keyword")
        }

        // Backchannel suppression — if the only transcript evidence is a
        // backchannel phrase, suppress unless overlap is very long.
        if BackchannelClassifier.isBackchannel(input.partialTranscript) {
            let longOverlapMs = config.minOverlapMs * 3
            if input.overlapDurationMs < longOverlapMs {
                return .ignore(reason: "backchannel_suppressed")
            }
            // Very long backchannel — user may be continuing, fall through.
        }

        // --- Adaptive decision logic ---

        let overlapMs = input.overlapDurationMs

        // Too early — not enough overlap to judge.
        if overlapMs < 150 {
            return .candidate
        }

        // Transcript-boosted path: if we have real words (not just a backchannel),
        // lower the overlap threshold — the user is genuinely speaking.
        let hasTranscriptEvidence = input.partialWordCount >= 1
            && !BackchannelClassifier.isBackchannel(input.partialTranscript)

        // Strong acoustic evidence: sustained overlap + energy persistence.
        let hasSustainedEnergy = isSustainedEnergy(floor: config.rmsSustainFloor)
        let hasStrongPeak = input.peakRms >= config.rmsSustainFloor * config.peakRmsRatio
        let hasSufficientChunks = input.consecutiveSpeechChunks >= config.minSustainedChunks

        // Semantic-boosted fast path: transcript evidence lowers the bar.
        if hasTranscriptEvidence && overlapMs >= 200 && (hasSustainedEnergy || hasStrongPeak) {
            return .interruptNow(reason: "adaptive_transcript_boosted")
        }

        // Fast path: clear sustained speech with strong energy.
        if overlapMs >= config.minOverlapMs && hasSustainedEnergy && hasStrongPeak && hasSufficientChunks {
            return .interruptNow(reason: "adaptive_sustained_speech")
        }

        // Medium confidence: longer overlap compensates for weaker energy.
        let extendedOverlapMs = config.minOverlapMs + 150
        if overlapMs >= extendedOverlapMs && hasSufficientChunks && (hasSustainedEnergy || hasStrongPeak) {
            return .interruptNow(reason: "adaptive_extended_overlap")
        }

        // Very long overlap: even without perfect energy profile, something real is happening.
        let longOverlapMs = config.minOverlapMs * 2
        if overlapMs >= longOverlapMs && input.consecutiveSpeechChunks >= 2 {
            return .interruptNow(reason: "adaptive_long_overlap")
        }

        return .candidate
    }

    mutating func reset() {
        rmsHistory = []
    }

    // MARK: - Energy Analysis

    /// Returns true if recent RMS values show sustained energy above the floor.
    /// Requires at least 60% of recent history to be above threshold.
    private func isSustainedEnergy(floor: Float) -> Bool {
        guard rmsHistory.count >= 3 else { return false }
        let recentCount = min(rmsHistory.count, 8)
        let recent = rmsHistory.suffix(recentCount)
        let aboveFloor = recent.filter { $0 >= floor }.count
        return Float(aboveFloor) / Float(recentCount) >= 0.6
    }
}
