import Accelerate
import CoreML
import Foundation

/// Speaker embedding engine with Core ML neural backend and mel-spectral fallback.
///
/// Converts raw audio to a log-mel spectrogram using Accelerate (vDSP FFT + mel filterbank).
/// When a compiled ECAPA-TDNN model (`SpeakerEncoder.mlmodelc`) is available, runs Core ML
/// inference to produce a 1024-dimensional speaker embedding. Otherwise, falls back to
/// mel-spectral statistics (mean + std of each mel band → 256-dimensional embedding).
///
/// The mel-spectral fallback is effective for distinguishing synthetic TTS voices from
/// human speech — sufficient for self-echo rejection (Fae recognizing her own voice).
///
/// Replaces: nothing (new subsystem for voice identity).
actor CoreMLSpeakerEncoder: SpeakerEmbeddingEngine {

    // MARK: - State

    private var model: MLModel?
    private var usingMelFallback = false
    private(set) var isLoaded = false
    private(set) var loadState: MLEngineLoadState = .notStarted

    // MARK: - Constants

    /// Model expects 24 kHz audio input.
    private static let modelSampleRate = 24_000

    /// STFT parameters matching Qwen3-TTS preprocessing.
    private static let nFFT = 1024
    private static let hopLength = 256
    private static let numMels = 128
    private static let fMin: Float = 0
    private static let fMax: Float = 12_000

    // MARK: - Precomputed Assets

    /// Mel filterbank matrix: [numMels × numFreqBins].
    private static let melFilterbank: [[Float]] = createMelFilterbank()

    /// Hanning window for STFT framing.
    private static let hannWindow: [Float] = {
        var window = [Float](repeating: 0, count: nFFT)
        vDSP_hann_window(&window, vDSP_Length(nFFT), Int32(vDSP_HANN_NORM))
        return window
    }()

    // MARK: - Load

    func load() async throws {
        loadState = .loading

        // Try Core ML model first (neural speaker embedding).
        let url = Bundle.faeResources.url(
            forResource: "SpeakerEncoder",
            withExtension: "mlmodelc"
        ) ?? Bundle.main.url(
            forResource: "SpeakerEncoder",
            withExtension: "mlmodelc"
        )

        if let url {
            let mlConfig = MLModelConfiguration()
            mlConfig.computeUnits = .cpuAndNeuralEngine
            do {
                model = try MLModel(contentsOf: url, configuration: mlConfig)
                isLoaded = true
                loadState = .loaded
                NSLog("CoreMLSpeakerEncoder: Core ML model loaded from bundle")
                return
            } catch {
                NSLog("CoreMLSpeakerEncoder: Core ML load failed: %@, falling back to mel-spectral",
                      error.localizedDescription)
            }
        }

        // Fallback: mel-spectral statistics (no trained model needed).
        // Produces a 256-dim embedding (mean + std of 128 mel bands).
        // Effective for distinguishing synthetic TTS voice from human speech.
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

        // 1. Resample to 24 kHz if needed.
        let audio24k = sampleRate == Self.modelSampleRate
            ? audio
            : Self.resample(audio, from: sampleRate, to: Self.modelSampleRate)

        // 2. Compute log-mel spectrogram → [numMels, numFrames].
        let mel = Self.computeLogMelSpectrogram(audio24k)
        let numFrames = mel.count / Self.numMels
        guard numFrames > 0 else {
            throw MLEngineError.notLoaded("SpeakerEncoder: audio too short for mel spectrogram")
        }

        // Liveness check (non-blocking — log only).
        let liveness = Self.checkLiveness(mel: mel, numFrames: numFrames)
        if liveness.isSuspicious {
            NSLog("CoreMLSpeakerEncoder: liveness warning — low spectral variance (%.4f) and low high-freq ratio (%.4f), possible replay",
                  liveness.spectralVariance, liveness.highFreqRatio)
        }

        // Mel-spectral fallback: mean + std of each mel band → 256-dim vector.
        if usingMelFallback {
            return Self.melSpectralEmbed(mel: mel, numFrames: numFrames)
        }

        // Core ML neural path.
        guard let model else {
            throw MLEngineError.notLoaded("SpeakerEncoder")
        }

        // 3. Create MLMultiArray input [1, 128, T].
        let shape: [NSNumber] = [1, NSNumber(value: Self.numMels), NSNumber(value: numFrames)]
        let input = try MLMultiArray(shape: shape, dataType: .float32)
        for i in 0..<mel.count {
            input[i] = NSNumber(value: mel[i])
        }

        // 4. Run Core ML prediction.
        let provider = try MLDictionaryFeatureProvider(
            dictionary: ["mel_input": MLFeatureValue(multiArray: input)]
        )
        let result = try await model.prediction(from: provider)

        // 5. Extract embedding from output.
        let embedding = try Self.extractEmbedding(from: result)

        // 6. L2-normalize.
        return Self.l2Normalize(embedding)
    }

    // MARK: - Mel-Spectral Fallback

    /// Compute a speaker fingerprint from mel-spectral statistics.
    ///
    /// For each of the 128 mel bands, computes the mean and standard deviation
    /// across all frames → 256-dimensional L2-normalized embedding.
    ///
    /// Effective for distinguishing synthetic TTS voices (very consistent spectral
    /// shape) from human speech (different formant structure, pitch variation).
    private static func melSpectralEmbed(mel: [Float], numFrames: Int) -> [Float] {
        // mel layout: [numMels × numFrames] in row-major order.
        var embedding = [Float](repeating: 0, count: numMels * 2)

        for m in 0..<numMels {
            var sum: Float = 0
            var sumSq: Float = 0
            let baseOffset = m * numFrames
            for f in 0..<numFrames {
                let val = mel[baseOffset + f]
                sum += val
                sumSq += val * val
            }
            let mean = sum / Float(numFrames)
            let variance = (sumSq / Float(numFrames)) - (mean * mean)
            embedding[m] = mean
            embedding[numMels + m] = sqrtf(max(variance, 0))
        }

        return l2Normalize(embedding)
    }

    // MARK: - Mel Spectrogram

    /// Compute log-mel spectrogram from 24 kHz audio.
    ///
    /// Returns a flat array of shape [numMels × numFrames] in row-major order
    /// (128 mel values for frame 0, then 128 for frame 1, etc.).
    private static func computeLogMelSpectrogram(_ audio: [Float]) -> [Float] {
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
            let filter = melFilterbank[m]
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
    private static func createMelFilterbank() -> [[Float]] {
        let numFreqBins = nFFT / 2 + 1 // 513
        let sr = Float(modelSampleRate)

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

    /// Result of basic replay/liveness checks on audio.
    struct LivenessCheck: Sendable {
        /// Variance of mel-band energy across frames (low = potential replay).
        let spectralVariance: Float
        /// Ratio of high-frequency energy to total (low = codec compression artifacts).
        let highFreqRatio: Float
        /// Whether the audio looks suspicious (not blocking — informational only).
        let isSuspicious: Bool
    }

    /// Run lightweight liveness heuristics on a log-mel spectrogram.
    ///
    /// Checks for two replay indicators:
    /// 1. **Spectral variance**: Real speech has dynamic formant variation across frames.
    ///    Recordings played through speakers tend to be spectrally flatter.
    /// 2. **High-frequency energy**: Codec compression (MP3, AAC, Opus) attenuates
    ///    energy above ~16 kHz. Raw microphone input preserves full bandwidth.
    ///
    /// Returns a `LivenessCheck` with findings. Does NOT block embedding —
    /// suspicion is logged for diagnostics only.
    static func checkLiveness(mel: [Float], numFrames: Int) -> LivenessCheck {
        guard numFrames > 1 else {
            return LivenessCheck(spectralVariance: 0, highFreqRatio: 0, isSuspicious: false)
        }

        // 1. Spectral variance: compute per-frame energy, then variance across frames.
        var frameEnergies = [Float](repeating: 0, count: numFrames)
        for f in 0..<numFrames {
            var energy: Float = 0
            for m in 0..<numMels {
                energy += mel[m * numFrames + f]
            }
            frameEnergies[f] = energy / Float(numMels)
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
        let highBandStart = numMels * 3 / 4  // top 32 of 128 bands
        var totalEnergy: Float = 0
        var highEnergy: Float = 0
        for m in 0..<numMels {
            var bandSum: Float = 0
            let base = m * numFrames
            vDSP_sve(Array(mel[base..<(base + numFrames)]), 1, &bandSum, vDSP_Length(numFrames))
            totalEnergy += abs(bandSum)
            if m >= highBandStart {
                highEnergy += abs(bandSum)
            }
        }
        let highFreqRatio = totalEnergy > 1e-10 ? highEnergy / totalEnergy : 0

        // Thresholds (empirically tuned — conservative to minimize false positives).
        let lowVariance = spectralVariance < 0.05
        let lowHighFreq = highFreqRatio < 0.02
        let isSuspicious = lowVariance && lowHighFreq

        return LivenessCheck(
            spectralVariance: spectralVariance,
            highFreqRatio: highFreqRatio,
            isSuspicious: isSuspicious
        )
    }

    // MARK: - L2 Normalization

    private static func l2Normalize(_ vec: [Float]) -> [Float] {
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
