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
            return 0.3  // 30% of normal — minimal speaker bleed
        case .builtInSpeaker:
            return 1.0  // Standard — MacBook speakers
        case .externalSpeaker:
            return 1.3  // 130% — external speakers may have more reverb
        case .unknown:
            return 1.0  // Conservative default
        }
    }

    // MARK: - Timing Constants

    /// Base echo tail after assistant stops speaking (milliseconds).
    /// Adjusted by output route multiplier at runtime.
    private var baseEchoTailMs: Int { aecEnabled ? 300 : 500 }

    /// Base short-utterance guard window after assistant stops (milliseconds).
    private var baseShortUtteranceGuardMs: Int { aecEnabled ? 500 : 800 }

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
    /// Uses simple energy-in-band computation via band-pass approximation:
    /// - Low: 0-500 Hz
    /// - Mid: 500-4000 Hz
    /// - High: 4000+ Hz
    ///
    /// This is a lightweight approximation using DFT bin summation. For 16kHz
    /// audio with 576 samples (36ms), frequency resolution is ~27.8 Hz/bin.
    static func computeBandEnergy(samples: [Float], sampleRate: Int) -> BandEnergy {
        guard !samples.isEmpty, sampleRate > 0 else { return BandEnergy() }

        let n = samples.count
        let nyquist = Float(sampleRate) / 2.0
        let binWidth = Float(sampleRate) / Float(n)

        // Band boundaries in bins.
        let lowCutoffBin = max(1, Int(500.0 / binWidth))
        let midCutoffBin = min(n / 2, Int(4000.0 / binWidth))
        let maxBin = n / 2

        guard maxBin > 0, binWidth > 0, nyquist > 0 else { return BandEnergy() }

        // Compute magnitude spectrum via DFT for bins of interest.
        // Only compute bins we need — not a full FFT (we only need ~150 bins for 16kHz/576 samples).
        var lowEnergy: Float = 0
        var midEnergy: Float = 0
        var highEnergy: Float = 0

        for k in 1...maxBin {
            // DFT for bin k: sum of x[n] * e^(-j*2*pi*k*n/N)
            var realPart: Float = 0
            var imagPart: Float = 0
            let freqFactor = 2.0 * Float.pi * Float(k) / Float(n)
            for i in 0..<n {
                let angle = freqFactor * Float(i)
                realPart += samples[i] * cos(angle)
                imagPart -= samples[i] * sin(angle)
            }
            let magnitude = sqrt(realPart * realPart + imagPart * imagPart) / Float(n)
            let power = magnitude * magnitude

            if k < lowCutoffBin {
                lowEnergy += power
            } else if k < midCutoffBin {
                midEnergy += power
            } else {
                highEnergy += power
            }
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
            // Add 50% safety margin to measured decay.
            let adaptiveTail = Int(Float(decay) * 1.5)
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
    /// 0.75 = at least 75% of the transcript's words must match recent assistant text.
    /// Set high to avoid rejecting legitimate user speech that references Fae's words
    /// (e.g., user says "check my calendar for Tuesday" after Fae said "check your calendar").
    private static let textOverlapThreshold: Float = 0.75

    /// Minimum consecutive matching words required as a secondary echo signal.
    /// Requires at least 4 consecutive words to appear in the same order as assistant text.
    /// This catches partial echo more reliably than bag-of-words overlap alone.
    private static let textOverlapMinConsecutiveWords = 4

    /// Minimum word count for text overlap checking (very short utterances
    /// like "yes" or "stop" should not be rejected as echo).
    private static let textOverlapMinWords = 4

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
    /// Uses two complementary signals:
    /// 1. **Bag-of-words overlap**: 75%+ of transcript words appear in recent assistant text.
    /// 2. **Consecutive-word match**: 4+ consecutive words from the transcript appear in order
    ///    in the assistant text (catches partial echo more reliably).
    ///
    /// Either signal alone is sufficient — echo text typically shows both, but partial
    /// echo (mic catches the end of a sentence) may only show the consecutive signal.
    ///
    /// Short utterances (< 4 words) are exempt — "stop", "no thanks", "yes please" should
    /// never be rejected as echo even if Fae recently said those words.
    func isLikelyEchoText(_ transcript: String) -> Bool {
        let normalized = Self.normalizeForOverlap(transcript)
        let words = normalized.split(separator: " ")
        guard words.count >= Self.textOverlapMinWords else { return false }

        let assistantText = recentAssistantText.joined(separator: " ")
        let assistantWords = Set(assistantText.split(separator: " "))
        guard !assistantWords.isEmpty else { return false }

        // Signal 1: Bag-of-words overlap (75%+ threshold).
        let matchCount = words.filter { assistantWords.contains($0) }.count
        let overlap = Float(matchCount) / Float(words.count)
        if overlap >= Self.textOverlapThreshold {
            return true
        }

        // Signal 2: Consecutive-word substring match.
        // Check if any run of N+ consecutive transcript words appears in assistant text.
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

        return false
    }

    /// Clear text history (call on pipeline reset or conversation change).
    mutating func clearTextHistory() {
        recentAssistantText.removeAll()
    }

    /// Normalize text for overlap comparison: lowercase, strip punctuation, collapse whitespace.
    private static func normalizeForOverlap(_ text: String) -> String {
        text.lowercased()
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

    // MARK: - Computed Properties

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
