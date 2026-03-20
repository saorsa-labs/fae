import Foundation

/// Audio state accumulated during post-playback barge-in detection (Path B).
///
/// Tracks speech samples, RMS energy, and keyword classification results
/// while the interruption decider evaluates whether to interrupt the assistant.
struct PendingBargeIn: Sendable {
    /// When the barge-in candidate speech was first captured.
    var capturedAt: Date
    /// Total speech samples accumulated.
    var speechSamples: Int = 0
    /// Most recent chunk RMS.
    var lastRms: Float = 0
    /// Peak RMS seen during this candidate.
    var peakRms: Float = 0
    /// Consecutive chunks classified as speech.
    var consecutiveSpeechChunks: Int = 0
    /// Raw audio samples for speaker identity and keyword classification.
    var audioSamples: [Float] = []
    /// Partial transcript from keyword spotter check.
    var partialTranscript: String?
    /// Whether an interrupt keyword was detected during accumulation.
    var hasInterruptKeyword: Bool = false
}

/// Audio state accumulated during active playback barge-in detection (Path A).
///
/// Unlike ``PendingBargeIn`` (which is echo-gated and used post-playback),
/// this accumulates audio during playback for identity-based interruption.
struct PlaybackBargeInCandidate: Sendable {
    /// When the candidate speech was first captured.
    var capturedAt: Date
    /// Total speech samples accumulated.
    var speechSamples: Int = 0
    /// Most recent chunk RMS.
    var lastRms: Float = 0
    /// Peak RMS seen during this candidate.
    var peakRms: Float = 0
    /// Consecutive chunks classified as speech.
    var consecutiveSpeechChunks: Int = 0
    /// Raw audio samples for speaker identity and keyword classification.
    var audioSamples: [Float] = []

    /// Maximum audio samples to accumulate (1 second at 16 kHz).
    static let maxAudioSamples = 16_000
    /// Minimum samples needed for speaker identity check (~350 ms at 16 kHz).
    static let minSamplesForIdentity = 5_600
}

/// Audio state for generation takeover detection (Path C).
///
/// Tracks user speech energy during silent LLM generation. When the user
/// speaks strongly enough (sustained energy or interrupt keyword), the
/// current generation is cancelled and the segment flows through normally.
struct GenerationTakeoverCandidate: Sendable {
    /// Raw audio samples for keyword classification.
    var audioSamples: [Float] = []
    /// Total speech samples accumulated.
    var speechSamples: Int = 0
    /// Consecutive chunks classified as speech.
    var consecutiveSpeechChunks: Int = 0
    /// Peak RMS seen during this candidate.
    var peakRms: Float = 0
    /// Whether an interrupt keyword was detected during accumulation.
    var hasInterruptKeyword: Bool = false

    /// 500 ms at 16 kHz -- minimum audio for keyword classifier.
    static let minSamplesForKeyword = 8_000
    /// 1.5 s at 16 kHz -- stop accumulating after this.
    static let maxAudioSamples = 24_000
    /// ~800 ms at 36 ms/chunk -- sustained speech threshold.
    static let minConsecutiveChunksForTakeover = 22
    /// Minimum RMS for takeover without keyword.
    static let minRmsForTakeover: Float = 0.06
}
