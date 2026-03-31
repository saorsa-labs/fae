import Accelerate
import Foundation

/// Tracks echo suppression state for the VAD stage.
///
/// When the assistant is speaking, audio captured from the mic contains
/// speaker bleedthrough. This module manages suppression windows and
/// decides whether a completed VAD segment should be accepted or dropped.
///
/// ## Echo Rejection Layers
///
/// 1. **Active suppression** — hard reject while assistant is speaking
/// 2. **Echo tail window** — onset-time based, duration-proportional scaling
/// 3. **Short utterance guard** — blocks brief pops after playback ends
/// 4. **Duration cap** — 15s max (long segments are bleed loops)
/// 5. **Amplitude cap** — RMS ceiling during guard window
/// 6. **Text-overlap rejection** — bag-of-words + consecutive-word matching
/// 7. **Playback baseline tracking** — EMA of mic RMS during TTS for spike detection
/// 8. **Per-band energy tracking** — spectral shape discrimination (speaker-colored vs full-spectrum)
/// 9. **Output route awareness** — headphones vs speakers adjusts aggressiveness
/// 10. **fae_self similarity boost** — lower embedding threshold during playback window
/// 11. **Cross-correlation** — correlate mic audio with playback ring buffer for early echo detection
/// 12. **Spectral envelope comparison** — cosine similarity of band energies vs TTS output
///
/// Replaces: echo suppression logic from `src/pipeline/coordinator.rs`
struct EchoSuppressor {

    // MARK: - Configuration

    /// Whether hardware AEC (Acoustic Echo Cancellation) is active.
    /// macOS AVAudioEngine does not expose hardware AEC, so this defaults
    /// to false. With no AEC, longer suppression windows are needed to
    /// prevent Fae from hearing her own voice through the speakers.
    var aecEnabled: Bool = false

    // MARK: - Output Route Detection

    /// Detected audio output route. Affects echo suppression aggressiveness.
    ///
    /// - `headphones`: Minimal speaker bleedthrough; relaxed echo windows.
    /// - `builtInSpeaker`: MacBook speakers; moderate bleedthrough; standard windows.
    /// - `externalSpeaker`: External speakers; potentially more reverb; aggressive windows.
    /// - `unknown`: Fall back to conservative (speaker) behavior.
    enum OutputRoute: Sendable, Equatable {
        case headphones
        case builtInSpeaker
        case externalSpeaker
        case unknown
    }

    /// Current audio output route. Updated by AudioPlaybackManager when the
    /// system audio route changes.
    var outputRoute: OutputRoute = .unknown

    /// Multiplier applied to echo timing windows based on output route.
    /// Headphones need minimal echo protection; speakers need full protection.
    private var routeTimingMultiplier: Float {
        switch outputRoute {
        case .headphones:
            return 0.1  // Near-zero — headphones produce no acoustic echo.
                        // Rely on fae_self voiceprint as safety net.
        case .builtInSpeaker:
            return 0.8  // Reduced from 1.0 — MacBook speakers have tight coupling
        case .externalSpeaker:
            return 1.2  // External speakers may have more reverb
        case .unknown:
            return 1.0  // Conservative default
        }
    }

    // MARK: - Timing Constants

    /// Base echo tail after assistant stops speaking (milliseconds).
    /// Adjusted by output route multiplier at runtime.
    /// Without AEC, speaker→mic echo can take 800ms+ to fully decay.
    private var baseEchoTailMs: Int { aecEnabled ? 300 : 800 }

    /// Base short-utterance guard window after assistant stops (milliseconds).
    /// Increased to prevent short echo fragments from triggering new turns.
    private var baseShortUtteranceGuardMs: Int { aecEnabled ? 500 : 1200 }

    /// Echo tail after assistant stops speaking, adjusted for output route.
    var echoTailMs: Int {
        Int(Float(baseEchoTailMs) * routeTimingMultiplier)
    }

    /// Short-utterance guard window after assistant stops, adjusted for output route.
    var shortUtteranceGuardMs: Int {
        Int(Float(baseShortUtteranceGuardMs) * routeTimingMultiplier)
    }

    /// Echo tail for scheduling listening tone after approval.
    var echoTailForToneMs: Int { aecEnabled ? 500 : 800 }

    // MARK: - Amplitude Constants

    /// Minimum segment duration after playback (seconds).
    static let minPostPlaybackSegmentSecs: Float = 0.5
    /// If speech starts inside the echo tail but continues materially beyond it,
    /// treat it as a real user utterance rather than dropping the whole segment.
    static let minSpeechBeyondTailSecs: TimeInterval = 0.75
    static let minSpeechBeyondTailFraction: Double = 0.35
    /// Maximum segment duration before force-drop (seconds).
    static let maxSegmentSecs: Float = 15.0
    /// RMS ceiling — segments louder than this are likely speaker bleed.
    static let echoRmsCeiling: Float = 0.12
    /// Minimum segment for approval responses (seconds).
    static let minApprovalSegmentSecs: Float = 0.15

    // MARK: - Playback Baseline Tracking

    /// Exponential moving average of mic RMS while the assistant is speaking.
    /// Represents how loud Fae's TTS sounds through the microphone — user speech
    /// during playback must be significantly louder than this to be distinguished.
    private(set) var playbackBaselineRms: Float = 0

