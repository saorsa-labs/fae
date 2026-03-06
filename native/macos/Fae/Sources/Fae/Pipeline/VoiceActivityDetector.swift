import Foundation

/// Neural voice activity detector backed by Silero VAD, with legacy energy
/// fallback if the model cannot be loaded.
///
/// Fae keeps utterance segmentation, pre-roll, silence handling, and force-flush
/// logic here. Silero supplies the per-frame speech probability used to drive the
/// segmentation state machine.
struct VoiceActivityDetector {

    // MARK: - Configuration

    /// Speech probability threshold to enter speech state.
    var threshold: Float = 0.30
    /// Ratio applied to `threshold` while already in speech.
    /// Default 0.8333 ~= 0.25 / 0.30, matching common Silero settings.
    var hysteresisRatio: Float = 0.8333333
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
    private var sampleRate: Int = SileroVADEngine.sampleRate
    /// Wall-clock time when current speech began (set on speech onset).
    private var currentOnsetAt: Date?
    /// Most recent Silero speech probability.
    private var lastSpeechProbability: Float = 0
    /// Neural VAD backend when available. If loading fails, we transparently fall
    /// back to the old RMS detector so Fae still works.
    private var silero: SileroVADEngine?

    private static let legacyEnergyThresholdUpperBound: Float = 0.05
    private static let fallbackEnergyThreshold: Float = 0.008
    private static let fallbackEnergyHysteresisRatio: Float = 0.6
    private static let defaultSileroThreshold: Float = 0.30
    private static let defaultSileroHysteresisRatio: Float = 0.8333333

    /// Sustained threshold = threshold * hysteresisRatio.
    private var sustainThreshold: Float { threshold * hysteresisRatio }
    private var energySustainThreshold: Float {
        Self.fallbackEnergyThreshold * Self.fallbackEnergyHysteresisRatio
    }
    private var isUsingSilero: Bool { silero != nil }

    // MARK: - Init

    init(sampleRate: Int = SileroVADEngine.sampleRate) {
        self.sampleRate = sampleRate
        self.silero = try? SileroVADEngine()
        if silero == nil {
            NSLog("VoiceActivityDetector: Silero model unavailable — falling back to legacy RMS VAD")
        }
        recalculateThresholds()
    }

    /// Apply the persisted VAD configuration and refresh derived sample thresholds.
    mutating func applyConfiguration(_ config: FaeConfig.VadConfig) {
        if config.threshold < Self.legacyEnergyThresholdUpperBound {
            threshold = Self.defaultSileroThreshold
            hysteresisRatio = Self.defaultSileroHysteresisRatio
            NSLog(
                "VoiceActivityDetector: migrating legacy VAD threshold %.4f to Silero defaults %.2f / %.2f",
                config.threshold,
                Self.defaultSileroThreshold,
                Self.defaultSileroHysteresisRatio
            )
        } else {
            threshold = config.threshold
            hysteresisRatio = max(0.1, config.hysteresisRatio)
        }
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
        var speechProbability: Float?
    }

    /// Process an audio chunk and return VAD output.
    mutating func processChunk(_ chunk: AudioChunk) -> Output {
        var output = Output()

        let rms = Self.computeRMS(chunk.samples)
        output.rms = rms

        let speechScore: Float
        if let silero {
            if let probability = try? silero.process(samples: chunk.samples) {
                lastSpeechProbability = probability
            }
            speechScore = lastSpeechProbability
            output.speechProbability = speechScore
        } else {
            speechScore = rms
        }

        let effectiveThreshold: Float
        if isUsingSilero {
            effectiveThreshold = inSpeech ? sustainThreshold : threshold
        } else {
            effectiveThreshold = inSpeech ? energySustainThreshold : Self.fallbackEnergyThreshold
        }

        let isSpeech = speechScore > effectiveThreshold
        output.isSpeech = isSpeech

        preRoll.append(contentsOf: chunk.samples)
        if preRoll.count > preRollMax {
            preRoll.removeFirst(preRoll.count - preRollMax)
        }

        if isSpeech {
            if !inSpeech {
                inSpeech = true
                output.speechStarted = true
                currentOnsetAt = Date()
                speechBuffer.append(contentsOf: preRoll)
            }
            silenceSamples = 0
            speechBuffer.append(contentsOf: chunk.samples)
        } else if inSpeech {
            silenceSamples += chunk.samples.count
            speechBuffer.append(contentsOf: chunk.samples)

            if silenceSamples >= silenceSamplesThreshold {
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
        lastSpeechProbability = 0
        silero?.reset()
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
        for sample in samples {
            sumSquares += sample * sample
        }
        return (sumSquares / Float(samples.count)).squareRoot()
    }
}
