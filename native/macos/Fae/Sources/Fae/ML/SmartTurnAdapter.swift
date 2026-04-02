import Foundation
import MLX
import MLXAudioVAD

/// Adapter around `MLXAudioVAD.SmartTurnModel` for semantic end-of-utterance detection.
///
/// SmartTurn is a Whisper-encoder-based binary classifier that predicts whether
/// the user has finished their conversational turn, using audio features rather
/// than text. It replaces the rule-based heuristics in ``MLXTurnDetector`` with
/// a learned model that handles nuanced linguistic patterns.
///
/// Usage: load once via ``load(repoID:)``, then call ``predictEndpoint(samples:sampleRate:)``
/// after each VAD speech segment to decide whether to extend or shorten the
/// silence timeout before committing the utterance to STT.
actor SmartTurnAdapter {

    // MARK: - Types

    /// Endpoint prediction result.
    struct EndpointPrediction: Sendable {
        /// Probability that the user has finished their turn (0–1).
        let probability: Float
        /// Whether the model predicts end-of-turn (probability > threshold).
        let isEndOfTurn: Bool
        /// Inference latency in milliseconds.
        let latencyMs: Double
    }

    // MARK: - State

    private var model: SmartTurnModel?
    private(set) var isLoaded = false

    /// Default HuggingFace repo for the SmartTurn model.
    static let defaultRepoID = "Blaizzy/SmartTurn"

    // MARK: - Load

    /// Load the SmartTurn model from HuggingFace.
    ///
    /// Downloads and caches the model on first call. Subsequent calls are fast
    /// (cache hit). Thread-safe via actor isolation.
    ///
    /// - Parameter repoID: HuggingFace repository ID (default: ``defaultRepoID``).
    func load(repoID: String = SmartTurnAdapter.defaultRepoID) async throws {
        NSLog("SmartTurnAdapter: loading model from %@", repoID)
        let loaded = try await SmartTurnModel.fromPretrained(repoID)
        self.model = loaded
        self.isLoaded = true
        NSLog("SmartTurnAdapter: model loaded (threshold=%.2f)", loaded.config.processorConfig.threshold)
    }

    // MARK: - Predict

    /// Predict whether the user has finished their conversational turn.
    ///
    /// Converts raw audio samples to mel features and runs the SmartTurn classifier.
    /// The model expects 16 kHz mono audio (up to 8 seconds; longer audio is truncated
    /// to the last 8 seconds).
    ///
    /// - Parameters:
    ///   - samples: Float32 audio samples at the given sample rate.
    ///   - sampleRate: Sample rate of the audio (default: 16000).
    ///   - threshold: Override the model's default threshold (optional).
    /// - Returns: Endpoint prediction with probability and decision.
    func predictEndpoint(
        samples: [Float],
        sampleRate: Int = 16_000,
        threshold: Float? = nil
    ) -> EndpointPrediction? {
        guard let model else {
            NSLog("SmartTurnAdapter: predict called before model loaded")
            return nil
        }

        let startTime = Date()
        do {
            let audioArray = MLXArray(samples)
            let output = try model.predictEndpoint(audioArray, sampleRate: sampleRate, threshold: threshold)
            let latencyMs = Date().timeIntervalSince(startTime) * 1000
            return EndpointPrediction(
                probability: output.probability,
                isEndOfTurn: output.prediction == 1,
                latencyMs: latencyMs
            )
        } catch {
            NSLog("SmartTurnAdapter: prediction failed: %@", error.localizedDescription)
            return nil
        }
    }
}
