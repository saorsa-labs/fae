import Accelerate
import Foundation
import MLX
import MLXNN

/// Micro keyword classifier for barge-in interrupt detection.
///
/// Classifies short audio segments (~0.5-1s) into five classes:
/// - `interrupt`: "stop", "no", "go", etc.
/// - `wake`: "fae", "hey fae"
/// - `speech`: other speech (not a keyword)
/// - `silence`: no speech detected
/// - `noise`: background noise
///
/// Uses a 1D-CNN on time-normalized log-mel spectrograms (~200K params).
/// Inference is ~5ms on M-series, designed to run in the barge-in pipeline
/// without adding perceptible latency.
///
/// The mel pipeline reuses `CoreMLSpeakerEncoder.sharedLogMelSpectrogram()`
/// to ensure spectral consistency with the speaker encoder.
actor MLXKeywordClassifier {

    // MARK: - Types

    /// Classification result from the keyword classifier.
    struct KeywordClassification: Sendable {
        /// Predicted label class.
        let label: KeywordLabel
        /// Confidence score (0-1) for the predicted class.
        let confidence: Float
        /// Human-readable keyword string, if applicable (nil for speech/silence/noise).
        let keyword: String?
    }

    /// Label classes for the keyword classifier.
    enum KeywordLabel: Int, Sendable, CaseIterable {
        case interrupt = 0
        case wake = 1
        case speech = 2
        case silence = 3
        case noise = 4

        var name: String {
            switch self {
            case .interrupt: return "interrupt"
            case .wake: return "wake"
            case .speech: return "speech"
            case .silence: return "silence"
            case .noise: return "noise"
            }
        }
    }

    // MARK: - Model

    /// 1D-CNN model matching the Python training architecture.
    private final class Conv1DClassifier: Module, @unchecked Sendable {
        let conv1: Conv1d
        let conv2: Conv1d
        let conv3: Conv1d
        let classifier: Linear

        init(numClasses: Int = 5, inputFeatures: Int = 128) {
            self.conv1 = Conv1d(inputChannels: inputFeatures, outputChannels: 64, kernelSize: 3, padding: 1)
            self.conv2 = Conv1d(inputChannels: 64, outputChannels: 128, kernelSize: 3, padding: 1)
            self.conv3 = Conv1d(inputChannels: 128, outputChannels: 128, kernelSize: 3, padding: 1)
            self.classifier = Linear(128, numClasses)
        }

        func callAsFunction(_ x: MLXArray) -> MLXArray {
            var h = relu(conv1(x))                          // [B, 48, 64]
            h = h[0..., .stride(by: 2), 0...]               // MaxPool → [B, 24, 64]
            h = relu(conv2(h))                              // [B, 24, 128]
            h = h[0..., .stride(by: 2), 0...]               // MaxPool → [B, 12, 128]
            h = relu(conv3(h))                              // [B, 12, 128]
            h = mean(h, axis: 1)                            // GlobalAvgPool → [B, 128]
            return classifier(h)                            // [B, 5]
        }
    }

    // MARK: - State

    private var model: Conv1DClassifier?
    private var config: ClassifierConfig?
    private(set) var isLoaded = false

    /// Configuration loaded from `config.json` alongside the model weights.
    struct ClassifierConfig: Codable, Sendable {
        let numClasses: Int
        let inputFeatures: Int
        let targetFrames: Int
        let sampleRate: Int
        let nMels: Int
        let labelNames: [String]

        enum CodingKeys: String, CodingKey {
            case numClasses = "num_classes"
            case inputFeatures = "input_features"
            case targetFrames = "target_frames"
            case sampleRate = "sample_rate"
            case nMels = "n_mels"
            case labelNames = "label_names"
        }
    }

    // MARK: - Load

    /// Load the keyword classifier model from a directory containing
    /// `model.safetensors` and `config.json`.
    func load(modelPath: URL) async throws {
        let configURL = modelPath.appendingPathComponent("config.json")
        let weightsURL = modelPath.appendingPathComponent("model.safetensors")

        guard FileManager.default.fileExists(atPath: configURL.path),
              FileManager.default.fileExists(atPath: weightsURL.path) else {
            throw MLEngineError.loadFailed(
                "KeywordClassifier",
                NSError(
                    domain: "MLXKeywordClassifier",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Model files not found at \(modelPath.path)"]
                )
            )
        }

        let configData = try Data(contentsOf: configURL)
        let classifierConfig = try JSONDecoder().decode(ClassifierConfig.self, from: configData)

        let classifierModel = Conv1DClassifier(
            numClasses: classifierConfig.numClasses,
            inputFeatures: classifierConfig.inputFeatures
        )

        // Load safetensors weights.
        let weights = try loadArrays(url: weightsURL)
        let loadedWeights = ModuleParameters.unflattened(weights)
        try classifierModel.update(parameters: loadedWeights, verify: .noUnusedKeys)
        eval(classifierModel.parameters())

        self.model = classifierModel
        self.config = classifierConfig
        self.isLoaded = true
        NSLog("MLXKeywordClassifier: loaded from %@ (%d classes)", modelPath.path, classifierConfig.numClasses)
    }

    // MARK: - Classify

    /// Classify a short audio segment into a keyword category.
    ///
    /// - Parameters:
    ///   - audio: Raw audio samples (typically 0.5-1s at 16kHz).
    ///   - sampleRate: Sample rate of the input audio.
    /// - Returns: Classification result with label, confidence, and optional keyword string.
    func classify(audio: [Float], sampleRate: Int) async throws -> KeywordClassification {
        guard let model, let config, isLoaded else {
            throw MLEngineError.notLoaded("KeywordClassifier")
        }

        guard !audio.isEmpty else {
            throw MLEngineError.notLoaded("KeywordClassifier: empty audio")
        }

        // 1. Compute log-mel spectrogram using the shared speaker encoder pipeline.
        let (mel, numFrames) = CoreMLSpeakerEncoder.sharedLogMelSpectrogram(
            audio: audio,
            sampleRate: sampleRate
        )

        guard !mel.isEmpty, numFrames >= 4 else {
            // Audio too short for meaningful classification.
            return KeywordClassification(label: .silence, confidence: 0.5, keyword: nil)
        }

        // 2. Time-normalize to target frames (48).
        let normalized = timeNormalizeMel(
            mel,
            numFrames: numFrames,
            numMels: config.nMels,
            targetFrames: config.targetFrames
        )

        guard !normalized.isEmpty else {
            return KeywordClassification(label: .silence, confidence: 0.5, keyword: nil)
        }

        // 3. Convert to MLX array: [1, targetFrames, nMels].
        // The mel is in [numMels × numFrames] row-major order.
        // We need [targetFrames, numMels] for the model input.
        var transposed = [Float](repeating: 0, count: config.targetFrames * config.nMels)
        for m in 0..<config.nMels {
            for f in 0..<config.targetFrames {
                transposed[f * config.nMels + m] = normalized[m * config.targetFrames + f]
            }
        }

        let inputArray = MLXArray(transposed, [1, config.targetFrames, config.nMels])

        // 4. Run inference.
        let logits = model(inputArray)
        let probabilities = softmax(logits, axis: -1)
        let predIndex = argMax(logits, axis: -1)
        eval(probabilities, predIndex)

        let predLabel = predIndex[0].item(Int.self)
        let confidence = probabilities[0, predLabel].item(Float.self)

        guard let label = KeywordLabel(rawValue: predLabel) else {
            return KeywordClassification(label: .noise, confidence: confidence, keyword: nil)
        }

        // Map label to keyword string.
        let keyword: String? = switch label {
        case .interrupt: "stop"  // Generic interrupt indicator.
        case .wake: "fae"
        case .speech, .silence, .noise: nil
        }

        return KeywordClassification(label: label, confidence: confidence, keyword: keyword)
    }

    // MARK: - Mel Processing (matching WakeWordAcousticDetector)

    /// Time-normalize mel spectrogram to fixed frame count.
    /// Matches `WakeWordAcousticDetector.timeNormalizeMel()` exactly.
    private func timeNormalizeMel(
        _ mel: [Float],
        numFrames: Int,
        numMels: Int,
        targetFrames: Int
    ) -> [Float] {
        guard numFrames > 0, numMels > 0, targetFrames > 1 else { return [] }
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

    // MARK: - Model Discovery

    /// Default model directory path.
    static let defaultModelPath: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport.appendingPathComponent("fae/models/keyword-classifier")
    }()

    /// Check if a trained model exists at the default location.
    static var modelExists: Bool {
        let weightsPath = defaultModelPath.appendingPathComponent("model.safetensors").path
        let configPath = defaultModelPath.appendingPathComponent("config.json").path
        return FileManager.default.fileExists(atPath: weightsPath)
            && FileManager.default.fileExists(atPath: configPath)
    }
}
