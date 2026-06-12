import Accelerate
import CoreML
import Foundation

/// Core ML audio classifier that runs 1D-CNN models on the Apple Neural Engine.
///
/// Replaces MLX-based classifiers (MLXSpeechVerifier; formerly also the keyword classifier) for
/// production use. Running on ANE frees the GPU for LLM/STT/TTS inference and
/// eliminates per-frame GPU context switching.
///
/// Both keyword classification and speech verification share the same Conv1D
/// backbone architecture — this class handles both via configuration.
actor CoreMLAudioClassifier {

    // MARK: - Types

    /// Classification result.
    struct ClassificationResult: Sendable {
        let labelIndex: Int
        let labelName: String
        let confidence: Float
    }

    /// Configuration loaded from the model's config JSON.
    struct ClassifierConfig: Codable, Sendable {
        let numClasses: Int
        let inputFeatures: Int
        let targetFrames: Int
        let sampleRate: Int
        let labelNames: [String]

        enum CodingKeys: String, CodingKey {
            case numClasses = "num_classes"
            case inputFeatures = "input_features"
            case targetFrames = "target_frames"
            case sampleRate = "sample_rate"
            case labelNames = "label_names"
        }
    }

    // MARK: - State

    private var model: MLModel?
    private var config: ClassifierConfig?
    private(set) var isLoaded = false

    /// Human-readable name for logging.
    private let name: String

    init(name: String) {
        self.name = name
    }

    // MARK: - Load

    /// Load a compiled Core ML model (.mlmodelc) and its config JSON.
    ///
    /// The model is configured for `.all` compute units, allowing Core ML to
    /// schedule inference on the Neural Engine when available.
    func load(modelURL: URL, configURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw MLEngineError.loadFailed(
                name,
                NSError(domain: "CoreMLAudioClassifier", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Model not found at \(modelURL.path)"])
            )
        }

        let configData = try Data(contentsOf: configURL)
        let classifierConfig = try JSONDecoder().decode(ClassifierConfig.self, from: configData)

        let mlConfig = MLModelConfiguration()
        mlConfig.computeUnits = .all  // Prefer ANE, fallback to GPU/CPU
        let loadedModel = try MLModel(contentsOf: modelURL, configuration: mlConfig)

        self.model = loadedModel
        self.config = classifierConfig
        self.isLoaded = true
        NSLog("CoreMLAudioClassifier[%@]: loaded on ANE (%d classes, input [1,%d,%d])",
              name, classifierConfig.numClasses, classifierConfig.targetFrames, classifierConfig.inputFeatures)
    }

    // MARK: - Classify

    /// Classify an audio segment.
    ///
    /// Preprocesses audio to a log-mel spectrogram, normalizes to the target
    /// frame count, and runs inference on the Neural Engine.
    ///
    /// - Parameters:
    ///   - audio: Raw audio samples.
    ///   - sampleRate: Sample rate of the input audio.
    /// - Returns: Classification result with label and confidence.
    func classify(audio: [Float], sampleRate: Int) async throws -> ClassificationResult {
        guard let model, let config, isLoaded else {
            throw MLEngineError.notLoaded(name)
        }
        guard !audio.isEmpty else {
            return ClassificationResult(labelIndex: config.numClasses - 1, labelName: config.labelNames.last ?? "unknown", confidence: 0.5)
        }

        // Use first 1 second max for classification.
        let maxSamples = sampleRate
        let clip = audio.count > maxSamples ? Array(audio.prefix(maxSamples)) : audio

        // 1. Compute log-mel spectrogram (shared with speaker encoder).
        let (mel, numFrames) = CoreMLSpeakerEncoder.sharedLogMelSpectrogram(
            audio: clip,
            sampleRate: sampleRate
        )

        guard !mel.isEmpty, numFrames >= 4 else {
            return ClassificationResult(labelIndex: config.numClasses - 1, labelName: config.labelNames.last ?? "unknown", confidence: 0.5)
        }

        // 2. Time-normalize to target frames.
        let normalized = timeNormalizeMel(
            mel,
            numFrames: numFrames,
            numMels: config.inputFeatures,
            targetFrames: config.targetFrames
        )

        guard !normalized.isEmpty else {
            return ClassificationResult(labelIndex: config.numClasses - 1, labelName: config.labelNames.last ?? "unknown", confidence: 0.5)
        }

        // 3. Transpose [numMels, targetFrames] → [targetFrames, numMels] and create MLMultiArray.
        let inputArray = try MLMultiArray(shape: [1, config.targetFrames as NSNumber, config.inputFeatures as NSNumber], dataType: .float32)
        for f in 0..<config.targetFrames {
            for m in 0..<config.inputFeatures {
                let value = normalized[m * config.targetFrames + f]
                inputArray[[0, f, m] as [NSNumber]] = NSNumber(value: value)
            }
        }

        // 4. Run inference (Core ML schedules on ANE automatically).
        let provider = try MLDictionaryFeatureProvider(dictionary: ["mel_input": MLFeatureValue(multiArray: inputArray)])
        let prediction = try await Task { try model.prediction(from: provider) }.value

        // 5. Extract logits and compute softmax.
        guard let logitsFeature = prediction.featureValue(for: "logits"),
              let logitsArray = logitsFeature.multiArrayValue
        else {
            throw MLEngineError.notLoaded("\(name): missing logits output")
        }

        let numClasses = config.numClasses
        var logits = [Float](repeating: 0, count: numClasses)
        for i in 0..<numClasses {
            logits[i] = Float(truncating: logitsArray[[0, i] as [NSNumber]])
        }

        // Softmax
        let maxLogit = logits.max() ?? 0
        var expLogits = logits.map { exp($0 - maxLogit) }
        let sumExp = expLogits.reduce(0, +)
        for i in 0..<numClasses { expLogits[i] /= sumExp }

        // Argmax
        var bestIndex = 0
        var bestConf: Float = 0
        for i in 0..<numClasses {
            if expLogits[i] > bestConf {
                bestConf = expLogits[i]
                bestIndex = i
            }
        }

        let labelName = bestIndex < config.labelNames.count ? config.labelNames[bestIndex] : "class_\(bestIndex)"
        return ClassificationResult(labelIndex: bestIndex, labelName: labelName, confidence: bestConf)
    }

    // MARK: - Mel Processing

    /// Time-normalize a mel spectrogram to a fixed number of frames via linear interpolation.
    private func timeNormalizeMel(
        _ mel: [Float],
        numFrames: Int,
        numMels: Int,
        targetFrames: Int
    ) -> [Float] {
        guard numFrames > 0, numMels > 0 else { return [] }
        if numFrames == targetFrames { return mel }

        var output = [Float](repeating: 0, count: numMels * targetFrames)
        let scale = Float(numFrames - 1) / Float(max(targetFrames - 1, 1))

        for m in 0..<numMels {
            let srcRow = m * numFrames
            let dstRow = m * targetFrames
            for t in 0..<targetFrames {
                let srcPos = Float(t) * scale
                let lo = Int(srcPos)
                let hi = min(lo + 1, numFrames - 1)
                let frac = srcPos - Float(lo)
                output[dstRow + t] = mel[srcRow + lo] * (1 - frac) + mel[srcRow + hi] * frac
            }
        }

        return output
    }
}
