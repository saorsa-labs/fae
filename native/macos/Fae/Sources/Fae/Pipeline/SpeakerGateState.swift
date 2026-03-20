import Foundation

/// Groups all speaker identity state that was previously scattered across
/// PipelineCoordinator as individual instance variables.
///
/// By consolidating ~20 speaker-related state variables into a single struct,
/// we reduce PipelineCoordinator's top-level variable count and make the
/// speaker identity subsystem's state boundaries explicit.
///
/// This type is a value type owned by PipelineCoordinator — no async boundary.
struct SpeakerGateState: Sendable {

    // MARK: - Speaker Identity

    /// Label of the currently identified speaker (profile ID or "unknown").
    var currentSpeakerLabel: String?

    /// Human-readable display name of the current speaker.
    var currentSpeakerDisplayName: String?

    /// Role of the current speaker (owner, guest, etc.).
    var currentSpeakerRole: SpeakerRole?

    /// Whether the current speaker is the verified owner.
    var currentSpeakerIsOwner: Bool = false

    /// True when speaker verification ran and matched a non-owner profile.
    /// Distinguished from "not matched at all" (unknown/degraded) — only this
    /// flag should hard-block tools when `requireOwnerForTools` is enabled.
    var currentSpeakerIsKnownNonOwner: Bool = false

    /// Cached mel-fallback state of the speaker encoder. `nil` until first check.
    /// When `true`, the encoder can only distinguish TTS from human speech — it
    /// cannot discriminate between different humans.
    var speakerEncoderMelFallbackCached: Bool?

    /// Label of the previously identified speaker (for speaker-change detection).
    var previousSpeakerLabel: String?

    /// Number of utterances since the owner was last verified.
    var utterancesSinceOwnerVerified: Int = 0

    /// Wall-clock time when the current utterance was captured by the VAD.
    var currentUtteranceTimestamp: Date?

    // MARK: - Enrollment State

    /// True while first-owner enrollment is actively running.
    /// Set by FaeCore when enrollment starts, cleared on enrollment_complete.
    /// Bypasses direct-address gating and allows barge-in from anyone (no owner yet).
    var firstOwnerEnrollmentActive: Bool = false

    /// One-shot system prompt addition for the LLM's first response after owner enrollment.
    /// Set by FaeCore during the voice enrollment flow; cleared after first use.
    var firstOwnerEnrollmentContext: String?

    // MARK: - Streaming Speaker Gate

    /// Audio samples accumulated for streaming speaker verification.
    var streamingSpeakerSamples: [Float] = []

    /// Number of samples last evaluated by the streaming speaker gate (stride gate).
    var streamingSpeakerLastEvaluatedSamples: Int = 0

    /// Current streaming speaker gate verdict (nil = undecided).
    var streamingSpeakerVerdict: StreamingSpeakerGateVerdict?

    /// Whether streaming speaker verification is available for this segment.
    var streamingSpeakerVerificationAvailable: Bool = false

    /// Streaming speaker gate decision for early rejection of non-owner speech.
    enum StreamingSpeakerGateVerdict: Equatable {
        case allow
        case rejectUnknown
    }

    // MARK: - Mutation Helpers

    /// Reset the streaming speaker gate state for a new segment.
    mutating func resetStreamingSpeakerGate() {
        streamingSpeakerSamples.removeAll(keepingCapacity: true)
        streamingSpeakerLastEvaluatedSamples = 0
        streamingSpeakerVerdict = nil
        streamingSpeakerVerificationAvailable = false
    }

    /// Clear all speaker identity state (used on pipeline stop).
    mutating func clearIdentity() {
        currentSpeakerLabel = nil
        currentSpeakerDisplayName = nil
        currentSpeakerRole = nil
        currentSpeakerIsOwner = false
        currentSpeakerIsKnownNonOwner = false
        previousSpeakerLabel = nil
        utterancesSinceOwnerVerified = 0
        currentUtteranceTimestamp = nil
        resetStreamingSpeakerGate()
    }
}
