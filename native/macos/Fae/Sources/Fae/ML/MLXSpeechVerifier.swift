import Accelerate
import Foundation
import MLX
import MLXNN

/// Post-VAD speech verifier that classifies audio segments as speech, music,
/// or noise using a micro 1D-CNN (~99K params).
///
/// Trained on the MUSAN corpus.  Runs on completed VAD segments to reject
/// false-positive speech detections from music or environmental noise.
/// Inference is ~5ms on M-series, designed to run in the segment processing
/// path without adding perceptible latency.
///
/// The architecture matches ``MLXKeywordClassifier`` exactly (same Conv1D
/// backbone, mel pipeline, and model discovery pattern).
actor MLXSpeechVerifier {

    // MARK: - Types

    /// Verification result from the speech verifier.
    struct VerificationResult: Sendable {
        /// Predicted audio type.
        let label: AudioLabel
        /// Confidence score (0-1) for the predicted class.
        let confidence: Float
    }

    /// Audio type classes.
    enum AudioLabel: Int, Sendable, CaseIterable {
        case speech = 0
        case music = 1
        case noise = 2

        var name: String {
            switch self {
            case .speech: return "speech"
            case .music: return "music"
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

        init(numClasses: Int = 3, inputFeatures: Int = 128) {
            self.conv1 = Conv1d(inputChannels: inputFeatures, outputChannels: 64, kernelSize: 3, padding: 1)
            self.conv2 = Conv1d(inputChannels: 64, outputChannels: 128, kernelSize: 3, padding: 1)
            self.conv3 = Conv1d(inputChannels: 128, outputChannels: 128, kernelSize: 3, padding: 1)
            self.classifier = Linear(128, numClasses)
        }

        func callAsFunction(_ x: MLXArray) -> MLXArray {
            var h = relu(conv1(x))
            h = h[0..., .stride(by: 2), 0...]
            h = relu(conv2(h))
            h = h[0..., .stride(by: 2), 0...]
            h = relu(conv3(h))
            h = mean(h, axis: 1)
            return classifier(h)
        }
    }

    // MARK: - State

    private var model: Conv1DClassifier?
    private var config: ClassifierConfig?
    private(set) var isLoaded = false

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

    // MARK: - Load

    func load(modelPath: URL) async throws {
        let configURL = modelPath.appendingPathComponent("config.json")
        let weightsURL = modelPath.appendingPathComponent("model.safetensors")

        guard FileManager.default.fileExists(atPath: configURL.path),
              FileManager.default.fileExists(atPath: weightsURL.path) else {
            throw MLEngineError.loadFailed(
                "SpeechVerifier",
                NSError(
                    domain: "MLXSpeechVerifier",
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

        let weights = try loadArrays(url: weightsURL)
        let loadedWeights = ModuleParameters.unflattened(weights)
        try classifierModel.update(parameters: loadedWeights, verify: .noUnusedKeys)
        eval(classifierModel.parameters())

        self.model = classifierModel
        self.config = classifierConfig
        self.isLoaded = true
        NSLog("MLXSpeechVerifier: loaded from %@ (%d classes)", modelPath.path, classifierConfig.numClasses)
    }

    // MARK: - Verify

    /// Verify whether an audio segment contains speech, music, or noise.
    ///
    /// - Parameters:
    ///   - audio: Raw audio samples (typically 0.25-15s at 16kHz).
    ///   - sampleRate: Sample rate of the input audio.
    /// - Returns: Verification result with label and confidence.
    func verify(audio: [Float], sampleRate: Int) async throws -> VerificationResult {
        guard let model, let config, isLoaded else {
            throw MLEngineError.notLoaded("SpeechVerifier")
        }
        guard !audio.isEmpty else {
            return VerificationResult(label: .noise, confidence: 0.5)
        }

        // Use the first 1 second (or full clip if shorter) for classification.
        let maxSamples = sampleRate
        let clip = audio.count > maxSamples ? Array(audio.prefix(maxSamples)) : audio

        // 1. Compute log-mel spectrogram.
        let (mel, numFrames) = CoreMLSpeakerEncoder.sharedLogMelSpectrogram(
            audio: clip,
            sampleRate: sampleRate
        )

        guard !mel.isEmpty, numFrames >= 4 else {
            return VerificationResult(label: .noise, confidence: 0.5)
        }

        // 2. Time-normalize to target frames.
        let normalized = timeNormalizeMel(
            mel,
            numFrames: numFrames,
            numMels: config.inputFeatures,
            targetFrames: config.targetFrames
        )

        guard !normalized.isEmpty else {
            return VerificationResult(label: .noise, confidence: 0.5)
        }

        // 3. Convert to MLX array: [1, targetFrames, inputFeatures].
        var transposed = [Float](repeating: 0, count: config.targetFrames * config.inputFeatures)
        for m in 0..<config.inputFeatures {
            for f in 0..<config.targetFrames {
                transposed[f * config.inputFeatures + m] = normalized[m * config.targetFrames + f]
            }
        }

        let inputArray = MLXArray(transposed, [1, config.targetFrames, config.inputFeatures])

        // 4. Run inference.
        let logits = model(inputArray)
        let probabilities = softmax(logits, axis: -1)
        let predIndex = argMax(logits, axis: -1)
        eval(probabilities, predIndex)

        let predLabel = predIndex[0].item(Int.self)
        let confidence = probabilities[0, predLabel].item(Float.self)

        guard let label = AudioLabel(rawValue: predLabel) else {
            return VerificationResult(label: .noise, confidence: confidence)
        }

        return VerificationResult(label: label, confidence: confidence)
    }

    // MARK: - Mel Processing

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

    /// Resolves model path: bundled Resources/Models first, then App Support.
    static let defaultModelPath: URL = {
        // Check bundled resources first (397KB model shipped with the app).
        if let bundled = Bundle.main.url(forResource: "speech-verifier", withExtension: nil, subdirectory: "Models") {
            let weights = bundled.appendingPathComponent("model.safetensors")
            if FileManager.default.fileExists(atPath: weights.path) {
                return bundled
            }
        }
        // Fallback: user-trained model in App Support.
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport.appendingPathComponent("fae/models/speech-verifier")
    }()

    static var modelExists: Bool {
        let weightsPath = defaultModelPath.appendingPathComponent("model.safetensors").path
        let configPath = defaultModelPath.appendingPathComponent("config.json").path
        return FileManager.default.fileExists(atPath: weightsPath)
            && FileManager.default.fileExists(atPath: configPath)
    }
}