    /// Whether the baseline has been seeded with at least one sample.
    private var playbackBaselineSeeded: Bool = false

    /// EMA smoothing factor for playback baseline (lower = smoother).
    /// Adaptive: 0.12 when RMS is rising (room getting louder), 0.03 when falling.
    /// This allows fast adaptation to volume increases while resisting sudden drops.
    private static let playbackBaselineAlphaRising: Float = 0.12
    private static let playbackBaselineAlphaFalling: Float = 0.03

    /// User speech must exceed this multiple of the playback baseline to be
    /// considered likely human speech rather than echo.
    private static let playbackSpikeMultiplier: Float = 2.5

    /// Update the playback baseline with a new RMS sample during assistant speech.
    /// Uses adaptive EMA: fast rising (tracks volume increases quickly),
    /// slow falling (resists sudden drops that could cause false user-speech detection).
    mutating func updatePlaybackBaseline(rms: Float) {
        if playbackBaselineSeeded {
            let alpha = rms > playbackBaselineRms
                ? Self.playbackBaselineAlphaRising
                : Self.playbackBaselineAlphaFalling
            playbackBaselineRms = playbackBaselineRms * (1 - alpha) + rms * alpha
        } else {
            playbackBaselineRms = rms
            playbackBaselineSeeded = true
        }
    }

    /// Whether the given RMS is significantly above the playback baseline,
    /// suggesting user speech rather than echo.
    func userSpeechLikelyAbovePlayback(rms: Float) -> Bool {
        guard playbackBaselineSeeded, playbackBaselineRms > 0 else { return false }
        return rms > playbackBaselineRms * Self.playbackSpikeMultiplier
    }

    /// Reset the playback baseline when assistant speech ends.
    mutating func resetPlaybackBaseline() {
        playbackBaselineRms = 0
        playbackBaselineSeeded = false
    }

    // MARK: - Per-Band Energy Tracking

    /// Three-band energy representation for spectral shape analysis.
    /// Speaker echo has a characteristic spectral signature: boosted low-mids
    /// (200-2kHz speaker resonance), attenuated highs (>4kHz rolled off by
    /// small MacBook speakers). Human speech near the mic has a flatter profile
    /// with more high-frequency energy (sibilants, fricatives).
    struct BandEnergy: Sendable, Equatable {
        /// Low band energy (0-500 Hz) — bass/fundamental frequency.
        var low: Float = 0
        /// Mid band energy (500-4000 Hz) — speech formants, speaker resonance.
        var mid: Float = 0
        /// High band energy (4000+ Hz) — sibilants, fricatives, breath noise.
        var high: Float = 0

        /// Spectral tilt: ratio of high to low+mid energy.
        /// Human near-field speech typically has tilt > 0.15.
        /// Speaker echo typically has tilt < 0.08 (highs rolled off).
        var spectralTilt: Float {
            let total = low + mid
            guard total > 0.0001 else { return 0 }
            return high / total
        }

        /// Whether this energy profile looks like speaker echo rather than
        /// near-field human speech. Speaker echo has attenuated highs relative
        /// to low+mid energy (the speaker's frequency response rolls off).
        var looksLikeSpeakerEcho: Bool {
            spectralTilt < Self.echoTiltThreshold && (low + mid + high) > 0.001
        }

        /// Spectral tilt threshold below which audio is likely speaker echo.
        static let echoTiltThreshold: Float = 0.08

        /// Spectral tilt threshold above which audio is likely near-field speech.
        static let speechTiltThreshold: Float = 0.15
    }

    /// EMA of per-band energy during playback for baseline comparison.
    private(set) var playbackBandBaseline = BandEnergy()

    /// Whether band baseline has been seeded.
    private var bandBaselineSeeded: Bool = false

    /// EMA alpha for band energy tracking.
    private static let bandBaselineAlpha: Float = 0.10

    /// Update per-band energy baseline during assistant playback.
    ///
    /// - Parameter energy: Current per-band energy from microphone input.
    mutating func updatePlaybackBandBaseline(energy: BandEnergy) {
        if bandBaselineSeeded {
            let alpha = Self.bandBaselineAlpha
            playbackBandBaseline.low = playbackBandBaseline.low * (1 - alpha) + energy.low * alpha
            playbackBandBaseline.mid = playbackBandBaseline.mid * (1 - alpha) + energy.mid * alpha
            playbackBandBaseline.high = playbackBandBaseline.high * (1 - alpha) + energy.high * alpha
        } else {
            playbackBandBaseline = energy
            bandBaselineSeeded = true
        }
    }

    /// Whether per-band energy suggests user speech rather than echo.
    ///
    /// Checks two conditions:
    /// 1. Spectral tilt of incoming audio is higher than echo baseline (more highs = near-field speech).
    /// 2. Overall energy is significantly above baseline (user is louder than echo).
    func bandEnergyLooksLikeSpeech(_ energy: BandEnergy) -> Bool {
        guard bandBaselineSeeded else { return false }

        // Condition 1: Higher spectral tilt than echo baseline suggests near-field speech.
        let tiltAboveBaseline = energy.spectralTilt > playbackBandBaseline.spectralTilt * 1.5
            && energy.spectralTilt >= BandEnergy.echoTiltThreshold

        // Condition 2: Overall energy significantly above baseline.
        let baseTotal = playbackBandBaseline.low + playbackBandBaseline.mid + playbackBandBaseline.high
        let inputTotal = energy.low + energy.mid + energy.high
        let energyAboveBaseline = baseTotal > 0.0001 && inputTotal > baseTotal * 2.0

        return tiltAboveBaseline || energyAboveBaseline
    }

