import AVFoundation
import Foundation
import MLXAudioTTS

/// Text-to-speech engine using Qwen3-TTS via mlx-audio-swift.
///
/// Replaces: `src/tts/kokoro/{engine.rs, phonemize.rs}`
actor MLXTTSEngine: TTSEngine {
    private var model: (any SpeechGenerationModel)?
    private(set) var isLoaded: Bool = false

    /// Load the TTS model.
    func load(modelID: String = "mlx-community/Qwen3-TTS-0.6B") async throws {
        NSLog("MLXTTSEngine: loading model %@", modelID)
        model = try await TTS.loadModel(modelRepo: modelID)
        isLoaded = true
        NSLog("MLXTTSEngine: model loaded")
    }

    /// Synthesize text to a stream of audio buffers.
    func synthesize(text: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            Task {
                await self.synthesizeInternal(text: text, continuation: continuation)
            }
        }
    }

    /// Internal synthesis — runs within actor isolation so model access is safe.
    private func synthesizeInternal(
        text: String,
        continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation
    ) async {
        guard let model else {
            continuation.finish(throwing: MLEngineError.notLoaded("TTS"))
            return
        }

        do {
            let sampleRate = model.sampleRate
            let stream = model.generateSamplesStream(
                text: text,
                voice: nil,
                refAudio: nil,
                refText: nil,
                language: nil
            )
            for try await samples in stream {
                guard let format = AVAudioFormat(
                    standardFormatWithSampleRate: Double(sampleRate),
                    channels: 1
                ) else { continue }
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(samples.count)
                ) else { continue }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                if let dest = buffer.floatChannelData?[0] {
                    samples.withUnsafeBufferPointer { src in
                        dest.update(from: src.baseAddress!, count: samples.count)
                    }
                }
                continuation.yield(buffer)
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }
}
