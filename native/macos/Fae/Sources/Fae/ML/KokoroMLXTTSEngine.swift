import AVFoundation
import Foundation
import MLX
import KokoroSwift

/// Kokoro-82M TTS engine — pure Swift MLX port (mlalma/kokoro-ios).
///
/// Runs via MLX on Apple Silicon. No Python, no subprocess, no external
/// runtime dependencies. Voice embeddings are loaded from pre-trained `.bin`
/// files (raw float32, shape [510, 1, 256]).
///
/// Synthesis is non-streaming: all audio frames are generated in a single
/// forward pass and yielded as one AVAudioPCMBuffer at 24 kHz mono.
///
/// **Model file:** `kokoro-v1_0.safetensors` (hexgrad/Kokoro-82M on HuggingFace)
/// **Voices:**     `voices/*.bin` — identical across hexgrad and onnx-community caches
///
/// **Model discovery order (checked on every launch):**
///   1. `~/Library/Application Support/fae/models/kokoro/`
///   2. `~/.cache/huggingface/hub/models--hexgrad--Kokoro-82M/snapshots/*/`
///   3. ONNX voices dir + standalone safetensors model at app support path
///   4. Auto-download from `hexgrad/Kokoro-82M` → saves to location 1
actor KokoroMLXTTSEngine: TTSEngine {

    // MARK: - State

    private(set) var loadState: MLEngineLoadState = .notStarted
    private var voiceName: String = "af_heart"
    private var speed: Float = 1.0
    private var kokoroTTS: KokoroTTS?
    private var voiceEmbedding: MLXArray?
    private var voicesDir: URL?

    // MARK: - TTSEngine

    var isLoaded: Bool { loadState.isLoaded }
    var isVoiceLoaded: Bool { voiceEmbedding != nil }

    func load(modelID: String) async throws {
        // modelID format: "kokoro" | "kokoro:af_heart" | "kokoro:af_heart:1.2"
        let parts = modelID.split(separator: ":").map(String.init)
        if parts.count > 1 {
            let v = parts[1]
            if !v.isEmpty && v != "kokoro" { voiceName = v }
        }
        if parts.count > 2, let s = Float(parts[2]) { speed = s }

        loadState = .loading
        do {
            // Find existing model files, or auto-download from HuggingFace.
            let (modelURL, foundVoicesDir): (URL, URL)
            if let found = Self.findModelFiles() {
                (modelURL, foundVoicesDir) = found
            } else {
                NSLog("KokoroMLXTTSEngine: model not found locally — downloading hexgrad/Kokoro-82M")
                (modelURL, foundVoicesDir) = try await Self.downloadModelFiles()
            }
            voicesDir = foundVoicesDir

            let tts = KokoroTTS(modelPath: modelURL)
            kokoroTTS = tts

            // Load voice embedding.
            // Respect the requested voice by default.
            // The bundled fae.bin is only selected when the caller explicitly asks
            // for the canonical Fae voice via `kokoro:fae`.
            let bundledFaeVoice = Bundle.module.url(forResource: "fae", withExtension: "bin",
                                                     subdirectory: "Voices")
            let bundledFaeEmbedding = bundledFaeVoice.flatMap { Self.loadBinFile(url: $0) }
            let requestedFaeVoice = voiceName.caseInsensitiveCompare("fae") == .orderedSame

            if requestedFaeVoice, let bundledFaeEmbedding {
                voiceEmbedding = bundledFaeEmbedding
                voiceName = "fae"
            } else {
                let requestedEmbedding = Self.loadVoiceEmbedding(voicesDir: foundVoicesDir, name: voiceName)
                let heartEmbedding = Self.loadVoiceEmbedding(voicesDir: foundVoicesDir, name: "af_heart")
                let emmaEmbedding = Self.loadVoiceEmbedding(voicesDir: foundVoicesDir, name: "bf_emma")
                voiceEmbedding = requestedEmbedding ?? heartEmbedding ?? emmaEmbedding ?? bundledFaeEmbedding
                if requestedEmbedding == nil && heartEmbedding == nil && emmaEmbedding == nil && bundledFaeEmbedding != nil {
                    voiceName = "fae"
                }
            }

            if voiceEmbedding == nil {
                NSLog("KokoroMLXTTSEngine: WARNING — no voice embedding found")
            }

            loadState = .loaded
            NSLog("KokoroMLXTTSEngine: ready (voice=%@ speed=%.1f)", voiceName, speed)
        } catch {
            loadState = .failed(error.localizedDescription)
            throw error
        }
    }

    func loadVoice(referenceAudioURL: URL, referenceText: String?) async throws {
        // Kokoro uses pre-computed style vectors; runtime voice cloning is not
        // supported. If the URL stem matches a known built-in voice, switch to it.
        let stem = referenceAudioURL.deletingPathExtension().lastPathComponent
        if let vDir = voicesDir,
           let embedding = Self.loadVoiceEmbedding(voicesDir: vDir, name: stem) {
            voiceEmbedding = embedding
            voiceName = stem
            NSLog("KokoroMLXTTSEngine: voice → %@ (matched from loadVoice)", stem)
        } else {
            NSLog("KokoroMLXTTSEngine: loadVoice — no match for '%@', keeping current voice", stem)
        }
    }

    func loadCustomVoice(url: URL, referenceText: String?) async throws {
        let stem = url.deletingPathExtension().lastPathComponent
        if let embedding = Self.loadBinFile(url: url) {
            voiceEmbedding = embedding
            voiceName = stem
            NSLog("KokoroMLXTTSEngine: custom voice → %@ (from %@)", stem, url.lastPathComponent)
        } else if let vDir = voicesDir,
                  let embedding = Self.loadVoiceEmbedding(voicesDir: vDir, name: stem) {
            voiceEmbedding = embedding
            voiceName = stem
            NSLog("KokoroMLXTTSEngine: custom voice → %@ (by name lookup)", stem)
        }
    }

    func synthesize(text: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        synthesize(text: text, voiceInstruct: nil)
    }

    func synthesize(
        text: String,
        voiceInstruct: String?
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        return AsyncThrowingStream { continuation in
            Task {
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

    // MARK: - Private synthesis

    private func performSynthesis(
        text: String,
        voiceInstruct: String?,
        continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation
    ) async throws {
        guard let tts = kokoroTTS else { throw KokoroMLXError.notReady }

        let embedding: MLXArray
        if let instruct = voiceInstruct,
           let vDir = voicesDir,
           let resolved = Self.resolveVoiceFromInstruct(instruct, voicesDir: vDir) {
            embedding = resolved
        } else if let e = voiceEmbedding {
            embedding = e
        } else {
            throw KokoroMLXError.notReady
        }

        let t0 = Date()
        let (samples, _) = try tts.generateAudio(
            voice: embedding,
            language: .enUS,
            text: text,
            speed: speed
        )

        guard !samples.isEmpty else { return }

        let duration = Double(samples.count) / 24_000.0
        let elapsed = Date().timeIntervalSince(t0)
        NSLog(
            "KokoroMLXTTSEngine: %.2fs audio in %.3fs (RTF=%.2f) voice=%@",
            duration, elapsed, elapsed / max(duration, 0.001), voiceName
        )

        let buffer = try Self.makePCMBuffer(from: samples)
        continuation.yield(buffer)
    }

    // MARK: - Voice Resolution

    private static func resolveVoiceFromInstruct(_ instruct: String, voicesDir: URL) -> MLXArray? {
        let known = [
            "af_aoede", "af_bella", "af_heart", "af_nicole", "af_sky",
            "bf_emma", "bf_isabella", "am_adam", "am_echo", "bm_daniel",
        ]
        let lower = instruct.lowercased()
        guard let match = known.first(where: { lower.contains($0) }) else { return nil }
        return loadVoiceEmbedding(voicesDir: voicesDir, name: match)
    }

    // MARK: - Auto-download

    /// Pinned Hugging Face revision for deterministic Kokoro downloads.
    /// Matches the local cache snapshot currently used in development.
    static let pinnedRevision = "f3ff3571791e39611d31c381e3a41a3af07b4987"

    /// Download `kokoro-v1_0.safetensors` and the 10 standard voice `.bin` files from
    /// `hexgrad/Kokoro-82M` on HuggingFace into the app-support models directory.
    ///
    /// Files are only fetched when absent — interrupted downloads resume on the next
    /// launch. The destination (`~/Library/Application Support/fae/models/kokoro/`) is
    /// location 1 in `findModelFiles()`, so subsequent launches skip the download.
    private static func downloadModelFiles() async throws -> (modelURL: URL, voicesDir: URL) {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/fae/models/kokoro")
        let voicesBase = base.appendingPathComponent("voices")
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        try fm.createDirectory(at: voicesBase, withIntermediateDirectories: true)

        let hfBase = "https://huggingface.co/hexgrad/Kokoro-82M/resolve/\(pinnedRevision)/"

        // Model weights (~326 MB as of v1.0).
        let modelDest = base.appendingPathComponent("kokoro-v1_0.safetensors")
        try await downloadFile(
            from: URL(string: hfBase + "kokoro-v1_0.safetensors")!,
            to: modelDest,
            label: "kokoro-v1_0.safetensors"
        )

        // Voice embeddings (~200 KB each, 10 standard voices).
        let knownVoices = [
            "af_aoede", "af_bella", "af_heart", "af_nicole", "af_sky",
            "bf_emma", "bf_isabella", "am_adam", "am_echo", "bm_daniel",
        ]
        for voice in knownVoices {
            let dest = voicesBase.appendingPathComponent("\(voice).bin")
            try await downloadFile(
                from: URL(string: hfBase + "voices/\(voice).bin")!,
                to: dest,
                label: "voices/\(voice).bin"
            )
        }

        guard fm.fileExists(atPath: modelDest.path) else {
            throw KokoroMLXError.downloadFailed("model file missing after download")
        }
        return (modelDest, voicesBase)
    }

    /// Download a single file from `url` to `destination` using a `.tmp` intermediate
    /// for atomicity. Skips silently if the destination already exists.
    private static func downloadFile(from url: URL, to destination: URL, label: String) async throws {
        guard !fm.fileExists(atPath: destination.path) else { return }
        NSLog("KokoroMLXTTSEngine: downloading %@", label)
        let (tmpURL, response) = try await URLSession.shared.download(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw KokoroMLXError.downloadFailed("\(label): HTTP \(code)")
        }
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tmpURL, to: destination)
        NSLog("KokoroMLXTTSEngine: saved %@", label)
    }

    // MARK: - Model & Voice Discovery

    /// Locate the model safetensors URL and voices directory URL.
    /// Returns nil when no model is available — surface an error or download prompt.
    static func findModelFiles() -> (modelURL: URL, voicesDir: URL)? {
        let home = FileManager.default.homeDirectoryForCurrentUser

        // 1. App support directory (user-installed).
        let appKokoro = home
            .appendingPathComponent("Library/Application Support/fae/models/kokoro")
        let appModel = appKokoro.appendingPathComponent("kokoro-v1_0.safetensors")
        let appVoices = appKokoro.appendingPathComponent("voices")
        if fm.fileExists(atPath: appModel.path) && fm.fileExists(atPath: appVoices.path) {
            return (appModel, appVoices)
        }

        // 2. HuggingFace cache — hexgrad/Kokoro-82M (official safetensors model).
        if let pair = hfCacheLookup(
            home: home, repo: "hexgrad--Kokoro-82M",
            modelFile: "kokoro-v1_0.safetensors"
        ) { return pair }

        // 3. ONNX voices + standalone safetensors at app-support path.
        //    The ONNX .bin voice files are identical to the hexgrad voices.
        if let onnxVoices = hfVoicesOnly(home: home, repo: "onnx-community--Kokoro-82M-v1.0-ONNX"),
           fm.fileExists(atPath: appModel.path) {
            return (appModel, onnxVoices)
        }

        return nil
    }

    /// Whether model files are present (used by Settings UI).
    static var isModelAvailable: Bool { findModelFiles() != nil }

    /// Recommended install directory for model files.
    static var appModelDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/fae/models/kokoro")
    }

    private static var fm: FileManager { FileManager.default }

    private static func hfCacheLookup(
        home: URL, repo: String, modelFile: String
    ) -> (modelURL: URL, voicesDir: URL)? {
        let snapshots = home
            .appendingPathComponent(".cache/huggingface/hub/models--\(repo)/snapshots")
        guard let snaps = try? fm.contentsOfDirectory(atPath: snapshots.path) else { return nil }
        for snap in snaps.sorted().reversed() {
            let base = snapshots.appendingPathComponent(snap)
            let model = base.appendingPathComponent(modelFile)
            let voices = base.appendingPathComponent("voices")
            if fm.fileExists(atPath: model.path) && fm.fileExists(atPath: voices.path) {
                return (model, voices)
            }
        }
        return nil
    }

    private static func hfVoicesOnly(home: URL, repo: String) -> URL? {
        let snapshots = home
            .appendingPathComponent(".cache/huggingface/hub/models--\(repo)/snapshots")
        guard let snaps = try? fm.contentsOfDirectory(atPath: snapshots.path) else { return nil }
        for snap in snaps.sorted().reversed() {
            let voices = snapshots.appendingPathComponent(snap).appendingPathComponent("voices")
            if fm.fileExists(atPath: voices.path) { return voices }
        }
        return nil
    }

    // MARK: - Voice Embedding Helpers

    /// Load a named voice from a voices directory (looks for `<name>.bin`).
    static func loadVoiceEmbedding(voicesDir: URL, name: String) -> MLXArray? {
        loadBinFile(url: voicesDir.appendingPathComponent("\(name).bin"))
    }

    /// Load a raw float32 voice `.bin` file.
    /// Expected layout: 510 × 1 × 256 floats = 522,240 bytes.
    static func loadBinFile(url: URL) -> MLXArray? {
        let expectedBytes = 510 * 1 * 256 * MemoryLayout<Float>.size
        guard let data = try? Data(contentsOf: url),
              data.count == expectedBytes else { return nil }
        let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        return MLXArray(floats, [510, 1, 256])
    }

    // MARK: - PCM Buffer

    private static func makePCMBuffer(from samples: [Float]) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        )!
        let frameCount = AVAudioFrameCount(samples.count)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw KokoroMLXError.bufferAllocationFailed
        }
        buffer.frameLength = frameCount
        guard let channelData = buffer.floatChannelData?[0] else {
            throw KokoroMLXError.bufferAllocationFailed
        }
        samples.withUnsafeBufferPointer { ptr in
            channelData.initialize(from: ptr.baseAddress!, count: samples.count)
        }
        return buffer
    }
}

// MARK: - Errors

enum KokoroMLXError: LocalizedError {
    case modelNotFound
    case notReady
    case bufferAllocationFailed
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Kokoro model not found. "
                + "Download hexgrad/Kokoro-82M and place kokoro-v1_0.safetensors + voices/ in "
                + "~/Library/Application Support/fae/models/kokoro/"
        case .notReady:
            return "Kokoro MLX TTS engine not ready"
        case .bufferAllocationFailed:
            return "Failed to allocate AVAudioPCMBuffer"
        case .downloadFailed(let detail):
            return "Kokoro model download failed: \(detail)"
        }
    }
}
