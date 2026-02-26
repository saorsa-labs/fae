import AVFoundation
import Foundation

/// Speech-to-text engine protocol.
///
/// Implementations: `MLXSTTEngine` (Phase 1, Qwen3-ASR via mlx-audio-swift).
protocol STTEngine: Actor {
    func load(modelID: String) async throws
    func transcribe(samples: [Float], sampleRate: Int) async throws -> STTResult
    var isLoaded: Bool { get }
}

/// Large language model engine protocol.
///
/// Implementations: `MLXLLMEngine` (Phase 1, Qwen3 via mlx-swift-lm).
protocol LLMEngine: Actor {
    func load(modelID: String) async throws
    func generate(
        messages: [LLMMessage],
        systemPrompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<String, Error>
    var isLoaded: Bool { get }
}

/// Text-to-speech engine protocol.
///
/// Implementations: `MLXTTSEngine` (Phase 1, Qwen3-TTS via mlx-audio-swift).
protocol TTSEngine: Actor {
    func load(modelID: String) async throws
    func synthesize(text: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error>
    var isLoaded: Bool { get }
}

/// Text embedding engine protocol for semantic memory search.
///
/// Implementations: `MLXEmbeddingEngine` (Phase 2).
protocol EmbeddingEngine: Actor {
    func load(modelID: String) async throws
    func embed(text: String) async throws -> [Float]
    var isLoaded: Bool { get }
}
