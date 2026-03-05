import Foundation

/// Energy-based voice activity detector with hysteresis.
///
/// Accumulates audio samples into speech segments, using RMS energy
/// thresholds with configurable silence gap and pre-roll buffer.
///
/// Replaces: `src/vad/mod.rs` (SileroVad)
struct VoiceActivityDetector {

    // MARK: - Configuration

    /// RMS threshold to enter speech state.
    var threshold: Float = 0.008
    /// Ratio applied to threshold for sustain (hysteresis).
    var hysteresisRatio: Float = 0.6
    /// Silence duration (ms) to end speech segment.
    var minSilenceDurationMs: Int = 1000
    /// Pre-roll buffer duration (ms) prepended to speech start.
    var speechPadMs: Int = 30
    /// Minimum speech duration (ms) to emit a segment.
    var minSpeechDurationMs: Int = 250
    /// Maximum speech duration (ms) before force-emit.
    var maxSpeechDurationMs: Int = 15_000

    // MARK: - State

    private var preRoll: [Float] = []
    private var preRollMax: Int = 0
    private var speechBuffer: [Float] = []
    private var inSpeech: Bool = false
    private var silenceSamples: Int = 0
    private var silenceSamplesThreshold: Int = 0
    private var minSpeechSamples: Int = 0
    private var maxSpeechSamples: Int = 0
    private var sampleRate: Int = 16_000
    /// Wall-clock time when current speech began (set on speech onset).
    private var currentOnsetAt: Date?

    /// Sustained threshold = threshold * hysteresisRatio.
    private var sustainThreshold: Float { threshold * hysteresisRatio }

    // MARK: - Init

    init(sampleRate: Int = 16_000) {
        self.sampleRate = sampleRate
        recalculateThresholds()
    }

    /// Apply the persisted VAD configuration and refresh derived sample thresholds.
    mutating func applyConfiguration(_ config: FaeConfig.VadConfig) {
        threshold = config.threshold
        hysteresisRatio = config.hysteresisRatio
        minSilenceDurationMs = config.minSilenceDurationMs
        speechPadMs = config.speechPadMs
        minSpeechDurationMs = config.minSpeechDurationMs
        maxSpeechDurationMs = config.maxSpeechDurationMs
        recalculateThresholds()
    }

    // MARK: - Processing

    struct Output {
        var speechStarted: Bool = false
        var isSpeech: Bool = false
        var segment: SpeechSegment?
        var rms: Float = 0
    }

    /// Process an audio chunk and return VAD output.
    mutating func processChunk(_ chunk: AudioChunk) -> Output {
        var output = Output()

        // Compute RMS energy.
        let rms = Self.computeRMS(chunk.samples)
        output.rms = rms

        let effectiveThreshold = inSpeech ? sustainThreshold : threshold
        let isSpeech = rms > effectiveThreshold
        output.isSpeech = isSpeech

        // Update pre-roll ring buffer.
        preRoll.append(contentsOf: chunk.samples)
        if preRoll.count > preRollMax {
            preRoll.removeFirst(preRoll.count - preRollMax)
        }

        if isSpeech {
            if !inSpeech {
                // Speech onset — prepend pre-roll.
                inSpeech = true
                output.speechStarted = true
                currentOnsetAt = Date()
                speechBuffer.append(contentsOf: preRoll)
            }
            silenceSamples = 0
            speechBuffer.append(contentsOf: chunk.samples)
        } else if inSpeech {
            // In speech but current chunk is silence — accumulate.
            silenceSamples += chunk.samples.count
            speechBuffer.append(contentsOf: chunk.samples)

            if silenceSamples >= silenceSamplesThreshold {
                // Silence gap exceeded — end segment.
                inSpeech = false
                silenceSamples = 0
                if speechBuffer.count >= minSpeechSamples {
                    output.segment = SpeechSegment(
                        samples: speechBuffer,
                        sampleRate: sampleRate,
                        durationSeconds: Double(speechBuffer.count) / Double(sampleRate),
                        capturedAt: currentOnsetAt ?? Date()
                    )
                }
                speechBuffer.removeAll(keepingCapacity: true)
                currentOnsetAt = nil
            }
        }

        // Safety cap — force-emit if speech exceeds max duration.
        if inSpeech && speechBuffer.count >= maxSpeechSamples {
            inSpeech = false
            silenceSamples = 0
            if speechBuffer.count >= minSpeechSamples {
                output.segment = SpeechSegment(
                    samples: speechBuffer,
                    sampleRate: sampleRate,
                    durationSeconds: Double(speechBuffer.count) / Double(sampleRate),
                    capturedAt: currentOnsetAt ?? Date()
                )
            }
            speechBuffer.removeAll(keepingCapacity: true)
            currentOnsetAt = nil
        }

        return output
    }

    /// Reset all state (call when assistant stops speaking to flush echo).
    mutating func reset() {
        preRoll.removeAll(keepingCapacity: true)
        speechBuffer.removeAll(keepingCapacity: true)
        inSpeech = false
        silenceSamples = 0
        currentOnsetAt = nil
    }

    /// Dynamically adjust silence threshold for barge-in responsiveness.
    mutating func setSilenceThresholdMs(_ ms: Int) {
        minSilenceDurationMs = ms
        silenceSamplesThreshold = (ms * sampleRate) / 1000
    }

    var debugDerivedThresholds: (
        preRollMax: Int,
        silenceSamplesThreshold: Int,
        minSpeechSamples: Int,
        maxSpeechSamples: Int
    ) {
        (preRollMax, silenceSamplesThreshold, minSpeechSamples, maxSpeechSamples)
    }

    // MARK: - Private

    private mutating func recalculateThresholds() {
        preRollMax = (speechPadMs * sampleRate) / 1000
        silenceSamplesThreshold = (minSilenceDurationMs * sampleRate) / 1000
        minSpeechSamples = (minSpeechDurationMs * sampleRate) / 1000
        maxSpeechSamples = maxSpeechDurationMs > 0
            ? (maxSpeechDurationMs * sampleRate) / 1000
            : Int.max
    }

    static func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        for s in samples { sumSquares += s * s }
        return (sumSquares / Float(samples.count)).squareRoot()
    }
}
