import Foundation
import MLX
import MLXAudioSTT

/// Speech-to-text engine using Qwen3-ASR via mlx-audio-swift.
///
/// Provides two transcription modes:
/// - **Batch**: `transcribe(samples:sampleRate:)` for complete speech segments
/// - **Streaming**: `StreamingInferenceSession` with provisional→confirmed token
///   promotion, configurable latency presets, and proper cancellation
actor MLXSTTEngine: STTEngine {
    private var model: Qwen3ASRModel?
    private(set) var isLoaded: Bool = false
    private(set) var loadState: MLEngineLoadState = .notStarted

    // MARK: - Streaming Session

    /// Active streaming inference session, or nil when not streaming.
    private var streamingSession: StreamingInferenceSession?

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

        var processed = samples
        Self.preprocessForASR(&processed, sampleRate: sampleRate)

        let audio = MLXArray(processed)
        let output = model.generate(audio: audio)

        return STTResult(
            text: output.text,
            language: output.language,
            confidence: nil
        )
    }

    // MARK: - Audio Preprocessing

    /// Normalize peak amplitude to -3dBFS and apply 80Hz high-pass filter.
    static func preprocessForASR(_ samples: inout [Float], sampleRate: Int) {
        let peak = samples.lazy.map { abs($0) }.max() ?? 0
        if peak > 0.001 {
            let gain = Float(0.707) / peak
            for i in samples.indices { samples[i] *= gain }
        }

        let rc = 1.0 / (2.0 * Float.pi * 80.0)
        let dt = 1.0 / Float(sampleRate)
        let alpha = rc / (rc + dt)
        var prev: Float = 0
        var prevFiltered: Float = 0
        for i in samples.indices {
            let filtered = alpha * (prevFiltered + samples[i] - prev)
            prev = samples[i]
            prevFiltered = filtered
            samples[i] = filtered
        }
    }

    // MARK: - Streaming ASR (via StreamingInferenceSession)

    /// Start a new streaming session for real-time transcription.
    ///
    /// Creates a `StreamingInferenceSession` with the `.agent` delay preset
    /// (480ms latency, balanced for voice assistants). The session provides
    /// provisional→confirmed token promotion with minimum 2 agreement passes.
    func startStreamingSession() {
        guard let model else {
            NSLog("MLXSTTEngine: cannot start streaming — model not loaded")
            return
        }
        // Cancel any existing session before starting a new one.
        streamingSession?.cancel()
        let config = StreamingConfig(
            decodeIntervalSeconds: 1.0,
            delayPreset: .agent,
            language: "English",
            temperature: 0.0,
            minAgreementPasses: 2
        )
        streamingSession = StreamingInferenceSession(model: model, config: config)
        NSLog("MLXSTTEngine: streaming session started (.agent preset)")
    }

    /// Feed audio samples to the active streaming session.
    func feedStreamingAudio(_ samples: [Float]) {
        streamingSession?.feedAudio(samples: samples)
    }

    /// Access the event stream from the active session.
    /// Returns nil if no session is active.
    var streamingEvents: AsyncStream<TranscriptionEvent>? {
        streamingSession?.events
    }

    /// Stop the streaming session gracefully (finalizes transcription).
    func stopStreamingSession() {
        streamingSession?.stop()
        streamingSession = nil
        NSLog("MLXSTTEngine: streaming session stopped")
    }

    /// Cancel the streaming session (discards pending work).
    func cancelStreamingSession() {
        streamingSession?.cancel()
        streamingSession = nil
    }

    /// Whether a streaming session is currently active.
    var isStreaming: Bool {
        streamingSession != nil
    }

    /// Reset streaming state — equivalent to cancel + cleanup.
    /// Called on segment completion or pipeline reset.
    func resetStreaming() {
        streamingSession?.cancel()
        streamingSession = nil
    }
}