    /// Reset band energy baseline.
    mutating func resetBandBaseline() {
        playbackBandBaseline = BandEnergy()
        bandBaselineSeeded = false
    }

    /// Compute per-band energy from raw audio samples at a given sample rate.
    ///
    /// Uses Accelerate vDSP FFT for efficient frequency analysis:
    /// - Low: 0-500 Hz
    /// - Mid: 500-4000 Hz
    /// - High: 4000+ Hz
    ///
    /// For 16kHz audio with 576 samples (36ms), frequency resolution is ~27.8 Hz/bin.
    /// Uses O(n log n) FFT instead of O(n²) DFT — approximately 30x faster.
    static func computeBandEnergy(samples: [Float], sampleRate: Int) -> BandEnergy {
        guard !samples.isEmpty, sampleRate > 0 else { return BandEnergy() }

        let n = samples.count

        // Find next power of 2 for FFT (vDSP requires power-of-2 sizes).
        let log2n = vDSP_Length(ceil(log2(Float(n))))
        let fftSize = Int(1 << log2n)
        let halfFFTSize = fftSize / 2

        guard halfFFTSize > 0 else { return BandEnergy() }

        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return BandEnergy()
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Zero-pad input to power-of-2 size.
        var paddedSamples = [Float](repeating: 0, count: fftSize)
        for i in 0..<min(n, fftSize) {
            paddedSamples[i] = samples[i]
        }

        // Prepare split complex arrays for in-place FFT.
        var realPart = [Float](repeating: 0, count: halfFFTSize)
        var imagPart = [Float](repeating: 0, count: halfFFTSize)

        // Pack real signal into split complex format and perform FFT.
        realPart.withUnsafeMutableBufferPointer { realPtr in
            imagPart.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(
                    realp: realPtr.baseAddress!,
                    imagp: imagPtr.baseAddress!
                )

                // Convert interleaved real samples to split complex format.
                paddedSamples.withUnsafeBufferPointer { inputPtr in
                    inputPtr.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self,
                        capacity: halfFFTSize
                    ) { complexPtr in
                        vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(halfFFTSize))
                    }
                }

