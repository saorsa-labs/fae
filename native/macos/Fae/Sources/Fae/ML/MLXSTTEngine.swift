import Foundation
import MLX
import MLXAudioSTT

/// Speech-to-text engine using Qwen3-ASR via mlx-audio-swift.
///
/// Replaces: `src/stt/mod.rs` (parakeet-rs)
actor MLXSTTEngine: STTEngine {
    private var model: Qwen3ASRModel?
    private(set) var isLoaded: Bool = false

    /// Load the STT model.
    func load(modelID: String = "mlx-community/Qwen3-ASR-0.6B-4bit") async throws {
        NSLog("MLXSTTEngine: loading model %@", modelID)
        model = try await Qwen3ASRModel.fromPretrained(modelID)
        isLoaded = true
        NSLog("MLXSTTEngine: model loaded")
    }

    /// Transcribe a speech segment to text.
    func transcribe(samples: [Float], sampleRate: Int) async throws -> STTResult {
        guard let model else {
            throw MLEngineError.notLoaded("STT")
        }

        let audio = MLXArray(samples)
        let output = model.generate(audio: audio)

        return STTResult(
            text: output.text,
            language: output.language,
            confidence: nil
        )
    }
}
