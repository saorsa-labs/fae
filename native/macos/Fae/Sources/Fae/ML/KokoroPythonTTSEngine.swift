import AVFoundation
import Foundation

/// Kokoro-ONNX TTS engine running in a separate Python subprocess.
///
/// Spawns `kokoro_tts_server.py` via `uv run --script` on first synthesis.
/// The process persists across utterances — only the model loading overhead
/// is paid once (~0.3s). Subsequent synthesis runs at RTF ~0.5-0.8.
///
/// **Why a separate process?**
/// MLX (LLM + previous TTS) uses Metal GPU. Running TTS in a subprocess
/// on CPU via ONNX Runtime completely eliminates Metal contention that
/// caused audio stuttering during background tool calls.
///
/// Protocol (stdin/stdout binary):
///   Request:  JSON line → stdin
///   Response: [4-byte int32 N][N×float32 samples] chunks, terminated by [int32=0]
///             On error: [int32=-1][4-byte int32 errLen][UTF-8 error bytes]
actor KokoroPythonTTSEngine: TTSEngine {

    // MARK: - State

    private(set) var loadState: MLEngineLoadState = .notStarted
    private var voiceName: String = "af_heart"
    private var speed: Float = 1.0

    /// The Python subprocess handle — spawned lazily on first synthesis.
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?

    // MARK: - TTSEngine

    var isLoaded: Bool { loadState.isLoaded }
    var isVoiceLoaded: Bool { true }  // Always ready; voice is selected, not loaded

    func load(modelID: String) async throws {
        // modelID can optionally encode voice + speed as "af_heart:1.0"
        let parts = modelID.split(separator: ":").map(String.init)
        if let v = parts.first, !v.isEmpty, v != "kokoro" {
            voiceName = v
        }
        if parts.count > 1, let s = Float(parts[1]) {
            speed = s
        }
        loadState = .loading
        do {
            try await spawnServerIfNeeded()
            loadState = .loaded
            NSLog("KokoroPythonTTSEngine: ready (voice=%@ speed=%.1f)", voiceName, speed)
        } catch {
            loadState = .failed(error.localizedDescription)
            throw error
        }
    }

    func loadVoice(referenceAudioURL: URL, referenceText: String?) async throws {
        // Kokoro uses pre-defined voice embeddings. We select the closest built-in
        // voice rather than doing real-time voice cloning.
        // fae.wav → use af_heart as the default Fae voice (warm, feminine, clear).
        NSLog("KokoroPythonTTSEngine: loadVoice called (using af_heart as Fae voice)")
        voiceName = "af_heart"
    }

    func loadCustomVoice(url: URL, referenceText: String?) async throws {
        // If the caller provides a voice name as the last path component (e.g. af_sky.bin),
        // extract and use it. Otherwise fall back to af_heart.
        let stem = url.deletingPathExtension().lastPathComponent
        let knownVoices = ["af_aoede", "af_bella", "af_heart", "af_nicole", "af_sky", "bf_emma"]
        if knownVoices.contains(stem) {
            voiceName = stem
            NSLog("KokoroPythonTTSEngine: custom voice → %@", stem)
        } else {
            NSLog("KokoroPythonTTSEngine: unknown voice %@ — using af_heart", stem)
            voiceName = "af_heart"
        }
    }

    func synthesize(text: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        synthesize(text: text, voiceInstruct: nil)
    }

    func synthesize(
        text: String,
        voiceInstruct: String?
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        // voiceInstruct in Kokoro maps to a different voice name if it matches a known voice.
        let effectiveVoice = resolveVoice(from: voiceInstruct) ?? voiceName
        let effectiveSpeed = self.speed

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.performSynthesis(
                        text: text,
                        voice: effectiveVoice,
                        speed: effectiveSpeed,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private

    private func resolveVoice(from instruct: String?) -> String? {
        guard let instruct else { return nil }
        let known = ["af_aoede", "af_bella", "af_heart", "af_nicole", "af_sky", "bf_emma"]
        let lower = instruct.lowercased()
        return known.first { lower.contains($0) }
    }

    private func performSynthesis(
        text: String,
        voice: String,
        speed: Float,
        continuation: AsyncThrowingStream<AVAudioPCMBuffer, Error>.Continuation
    ) async throws {
        try await spawnServerIfNeeded()
        guard let stdin = stdinPipe, let stdout = stdoutPipe else {
            throw TTSError.notReady
        }

        // Build request JSON
        let req: [String: Any] = [
            "text": text,
            "voice": voice,
            "speed": speed,
            "lang": "en-us",
        ]
        let reqData = try JSONSerialization.data(withJSONObject: req)
        var reqLine = reqData
        reqLine.append(0x0A)  // newline

        // Write request to server stdin
        stdin.fileHandleForWriting.write(reqLine)

        // Read chunked PCM response
        let fileHandle = stdout.fileHandleForReading
        while true {
            // Read 4-byte length header
            let hdrData = fileHandle.readData(ofLength: 4)
            guard hdrData.count == 4 else {
                throw TTSError.protocolError("EOF reading chunk header")
            }
            let n = Int32(bitPattern: hdrData.withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).littleEndian
            })

            if n == 0 {
                // Sentinel — end of utterance
                break
            } else if n < 0 {
                // Error from server
                let errLenData = fileHandle.readData(ofLength: 4)
                let errLen = Int32(bitPattern: errLenData.withUnsafeBytes {
                    $0.loadUnaligned(as: UInt32.self).littleEndian
                })
                let errData = fileHandle.readData(ofLength: Int(errLen))
                let msg = String(data: errData, encoding: .utf8) ?? "unknown error"
                throw TTSError.synthesisError(msg)
            } else {
                // PCM chunk
                let byteCount = Int(n) * 4
                let pcmData = fileHandle.readData(ofLength: byteCount)
                guard pcmData.count == byteCount else {
                    throw TTSError.protocolError("Short PCM read: \(pcmData.count)/\(byteCount)")
                }
                let buffer = try makePCMBuffer(from: pcmData, sampleCount: Int(n))
                continuation.yield(buffer)
            }
        }
    }

    private func makePCMBuffer(from data: Data, sampleCount: Int) throws -> AVAudioPCMBuffer {
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        )!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleCount)) else {
            throw TTSError.bufferAllocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        guard let channelData = buffer.floatChannelData?[0] else {
            throw TTSError.bufferAllocationFailed
        }
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            channelData.initialize(from: base.assumingMemoryBound(to: Float.self), count: sampleCount)
        }
        return buffer
    }

    // MARK: - Subprocess management

    private func spawnServerIfNeeded() async throws {
        if let p = process, p.isRunning { return }

        // Tear down any stale process.
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil

        guard let scriptURL = Bundle.faeResources.url(forResource: "kokoro_tts_server", withExtension: "py", subdirectory: "Scripts") else {
            throw TTSError.scriptNotFound
        }

        let uvPath = Self.uvPath()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: uvPath)
        proc.arguments = ["run", "--script", scriptURL.path]

        // Environment: pass model paths and inherit HOME for HF cache lookup.
        var env = ProcessInfo.processInfo.environment
        // Point server to HF cache if available; server also auto-discovers it.
        env["FAE_KOKORO_VOICES_DIR"] = Self.hfVoicesDir() ?? ""
        env["FAE_KOKORO_MODEL_PATH"] = Self.hfModelPath() ?? ""
        proc.environment = env

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Forward server stderr → NSLog
        errPipe.fileHandleForReading.readabilityHandler = { fh in
            let data = fh.availableData
            if !data.isEmpty, let msg = String(data: data, encoding: .utf8) {
                for line in msg.components(separatedBy: "\n") where !line.isEmpty {
                    NSLog("%@", line)
                }
            }
        }

        try proc.run()
        process = proc
        stdinPipe = inPipe
        stdoutPipe = outPipe

        // Wait for "Server ready" marker line on stderr before accepting requests.
        try await waitForReady(errPipe: errPipe)
        NSLog("KokoroPythonTTSEngine: subprocess ready (pid=%d)", proc.processIdentifier)
    }

    private func waitForReady(errPipe: Pipe) async throws {
        // The server writes [int32 = -2] on stdout when startup is complete.
        // We read it here before releasing the caller.
        guard let stdout = stdoutPipe else { throw TTSError.serverDied("No stdout pipe") }
        let fileHandle = stdout.fileHandleForReading

        // Read with a 30s timeout to cover first-run package installation by uv.
        let readyTask = Task {
            let hdrData = fileHandle.readData(ofLength: 4)
            guard hdrData.count == 4 else { return false }
            let code = Int32(bitPattern: hdrData.withUnsafeBytes {
                $0.loadUnaligned(as: UInt32.self).littleEndian
            })
            return code == -2  // -2 = ready sentinel
        }
        // Wrap in a timeout.
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            readyTask.cancel()
        }
        let isReady = await readyTask.value
        timeoutTask.cancel()

        guard isReady else {
            process?.terminate()
            throw TTSError.serverDied("Startup sentinel not received within 30s")
        }
        guard let p = process, p.isRunning else {
            throw TTSError.serverDied("Process exited during startup")
        }
    }

    // MARK: - Path helpers

    private static func uvPath() -> String {
        let candidates = [
            "/Users/\(NSUserName())/.local/bin/uv",
            "/usr/local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/opt/zerobrew/bin/uv",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "uv"  // Fall back to PATH lookup
    }

    private static func hfCacheBase() -> String? {
        let base = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.cache/huggingface/hub"
        let repoDir = "\(base)/models--onnx-community--Kokoro-82M-v1.0-ONNX/snapshots"
        guard FileManager.default.fileExists(atPath: repoDir) else { return nil }
        let snaps = (try? FileManager.default.contentsOfDirectory(atPath: repoDir))?.sorted().reversed() ?? []
        for snap in snaps {
            let p = "\(repoDir)/\(snap)"
            if FileManager.default.fileExists(atPath: "\(p)/onnx/model_quantized.onnx") {
                return p
            }
        }
        return nil
    }

    private static func hfModelPath() -> String? {
        guard let base = hfCacheBase() else { return nil }
        return "\(base)/onnx/model_quantized.onnx"
    }

    private static func hfVoicesDir() -> String? {
        guard let base = hfCacheBase() else { return nil }
        return "\(base)/voices"
    }

    // MARK: - Cleanup

    func shutdown() {
        process?.terminate()
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        NSLog("KokoroPythonTTSEngine: shutdown")
    }
}

// MARK: - Errors

enum TTSError: LocalizedError {
    case notReady
    case scriptNotFound
    case serverDied(String)
    case protocolError(String)
    case synthesisError(String)
    case bufferAllocationFailed

    var errorDescription: String? {
        switch self {
        case .notReady: return "Kokoro TTS engine not ready"
        case .scriptNotFound: return "kokoro_tts_server.py not found in app bundle"
        case .serverDied(let msg): return "Kokoro TTS server died: \(msg)"
        case .protocolError(let msg): return "Kokoro TTS protocol error: \(msg)"
        case .synthesisError(let msg): return "Kokoro TTS synthesis failed: \(msg)"
        case .bufferAllocationFailed: return "Failed to allocate AVAudioPCMBuffer"
        }
    }
}