                // Perform in-place real-to-complex FFT.
                vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }

        // Compute squared magnitudes (power spectrum).
        var magnitudesSquared = [Float](repeating: 0, count: halfFFTSize)
        realPart.withUnsafeMutableBufferPointer { realPtr in
            imagPart.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(
                    realp: realPtr.baseAddress!,
                    imagp: imagPtr.baseAddress!
                )
                vDSP_zvmags(&splitComplex, 1, &magnitudesSquared, 1, vDSP_Length(halfFFTSize))
            }
        }

        // Scale by 1/n² to normalize (FFT introduces factor of n).
        var scale = 1.0 / Float(fftSize * fftSize)
        vDSP_vsmul(magnitudesSquared, 1, &scale, &magnitudesSquared, 1, vDSP_Length(halfFFTSize))

        // Compute band boundaries in bins.
        // Bin k corresponds to frequency k * sampleRate / fftSize.
        let binWidth = Float(sampleRate) / Float(fftSize)
        let lowCutoffBin = max(1, Int(500.0 / binWidth))
        let midCutoffBin = min(halfFFTSize, Int(4000.0 / binWidth))

        // Sum power in each band using simple loops (small arrays, SIMD overhead not worth it).
        var lowEnergy: Float = 0
        var midEnergy: Float = 0
        var highEnergy: Float = 0

        for k in 1..<lowCutoffBin where k < halfFFTSize {
            lowEnergy += magnitudesSquared[k]
        }
        for k in lowCutoffBin..<midCutoffBin where k < halfFFTSize {
            midEnergy += magnitudesSquared[k]
        }
        for k in midCutoffBin..<halfFFTSize {
            highEnergy += magnitudesSquared[k]
        }

        return BandEnergy(
            low: sqrt(lowEnergy),
            mid: sqrt(midEnergy),
            high: sqrt(highEnergy)
        )
    }

    // MARK: - Room Decay Estimation

    /// Estimated room echo decay time in milliseconds, derived from observing
    /// how quickly microphone RMS drops after playback stops.
    ///
    /// `nil` means no estimate available yet (need at least one playback cycle).
    /// Used to dynamically adjust `echoTailMs` — shorter measured decay allows
    /// shorter echo tail and faster response.
    private(set) var estimatedDecayMs: Int?

    /// Minimum decay estimate floor (milliseconds). Even in a very dry room,
    /// we need at least this much tail for digital-to-analog latency.
    private static let minDecayMs: Int = 100

    /// Maximum decay estimate ceiling (milliseconds). Caps adaptation in
    /// very reverberant rooms to prevent excessively long blocking.
    private static let maxDecayMs: Int = 800

    /// EMA alpha for decay estimation.
    private static let decayAlpha: Float = 0.2

    /// RMS samples collected after playback ends, used to estimate decay time.
    private var postPlaybackRmsSamples: [(timestamp: Date, rms: Float)] = []

    /// Whether we're currently collecting decay samples.
    private var collectingDecay: Bool = false

    /// RMS level at the moment playback stopped (baseline for decay measurement).
    private var decayBaselineRms: Float = 0

    /// Start collecting post-playback RMS samples for decay estimation.
    ///
    /// Called when assistant speech ends. The pipeline should continue feeding
    /// RMS samples via `addDecaySample()` for the next ~1 second.
    mutating func beginDecayMeasurement(currentRms: Float) {
        postPlaybackRmsSamples.removeAll()
        decayBaselineRms = max(currentRms, playbackBaselineRms)
        collectingDecay = decayBaselineRms > 0.005  // Only measure if there was audible playback
    }

    /// Add a post-playback RMS sample for decay estimation.
    ///
    /// Call this with each audio chunk's RMS for ~1 second after playback ends.
    /// The decay estimator looks for when RMS drops below 10% of the playback
    /// baseline — the time to reach that point is the estimated decay time.
    mutating func addDecaySample(timestamp: Date, rms: Float) {
        guard collectingDecay else { return }
        postPlaybackRmsSamples.append((timestamp: timestamp, rms: rms))

        // Stop collecting after 1.5 seconds — any remaining echo is negligible.
        if let first = postPlaybackRmsSamples.first,
           timestamp.timeIntervalSince(first.timestamp) > 1.5 {
            finalizeDecayEstimate()
        }

        // Also stop if RMS has dropped below threshold.
        let decayThreshold = decayBaselineRms * 0.1
        if rms < decayThreshold && postPlaybackRmsSamples.count >= 3 {
            finalizeDecayEstimate()
        }
    }

    /// Compute the decay time from collected samples and update the EMA estimate.
    private mutating func finalizeDecayEstimate() {
        collectingDecay = false

        guard let firstSample = postPlaybackRmsSamples.first,
              decayBaselineRms > 0.005 else {
            postPlaybackRmsSamples.removeAll()
            return
        }

        let decayThreshold = decayBaselineRms * 0.1
        var measuredDecayMs: Int = Self.maxDecayMs

        // Find the first sample that drops below 10% of baseline.
        for sample in postPlaybackRmsSamples {
            if sample.rms < decayThreshold {
                let elapsed = sample.timestamp.timeIntervalSince(firstSample.timestamp)
                measuredDecayMs = max(Self.minDecayMs, Int(elapsed * 1000))
                break
            }
        }

        measuredDecayMs = min(measuredDecayMs, Self.maxDecayMs)

        // Update EMA estimate.
        if let existing = estimatedDecayMs {
            let alpha = Self.decayAlpha
            estimatedDecayMs = Int(Float(existing) * (1 - alpha) + Float(measuredDecayMs) * alpha)
        } else {
            estimatedDecayMs = measuredDecayMs
        }

        postPlaybackRmsSamples.removeAll()
    }

    /// Effective echo tail incorporating room decay estimate when available.
    /// If we have a measured decay time, use it (with a safety margin) instead
    /// of the fixed default — this adapts to the actual room acoustics.
    var effectiveEchoTailMs: Int {
        if let decay = estimatedDecayMs {
            // Add 20% safety margin to measured decay (reduced from 50%).
            let adaptiveTail = Int(Float(decay) * 1.2)
            // Clamp between route-adjusted minimum and the route-adjusted default.
            return max(Int(Float(Self.minDecayMs) * routeTimingMultiplier),
                       min(adaptiveTail, echoTailMs))
        }
        return echoTailMs
    }

    // MARK: - Enhanced fae_self Threshold

    /// During active playback or within the echo tail window, the fae_self
    /// speaker embedding similarity threshold should be lower — echo from
    /// speakers is more likely to match Fae's voice embedding, so we should
    /// accept a lower similarity as evidence of echo and reject the segment.
    ///
    /// Outside the playback window, the threshold returns to normal to avoid
    /// false rejections (e.g., a user whose voice happens to be similar to
    /// Fae's TTS voice).
    ///
    /// - Parameter baseThreshold: The normal fae_self rejection threshold
    ///   (typically ~0.45 cosine similarity).
    /// - Returns: Adjusted threshold — lower during playback window, normal otherwise.
    func faeSelfThresholdDuringPlayback(baseThreshold: Float) -> Float {
        if assistantSpeaking || isInSuppression {
            // During playback: accept lower similarity as echo evidence.
            // Reduce threshold by 20% — a 0.45 base becomes 0.36.
            return baseThreshold * Self.faeSelfPlaybackMultiplier
        }
        return baseThreshold
    }

    /// Multiplier for fae_self threshold during playback window.
    /// 0.8 means the threshold is 80% of normal (more likely to reject as echo).
    static let faeSelfPlaybackMultiplier: Float = 0.8

    // MARK: - Playback Audio Cross-Correlation

    /// Ring buffer of recent TTS audio samples for cross-correlation echo detection.
    /// Stores the last N seconds of audio sent to playback so we can correlate
    /// incoming mic audio against it to detect acoustic echo.
    ///
    /// Unlike text-overlap (which operates on STT output), this operates on raw
    /// audio and can detect echo before STT even runs — useful for early rejection.
    private var playbackAudioRingBuffer: [Float] = []

    /// Maximum ring buffer size in samples (at 16kHz).
    /// 3 seconds = 48,000 samples — enough to capture the most recent TTS output
    /// for correlation checking.
    private static let playbackRingBufferMaxSamples = 48_000

    /// Cross-correlation threshold above which mic audio is considered echo.
    /// Normalized cross-correlation ranges from -1 to 1. Values above 0.6
    /// indicate strong similarity suggesting acoustic echo.
    static let crossCorrelationEchoThreshold: Float = 0.6

    /// Record TTS audio samples being sent to playback.
    ///
    /// Call this when audio is enqueued to `AudioPlaybackManager`. The samples
    /// should be at 16kHz (pipeline capture rate) or will be downsampled.
    ///
    /// - Parameters:
    ///   - samples: PCM Float32 audio samples.
    ///   - sampleRate: Sample rate of the provided audio.
    mutating func recordPlaybackAudio(samples: [Float], sampleRate: Int) {
        // Downsample to 16kHz if needed (simple decimation for this ring buffer).
        let targetRate = 16_000
        let recorded: [Float]
        if sampleRate != targetRate && sampleRate > 0 {
            let ratio = Float(sampleRate) / Float(targetRate)
            let outputCount = Int(Float(samples.count) / ratio)
            guard outputCount > 0 else { return }
            var downsampled = [Float](repeating: 0, count: outputCount)
            for i in 0..<outputCount {
                let srcIdx = min(Int(Float(i) * ratio), samples.count - 1)
                downsampled[i] = samples[srcIdx]
            }
            recorded = downsampled
        } else {
            recorded = samples
        }

        playbackAudioRingBuffer.append(contentsOf: recorded)

        // Trim to max size.
        if playbackAudioRingBuffer.count > Self.playbackRingBufferMaxSamples {
            let excess = playbackAudioRingBuffer.count - Self.playbackRingBufferMaxSamples
            playbackAudioRingBuffer.removeFirst(excess)
        }
    }

    /// Check whether mic audio correlates with recent playback audio.
    ///
    /// Computes normalized cross-correlation between the mic segment and
    /// sliding windows of the playback ring buffer. High correlation indicates
    /// the mic is picking up speaker output (echo).
    ///
    /// This is a lightweight check using a strided approach — not a full
    /// sample-by-sample correlation. Checks every 160 samples (10ms hops).
    ///
    /// - Parameter micSamples: Audio samples from the microphone (16kHz).
    /// - Returns: Peak normalized cross-correlation value (0-1). Values above
    ///   `crossCorrelationEchoThreshold` suggest echo.
    func peakCrossCorrelation(micSamples: [Float]) -> Float {
        let micLen = micSamples.count
        let refLen = playbackAudioRingBuffer.count

        // Need at least 160 samples (10ms) to correlate meaningfully.
        guard micLen >= 160, refLen >= micLen else { return 0 }

        // Compute mic energy for normalization.
        var micEnergy: Float = 0
        for s in micSamples { micEnergy += s * s }
        guard micEnergy > 0.00001 else { return 0 }

        let hopSize = 160  // 10ms at 16kHz
        let maxOffset = refLen - micLen
        var peakCorr: Float = 0

        // Stride through the reference buffer.
        var offset = 0
        while offset <= maxOffset {
            var dotProduct: Float = 0
            var refEnergy: Float = 0
            for i in 0..<micLen {
                let ref = playbackAudioRingBuffer[offset + i]
                dotProduct += micSamples[i] * ref
                refEnergy += ref * ref
            }

            // Normalized cross-correlation.
            let denominator = sqrt(micEnergy * refEnergy)
            if denominator > 0.00001 {
                let corr = dotProduct / denominator
                peakCorr = max(peakCorr, corr)

                // Early exit: once we exceed the echo threshold, we know it's echo.
                // No need to scan the remaining ~300 offsets in the ring buffer.
                if peakCorr >= Self.crossCorrelationEchoThreshold {
                    return peakCorr
                }
            }

            offset += hopSize
        }

        return peakCorr
    }

    /// Whether mic audio shows strong cross-correlation with recent playback,
    /// indicating it is likely echo.
    func isLikelyAcousticEcho(micSamples: [Float]) -> Bool {
        peakCrossCorrelation(micSamples: micSamples) >= Self.crossCorrelationEchoThreshold
    }

    /// Clear the playback audio ring buffer (on reset or conversation change).
    mutating func clearPlaybackAudioBuffer() {
        playbackAudioRingBuffer.removeAll()
    }

    // MARK: - Spectral Envelope Comparison

    /// Compare the spectral envelope of mic audio against the known TTS spectral
    /// shape. Speaker echo has a characteristic coloring: the speaker's frequency
    /// response attenuates certain bands. If mic audio's spectral shape matches
    /// this speaker-colored TTS pattern (rather than natural speech), it's echo.
    ///
    /// Returns a similarity score (0-1) where higher means more likely echo.
    ///
    /// - Parameters:
    ///   - micEnergy: Per-band energy of the mic audio.
    ///   - ttsEnergy: Per-band energy of the TTS output (from ring buffer).
    /// - Returns: Spectral similarity score (0-1).
    static func spectralEnvelopeSimilarity(
        micEnergy: BandEnergy,
        ttsEnergy: BandEnergy
    ) -> Float {
        // Normalize both to unit vectors for cosine similarity.
        let micVec = [micEnergy.low, micEnergy.mid, micEnergy.high]
        let ttsVec = [ttsEnergy.low, ttsEnergy.mid, ttsEnergy.high]

        var dot: Float = 0
        var micMag: Float = 0
        var ttsMag: Float = 0
        for i in 0..<3 {
            dot += micVec[i] * ttsVec[i]
            micMag += micVec[i] * micVec[i]
            ttsMag += ttsVec[i] * ttsVec[i]
        }

        let denominator = sqrt(micMag * ttsMag)
        guard denominator > 0.00001 else { return 0 }
        return max(0, dot / denominator)
    }

    /// Spectral similarity threshold above which mic audio is likely speaker-colored echo.
    static let spectralSimilarityEchoThreshold: Float = 0.95

    // MARK: - Text-Overlap Echo Rejection

    /// Ring buffer of recent assistant TTS text for text-overlap echo detection.
    /// When STT transcribes audio that closely matches what Fae just said, it's
    /// almost certainly speaker bleedthrough — not the user speaking.
    private var recentAssistantText: [String] = []

    /// Maximum number of recent assistant text chunks to retain.
    private static let maxRecentTextChunks = 8

    /// Word overlap threshold above which a transcript is considered echo.
    /// 0.85 = at least 85% of the transcript's words must match recent assistant text.
    /// Set high to avoid rejecting legitimate user speech that shares common words with
    /// assistant text (e.g., "tell me about the project" after Fae said "the project").
    private static let textOverlapThreshold: Float = 0.85

    /// Minimum consecutive matching words required as a secondary echo signal.
    /// Requires at least 5 consecutive words to appear in the same order as assistant text.
    /// Raised from 4 to reduce false positives from common word sequences.
    private static let textOverlapMinConsecutiveWords = 5

    /// Minimum word count for bag-of-words overlap checking.
    /// Short utterances use exact-match instead (see isLikelyEchoText).
    private static let textOverlapMinWords = 4

    /// Function words excluded from bag-of-words echo overlap.
    /// These appear in virtually every English sentence and inflate overlap scores
    /// when user speech happens to reference the same topic as assistant speech.
    private static let functionWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "in", "on", "at", "to", "for",
        "of", "with", "by", "from", "is", "are", "was", "were", "be", "been",
        "has", "have", "had", "do", "does", "did", "will", "would", "could",
        "should", "can", "may", "might", "shall", "it", "its", "i", "me", "my",
        "you", "your", "we", "our", "they", "them", "their", "this", "that",
        "these", "those", "not", "no", "so", "if", "then", "also", "just",
        "about", "up", "out", "into", "over", "after", "before",
    ]

    /// Number words → digit normalization for echo matching.
    /// "five fifty six" in transcript should match "556" in assistant text.
    private static let numberWords: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4",
        "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9",
        "ten": "10", "eleven": "11", "twelve": "12", "thirteen": "13",
        "fourteen": "14", "fifteen": "15", "sixteen": "16", "seventeen": "17",
        "eighteen": "18", "nineteen": "19", "twenty": "20", "thirty": "30",
        "forty": "40", "fifty": "50", "sixty": "60", "seventy": "70",
        "eighty": "80", "ninety": "90", "hundred": "00", "thousand": "000",
    ]

    /// Record text that the assistant is about to speak (call before TTS).
    /// This builds the reference corpus for text-overlap echo detection.
    mutating func recordAssistantText(_ text: String) {
        let normalized = Self.normalizeForOverlap(text)
        guard !normalized.isEmpty else { return }
        recentAssistantText.append(normalized)
        if recentAssistantText.count > Self.maxRecentTextChunks {
            recentAssistantText.removeFirst(recentAssistantText.count - Self.maxRecentTextChunks)
        }
    }

    /// Check whether a transcribed text is likely echo of Fae's own speech.
    ///
    /// Uses multiple signals:
    /// 0. **Short utterance match**: For < 4 words, checks exact substring or number-word match.
    /// 1. **Bag-of-words overlap**: 75%+ of transcript words appear in recent assistant text.
    /// 2. **Consecutive-word match**: 4+ consecutive words from the transcript appear in order.
    /// 3. **Number-word match**: "five fifty six" matches assistant text containing "556".
    ///
    /// Short utterances that are clearly user commands ("stop", "no", "yes") pass through
    /// because they won't match assistant text (Fae doesn't say "stop" to herself).
    func isLikelyEchoText(_ transcript: String) -> Bool {
        let normalized = Self.normalizeForOverlap(transcript)
        let words = normalized.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return false }

        let assistantText = recentAssistantText.joined(separator: " ")
        guard !assistantText.isEmpty else { return false }

        // Signal 0: Short utterance — only catch number-words as echo.
        // Single/two-word commands ("stop", "no", "cancel", "yes") must ALWAYS
        // pass through for barge-in.  Only number sequences ("five fifty six")
        // are reliably identifiable as echo from assistant speech.
        if words.count < Self.textOverlapMinWords {
            let transcriptDigits = Self.extractDigitsFromNumberWords(words)
            if !transcriptDigits.isEmpty {
                let assistantNumbers = Self.extractNumbersFromText(assistantText)
                for num in assistantNumbers where Self.numbersFuzzyMatch(transcriptDigits, num) {
                    return true
                }
            }
            return false
        }

        let assistantWords = Set(assistantText.split(separator: " ").map(String.init))

        // Signal 1: Bag-of-words overlap (85%+ threshold).
        // Exclude common function words from the overlap count — they appear in almost
        // every sentence and cause false positives when the user references the same topic.
        let contentWords = words.filter { !Self.functionWords.contains($0) }
        guard contentWords.count >= 3 else { return false }
        let matchCount = contentWords.filter { assistantWords.contains($0) }.count
        let overlap = Float(matchCount) / Float(contentWords.count)
        if overlap >= Self.textOverlapThreshold {
            return true
        }

        // Signal 2: Consecutive-word substring match.
        if words.count >= Self.textOverlapMinConsecutiveWords {
            let assistantNormalized = assistantText
            for startIdx in 0...(words.count - Self.textOverlapMinConsecutiveWords) {
                let phrase = words[startIdx..<(startIdx + Self.textOverlapMinConsecutiveWords)]
                    .joined(separator: " ")
                if assistantNormalized.contains(phrase) {
                    return true
                }
            }
        }

        // Signal 3: Number-word match for longer transcripts.
        let transcriptDigits = Self.extractDigitsFromNumberWords(words)
        if !transcriptDigits.isEmpty {
            let assistantNumbers = Self.extractNumbersFromText(assistantText)
            for num in assistantNumbers where Self.numbersFuzzyMatch(transcriptDigits, num) {
                return true
            }
        }

        return false
    }

    /// Convert number words to numeric value: ["fifty", "six"] → "56".
    ///
    /// Handles tens+ones combining: "fifty" + "six" = 56, not "506".
    /// Also handles "hundred"/"thousand" multipliers.
    private static func extractDigitsFromNumberWords(_ words: [String]) -> String {
        // First pass: convert words to numeric components
        let ones: Set<String> = ["one","two","three","four","five","six","seven","eight","nine"]
        let tens: Set<String> = ["twenty","thirty","forty","fifty","sixty","seventy","eighty","ninety"]
        let onesMap: [String: Int] = [
            "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
            "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
            "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
            "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
            "eighteen": 18, "nineteen": 19,
            "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
            "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        ]

        var result = 0
        var current = 0
        var hasNumber = false

        for word in words {
            if let val = onesMap[word] {
                hasNumber = true
                if tens.contains(word) {
                    current += val
                } else if ones.contains(word) && current > 0 && current % 10 == 0 {
                    // tens + ones: "fifty" (50) + "six" (6) = 56
                    current += val
                } else {
                    current += val
                }
            } else if word == "hundred" {
                hasNumber = true
                current = (current == 0 ? 1 : current) * 100
            } else if word == "thousand" {
                hasNumber = true
                current = (current == 0 ? 1 : current) * 1000
                result += current
                current = 0
            } else if word.allSatisfy(\.isNumber) {
                hasNumber = true
                current = current * 10 + (Int(word) ?? 0)
            }
        }
        result += current

        return hasNumber ? String(result) : ""
    }

    /// Extract all digit sequences from text: "the answer is 546" → ["546"].
    private static func extractNumbersFromText(_ text: String) -> [String] {
        var numbers: [String] = []
        var current = ""
        for ch in text {
            if ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                numbers.append(current)
                current = ""
            }
        }
        if !current.isEmpty { numbers.append(current) }
        return numbers
    }

    /// Fuzzy number match — allows off-by-one digits (ASR might hear "556" instead of "546").
    private static func numbersFuzzyMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        // Same length, at most 1 digit different
        guard a.count == b.count, a.count <= 6 else { return false }
        var diffs = 0
        for (ca, cb) in zip(a, b) {
            if ca != cb { diffs += 1 }
            if diffs > 1 { return false }
        }
        return true
    }

    /// Clear text history (call on pipeline reset or conversation change).
    mutating func clearTextHistory() {
        recentAssistantText.removeAll()
    }

    /// Normalize text for overlap comparison: lowercase, hyphens→spaces, strip punctuation, collapse whitespace.
    private static func normalizeForOverlap(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " }
            .map { String($0) }
            .joined()
            .split(separator: " ")
            .joined(separator: " ")
    }

    // MARK: - State

    /// Whether the assistant is currently speaking.
    var assistantSpeaking: Bool = false
    /// Time when assistant stopped speaking.
    private var suppressUntil: Date?
    /// Short utterance guard expiry.
    private var shortUtteranceGuardUntil: Date?

    /// Time when the assistant's last speech ended (echo tail start).
    private var lastSpeechEndedAt: Date?

    // MARK: - Computed Properties

    /// Seconds since the assistant last stopped speaking.
    /// Returns `Double.infinity` if the assistant has never spoken.
    var secondsSinceLastSpeech: Double {
        guard let lastEnd = lastSpeechEndedAt else { return .infinity }
        return Date().timeIntervalSince(lastEnd)
    }

    /// Whether the echo suppressor is currently actively suppressing audio.
    /// True when assistant is speaking or within the echo tail window.
    var isInSuppression: Bool {
        if assistantSpeaking { return true }
        if let until = suppressUntil, Date() < until { return true }
        return false
    }

    // MARK: - Public API

    /// Call when assistant starts speaking.
    mutating func onAssistantSpeechStart() {
        assistantSpeaking = true
        suppressUntil = nil
        shortUtteranceGuardUntil = nil
    }

    /// Call when assistant stops speaking. Starts the echo tail windows.
    ///
    /// - Parameter speechDurationSecs: How long the assistant spoke. Longer TTS
    ///   responses produce more room echo and speaker bleedthrough, so the echo
    ///   tail and guard windows scale proportionally — but capped conservatively
    ///   to avoid blocking real speech for too long ("goes to sleep" effect).
    mutating func onAssistantSpeechEnd(speechDurationSecs: Double = 0) {
        assistantSpeaking = false
        let now = Date()
        lastSpeechEndedAt = now

        // Scale echo windows based on speech duration: +50ms per second of speech,
        // capped at 300ms bonus. An 8s response adds ~300ms (total ~800ms).
        // Reduced from +100ms/500ms cap — text-overlap + voice identity now handle late echo.
        let durationBonusMs = Int(min(speechDurationSecs * 50, 300))
        let tailMs = effectiveEchoTailMs + durationBonusMs
        let guardMs = shortUtteranceGuardMs + durationBonusMs

        suppressUntil = now.addingTimeInterval(Double(tailMs) / 1000.0)
        shortUtteranceGuardUntil = now.addingTimeInterval(Double(guardMs) / 1000.0)
    }

    mutating func reset() {
        assistantSpeaking = false
        suppressUntil = nil
        shortUtteranceGuardUntil = nil
        clearTextHistory()
        resetBandBaseline()
        clearPlaybackAudioBuffer()
        collectingDecay = false
        postPlaybackRmsSamples.removeAll()
    }

    /// Evaluate whether a completed speech segment should be accepted or dropped.
    ///
    /// - Parameters:
    ///   - durationSecs: Duration of the speech segment in seconds.
    ///   - rms: RMS energy of the segment.
    ///   - awaitingApproval: Whether we're waiting for a yes/no approval response.
    ///   - segmentOnset: Wall-clock time when speech onset was detected by the VAD.
    ///     The echo tail is checked against this onset time (not current time) to
    ///     catch segments that *started* during the echo window but took seconds
    ///     to complete — e.g. an 8s echo segment that finishes 9s after playback
    ///     ends would slip through a current-time check but is caught by onset.
    /// - Returns: `true` if the segment should be forwarded to STT, `false` to drop.
    mutating func shouldAccept(
        durationSecs: Float,
        rms: Float,
        awaitingApproval: Bool,
        segmentOnset: Date
    ) -> Bool {
        let onset = segmentOnset
        let now = Date()

        // 1. Active suppression — assistant is speaking.
        if assistantSpeaking {
            return false
        }

        // 2. Echo tail window — check against segment ONSET time.
        //    A segment whose speech started during the echo tail is almost certainly
        //    speaker bleedthrough, unless it clearly continues beyond the tail and
        //    is more likely to be the user starting promptly after Fae stops.
        if let until = suppressUntil,
           Self.shouldRejectForEchoTail(
               segmentOnset: onset,
               durationSecs: durationSecs,
               suppressUntil: until
           )
        {
            return false
        }

        // 3. Short utterance guard — drop very short segments post-playback.
        //    Use current time here: a long segment that starts in the guard window
        //    but extends past it is likely real speech, not echo.
        if let until = shortUtteranceGuardUntil, now < until {
            if durationSecs < Self.minPostPlaybackSegmentSecs {
                // Exception: during approval, accept shorter segments.
                if awaitingApproval && durationSecs >= Self.minApprovalSegmentSecs {
                    // Accept approval response.
                } else {
                    return false
                }
            }
        }

        // 4. Duration cap — very long segments are echo bleed.
        if durationSecs > Self.maxSegmentSecs {
            return false
        }

        // 5. Amplitude cap — only apply while still inside the recent playback
        //    guard window. Applying this unconditionally rejects legitimate
        //    loud user speech long after Fae has stopped talking.
        if let guardUntil = shortUtteranceGuardUntil,
           onset < guardUntil,
           rms > Self.echoRmsCeiling
        {
            return false
        }

        // Accepted — clear guard windows.
        suppressUntil = nil
        shortUtteranceGuardUntil = nil
        return true
    }

    static func shouldRejectForEchoTail(
        segmentOnset: Date,
        durationSecs: Float,
        suppressUntil: Date
    ) -> Bool {
        guard segmentOnset < suppressUntil else { return false }

        let segmentEnd = segmentOnset.addingTimeInterval(TimeInterval(durationSecs))
        let speechBeyondTailSecs = segmentEnd.timeIntervalSince(suppressUntil)
        if speechBeyondTailSecs <= 0 {
            return true
        }

        let beyondTailFraction = speechBeyondTailSecs / max(TimeInterval(durationSecs), 0.001)
        return speechBeyondTailSecs < Self.minSpeechBeyondTailSecs
            && beyondTailFraction < Self.minSpeechBeyondTailFraction
    }
}
