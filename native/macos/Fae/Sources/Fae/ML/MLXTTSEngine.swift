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
    func load(modelID: String = "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16") async throws {
        loadState = .loading
        NSLog("MLXTTSEngine: loading model %@", modelID)

        // Patch cached config.json for CustomVoice models — mlx-audio-swift expects
        // spk_id as [String: [Int]] but the HuggingFace config has [String: Int],
        // and spk_is_dialect has mixed Bool/String values.
        Self.patchConfigIfNeeded(modelID: modelID)

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

    // MARK: - Config Patching

    /// Patch the cached config.json to fix type mismatches between HuggingFace model
    /// configs and what mlx-audio-swift expects.
    ///
    /// Known mismatches in CustomVoice models:
    /// - `talker_config.spk_id`: HF has `{name: int}`, library expects `{name: [int]}`
    /// - `talker_config.spk_is_dialect`: HF has mixed `bool|string`, library expects `{name: string}`
    private static func patchConfigIfNeeded(modelID: String) {
        // mlx-audio caches models at ~/.cache/huggingface/hub/mlx-audio/{org}_{repo}/
        let cacheKey = modelID.replacingOccurrences(of: "/", with: "_")
        let cacheDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/mlx-audio")
            .appendingPathComponent(cacheKey)
        let configPath = cacheDir.appendingPathComponent("config.json")

        guard FileManager.default.fileExists(atPath: configPath.path) else { return }

        do {
            let data = try Data(contentsOf: configPath)
            guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            guard var talker = root["talker_config"] as? [String: Any] else { return }

            var patched = false

            // Fix spk_id: convert {name: Int} → {name: [Int]}
            if let spkId = talker["spk_id"] as? [String: Any] {
                var fixed = [String: [Int]]()
                for (name, value) in spkId {
                    if let intVal = value as? Int {
                        fixed[name] = [intVal]
                        patched = true
                    } else if let arrVal = value as? [Int] {
                        fixed[name] = arrVal
                    }
                }
                if patched {
                    talker["spk_id"] = fixed
                }
            }

            // Fix spk_is_dialect: convert mixed Bool/String → all String
            if let spkDialect = talker["spk_is_dialect"] as? [String: Any] {
                var fixed = [String: String]()
                for (name, value) in spkDialect {
                    if let strVal = value as? String {
                        fixed[name] = strVal
                    } else if let boolVal = value as? Bool {
                        fixed[name] = boolVal ? "true" : "false"
                        patched = true
                    } else {
                        fixed[name] = String(describing: value)
                        patched = true
                    }
                }
                if patched || fixed.count != (spkDialect as NSDictionary).count {
                    talker["spk_is_dialect"] = fixed
                    patched = true
                }
            }

            if patched {
                root["talker_config"] = talker
                let patchedData = try JSONSerialization.data(
                    withJSONObject: root,
                    options: [.prettyPrinted, .sortedKeys]
                )
                try patchedData.write(to: configPath, options: .atomic)
                NSLog("MLXTTSEngine: patched config.json for CustomVoice compatibility")
            }
        } catch {
            NSLog("MLXTTSEngine: config patch failed (non-fatal): %@", error.localizedDescription)
        }
    }

    /// Load a reference voice from a `.wav` file for voice cloning.
    ///
    /// The CustomVoice model uses ~3 seconds of reference audio to clone a voice.
    /// The reference audio must be 24kHz mono PCM 16-bit WAV.
    /// Automatically skips leading silence and extracts the first voiced segment.
    func loadVoice(referenceAudioURL: URL, referenceText: String? = nil) async throws {
        let audioData = try Data(contentsOf: referenceAudioURL)
        let samples = Self.parseWAVToFloat32(audioData)

        // Skip leading silence: find first sample above threshold.
        // TTS-generated WAVs often have silence at the start.
        let silenceThreshold: Float = 0.01
        let windowSize = 480  // 20ms at 24kHz
        var speechStart = 0
        for i in stride(from: 0, to: samples.count - windowSize, by: windowSize) {
            let window = samples[i ..< i + windowSize]
            let rms = sqrt(window.reduce(0) { $0 + $1 * $1 } / Float(windowSize))
            if rms > silenceThreshold {
                speechStart = max(0, i - windowSize)  // Back up one window for a clean start.
                break
            }
        }

        // Take 1.5 seconds of speech at 24kHz = 36000 samples.
        // Shorter clips reduce the chance of refText bleeding into generated audio
        // while still providing enough voice characteristic for cloning.
        let clipEnd = min(speechStart + 36_000, samples.count)
        let clipSamples = Array(samples[speechStart ..< clipEnd])

        refAudio = MLXArray(clipSamples)
        refText = referenceText
        isVoiceLoaded = true
        NSLog("MLXTTSEngine: voice loaded (%d samples, speech offset=%d)", clipSamples.count, speechStart)
    }

    /// Load a custom voice from a user-provided WAV file with validation.
    ///
    /// Validates format (mono PCM 16-bit) and duration (2-8 seconds of speech).
    /// Falls through to the standard `loadVoice` path after validation.
    func loadCustomVoice(url: URL, referenceText: String?) async throws {
        let audioData = try Data(contentsOf: url)
        let samples = Self.parseWAVToFloat32(audioData)

        guard !samples.isEmpty else {
            throw MLEngineError.loadFailed("TTS", NSError(
                domain: "MLXTTSEngine", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "WAV must be mono PCM 16-bit format"]
            ))
        }

        // Validate duration: 2-8 seconds at 24kHz.
        let durationSecs = Float(samples.count) / 24_000
        guard durationSecs >= 2.0, durationSecs <= 8.0 else {
            throw MLEngineError.loadFailed("TTS", NSError(
                domain: "MLXTTSEngine", code: 3,
                userInfo: [NSLocalizedDescriptionKey:
                    String(format: "WAV duration %.1fs — must be 2-8 seconds of clear speech", durationSecs)]
            ))
        }

        try await loadVoice(referenceAudioURL: url, referenceText: referenceText)
        NSLog("MLXTTSEngine: custom voice loaded from %@", url.lastPathComponent)
    }

    /// Synthesize text to a stream of audio buffers using Fae's cloned voice (ICL mode).
    func synthesize(text: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        synthesize(text: text, voiceInstruct: nil)
    }

    /// Synthesize text with a cloned voice from a specific reference audio (per-character cloning).
    ///
    /// - Parameters:
    ///   - text: The text to speak.
    ///   - refAudio: MLXArray of reference audio samples for voice cloning.
    ///   - refText: Transcript of the reference audio.
    func synthesize(text: String, refAudio: MLXArray, refText: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.synthesizeWithRef(
                    text: text,
                    refAudio: refAudio,
                    refText: refText,
                    continuation: continuation
                )
            }

            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }

    /// Synthesize text with a specific voice description (instruct mode).
    ///
    /// - Parameters:
    ///   - text: The text to speak.
    ///   - voiceInstruct: A voice description string for instruct mode (e.g. "A deep male British accent").
    ///     Pass nil to use Fae's cloned voice via ICL (in-context learning) mode.
    func synthesize(text: String, voiceInstruct: String?) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                await self.synthesizeInternal(
                    text: text,
                    voiceInstruct: voiceInstruct,
                    continuation: continuation
                )
            }

            continuation.onTermination = { @Sendable _ in
                producer.cancel()
            }
        }
    }

    /// Internal synthesis — runs within actor isolation so model access is safe.
    private func synthesizeInternal(
        text: String,
        voiceInstruct: String?,
        continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation
    ) async {
        guard let model else {
            continuation.finish(throwing: MLEngineError.notLoaded("TTS"))
            return
        }

        // When using instruct mode (voiceInstruct != nil), pass the voice description
        // and skip refAudio/refText. When nil, use ICL voice cloning.
        let voice: String?
        let ref: MLXArray?
        let refTxt: String?

        if let instruct = voiceInstruct {
            voice = instruct
            ref = nil
            refTxt = nil
        } else {
            voice = nil
            ref = refAudio
            refTxt = refText

            if refAudio == nil || refText == nil {
                NSLog("MLXTTSEngine: WARNING — voice cloning inactive (refAudio=%@, refText=%@)",
                      refAudio != nil ? "set" : "nil", refText != nil ? "set" : "nil")
            }
        }

        do {
            let sampleRate = model.sampleRate
            let stream = model.generateSamplesStream(
                text: text,
                voice: voice,
                refAudio: ref,
                refText: refTxt,
                language: nil
            )
            for try await samples in stream {
                if Task.isCancelled {
                    break
                }
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
                if Task.isCancelled {
                    break
                }
                continuation.yield(buffer)
            }
            continuation.finish()
        } catch {
            if Task.isCancelled {
                continuation.finish()
            } else {
                continuation.finish(throwing: error)
            }
        }
    }

    /// Load reference audio from a WAV file and return as MLXArray for per-character cloning.
    func loadRefAudioFromFile(url: URL) throws -> MLXArray {
        let data = try Data(contentsOf: url)
        let samples = Self.parseWAVToFloat32(data)
        guard !samples.isEmpty else {
            throw MLEngineError.loadFailed("TTS", NSError(
                domain: "MLXTTSEngine", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Invalid WAV file: \(url.lastPathComponent)"]
            ))
        }

        // Same silence-skipping and clipping as loadVoice.
        let silenceThreshold: Float = 0.01
        let windowSize = 480
        var speechStart = 0
        for i in stride(from: 0, to: samples.count - windowSize, by: windowSize) {
            let window = samples[i..<i + windowSize]
            let rms = sqrt(window.reduce(0) { $0 + $1 * $1 } / Float(windowSize))
            if rms > silenceThreshold {
                speechStart = max(0, i - windowSize)
                break
            }
        }
        let clipEnd = min(speechStart + 72_000, samples.count)
        return MLXArray(Array(samples[speechStart..<clipEnd]))
    }

    /// Internal synthesis with per-call reference audio (for character voice cloning).
    private func synthesizeWithRef(
        text: String,
        refAudio: MLXArray,
        refText: String,
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
                if Task.isCancelled {
                    break
                }
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
                if Task.isCancelled {
                    break
                }
                continuation.yield(buffer)
            }
            continuation.finish()
        } catch {
            if Task.isCancelled {
                continuation.finish()
            } else {
                continuation.finish(throwing: error)
            }
        }
    }

    // MARK: - WAV Parsing

    /// Read a little-endian UInt16 from Data at the given byte offset.
    private static func readU16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    /// Read a little-endian UInt32 from Data at the given byte offset.
    private static func readU32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    /// Read a little-endian Int16 from Data at the given byte offset.
    private static func readI16(_ data: Data, at offset: Int) -> Int16 {
        Int16(bitPattern: readU16(data, at: offset))
    }

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
            let chunkSize = readU32(data, at: offset + 4)

            if chunkID == "fmt " {
                guard Int(chunkSize) >= 16, offset + 8 + 16 <= data.count else {
                    NSLog("MLXTTSEngine: WAV fmt chunk too small (%d bytes)", chunkSize)
                    return []
                }
                let audioFormat = readU16(data, at: offset + 8)
                let numChannels = readU16(data, at: offset + 10)
                let bitsPerSample = readU16(data, at: offset + 22)
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
                let sampleCount = (dataEnd - dataStart) / 2

                var samples = [Float](repeating: 0, count: sampleCount)
                for i in 0..<sampleCount {
                    let int16 = readI16(data, at: dataStart + i * 2)
                    samples[i] = Float(int16) / 32768.0
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
