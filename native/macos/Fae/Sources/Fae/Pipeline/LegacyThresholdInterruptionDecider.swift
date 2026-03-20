import Foundation

/// Preserves the original fixed-threshold barge-in behavior behind the
/// `InterruptionDeciding` protocol. Acts as a safe baseline and control
/// for A/B testing against the adaptive decider.
///
/// Logic mirrors the pre-refactor `advancePendingBargeIn` + `handleBargeInWithVerification`
/// confirmation check: interrupt when `speechSamples >= confirmSamples` and `rms >= minRms`.
struct LegacyThresholdInterruptionDecider: InterruptionDeciding {
    private let confirmMs: Int
    private let minRms: Float
    private let sampleRate: Int
    private let assistantStartHoldoffMs: Int

    init(
        confirmMs: Int = 200,
        minRms: Float = 0.08,
        sampleRate: Int = 16_000,
        assistantStartHoldoffMs: Int = 200
    ) {
        self.confirmMs = confirmMs
        self.minRms = minRms
        self.sampleRate = sampleRate
        self.assistantStartHoldoffMs = assistantStartHoldoffMs
    }

    mutating func process(_ input: InterruptionInput) -> InterruptionDecision {
        // Hard gates — suppressed, cooldown (echo is now a signal, not a gate).
        if input.bargeInSuppressed {
            return .ignore(reason: "barge_in_suppressed")
        }
        if input.inDenyCooldown {
            return .ignore(reason: "deny_cooldown")
        }

        // Must be audibly speaking to interrupt.
        guard input.assistantSpeaking else {
            return .ignore(reason: "not_speaking")
        }

        // Holdoff — don't interrupt immediately after playback starts.
        if input.assistantSpeechElapsedMs < assistantStartHoldoffMs {
            return .ignore(reason: "holdoff_window")
        }

        // RMS noise floor gate.
        guard input.rms >= minRms else {
            return .ignore(reason: "below_rms_threshold")
        }

        // Echo suppression raises the bar but doesn't hard-block.
        // During echo, require double the normal confirmation time to
        // filter speaker bleedthrough while allowing deliberate speech.
        let effectiveConfirmMs = input.echoSuppression ? confirmMs * 2 : confirmMs
        let confirmSamples = (effectiveConfirmMs * sampleRate) / 1000
        let accumulatedSamples = input.overlapDurationMs * sampleRate / 1000
        if accumulatedSamples >= confirmSamples {
            return .interruptNow(reason: "legacy_threshold_confirmed")
        }

        return .candidate
    }

    mutating func reset() {
        // No internal state to reset in legacy mode.
    }
}
