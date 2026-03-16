// StreamingSTTEngine.swift
// Fae
//
// Protocol for streaming speech-to-text engines that provide partial transcripts
// as audio is being spoken, enabling low-latency keyword detection and
// semantic endpointing.
//
// Architecture: This runs as the "fast path" alongside the existing Qwen3-ASR
// "slow path". The streaming engine provides partial transcripts for keyword
// detection within ~200-500ms, while Qwen3-ASR provides full-quality
// transcription after the speech segment completes.
//
// See docs/guides/streaming-asr-evaluation.md for design rationale.

import Foundation

// MARK: - Streaming STT Protocol

/// A speech-to-text engine that processes audio incrementally and provides
/// partial transcription results as speech progresses.
///
/// Unlike the batch `STTEngine` protocol which processes complete segments,
/// `StreamingSTTEngine` accepts small audio chunks (e.g., 32ms at 16kHz)
/// and emits partial transcripts suitable for keyword detection.
///
/// Conforming types should be actors to ensure thread-safe state management.
public protocol StreamingSTTEngine: AnyObject, Sendable {
    /// Feed a chunk of audio samples to the engine.
    ///
    /// Audio should be 16kHz mono Float32. Chunks can be any size but
    /// 512 samples (~32ms) is typical for Fae's audio pipeline.
    func feedAudio(_ samples: [Float]) async

    /// Get the current partial transcript.
    ///
    /// Returns the best hypothesis for the audio processed so far.
    /// This text is provisional and may change as more audio arrives.
    func getPartialTranscript() async -> String

    /// Get the final transcript for the current segment and reset.
    ///
    /// Call this when the speech segment is complete (e.g., after VAD
    /// detects silence). Returns the best final transcript and resets
    /// internal state for the next segment.
    func getFinalTranscript() async -> String

    /// Reset the engine state, discarding any buffered audio and partial results.
    func reset() async

    /// Whether the engine has been loaded and is ready to process audio.
    var isLoaded: Bool { get async }

    /// Load the streaming model. Call before first use.
    func load() async throws
}

// MARK: - Streaming Result

/// A partial or final result from a streaming STT engine.
public struct StreamingSTTResult: Sendable, Equatable {
    /// The transcribed text (partial or final).
    public let text: String

    /// Whether this is a final result (segment complete) or partial (in-progress).
    public let isFinal: Bool

    /// Confidence score (0.0-1.0) if available from the engine.
    public let confidence: Float?

    /// Wall-clock time when this result was produced.
    public let timestamp: Date

    public init(
        text: String,
        isFinal: Bool,
        confidence: Float? = nil,
        timestamp: Date = Date()
    ) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
        self.timestamp = timestamp
    }

    public static func == (lhs: StreamingSTTResult, rhs: StreamingSTTResult) -> Bool {
        lhs.text == rhs.text && lhs.isFinal == rhs.isFinal && lhs.confidence == rhs.confidence
    }
}

// MARK: - Streaming Callbacks

/// Delegate protocol for receiving streaming STT events.
public protocol StreamingSTTDelegate: AnyObject, Sendable {
    /// Called when a new partial transcript is available.
    func streamingSTT(didProducePartialResult result: StreamingSTTResult) async

    /// Called when a keyword is detected in the partial transcript.
    func streamingSTT(didDetectKeyword keyword: String, inTranscript transcript: String) async
}

// MARK: - Keyword Bias Configuration

/// Configuration for keyword biasing in the streaming STT pipeline.
///
/// Defines phrases that should be detected with low latency from the
/// streaming partial transcripts. Checked by `KeywordSpotter`.
public struct KeywordBiasConfig: Sendable, Codable {
    /// Phrases that trigger an immediate pipeline interrupt.
    public var interruptPhrases: [String]

    /// Phrases that activate Fae's attention (wake words).
    public var wakePhrases: [String]

    /// Minimum confidence threshold for keyword detection (0.0 = check all).
    public var minimumConfidence: Float

    /// Whether keyword detection is case-insensitive.
    public var caseInsensitive: Bool

    /// Whether to use fuzzy matching (Levenshtein edit distance).
    public var fuzzyMatching: Bool

    public init(
        interruptPhrases: [String] = KeywordBiasConfig.defaultInterruptPhrases,
        wakePhrases: [String] = KeywordBiasConfig.defaultWakePhrases,
        minimumConfidence: Float = 0.0,
        caseInsensitive: Bool = true,
        fuzzyMatching: Bool = true
    ) {
        self.interruptPhrases = interruptPhrases
        self.wakePhrases = wakePhrases
        self.minimumConfidence = minimumConfidence
        self.caseInsensitive = caseInsensitive
        self.fuzzyMatching = fuzzyMatching
    }

    public static let defaultInterruptPhrases: [String] = [
        "stop", "quiet", "shut up", "that's enough", "enough",
        "be quiet", "hush", "silence", "cancel", "never mind",
    ]

    public static let defaultWakePhrases: [String] = [
        "hey fae", "hi fae", "fae", "okay fae",
    ]

    public static let `default` = KeywordBiasConfig()
}
