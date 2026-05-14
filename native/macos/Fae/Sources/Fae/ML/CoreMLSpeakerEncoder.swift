import Accelerate
import CoreML
import Foundation

/// Speaker embedding engine with Core ML neural backend and mel-spectral fallback.
///
/// Converts raw audio to a log-mel spectrogram using Accelerate (vDSP FFT + mel filterbank).
/// When a WeSpeaker ResNet34-LM CoreML model is available, runs Neural Engine inference to
/// produce a 256-dimensional L2-normalized speaker embedding. Otherwise, falls back to
/// mel-spectral statistics (mean + std of each mel band → 640-dimensional embedding).
///
/// The WeSpeaker model provides accurate speaker discrimination between humans.
/// The mel-spectral fallback is effective for distinguishing synthetic TTS voices from
/// human speech — sufficient for self-echo rejection (Fae recognizing her own voice).
///
/// Model: aufklarer/WeSpeaker-ResNet34-LM-CoreML (pyannote/wespeaker-voxceleb-resnet34-LM)
actor CoreMLSpeakerEncoder: SpeakerEmbeddingEngine {

    // MARK: - State

    private var model: MLModel?
    /// When `true`, the encoder produces 640-dim mel-spectral embeddings that can
    /// distinguish TTS from human speech but **cannot** discriminate between different
    /// humans. The pipeline must fall back to wake-word gating when this is `true`.
    private(set) var usingMelFallback = false
    private(set) var isLoaded = false
    private(set) var loadState: MLEngineLoadState = .notStarted
    /// Last liveness analysis result — queried by pipeline for threshold enforcement.
    private(set) var lastLivenessResult: LivenessResult?

    /// Whether the loaded model is the WeSpeaker neural encoder (vs legacy ECAPA-TDNN).
    private var isWeSpeakerModel = false

    /// The embedding dimension produced by the currently loaded encoder.
    /// WeSpeaker: 256, ECAPA-TDNN: 1024, mel-spectral fallback: 640.
    var embeddingDimension: Int {
        if usingMelFallback { return 640 }
        if isWeSpeakerModel { return 256 }
        return 1024
    }

    // MARK: - Constants

    /// WeSpeaker model expects 16 kHz audio input.
    private static let weSpeakerSampleRate = 16_000
    /// WeSpeaker uses 80-bin mel spectrogram.
    private static let weSpeakerNumMels = 80

    /// Legacy model sample rate (24 kHz) — used for mel-spectral fallback and liveness.
    private static let legacySampleRate = 24_000
    /// Legacy mel bins (128) — used for mel-spectral fallback and shared analysis.
    private static let legacyNumMels = 128

    /// WeSpeaker model accepts enumerated frame counts for flexible input shapes.
    /// The model was traced with these specific lengths.
    private static let weSpeakerEnumeratedFrames = [20, 50, 100, 200, 300, 500, 750, 1000, 1500, 2000]

    /// STFT parameters (same for both models).
    private static let nFFT = 1024
    private static let hopLength = 256
    private static let fMin: Float = 20
    private static let fMax: Float = 8_000  // WeSpeaker uses 8kHz max (16kHz Nyquist / 2)
    private static let legacyFMax: Float = 12_000  // Legacy fallback uses 12kHz

    // MARK: - Precomputed Assets

    /// Mel filterbank matrix for WeSpeaker: [80 × numFreqBins].
    private static let weSpeakerMelFilterbank: [[Float]] = createMelFilterbank(
        numMels: weSpeakerNumMels,
        sampleRate: weSpeakerSampleRate,
        fMax: fMax
    )

    /// Mel filterbank matrix for legacy fallback: [128 × numFreqBins].
    private static let legacyMelFilterbank: [[Float]] = createMelFilterbank(
        numMels: legacyNumMels,
        sampleRate: legacySampleRate,
        fMax: legacyFMax
    )

    /// Hanning window for STFT framing.
    private static let hannWindow: [Float] = {
        var window = [Float](repeating: 0, count: nFFT)
        vDSP_hann_window(&window, vDSP_Length(nFFT), Int32(vDSP_HANN_NORM))
        return window
    }()

    // MARK: - Load

    func load() async throws {
        loadState = .loading

        // Diagnostic: log bundle paths to help debug model-not-found issues.
        let faeBundle = Bundle.faeResources
        NSLog("CoreMLSpeakerEncoder: faeResources bundle=%@ resourceURL=%@",
              faeBundle.bundlePath,
              faeBundle.resourceURL?.path ?? "nil")

        // Try WeSpeaker CoreML model first (in Models/SpeakerEncoder/).
        let weSpeakerURL = faeBundle.url(
            forResource: "wespeaker",
            withExtension: "mlmodelc",
            subdirectory: "Models/SpeakerEncoder"
        ) ?? Bundle.main.url(
            forResource: "wespeaker",
            withExtension: "mlmodelc",
            subdirectory: "Models/SpeakerEncoder"
        )

        if let url = weSpeakerURL {
            NSLog("CoreMLSpeakerEncoder: found WeSpeaker model at %@", url.path)
            let mlConfig = MLModelConfiguration()
            mlConfig.computeUnits = .cpuAndNeuralEngine
            do {
                model = try MLModel(contentsOf: url, configuration: mlConfig)
                isWeSpeakerModel = true
                isLoaded = true
                loadState = .loaded
                NSLog("CoreMLSpeakerEncoder: WeSpeaker ResNet34-LM loaded (256-dim, Neural Engine)")
                return
            } catch {
                NSLog("CoreMLSpeakerEncoder: WeSpeaker load FAILED: %@", error.localizedDescription)
            }
        } else {
            NSLog("CoreMLSpeakerEncoder: WeSpeaker model NOT FOUND in bundle — voice identity will be degraded")
        }

        // Try legacy ECAPA-TDNN model (SpeakerEncoder.mlmodelc in bundle root).
        let legacyURL = faeBundle.url(
            forResource: "SpeakerEncoder",
            withExtension: "mlmodelc"
        ) ?? Bundle.main.url(
            forResource: "SpeakerEncoder",
            withExtension: "mlmodelc"
        )

        if let url = legacyURL {
            NSLog("CoreMLSpeakerEncoder: found legacy ECAPA-TDNN model at %@", url.path)
            let mlConfig = MLModelConfiguration()
            mlConfig.computeUnits = .cpuAndNeuralEngine
            do {
                model = try MLModel(contentsOf: url, configuration: mlConfig)
                isWeSpeakerModel = false
                isLoaded = true
                loadState = .loaded
                NSLog("CoreMLSpeakerEncoder: legacy ECAPA-TDNN model loaded (1024-dim)")
                return
            } catch {
                NSLog("CoreMLSpeakerEncoder: legacy model load FAILED: %@", error.localizedDescription)
            }
        } else {
            NSLog("CoreMLSpeakerEncoder: legacy ECAPA-TDNN model NOT FOUND in bundle")
        }

        // Mel-spectral fallback: last resort when no neural model loads.
        // WARNING: mel-spectral cannot distinguish between different humans
        // and poorly rejects high-quality TTS. Voice identity is effectively
        // broken in this mode.
        NSLog("CoreMLSpeakerEncoder: ⚠️ FALLING BACK TO MEL-SPECTRAL — voice identity degraded, cannot distinguish speakers")
        usingMelFallback = true
        isLoaded = true
        loadState = .loaded
        NSLog("CoreMLSpeakerEncoder: loaded in mel-spectral fallback mode (no .mlmodelc found)")
    }

    // MARK: - Embed

    func embed(audio: [Float], sampleRate: Int) async throws -> [Float] {
        guard isLoaded else {
            throw MLEngineError.notLoaded("SpeakerEncoder")
        }

        guard !audio.isEmpty else {
            throw MLEngineError.notLoaded("SpeakerEncoder: empty audio")
        }

        // Liveness check uses legacy mel-spectrogram (128 bins, 24kHz).
        let audio24k = sampleRate == Self.legacySampleRate
            ? audio
            : Self.resample(audio, from: sampleRate, to: Self.legacySampleRate)
        let legacyMel = Self.computeLogMelSpectrogram(
            audio24k,
            filterbank: Self.legacyMelFilterbank,
            numMels: Self.legacyNumMels
        )
        let legacyNumFrames = legacyMel.count / Self.legacyNumMels
        if legacyNumFrames > 0 {
            let liveness = Self.checkLiveness(mel: legacyMel, numFrames: legacyNumFrames, audio: audio24k)
            lastLivenessResult = liveness
            if liveness.suspicious {
                NSLog("CoreMLSpeakerEncoder: liveness warning — score %.3f (spectral=%.4f, highFreq=%.4f, f0=%.4f, proximity=%.4f)",
                      liveness.score, liveness.spectralVariance, liveness.highFreqRatio,
                      liveness.f0Variance, liveness.proximityRatio)
            }
        }

        // Mel-spectral fallback: 5 stats per mel band → 640-dim vector.
        if usingMelFallback {
            guard legacyNumFrames > 0 else {
                throw MLEngineError.notLoaded("SpeakerEncoder: audio too short for mel spectrogram")
            }
            return Self.melSpectralEmbed(mel: legacyMel, numFrames: legacyNumFrames)
        }

        // Core ML neural path.
        guard let model else {
            throw MLEngineError.notLoaded("SpeakerEncoder")
        }

        if isWeSpeakerModel {
            return try await embedWithWeSpeaker(audio: audio, sampleRate: sampleRate, model: model)
        } else {
            return try await embedWithLegacy(mel: legacyMel, numFrames: legacyNumFrames, model: model)
        }
    }

    // MARK: - WeSpeaker Inference

    /// WeSpeaker ResNet34-LM inference path (256-dim embeddings).
    private func embedWithWeSpeaker(audio: [Float], sampleRate: Int, model: MLModel) async throws -> [Float] {
        // 1. Resample to 16 kHz.
        let audio16k = sampleRate == Self.weSpeakerSampleRate
            ? audio
            : Self.resample(audio, from: sampleRate, to: Self.weSpeakerSampleRate)

        // 2. Compute 80-bin log-mel spectrogram → [numMels, numFrames].
        let mel = Self.computeLogMelSpectrogram(
            audio16k,
            filterbank: Self.weSpeakerMelFilterbank,
            numMels: Self.weSpeakerNumMels
        )
        let numFrames = mel.count / Self.weSpeakerNumMels
        guard numFrames >= 20 else {
            throw MLEngineError.notLoaded("SpeakerEncoder: audio too short (need at least 20 frames)")
        }

        // 3. Find the closest enumerated frame count (WeSpeaker model constraint).
        let targetFrames = Self.closestEnumeratedFrameCount(numFrames)

        // 4. Time-normalize mel to target frames.
        let normalizedMel = Self.timeNormalizeMel(
            mel,
            numFrames: numFrames,
            numMels: Self.weSpeakerNumMels,
            targetFrames: targetFrames
        )

        // 5. Transpose to [1, T, 80] (WeSpeaker expects time-major).
        // Current layout: [numMels, numFrames] row-major → need [numFrames, numMels]
        var transposed = [Float](repeating: 0, count: targetFrames * Self.weSpeakerNumMels)
        for t in 0..<targetFrames {
            for m in 0..<Self.weSpeakerNumMels {
                transposed[t * Self.weSpeakerNumMels + m] = normalizedMel[m * targetFrames + t]
            }
        }

        // 6. Create MLMultiArray input [1, T, 80] as Float16.
        let shape: [NSNumber] = [1, NSNumber(value: targetFrames), NSNumber(value: Self.weSpeakerNumMels)]
        let input = try MLMultiArray(shape: shape, dataType: .float16)
        for i in 0..<transposed.count {
            input[i] = NSNumber(value: transposed[i])
        }

        // 7. Run Core ML prediction.
        let provider = try MLDictionaryFeatureProvider(
            dictionary: ["mel": MLFeatureValue(multiArray: input)]
        )
        let result = try await model.prediction(from: provider)

        // 8. Extract embedding from output ("embedding" key, shape [1, 256]).
        guard let embeddingValue = result.featureValue(for: "embedding"),
              let embeddingArray = embeddingValue.multiArrayValue else {
            throw MLEngineError.notLoaded("SpeakerEncoder: WeSpeaker output missing 'embedding' key")
        }

        let embeddingDim = 256
        var embedding = [Float](repeating: 0, count: embeddingDim)
        for i in 0..<embeddingDim {
            embedding[i] = embeddingArray[i].floatValue
        }

        // WeSpeaker output is already L2-normalized, but normalize again for safety.
        return Self.l2Normalize(embedding)
    }

    /// Legacy ECAPA-TDNN inference path.
    private func embedWithLegacy(mel: [Float], numFrames: Int, model: MLModel) async throws -> [Float] {
        guard numFrames > 0 else {
            throw MLEngineError.notLoaded("SpeakerEncoder: audio too short for mel spectrogram")
        }

        // Create MLMultiArray input [1, 128, T].
        let shape: [NSNumber] = [1, NSNumber(value: Self.legacyNumMels), NSNumber(value: numFrames)]
        let input = try MLMultiArray(shape: shape, dataType: .float32)
        for i in 0..<mel.count {
            input[i] = NSNumber(value: mel[i])
        }

        // Run Core ML prediction.
        let provider = try MLDictionaryFeatureProvider(
            dictionary: ["mel_input": MLFeatureValue(multiArray: input)]
        )
        let result = try await model.prediction(from: provider)

        // Extract embedding from output.
        let embedding = try Self.extractEmbedding(from: result)

        // L2-normalize.
        return Self.l2Normalize(embedding)
    }

    /// Find the closest enumerated frame count for WeSpeaker model.
    static func closestEnumeratedFrameCount(_ numFrames: Int) -> Int {
        var closest = weSpeakerEnumeratedFrames[0]
        var minDiff = abs(numFrames - closest)
        for frames in weSpeakerEnumeratedFrames {
            let diff = abs(numFrames - frames)
            if diff < minDiff {
                minDiff = diff
                closest = frames
            }
        }
        return closest
    }

    /// Time-normalize mel spectrogram to target frame count via linear interpolation.
    private static func timeNormalizeMel(
        _ mel: [Float],
        numFrames: Int,
        numMels: Int,
        targetFrames: Int
    ) -> [Float] {
        guard numFrames > 0, numMels > 0, targetFrames > 1 else { return mel }
        if numFrames == targetFrames { return mel }

        var output = [Float](repeating: 0, count: numMels * targetFrames)
        let denominator = max(targetFrames - 1, 1)
        let sourceMax = Float(max(numFrames - 1, 0))

        for melIndex in 0..<numMels {
            let bandOffset = melIndex * numFrames
            let outOffset = melIndex * targetFrames
            for frameIndex in 0..<targetFrames {
                let position = Float(frameIndex) * sourceMax / Float(denominator)
                let left = Int(position.rounded(.down))
                let right = min(left + 1, numFrames - 1)
                let alpha = position - Float(left)
                let lhs = mel[bandOffset + left]
                let rhs = mel[bandOffset + right]
                output[outOffset + frameIndex] = lhs + (rhs - lhs) * alpha
            }
        }
        return output
    }

    // MARK: - Shared Analysis Helpers

    /// Shared sample rate for mel-spectral analysis helpers used by other audio subsystems.
    /// Uses legacy 24kHz for compatibility with existing liveness/analysis code.
    static var analysisSampleRate: Int { legacySampleRate }

    /// Shared mel bin count for mel-spectral analysis helpers used by other audio subsystems.
    /// Uses legacy 128 bins for compatibility with existing analysis code.
    static var analysisNumMels: Int { legacyNumMels }

    /// Compute the same log-mel representation used by the speaker encoder for arbitrary audio.
    /// Returns a flat `[numMels × numFrames]` buffer in row-major order.
    /// Uses legacy 128-bin mel for compatibility with existing analysis code.
    static func sharedLogMelSpectrogram(audio: [Float], sampleRate: Int) -> (mel: [Float], numFrames: Int) {
        let audio24k = sampleRate == legacySampleRate
            ? audio
            : resample(audio, from: sampleRate, to: legacySampleRate)
        let mel = computeLogMelSpectrogram(audio24k, filterbank: legacyMelFilterbank, numMels: legacyNumMels)
        let numFrames = mel.count / legacyNumMels
        return (mel, numFrames)
    }

    // MARK: - Mel-Spectral Fallback

    /// Compute a speaker fingerprint from mel-spectral statistics.
    ///
    /// For each of the 128 mel bands, computes four statistics across frames:
    /// - mean: spectral envelope (formant structure)
    /// - standard deviation: energy variation per band
    /// - skewness: asymmetry of energy distribution
    /// - kurtosis: peakedness of energy distribution
    ///
    /// Plus 128 delta features (temporal dynamics — how each band changes over time).
    ///
    /// Total: 128 × 5 = 640-dimensional L2-normalized embedding.
    ///
    /// This is sufficient for speaker discrimination in typical (1-3 person)
    /// home/office environments, though less accurate than neural WeSpeaker/ECAPA-TDNN
    /// for large-scale verification.
    private static func melSpectralEmbed(mel: [Float], numFrames: Int) -> [Float] {
        // mel layout: [legacyNumMels × numFrames] in row-major order.
        // 5 stats per band: mean, std, skewness, kurtosis, delta_std
        let statsPerBand = 5
        var embedding = [Float](repeating: 0, count: legacyNumMels * statsPerBand)

        for m in 0..<legacyNumMels {
            let baseOffset = m * numFrames
            var sum: Float = 0
            var sumSq: Float = 0
            var sumCub: Float = 0
            var sumQrt: Float = 0

            for f in 0..<numFrames {
                let val = mel[baseOffset + f]
                sum += val
                let sq = val * val
                sumSq += sq
                sumCub += sq * val
                sumQrt += sq * sq
            }

            let n = Float(numFrames)
            let mean = sum / n
            let variance = (sumSq / n) - (mean * mean)
            let std = sqrtf(max(variance, 0))

            // Skewness: E[(X - mean)^3] / std^3
            var skewness: Float = 0
            if std > 1e-8 {
                let m3 = (sumCub / n) - 3 * mean * (sumSq / n) + 2 * mean * mean * mean
                skewness = m3 / (std * std * std)
            }

            // Kurtosis: E[(X - mean)^4] / std^4 - 3 (excess kurtosis)
            var kurtosis: Float = 0
            if std > 1e-8 {
                let m4 = (sumQrt / n) - 4 * mean * (sumCub / n) + 6 * mean * mean * (sumSq / n) - 3 * mean * mean * mean * mean
                kurtosis = m4 / (std * std * std * std) - 3
            }

            // Delta features: std of frame-to-frame differences (temporal dynamics).
            var deltaStd: Float = 0
            if numFrames > 1 {
                var deltaSum: Float = 0
                var deltaSumSq: Float = 0
                for f in 1..<numFrames {
                    let delta = mel[baseOffset + f] - mel[baseOffset + f - 1]
                    deltaSum += delta
                    deltaSumSq += delta * delta
                }
                let dn = Float(numFrames - 1)
                let deltaMean = deltaSum / dn
                let deltaVar = (deltaSumSq / dn) - (deltaMean * deltaMean)
                deltaStd = sqrtf(max(deltaVar, 0))
            }

            embedding[m] = mean
            embedding[legacyNumMels + m] = std
            embedding[legacyNumMels * 2 + m] = skewness
            embedding[legacyNumMels * 3 + m] = kurtosis
            embedding[legacyNumMels * 4 + m] = deltaStd
        }

        return l2Normalize(embedding)
    }

    // MARK: - Mel Spectrogram

    /// Compute log-mel spectrogram from audio using the specified filterbank.
    ///
    /// - Parameters:
    ///   - audio: Audio samples at the expected sample rate for the filterbank.
    ///   - filterbank: Mel filterbank matrix [numMels × numFreqBins].
    ///   - numMels: Number of mel bands (must match filterbank).
    /// - Returns: Flat array of shape [numMels × numFrames] in row-major order.
    private static func computeLogMelSpectrogram(
        _ audio: [Float],
        filterbank: [[Float]],
        numMels: Int
    ) -> [Float] {
        let numFreqBins = nFFT / 2 + 1 // 513
        let numFrames = max(0, (audio.count - nFFT) / hopLength + 1)
        guard numFrames > 0 else { return [] }

        // Allocate magnitude spectrogram [numFrames × numFreqBins].
        var magnitudes = [Float](repeating: 0, count: numFrames * numFreqBins)

        // FFT setup.
        let log2n = vDSP_Length(log2(Float(nFFT)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return []
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Working buffers.
        var windowed = [Float](repeating: 0, count: nFFT)
        var realp = [Float](repeating: 0, count: nFFT / 2)
        var imagp = [Float](repeating: 0, count: nFFT / 2)

        for frame in 0..<numFrames {
            let start = frame * hopLength

            // Copy frame samples (zero-pad if at boundary).
            let available = min(nFFT, audio.count - start)
            for i in 0..<nFFT {
                windowed[i] = i < available ? audio[start + i] : 0
            }

            // Apply Hanning window.
            vDSP_vmul(windowed, 1, hannWindow, 1, &windowed, 1, vDSP_Length(nFFT))

            // Zero the split complex buffers.
            for i in 0..<(nFFT / 2) {
                realp[i] = 0
                imagp[i] = 0
            }

            // FFT with proper pointer scoping.
            realp.withUnsafeMutableBufferPointer { rBuf in
                imagp.withUnsafeMutableBufferPointer { iBuf in
                    var splitComplex = DSPSplitComplex(
                        realp: rBuf.baseAddress!,
                        imagp: iBuf.baseAddress!
                    )

                    // Pack interleaved real data into split complex.
                    windowed.withUnsafeBufferPointer { wBuf in
                        wBuf.baseAddress!.withMemoryRebound(
                            to: DSPComplex.self, capacity: nFFT / 2
                        ) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(nFFT / 2))
                        }
                    }

                    // Forward FFT (in-place).
                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))
                }
            }

            // Extract magnitudes.
            // vDSP_fft_zrip packs: DC in realp[0], Nyquist in imagp[0].
            let offset = frame * numFreqBins
            magnitudes[offset] = abs(realp[0]) // DC
            for k in 1..<(nFFT / 2) {
                let re = realp[k]
                let im = imagp[k]
                magnitudes[offset + k] = sqrtf(re * re + im * im)
            }
            magnitudes[offset + nFFT / 2] = abs(imagp[0]) // Nyquist
        }

        // Apply mel filterbank: [numMels × numFreqBins] × [numFreqBins × numFrames]
        // Output: [numMels × numFrames]
        var melSpec = [Float](repeating: 0, count: numMels * numFrames)

        for m in 0..<numMels {
            let filter = filterbank[m]
            for f in 0..<numFrames {
                var dot: Float = 0
                // Dot product of filter[0..<numFreqBins] with magnitudes[f*numFreqBins..<(f+1)*numFreqBins]
                let magOffset = f * numFreqBins
                vDSP_dotpr(
                    filter, 1,
                    Array(magnitudes[magOffset..<(magOffset + numFreqBins)]), 1,
                    &dot,
                    vDSP_Length(numFreqBins)
                )
                melSpec[m * numFrames + f] = dot
            }
        }

        // Log transform: log(max(x, 1e-5)).
        let floor: Float = 1e-5
        for i in 0..<melSpec.count {
            melSpec[i] = logf(max(melSpec[i], floor))
        }

        return melSpec
    }

    // MARK: - Mel Filterbank

    /// Create a mel filterbank matrix [numMels × numFreqBins] with Slaney normalization.
    ///
    /// - Parameters:
    ///   - numMels: Number of mel bands.
    ///   - sampleRate: Audio sample rate (determines frequency resolution).
    ///   - fMax: Maximum frequency for mel filterbank.
    /// - Returns: Mel filterbank matrix [numMels × numFreqBins].
    private static func createMelFilterbank(
        numMels: Int,
        sampleRate: Int,
        fMax: Float
    ) -> [[Float]] {
        let numFreqBins = nFFT / 2 + 1 // 513
        let sr = Float(sampleRate)

        func hzToMel(_ hz: Float) -> Float { 2595.0 * log10f(1.0 + hz / 700.0) }
        func melToHz(_ mel: Float) -> Float { 700.0 * (powf(10.0, mel / 2595.0) - 1.0) }

        let melMin = hzToMel(fMin)
        let melMax = hzToMel(fMax)

        // numMels + 2 evenly spaced points on mel scale.
        var melPoints = [Float](repeating: 0, count: numMels + 2)
        for i in 0...(numMels + 1) {
            melPoints[i] = melMin + Float(i) * (melMax - melMin) / Float(numMels + 1)
        }

        // Convert to frequency bin indices.
        let freqResolution = sr / Float(nFFT)
        let fftBins = melPoints.map { melToHz($0) / freqResolution }

        // Build triangular filters with Slaney normalization.
        var filterbank = [[Float]](
            repeating: [Float](repeating: 0, count: numFreqBins),
            count: numMels
        )

        for i in 0..<numMels {
            let left = fftBins[i]
            let center = fftBins[i + 1]
            let right = fftBins[i + 2]

            // Slaney normalization: 2 / (right_hz - left_hz)
            let leftHz = melToHz(melPoints[i])
            let rightHz = melToHz(melPoints[i + 2])
            let norm = 2.0 / (rightHz - leftHz)

            for j in 0..<numFreqBins {
                let freq = Float(j)
                if freq >= left && freq <= center && center > left {
                    filterbank[i][j] = norm * (freq - left) / (center - left)
                } else if freq > center && freq <= right && right > center {
                    filterbank[i][j] = norm * (right - freq) / (right - center)
                }
            }
        }

        return filterbank
    }

    // MARK: - Resampling

    /// Resample audio using linear interpolation (via vDSP_vlint).
    private static func resample(_ audio: [Float], from srcRate: Int, to dstRate: Int) -> [Float] {
        guard srcRate != dstRate, audio.count > 1 else { return audio }

        let outputLength = Int(Double(audio.count) * Double(dstRate) / Double(srcRate))
        guard outputLength > 1 else { return audio }

        // Generate fractional indices into the source array.
        var indices = [Float](repeating: 0, count: outputLength)
        let step = Float(audio.count - 1) / Float(outputLength - 1)
        for i in 0..<outputLength {
            indices[i] = Float(i) * step
        }

        // Linear interpolation.
        var output = [Float](repeating: 0, count: outputLength)
        vDSP_vlint(audio, indices, 1, &output, 1, vDSP_Length(outputLength), vDSP_Length(audio.count))

        return output
    }

    // MARK: - Output Extraction

    /// Extract the embedding vector from Core ML prediction output.
    ///
    /// Handles both utterance-level (1, 1024) and frame-level (1, T, 1024) outputs.
    /// For frame-level output, averages across the time dimension.
    private static func extractEmbedding(from result: MLFeatureProvider) throws -> [Float] {
        // Find the first multi-array output.
        for name in result.featureNames {
            guard let value = result.featureValue(for: name),
                  let multiArray = value.multiArrayValue
            else { continue }

            let shape = multiArray.shape.map { $0.intValue }

            if shape.count == 2 {
                // Utterance-level: [1, embeddingDim]
                let dim = shape[1]
                var embedding = [Float](repeating: 0, count: dim)
                let ptr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: dim)
                for i in 0..<dim {
                    embedding[i] = ptr[i]
                }
                return embedding

            } else if shape.count == 3 {
                // Frame-level: [1, T, embeddingDim] — average over T.
                let numFrames = shape[1]
                let dim = shape[2]
                guard numFrames > 0 else { continue }

                var embedding = [Float](repeating: 0, count: dim)
                let ptr = multiArray.dataPointer.bindMemory(to: Float.self, capacity: numFrames * dim)

                for f in 0..<numFrames {
                    let offset = f * dim
                    for d in 0..<dim {
                        embedding[d] += ptr[offset + d]
                    }
                }

                // Average.
                var divisor = Float(numFrames)
                vDSP_vsdiv(embedding, 1, &divisor, &embedding, 1, vDSP_Length(dim))

                return embedding
            }
        }

        throw MLEngineError.notLoaded("SpeakerEncoder: no valid output tensor found")
    }

    // MARK: - Liveness Heuristics

    /// Result of enhanced replay/liveness analysis on audio.
    ///
    /// Four independent checks aggregated into a composite score:
    /// - **Spectral variance**: formant dynamics across frames (replays are flatter)
    /// - **High-frequency ratio**: codec compression attenuates above ~16 kHz
    /// - **F0 variance**: pitch contour variation via autocorrelation (replays flatten dynamics)
    /// - **Proximity ratio**: direct-to-reverberant energy (speakers diffuse transients)
    struct LivenessResult: Sendable {
        let spectralVariance: Float
        let highFreqRatio: Float
        let f0Variance: Float
        let proximityRatio: Float
        /// Aggregate liveness score (0-1, higher = more likely live speech).
        let score: Float
        /// Per-check raw values for diagnostics.
        let checks: [String: Float]
        /// Whether the audio looks suspicious (score below threshold).
        let suspicious: Bool
    }

    /// Run enhanced liveness heuristics combining mel-spectral and time-domain analysis.
    ///
    /// Four independent checks aggregated into a composite score:
    /// 1. **Spectral variance**: Real speech has dynamic formant variation.
    /// 2. **High-frequency energy**: Codec compression attenuates above ~16 kHz.
    /// 3. **F0 variance**: Pitch contour variation via autocorrelation (vDSP).
    /// 4. **Proximity ratio**: Direct-to-reverberant energy (transient sharpness).
    ///
    /// Returns a `LivenessResult` — the pipeline queries `lastLivenessResult`
    /// to enforce thresholds when `voiceIdentity.mode == "enforce"`.
    static func checkLiveness(mel: [Float], numFrames: Int, audio: [Float]) -> LivenessResult {
        guard numFrames > 1 else {
            return LivenessResult(
                spectralVariance: 0, highFreqRatio: 0, f0Variance: 0,
                proximityRatio: 0, score: 0, checks: [:], suspicious: false
            )
        }

        // 1. Spectral variance: compute per-frame energy, then variance across frames.
        // Uses legacyNumMels (128) since liveness is computed on legacy mel-spectrogram.
        var frameEnergies = [Float](repeating: 0, count: numFrames)
        for f in 0..<numFrames {
            var energy: Float = 0
            for m in 0..<legacyNumMels {
                energy += mel[m * numFrames + f]
            }
            frameEnergies[f] = energy / Float(legacyNumMels)
        }

        var meanEnergy: Float = 0
        vDSP_meanv(frameEnergies, 1, &meanEnergy, vDSP_Length(numFrames))

        var sumSqDiff: Float = 0
        for e in frameEnergies {
            let diff = e - meanEnergy
            sumSqDiff += diff * diff
        }
        let spectralVariance = sumSqDiff / Float(numFrames)

        // 2. High-frequency energy ratio: compare top 1/4 mel bands vs total.
        let highBandStart = legacyNumMels * 3 / 4
        var totalEnergy: Float = 0
        var highEnergy: Float = 0
        for m in 0..<legacyNumMels {
            var bandSum: Float = 0
            let base = m * numFrames
            vDSP_sve(Array(mel[base..<(base + numFrames)]), 1, &bandSum, vDSP_Length(numFrames))
            totalEnergy += abs(bandSum)
            if m >= highBandStart {
                highEnergy += abs(bandSum)
            }
        }
        let highFreqRatio = totalEnergy > 1e-10 ? highEnergy / totalEnergy : 0

        // 3. F0 variance (pitch contour variation via autocorrelation).
        let f0Var = estimateF0Variance(audio)

        // 4. Proximity ratio (direct-to-reverberant energy via crest factor).
        let proxRatio = estimateProximityRatio(audio)

        // Normalize each check to [0, 1] for weighted aggregation.
        let normSpectral = min(spectralVariance / 0.5, 1.0)
        let normHighFreq = min(highFreqRatio / 0.15, 1.0)
        let normF0 = min(f0Var / 0.3, 1.0)
        let score = 0.3 * normSpectral + 0.3 * normHighFreq + 0.25 * normF0 + 0.15 * proxRatio

        let checks: [String: Float] = [
            "spectralVariance": spectralVariance,
            "highFreqRatio": highFreqRatio,
            "f0Variance": f0Var,
            "proximityRatio": proxRatio,
        ]

        return LivenessResult(
            spectralVariance: spectralVariance,
            highFreqRatio: highFreqRatio,
            f0Variance: f0Var,
            proximityRatio: proxRatio,
            score: score,
            checks: checks,
            suspicious: score < 0.3
        )
    }

    /// Estimate F0 (fundamental frequency) variance from raw audio via autocorrelation.
    ///
    /// Real speech has natural pitch variation (coefficient of variation >0.15).
    /// Recordings played through speakers tend to flatten pitch dynamics (<0.10).
    /// Uses vDSP for efficient dot-product computation at each lag.
    /// Note: Uses legacySampleRate (24kHz) since liveness is computed on resampled audio.
    private static func estimateF0Variance(_ audio: [Float]) -> Float {
        let frameLen = legacySampleRate * 30 / 1000   // 30ms = 720 samples at 24kHz
        let hopSamples = legacySampleRate * 10 / 1000  // 10ms hop = 240 samples
        let minLag = legacySampleRate / 400            // 400 Hz max F0 -> lag 60
        let maxLag = legacySampleRate / 80             // 80 Hz min F0 -> lag 300

        guard audio.count >= frameLen, maxLag < frameLen else { return 0 }

        var f0Values: [Float] = []

        audio.withUnsafeBufferPointer { buf in
            var offset = 0
            while offset + frameLen <= buf.count {
                let framePtr = buf.baseAddress! + offset

                // Skip silence.
                var rms: Float = 0
                vDSP_rmsqv(framePtr, 1, &rms, vDSP_Length(frameLen))
                guard rms > 0.01 else {
                    offset += hopSamples
                    continue
                }

                // Find dominant pitch via autocorrelation peak in F0 range.
                var bestLag = 0
                var bestCorr: Float = -1

                for lag in minLag...min(maxLag, frameLen - 1) {
                    var corr: Float = 0
                    let count = vDSP_Length(frameLen - lag)
                    vDSP_dotpr(framePtr, 1, framePtr + lag, 1, &corr, count)
                    // Normalize by frame energy for comparable correlation values.
                    var energy: Float = 0
                    vDSP_dotpr(framePtr, 1, framePtr, 1, &energy, count)
                    if energy > 1e-10 { corr /= energy }
                    if corr > bestCorr {
                        bestCorr = corr
                        bestLag = lag
                    }
                }

                if bestLag > 0 && bestCorr > 0.3 {
                    f0Values.append(Float(legacySampleRate) / Float(bestLag))
                }

                offset += hopSamples
            }
        }

        guard f0Values.count > 2 else { return 0 }

        // Coefficient of variation = std / mean.
        var mean: Float = 0
        vDSP_meanv(f0Values, 1, &mean, vDSP_Length(f0Values.count))
        guard mean > 1 else { return 0 }

        var sumSq: Float = 0
        for v in f0Values {
            let d = v - mean
            sumSq += d * d
        }
        return sqrtf(sumSq / Float(f0Values.count)) / mean
    }

    /// Estimate proximity ratio (direct-to-reverberant energy) from raw audio.
    ///
    /// Direct speech has sharper transients (higher crest factor = peak/RMS)
    /// than speech played through a speaker, where room acoustics diffuse energy.
    /// Returns a value in [0, 1] where higher = more likely direct speech.
    /// Note: Uses legacySampleRate (24kHz) since liveness is computed on resampled audio.
    private static func estimateProximityRatio(_ audio: [Float]) -> Float {
        let windowSize = legacySampleRate * 20 / 1000  // 20ms windows at 24kHz
        let hopSamples = legacySampleRate * 10 / 1000

        guard audio.count >= windowSize else { return 0 }

        var crestFactors: [Float] = []

        audio.withUnsafeBufferPointer { buf in
            var offset = 0
            while offset + windowSize <= buf.count {
                let ptr = buf.baseAddress! + offset

                var rms: Float = 0
                vDSP_rmsqv(ptr, 1, &rms, vDSP_Length(windowSize))
                guard rms > 0.005 else {
                    offset += hopSamples
                    continue
                }

                var peak: Float = 0
                vDSP_maxmgv(ptr, 1, &peak, vDSP_Length(windowSize))
                crestFactors.append(peak / rms)

                offset += hopSamples
            }
        }

        guard !crestFactors.isEmpty else { return 0 }

        var mean: Float = 0
        vDSP_meanv(crestFactors, 1, &mean, vDSP_Length(crestFactors.count))

        // Normalize: direct speech crest ~6-10, speaker playback ~3-5.
        return min(max((mean - 3.0) / 7.0, 0), 1)
    }

    // MARK: - L2 Normalization

    static func l2Normalize(_ vec: [Float]) -> [Float] {
        var sumSq: Float = 0
        vDSP_svesq(vec, 1, &sumSq, vDSP_Length(vec.count))
        let norm = sqrtf(sumSq)
        guard norm > 1e-10 else { return vec }

        var result = [Float](repeating: 0, count: vec.count)
        var divisor = norm
        vDSP_vsdiv(vec, 1, &divisor, &result, 1, vDSP_Length(vec.count))
        return result
    }
}
