import AVFoundation
import Foundation
import MLX
import MLXAudioTTS

private enum FaeTTSError: LocalizedError {
    case bufferCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .bufferCreationFailed(let reason): return "TTS buffer creation failed: \(reason)"
        }
    }
}

/// Thin TTS adapter wrapping mlx-audio-swift's Kokoro model with streaming support.
///
/// Replaces: `KokoroMLXTTSEngine` (vendored KokoroSwift, non-streaming),
///           `MLXTTSEngine` (legacy Qwen3-TTS), `KokoroPythonTTSEngine` (subprocess).
///
/// Uses `SpeechGenerationModel` from MLXAudioTTS which supports 54 voices,
/// 9 languages, and streaming audio generation via `generateSamplesStream()`.
actor FaeTTSAdapter: TTSEngine {
    private var model: (any SpeechGenerationModel)?
    private(set) var isLoaded: Bool = false
    private(set) var isVoiceLoaded: Bool = false
    private(set) var loadState: MLEngineLoadState = .notStarted

    /// Current voice name (e.g. "af_heart", "bf_emma").
    private var voiceName: String = "af_heart"

    /// Speech speed multiplier.
    private var speed: Float = 1.0

    /// Custom voice embedding loaded from the app bundle (Fae's own "fae"
    /// voice). Passed as `refAudio` so KokoroModel skips its HF-snapshot
    /// `voices/` lookup, which only contains the stock voices.
    private var customVoiceEmbedding: MLXArray?

    // MARK: - Loading

    /// Load the TTS model.
    ///
    /// Accepts model IDs in two formats:
    /// - HuggingFace repo: `"prince-canuma/Kokoro-82M"` (auto-downloads)
    /// - Fae format: `"kokoro:af_heart:1.0"` (voice + speed parsed, repo auto-resolved)
    func load(modelID: String) async throws {
        loadState = .loading
        let (repo, voice, spd) = Self.parseModelID(modelID)
        voiceName = voice
        speed = spd

        // Non-stock voices (Fae's own "fae") only exist as bundled
        // embeddings — KokoroModel.loadVoice would throw per-sentence.
        customVoiceEmbedding = Self.loadBundledVoiceEmbedding(named: voice)
        if customVoiceEmbedding == nil, !Self.isStockKokoroVoice(voice) {
            NSLog(
                "FaeTTSAdapter: voice '%@' has no bundled embedding and is not a stock voice — using af_heart",
                voice)
            voiceName = "af_heart"
        }

        NSLog("FaeTTSAdapter: loading model %@ voice=%@ speed=%.1f", repo, voiceName, speed)
        do {
            model = try await TTS.loadModel(modelRepo: repo)
            isLoaded = true
            isVoiceLoaded = true
            loadState = .loaded
            NSLog("FaeTTSAdapter: model loaded (sampleRate=%d)", model?.sampleRate ?? 0)
        } catch {
            loadState = .failed(error.localizedDescription)
            NSLog("FaeTTSAdapter: load failed: %@", error.localizedDescription)
            throw error
        }
    }

    // MARK: - Synthesis

    /// Synthesize speech from text, returning streaming PCM buffers.
    func synthesize(text: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        synthesize(text: text, voiceInstruct: nil)
    }

    /// Synthesize speech with optional voice override.
    ///
    /// If `voiceInstruct` contains a known voice name (e.g. "af_bella"),
    /// that voice is used for this utterance without changing the default.
    func synthesize(text: String, voiceInstruct: String?) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    try await self.performSynthesis(
                        text: text,
                        voiceInstruct: voiceInstruct,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Voice Control

    /// Switch the default voice for subsequent synthesis calls.
    func switchVoice(to name: String) {
        voiceName = name
        customVoiceEmbedding = Self.loadBundledVoiceEmbedding(named: name)
        NSLog("FaeTTSAdapter: switched voice to %@", name)
    }

    /// Set the speech speed multiplier.
    func setSpeed(_ newSpeed: Float) {
        speed = max(0.5, min(2.0, newSpeed))
    }

    // MARK: - Private

    private func performSynthesis(
        text: String,
        voiceInstruct: String?,
        continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation
    ) async throws {
        guard let model else {
            throw MLEngineError.notLoaded("TTS")
        }

        let effectiveVoice = Self.resolveVoice(voiceInstruct, fallback: voiceName)
        let sampleRate = model.sampleRate
        let t0 = Date()
        var totalSamples = 0

        // The default (custom) voice synthesizes via its bundled embedding;
        // explicit stock-voice overrides go through the name lookup.
        let refAudio = effectiveVoice == voiceName ? customVoiceEmbedding : nil

        // Use streaming generation for lower time-to-first-audio.
        let stream = model.generateSamplesStream(
            text: text,
            voice: effectiveVoice,
            refAudio: refAudio,
            refText: nil,
            language: "en",
            streamingInterval: 1.0
        )

        for try await samples in stream {
            guard !Task.isCancelled else { break }
            guard !samples.isEmpty else { continue }
            totalSamples += samples.count

            let buffer = try Self.makePCMBuffer(from: samples, sampleRate: sampleRate)
            continuation.yield(buffer)
        }

        let duration = Double(totalSamples) / Double(sampleRate)
        let elapsed = Date().timeIntervalSince(t0)
        NSLog(
            "FaeTTSAdapter: %.2fs audio in %.3fs (RTF=%.2f) voice=%@",
            duration, elapsed, elapsed / max(duration, 0.001), effectiveVoice
        )
    }

    // MARK: - Voice Resolution

    /// Resolve a voice from the instruct string, falling back to the default voice.
    private static func resolveVoice(_ instruct: String?, fallback: String) -> String {
        guard let instruct, !instruct.isEmpty else { return fallback }
        let lower = instruct.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Direct voice name match.
        let known = [
            "af_aoede", "af_bella", "af_heart", "af_nicole", "af_sky",
            "bf_emma", "bf_isabella", "am_adam", "am_echo", "bm_daniel",
        ]
        if let match = known.first(where: { lower.contains($0) }) {
            return match
        }

        // If the instruct looks like a bare voice ID (e.g. "af_heart"), use it directly.
        if lower.contains("_"), lower.count < 20 {
            return lower
        }

        return fallback
    }

    // MARK: - Model ID Parsing

    /// Parse Fae-format model IDs: `"kokoro:voice:speed"` or plain HuggingFace repo.
    private static func parseModelID(_ modelID: String) -> (repo: String, voice: String, speed: Float) {
        let parts = modelID.split(separator: ":", maxSplits: 3).map(String.init)
        if parts.count >= 2, parts[0].lowercased() == "kokoro" {
            let voice = parts.count > 1 ? parts[1] : "af_heart"
            let speed = parts.count > 2 ? Float(parts[2]) ?? 1.0 : 1.0
            return ("prince-canuma/Kokoro-82M", voice, speed)
        }
        // Plain HuggingFace repo ID.
        return (modelID, "af_heart", 1.0)
    }

    // MARK: - Custom Voices

    /// Whether a voice name follows the stock Kokoro id pattern
    /// (`af_heart`, `bm_daniel`, …) and can resolve from the HF snapshot's
    /// `voices/` directory.
    static func isStockKokoroVoice(_ name: String) -> Bool {
        let parts = name.split(separator: "_")
        return parts.count == 2 && parts[0].count == 2 && !parts[1].isEmpty
            && name.allSatisfy { ($0.isLowercase && $0.isLetter) || $0 == "_" }
    }

    /// Load a bundled custom voice embedding (`Resources/Voices/{name}.safetensors`)
    /// in the squeezed `[510, 256]` shape KokoroModel expects for `refAudio`.
    /// Returns nil when no bundled embedding exists for the name.
    static func loadBundledVoiceEmbedding(named name: String) -> MLXArray? {
        guard let url = Bundle.faeResources.url(forResource: name, withExtension: "safetensors")
        else { return nil }
        do {
            let arrays = try MLX.loadArrays(url: url)
            guard var voice = arrays["voice"] ?? arrays.values.first else {
                NSLog("FaeTTSAdapter: bundled voice '%@' has no tensors", name)
                return nil
            }
            voice = voice.asType(.float32)
            if voice.ndim == 3 { voice = voice.squeezed(axis: 1) }
            NSLog("FaeTTSAdapter: loaded bundled voice embedding '%@' %@", name, "\(voice.shape)")
            return voice
        } catch {
            NSLog(
                "FaeTTSAdapter: bundled voice '%@' failed to load: %@",
                name, error.localizedDescription)
            return nil
        }
    }

    // MARK: - PCM Buffer

    /// Create an AVAudioPCMBuffer from Float32 samples.
    private static func makePCMBuffer(from samples: [Float], sampleRate: Int) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw FaeTTSError.bufferCreationFailed("Failed to create audio format")
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw FaeTTSError.bufferCreationFailed("Failed to create PCM buffer")
        }

        guard let channelData = buffer.floatChannelData else {
            throw FaeTTSError.bufferCreationFailed("No channel data in buffer")
        }

        samples.withUnsafeBufferPointer { ptr in
            channelData[0].initialize(from: ptr.baseAddress!, count: samples.count)
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        return buffer
    }
}
