import AVFoundation
import Foundation

// MARK: - Errors

/// Errors specific to the daemon TTS lane. Socket/auth failures surface as
/// `DaemonLLMEngineError` (shared connection layer).
enum DaemonTTSEngineError: LocalizedError {
    case notLoaded
    case invalidAudioPayload(String)

    var errorDescription: String? {
        switch self {
        case .notLoaded:
            return "Daemon TTS engine not connected"
        case .invalidAudioPayload(let detail):
            return "fae-daemon tts.synthesize returned an unusable payload: \(detail)"
        }
    }
}

// MARK: - Engine

/// TTS engine that routes synthesis to the local Rust `fae-daemon`
/// (`tts.synthesize`, Kokoro via voice-tts) instead of running the MLX Kokoro
/// engine in-process.
///
/// Enabled via `tts.useDaemonEngine` (see `FaeConfig.TtsConfig`) and only when
/// the daemon LLM lane is active: this engine never launches the daemon — it
/// opens a SECOND socket connection to the process `DaemonLLMEngine` owns
/// (whose endpoints it receives at init). A dedicated connection is required
/// because the LLM connection serializes round trips that can run for minutes;
/// TTS must not queue behind them.
///
/// Speed is deliberately NOT sent to the daemon: the pipeline applies
/// `tts.speed` once, at playback (`AudioPlaybackManager` resample ratio), the
/// same as the in-process Kokoro lane.
actor DaemonTTSEngine: TTSEngine {
    private let socketPath: String
    private let tokenPath: String
    /// Daemon-side Kokoro voice id, resolved from the configured voice at
    /// init; switchable live via `switchVoice(to:)`.
    private var voice: String

    private var connection: DaemonSocketConnection?
    private var requestCounter = 0

    private(set) var loadState: MLEngineLoadState = .notStarted

    var isLoaded: Bool { loadState.isLoaded }

    /// Voice used when the configured voice has no daemon-side equivalent
    /// (e.g. Fae's custom "fae" embedding, which is not ported to voice-tts yet).
    static let fallbackVoice = "af_heart"

    /// - Parameters:
    ///   - socketPath: Unix socket of the already-running daemon
    ///     (`DaemonLLMEngine.endpoints`).
    ///   - tokenPath: Bootstrap token file path (same source).
    ///   - configuredVoice: `tts.voice` from config; mapped to a daemon-side
    ///     Kokoro voice via `daemonVoice(from:)`.
    init(socketPath: String, tokenPath: String, configuredVoice: String) {
        self.socketPath = socketPath
        self.tokenPath = tokenPath
        self.voice = Self.daemonVoice(from: configuredVoice)
    }

    deinit {
        connection?.close()
    }

    // MARK: TTSEngine

    /// Connect to the daemon socket and authenticate. The `modelID` parameter
    /// (the `kokoro:voice:speed` id chosen by ModelManager for the MLX lane)
    /// is intentionally ignored — the daemon owns its Kokoro model. Idempotent
    /// so ModelManager's `loadAll` can safely re-invoke `load` after FaeCore
    /// has already connected.
    func load(modelID: String) async throws {
        if isLoaded { return }
        loadState = .loading
        do {
            try await connectAndAuthenticate()
            loadState = .loaded
            NSLog(
                "DaemonTTSEngine: connected to fae-daemon (voice %@; MLX model id %@ ignored)",
                voice, modelID)
        } catch {
            loadState = .failed(error.localizedDescription)
            connection?.close()
            connection = nil
            throw error
        }
    }

    func synthesize(text: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        synthesize(text: text, voiceInstruct: nil)
    }

    /// Synthesize with an optional per-utterance voice override. An instruct
    /// that is a Kokoro voice id (e.g. voice preview passes "af_bella") is
    /// used for this request only; anything else keeps the current voice —
    /// the daemon has no instruct-conditioned synthesis.
    func synthesize(
        text: String, voiceInstruct: String?
    ) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    if let buffer = try await self.performSynthesis(
                        text: text, voiceInstruct: voiceInstruct),
                        !Task.isCancelled
                    {
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Switch the default voice for subsequent synthesis calls (live, no
    /// restart). Non-Kokoro names map to the daemon fallback voice.
    func switchVoice(to name: String) {
        voice = Self.daemonVoice(from: name)
        NSLog("DaemonTTSEngine: switched voice to %@", voice)
    }

    // MARK: - Internals

    /// One `tts.synthesize` round trip. Returns nil for empty input or empty
    /// synthesized audio (nothing to play — not an error).
    private func performSynthesis(
        text: String, voiceInstruct: String?
    ) async throws -> AVAudioPCMBuffer? {
        guard isLoaded, let connection else { throw DaemonTTSEngineError.notLoaded }
        let voice = Self.requestVoice(instruct: voiceInstruct, current: voice)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let requestID = nextRequestID()
        let frame = try DaemonWire.encodeFrame(
            requestID: requestID,
            command: "tts.synthesize",
            // The daemon bounds text at 2000 chars; the pipeline synthesizes
            // sentence-by-sentence so real requests sit far below the cap.
            payload: [
                "text": String(trimmed.prefix(2_000)),
                "voice": voice,
            ])

        let t0 = Date()
        let raw = try await connection.roundTrip(frame: frame, expectRequestID: requestID)
        let response = try DaemonWire.unwrapResponse(raw)
        let result = (response["result"] as? [String: Any]) ?? [:]
        guard let wavBase64 = result["wav_base64"] as? String,
              let wavData = Data(base64Encoded: wavBase64)
        else {
            throw DaemonTTSEngineError.invalidAudioPayload("missing or undecodable wav_base64")
        }
        let sampleRate = (result["sample_rate"] as? Int)
            ?? WAVParser.parseSampleRate(wavData)
            ?? 24_000

        let samples = WAVParser.parseToFloat32(wavData)
        guard !samples.isEmpty else {
            NSLog("DaemonTTSEngine: empty audio for %d-char text — skipping", trimmed.count)
            return nil
        }

        let duration = Double(samples.count) / Double(sampleRate)
        NSLog(
            "DaemonTTSEngine: %.2fs audio in %.3fs (RTF=%.2f) voice=%@",
            duration, Date().timeIntervalSince(t0),
            Date().timeIntervalSince(t0) / max(duration, 0.001), voice)

        return try Self.makePCMBuffer(samples: samples, sampleRate: sampleRate)
    }

    private func nextRequestID() -> String {
        requestCounter += 1
        return "t\(requestCounter)"
    }

    /// Connect to the existing daemon's socket (no launch, no polling — the
    /// daemon is already serving the LLM lane) and authenticate with the
    /// bootstrap token. The token is hash-verified per connection, so a second
    /// authenticated session alongside the LLM connection is supported.
    private func connectAndAuthenticate() async throws {
        let attempt = DaemonSocketConnection(queueLabel: "fae.daemon-tts.socket")
        try attempt.connect(to: socketPath)

        let token: String
        do {
            token = try String(contentsOfFile: tokenPath, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            attempt.close()
            throw DaemonLLMEngineError.tokenUnreadable(tokenPath)
        }
        guard !token.isEmpty else {
            attempt.close()
            throw DaemonLLMEngineError.tokenUnreadable(tokenPath)
        }

        let requestID = nextRequestID()
        let authFrame = try DaemonWire.encodeFrame(
            requestID: requestID,
            command: "session.authenticate",
            payload: [
                "client_id": "swift-frontend-bootstrap",
                "token": token,
            ])
        do {
            let raw = try await attempt.roundTrip(frame: authFrame, expectRequestID: requestID)
            _ = try DaemonWire.unwrapResponse(raw)
        } catch {
            attempt.close()
            throw error
        }

        connection = attempt
    }

    // MARK: - Pure helpers (unit-testable)

    /// Per-request voice: an instruct that is itself a Kokoro voice id wins;
    /// otherwise the engine's current voice stands. Unlike `daemonVoice(from:)`
    /// this never falls back to `fallbackVoice` — a descriptive instruct
    /// ("a warm, calm voice") must not silently reset a switched voice.
    static func requestVoice(instruct: String?, current: String) -> String {
        guard let instruct, !instruct.isEmpty else { return current }
        let mapped = daemonVoice(from: instruct)
        return mapped == fallbackVoice && instruct.lowercased() != fallbackVoice
            ? current
            : mapped
    }

    /// Map the configured `tts.voice` to a daemon-side Kokoro voice id.
    /// Kokoro ids look like `af_heart` / `bm_daniel` (accent+gender prefix,
    /// underscore, name). Anything else — notably Fae's custom "fae" embedding,
    /// which voice-tts cannot load yet — falls back to `fallbackVoice`.
    static func daemonVoice(from configured: String) -> String {
        let candidate = configured.lowercased().trimmingCharacters(in: .whitespaces)
        let parts = candidate.split(separator: "_")
        guard parts.count == 2,
              parts[0].count == 2,
              !parts[1].isEmpty,
              candidate.allSatisfy({ $0.isLowercase || $0 == "_" })
        else {
            return fallbackVoice
        }
        return candidate
    }

    /// Wrap mono Float32 samples in an `AVAudioPCMBuffer` for the playback path.
    static func makePCMBuffer(samples: [Float], sampleRate: Int) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(sampleRate),
            channels: 1,
            interleaved: false),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count))
        else {
            throw DaemonTTSEngineError.invalidAudioPayload(
                "could not allocate PCM buffer (\(samples.count) frames @ \(sampleRate) Hz)")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channel = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    channel.update(from: base, count: samples.count)
                }
            }
        }
        return buffer
    }
}
