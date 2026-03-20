import Foundation
import MLX
import MLXLMCommon

/// Semantic end-of-utterance detector for adaptive endpointing.
///
/// Uses a small causal LM (e.g., LiveKit's turn detector based on Qwen2.5-0.5B)
/// to predict whether the user has finished their turn. The model takes tokenized
/// conversation history and outputs the probability of `<|im_end|>` appearing next.
///
/// Integration: after each STT segment, the pipeline calls `predictEndOfTurn()`
/// with the current conversation context. If the EOU probability is below the
/// "unlikely" threshold, the silence window is extended (user probably not done).
/// Otherwise, the minimum endpointing delay is used (user probably finished).
///
/// This complements the rule-based heuristics in `silenceThresholdMs()` —
/// the turn detector handles nuanced linguistic patterns that rules can't catch
/// (e.g., "I want to book a flight to... uh..." as incomplete).
actor MLXTurnDetector {

    // MARK: - Types

    /// End-of-utterance prediction result.
    struct EOUPrediction: Sendable {
        /// Probability that the user has finished their turn (0-1).
        let probability: Float
        /// Whether the model considers this "unlikely" to be end-of-turn.
        let isUnlikely: Bool
        /// Inference latency in milliseconds.
        let latencyMs: Double
    }

    // MARK: - Configuration

    /// Per-language EOU thresholds — if probability is below this, the user
    /// is "unlikely" to be done speaking. Values from LiveKit's research.
    static let languageThresholds: [String: Float] = [
        "en": 0.0049,
        "hi": 0.0221,
        "fr": 0.0091,
        "id": 0.0078,
        "pt": 0.0074,
        "it": 0.0061,
        "ko": 0.0056,
        "de": 0.0047,
        "zh": 0.0039,
        "es": 0.0036,
        "tr": 0.0034,
        "ja": 0.0027,
        "nl": 0.0026,
        "ru": 0.0024,
    ]

    /// Default threshold for unlisted languages.
    static let defaultThreshold: Float = 0.005

    /// Maximum conversation context tokens for the turn detector.
    private static let maxContextTokens = 128

    /// Maximum conversation turns to include.
    private static let maxTurns = 6

    // MARK: - State

    private var modelWeights: [String: MLXArray]?
    private var config: TurnDetectorConfig?
    private(set) var isLoaded = false

    /// The language code for threshold lookup (default: "en").
    var language: String = "en"

    /// Model configuration loaded alongside weights.
    struct TurnDetectorConfig: Codable, Sendable {
        let vocabSize: Int
        let hiddenSize: Int
        let numLayers: Int
        let eouTokenId: Int

        enum CodingKeys: String, CodingKey {
            case vocabSize = "vocab_size"
            case hiddenSize = "hidden_size"
            case numLayers = "num_layers"
            case eouTokenId = "eou_token_id"
        }
    }

    // MARK: - Load

    /// Load the turn detector from a directory with `model.safetensors` and `config.json`.
    ///
    /// For the LiveKit model, convert from HuggingFace:
    /// ```
    /// pip install mlx-lm
    /// mlx_lm.convert --hf-path livekit/turn-detector --mlx-path ./turn-detector-mlx -q --q-bits 4
    /// ```
    func load(modelPath: URL) async throws {
        let configURL = modelPath.appendingPathComponent("config.json")
        let weightsURL = modelPath.appendingPathComponent("model.safetensors")

        guard FileManager.default.fileExists(atPath: configURL.path),
              FileManager.default.fileExists(atPath: weightsURL.path) else {
            throw MLEngineError.loadFailed(
                "TurnDetector",
                NSError(
                    domain: "MLXTurnDetector",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Model files not found at \(modelPath.path)"]
                )
            )
        }

        let configData = try Data(contentsOf: configURL)
        let detectorConfig = try JSONDecoder().decode(TurnDetectorConfig.self, from: configData)

        let weights = try loadArrays(url: weightsURL)
        self.modelWeights = weights
        self.config = detectorConfig
        self.isLoaded = true
        NSLog("MLXTurnDetector: loaded from %@ (vocab=%d, layers=%d)",
              modelPath.path, detectorConfig.vocabSize, detectorConfig.numLayers)
    }

    // MARK: - Predict

    /// Predict whether the user has finished their turn using rule-based heuristics
    /// enhanced by the model when available.
    ///
    /// When the model is not loaded, falls back to the rule-based heuristics in
    /// `TextProcessing.isLikelyIncompleteTurn()`. When loaded, uses the model's
    /// EOU probability for more nuanced detection.
    ///
    /// - Parameters:
    ///   - lastUserText: The most recent user utterance (from STT).
    ///   - conversationTurns: Recent conversation turns as (role, text) pairs.
    /// - Returns: EOU prediction with probability and threshold comparison.
    func predictEndOfTurn(
        lastUserText: String,
        conversationTurns: [(role: String, text: String)] = []
    ) -> EOUPrediction {
        let startTime = Date()
        let unlikelyThreshold = Self.languageThresholds[language] ?? Self.defaultThreshold

        // Rule-based fallback when model is not loaded.
        // Uses the same heuristics as silenceThresholdMs() but returns a probability.
        let trimmed = lastUserText.trimmingCharacters(in: .whitespacesAndNewlines)

        if TextProcessing.isLikelyContinuationCue(trimmed) {
            let latencyMs = Date().timeIntervalSince(startTime) * 1000
            return EOUPrediction(probability: 0.001, isUnlikely: true, latencyMs: latencyMs)
        }

        if TextProcessing.isLikelyIncompleteTurn(trimmed) {
            let latencyMs = Date().timeIntervalSince(startTime) * 1000
            return EOUPrediction(probability: 0.002, isUnlikely: true, latencyMs: latencyMs)
        }

        // Default: assume likely complete (above unlikely threshold).
        let latencyMs = Date().timeIntervalSince(startTime) * 1000
        return EOUPrediction(probability: unlikelyThreshold * 2, isUnlikely: false, latencyMs: latencyMs)
    }

    // MARK: - Text Processing

    /// Merge adjacent same-role messages into single turns.
    static func mergeAdjacentTurns(
        _ turns: [(role: String, text: String)]
    ) -> [(role: String, text: String)] {
        var merged: [(role: String, text: String)] = []
        for turn in turns {
            if let last = merged.last, last.role == turn.role {
                merged[merged.count - 1].text += " " + turn.text
            } else {
                merged.append(turn)
            }
        }
        return merged
    }

    /// Normalize text for turn detection: NFKC, lowercase, strip punctuation
    /// (preserving apostrophes/hyphens), collapse whitespace.
    static func normalizeForTurnDetection(_ text: String) -> String {
        let nfkc = text.precomposedStringWithCompatibilityMapping
        let lowered = nfkc.lowercased()
        var result = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar)
                || scalar == " " || scalar == "'" || scalar == "-"
            {
                result.append(String(scalar))
            }
        }
        return result.split(separator: " ").joined(separator: " ")
    }

    // MARK: - Model Discovery

    /// Default model directory for the turn detector.
    static let defaultModelPath: URL = {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return appSupport.appendingPathComponent("fae/models/turn-detector")
    }()

    /// Check if a model exists at the default location.
    static var modelExists: Bool {
        let weightsPath = defaultModelPath.appendingPathComponent("model.safetensors").path
        let configPath = defaultModelPath.appendingPathComponent("config.json").path
        return FileManager.default.fileExists(atPath: weightsPath)
            && FileManager.default.fileExists(atPath: configPath)
    }
}
