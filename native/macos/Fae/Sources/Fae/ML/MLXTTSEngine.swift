import AVFoundation
import Foundation
import MLX
import MLXAudioTTS

/// Text-to-speech engine using Qwen3-TTS via mlx-audio-swift.
///
/// Supports voice cloning via a reference audio file (e.g. `fae.wav`).
/// When a CustomVoice model is loaded, call `loadVoice()` with a reference
/// audio URL to enable Fae's unique voice identity.
///
/// Replaces: `src/tts/kokoro/{engine.rs, phonemize.rs}`
actor MLXTTSEngine: TTSEngine {
    private var model: (any SpeechGenerationModel)?
    private var refAudio: MLXArray?
    private var refText: String?
    private(set) var isLoaded: Bool = false
    private(set) var isVoiceLoaded: Bool = false
    private(set) var loadState: MLEngineLoadState = .notStarted

    /// Load the TTS model.
    func load(modelID: String = "mlx-community/Qwen3-TTS-1.7B-CustomVoice") async throws {
        loadState = .loading
        NSLog("MLXTTSEngine: loading model %@", modelID)
        do {
            model = try await TTS.loadModel(modelRepo: modelID)
            isLoaded = true
            loadState = .loaded
            NSLog("MLXTTSEngine: model loaded")
        } catch {
            loadState = .failed(error.localizedDescription)
            NSLog("MLXTTSEngine: load failed: %@", error.localizedDescription)
            throw error
        }
    }

    /// Load a reference voice from a `.wav` file for voice cloning.
    ///
    /// The CustomVoice model uses ~3 seconds of reference audio to clone a voice.
    /// The reference audio must be 24kHz mono PCM 16-bit WAV.
    func loadVoice(referenceAudioURL: URL, referenceText: String? = nil) async throws {
        let audioData = try Data(contentsOf: referenceAudioURL)
        let samples = Self.parseWAVToFloat32(audioData)
        // Take first 3 seconds at 24kHz = 72000 samples.
        let clipSamples = Array(samples.prefix(72_000))
        refAudio = MLXArray(clipSamples)
        refText = referenceText
        isVoiceLoaded = true
        NSLog("MLXTTSEngine: voice loaded (%d samples)", clipSamples.count)
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
                refAudio: refAudio,
                refText: refText,
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

    // MARK: - WAV Parsing

    /// Parse a WAV file's raw bytes into Float32 samples normalized to [-1, 1].
    ///
    /// Expects PCM 16-bit mono WAV format. Returns an empty array if the format
    /// is not recognized.
    static func parseWAVToFloat32(_ data: Data) -> [Float] {
        // Minimum WAV header: 44 bytes.
        guard data.count >= 44 else { return [] }

        // Verify RIFF header.
        let riff = String(data: data[0..<4], encoding: .ascii)
        let wave = String(data: data[8..<12], encoding: .ascii)
        guard riff == "RIFF", wave == "WAVE" else { return [] }

        // Parse chunks: validate fmt before reading data.
        var fmtValidated = false
        var offset = 12
        while offset + 8 < data.count {
            let chunkID = String(data: data[offset..<(offset + 4)], encoding: .ascii)
            let chunkSize = data.withUnsafeBytes { ptr in
                ptr.load(fromByteOffset: offset + 4, as: UInt32.self)
            }

            if chunkID == "fmt " {
                // Validate format: must be PCM (1), mono (1 channel), 16-bit.
                guard Int(chunkSize) >= 16, offset + 8 + 16 <= data.count else {
                    NSLog("MLXTTSEngine: WAV fmt chunk too small (%d bytes)", chunkSize)
                    return []
                }
                let audioFormat = data.withUnsafeBytes { ptr in
                    ptr.load(fromByteOffset: offset + 8, as: UInt16.self)
                }
                let numChannels = data.withUnsafeBytes { ptr in
                    ptr.load(fromByteOffset: offset + 10, as: UInt16.self)
                }
                let bitsPerSample = data.withUnsafeBytes { ptr in
                    ptr.load(fromByteOffset: offset + 22, as: UInt16.self)
                }
                guard audioFormat == 1 else {
                    NSLog("MLXTTSEngine: WAV not PCM (format=%d)", audioFormat)
                    return []
                }
                guard numChannels == 1 else {
                    NSLog("MLXTTSEngine: WAV not mono (channels=%d)", numChannels)
                    return []
                }
                guard bitsPerSample == 16 else {
                    NSLog("MLXTTSEngine: WAV not 16-bit (bits=%d)", bitsPerSample)
                    return []
                }
                fmtValidated = true
            }

            if chunkID == "data" {
                guard fmtValidated else {
                    NSLog("MLXTTSEngine: WAV data chunk found before fmt — invalid")
                    return []
                }
                let dataStart = offset + 8
                let dataEnd = min(dataStart + Int(chunkSize), data.count)
                let sampleCount = (dataEnd - dataStart) / 2  // 16-bit = 2 bytes per sample

                var samples = [Float](repeating: 0, count: sampleCount)
                data.withUnsafeBytes { ptr in
                    for i in 0..<sampleCount {
                        let byteOffset = dataStart + i * 2
                        let int16 = ptr.load(fromByteOffset: byteOffset, as: Int16.self)
                        samples[i] = Float(int16) / 32768.0
                    }
                }
                return samples
            }
            offset += 8 + Int(chunkSize)
            // WAV chunks are word-aligned.
            if chunkSize % 2 != 0 { offset += 1 }
        }

        return []
    }
}
