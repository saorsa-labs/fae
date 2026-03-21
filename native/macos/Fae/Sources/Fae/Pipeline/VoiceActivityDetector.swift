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

    // MARK: - EMA Dynamic Endpointing

    /// EMA of observed inter-utterance silence durations (ms).
    /// Adapts to the user's natural speaking rhythm over a conversation session.
    private(set) var emaSilenceDurationMs: Float = 0

    /// Whether the EMA has been seeded with at least one observation.
    private var emaSilenceSeeded: Bool = false

    /// EMA smoothing factor for silence duration (higher = faster adaptation).
    private static let emaSilenceAlpha: Float = 0.25

    /// Minimum EMA value to prevent overly aggressive endpointing.
    private static let emaSilenceFloorMs: Float = 400

    /// Maximum EMA value to prevent overly patient endpointing.
    /// Capped at 2000ms — longer waits feel sluggish in conversation.
    private static let emaSilenceCeilingMs: Float = 2000

    /// Record an observed silence duration to update the EMA.
    /// Call this when a pause between utterances is measured (e.g., between
    /// successive VAD segments within a conversation turn).
    mutating func recordObservedSilenceMs(_ silenceMs: Float) {
        guard silenceMs > 0 else { return }
        let clamped = min(max(silenceMs, Self.emaSilenceFloorMs), Self.emaSilenceCeilingMs)
        if emaSilenceSeeded {
            emaSilenceDurationMs = emaSilenceDurationMs * (1 - Self.emaSilenceAlpha)
                + clamped * Self.emaSilenceAlpha
        } else {
            emaSilenceDurationMs = clamped
            emaSilenceSeeded = true
        }
    }

    /// Suggested silence threshold based on EMA observation.
    /// Returns nil if no observations have been recorded (use static config).
    var emaSuggestedSilenceMs: Int? {
        guard emaSilenceSeeded else { return nil }
        // Use 1.3x the observed average as the threshold — slightly longer than
        // the user's typical pause to avoid cutting them off mid-thought.
        let suggested = emaSilenceDurationMs * 1.3
        let clamped = min(max(suggested, Self.emaSilenceFloorMs), Self.emaSilenceCeilingMs)
        return Int(clamped)
    }
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

        // Track ambient noise floor during non-speech frames for SNR estimation.
        if !isSpeech, !inSpeech {
            let noiseProb = isUsingSilero ? speechScore : 0
            if noiseProb < Self.noiseFloorSpeechProbThreshold {
                updateNoiseFloor(rms: rms)
            }
        }

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
            // Reset Silero LSTM state after force-flush to prevent stale
            // hidden state from causing immediate re-onset or delayed
            // detection on continuation speech.
            silero?.reset()
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

    // MARK: - Adaptive Noise Floor

    /// EMA of RMS during non-speech frames.  Tracks ambient noise level for
    /// per-chunk SNR estimation used by streaming STT gating.
    private(set) var noiseFloorRms: Float = 0.008

    /// Whether the noise floor has been seeded with at least one observation.
    private var noiseFloorSeeded: Bool = false

    /// EMA smoothing factor for noise floor (lower = slower adaptation).
    private static let noiseFloorAlpha: Float = 0.05

    /// Floor clamp — never estimate noise below this (quantisation noise).
    private static let noiseFloorMin: Float = 0.0005

    /// Ceiling clamp — a "noise floor" above this is implausible.
    private static let noiseFloorMax: Float = 0.05

    /// Silero speech probability below which a frame is considered noise-only.
    private static let noiseFloorSpeechProbThreshold: Float = 0.1

    /// Update the noise floor EMA with the RMS of a non-speech chunk.
    private mutating func updateNoiseFloor(rms: Float) {
        let clamped = min(max(rms, Self.noiseFloorMin), Self.noiseFloorMax)
        if noiseFloorSeeded {
            noiseFloorRms = noiseFloorRms * (1 - Self.noiseFloorAlpha) + clamped * Self.noiseFloorAlpha
        } else {
            noiseFloorRms = clamped
            noiseFloorSeeded = true
        }
    }

    /// Estimated SNR in dB for a chunk with the given RMS.
    /// Returns 0 if noise floor is not yet seeded.
    func estimatedSNRdB(chunkRms: Float) -> Float {
        guard noiseFloorSeeded, noiseFloorRms > 0 else { return 0 }
        let ratio = max(chunkRms, Self.noiseFloorMin) / noiseFloorRms
        return 20 * log10(ratio)
    }

    /// Minimum SNR (dB) to consider a chunk worth feeding to streaming STT.
    static let minStreamingSNRdB: Float = 6.0

    // MARK: - Private

    private mutating func recalculateThresholds() {
        preRollMax = (speechPadMs * sampleRate) / 1000
        silenceSamplesThreshold = (minSilenceDurationMs * sampleRate) / 1000
        minSpeechSamples = (minSpeechDurationMs * sampleRate) / 1000
        maxSpeechSamples = maxSpeechDurationMs > 0
            ? (maxSpeechDurationMs * sampleRate) / 1000
            : Int.max
    }

    // MARK: - Spectral Tilt Speech Filter

    /// Quick spectral check to reject music/noise that Silero misclassifies as speech.
    ///
    /// Speech has mid-band dominance (formants at 500-4000 Hz) and moderate high-frequency
    /// energy (fricatives/sibilants). Music often has exaggerated bass or treble.
    /// Environmental noise tends to be broadband.
    ///
    /// Returns `true` if the spectral shape is consistent with speech.
    /// When `false`, the VAD's `isSpeech` should be overridden to prevent false
    /// triggering on music or environmental noise.
    static func spectralTiltLooksSpeechlike(samples: [Float], sampleRate: Int) -> Bool {
        // Use at most 576 samples (36ms) for the DFT — the per-chunk check
        // in the pipeline loop only has 576 samples anyway, and running the
        // O(n^2) DFT on a full segment (up to 240K samples) is too expensive.
        let clip = samples.count > 576 ? Array(samples.prefix(576)) : samples
        let energy = EchoSuppressor.computeBandEnergy(samples: clip, sampleRate: sampleRate)
        let total = energy.low + energy.mid + energy.high
        guard total > 0.0005 else { return false }  // Silence — not speech.

        let midRatio = energy.mid / total
        let tilt = energy.spectralTilt  // high / (low + mid)

        // Speech characteristics (tuned against MUSAN corpus):
        // - Mid-band (formants at 500-4000 Hz) should carry some energy.
        //   Threshold 0.12 is permissive — passes most speech including
        //   distant/reverberant recordings where mids are attenuated.
        // - Spectral tilt should not be extreme. Pure bass hum (tilt ~0)
        //   and pure hiss (tilt >0.9) are clearly non-speech.
        //
        // MUSAN baseline: 44% speech acceptance at 0.20 mid threshold was
        // too aggressive. 0.12 mid + 0.01-0.90 tilt window is more permissive,
        // trading some music/noise rejection for much better speech acceptance.
        let midPresent = midRatio > 0.12
        let tiltReasonable = tilt > 0.01 && tilt < 0.90

        return midPresent || tiltReasonable
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
