import AVFoundation
import CoreGraphics
import FaeInference
import Foundation

// MARK: - Engine Protocols

/// Speech-to-text engine protocol.
///
/// Implementations: `MLXSTTEngine` (Phase 1, Qwen3-ASR via mlx-audio-swift).
protocol STTEngine: Actor {
    func load(modelID: String) async throws
    func transcribe(samples: [Float], sampleRate: Int) async throws -> STTResult
    var isLoaded: Bool { get }
    var loadState: MLEngineLoadState { get }
}

/// Text-to-speech engine protocol.
///
/// Active implementation: `KokoroMLXTTSEngine` (Kokoro-82M via KokoroSwift/MLX).
/// Legacy: `MLXTTSEngine` (Qwen3-TTS via mlx-audio-swift) — retained but not active.
protocol TTSEngine: Actor {
    func load(modelID: String) async throws
    func loadVoice(referenceAudioURL: URL, referenceText: String?) async throws
    func loadCustomVoice(url: URL, referenceText: String?) async throws
    func synthesize(text: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error>
    var isLoaded: Bool { get }
    var isVoiceLoaded: Bool { get }
    var loadState: MLEngineLoadState { get }
}

extension TTSEngine {
    /// Default no-op for engines that don't support voice cloning.
    func loadVoice(referenceAudioURL: URL, referenceText: String?) async throws {}
    func loadCustomVoice(url: URL, referenceText: String?) async throws {}
    var isVoiceLoaded: Bool { false }

    /// Default implementation delegates to `synthesize(text:)` ignoring voiceInstruct.
    func synthesize(text: String, voiceInstruct: String?) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        synthesize(text: text)
    }
}

/// Text embedding engine protocol for semantic memory search.
///
/// Implementations: `MLXEmbeddingEngine` (Phase 2).
protocol EmbeddingEngine: Actor {
    func load(modelID: String) async throws
    func embed(text: String) async throws -> [Float]
    var isLoaded: Bool { get }
    var loadState: MLEngineLoadState { get }
}

/// Vision-language model engine protocol.
///
/// Implementations: `MLXVLMEngine` (Qwen3-VL via mlx-swift-lm MLXVLM module).
protocol VLMEngine: Actor {
    func load(modelID: String) async throws
    func describe(image: CGImage, prompt: String, options: GenerationOptions) -> AsyncThrowingStream<String, Error>
    func warmup() async
    var isLoaded: Bool { get }
    var loadState: MLEngineLoadState { get }
}

extension VLMEngine {
    func warmup() async {}
}

/// Speaker embedding engine protocol for voice identity / speaker verification.
///
/// Produces a fixed-dimension embedding vector from raw audio that can be compared
/// via cosine similarity to identify or verify speakers.
///
/// Implementations: `CoreMLSpeakerEncoder` (ECAPA-TDNN via Core ML).
protocol SpeakerEmbeddingEngine: Actor {
    func load() async throws
    func embed(audio: [Float], sampleRate: Int) async throws -> [Float]
    var isLoaded: Bool { get }
    var loadState: MLEngineLoadState { get }
}
