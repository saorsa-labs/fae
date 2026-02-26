import Foundation
import MLX
import MLXAudioSTT

/// Speech-to-text engine using Qwen3-ASR via mlx-audio-swift.
///
/// Replaces: `src/stt/mod.rs` (parakeet-rs)
actor MLXSTTEngine: STTEngine {
    private var model: Qwen3ASRModel?
    private(set) var isLoaded: Bool = false
    private(set) var loadState: MLEngineLoadState = .notStarted

    /// Load the STT model.
    func load(modelID: String = "mlx-community/Qwen3-ASR-1.7B-4bit") async throws {
        loadState = .loading
        NSLog("MLXSTTEngine: loading model %@", modelID)
        do {
            model = try await Qwen3ASRModel.fromPretrained(modelID)
            isLoaded = true
            loadState = .loaded
            NSLog("MLXSTTEngine: model loaded")
        } catch {
            loadState = .failed(error.localizedDescription)
            NSLog("MLXSTTEngine: load failed: %@", error.localizedDescription)
            throw error
        }
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
