import Foundation
import MLX
import MoonshineMLX

/// Streaming ASR engine using Moonshine V2 (native Swift MLX).
///
/// Wraps kylehowells/moonshine-mlx to conform to Fae's ``StreamingSTTEngine``
/// protocol.  Provides true incremental decode — `addAudio()` processes only
/// new audio, while `transcribe()` re-decodes the accumulated features.
///
/// Model variants (HuggingFace repo IDs):
/// - `UsefulSensors/moonshine-streaming-tiny` (43M, ~50ms first partial)
/// - `UsefulSensors/moonshine-streaming-small` (147M, ~150ms first partial)
/// - `UsefulSensors/moonshine-streaming-medium` (245M, ~260ms first partial)
///
/// Auto-downloads from HuggingFace on first use (~300MB for tiny).
///
/// **Decode frequency**: `feedAudio()` only accumulates audio into the encoder.
/// `transcribe()` is called separately at a controlled rate (every 8000 samples
/// = 500ms at 16kHz) to avoid monopolizing the GPU with 28 decodes/sec.
actor MoonshineStreamingEngine: StreamingSTTEngine {

    // MARK: - Configuration

    /// Default model — tiny gives the best latency for streaming partials.
    static let defaultModelId = "UsefulSensors/moonshine-streaming-tiny"

    /// Audio samples between decode passes (500ms at 16kHz).
    /// Matching MLXSTTEngine.streamingIntervalSamples for consistency.
    static let decodeIntervalSamples = 8_000

    // MARK: - State

    private var model: MoonshineModel?
    private var stream: StreamingState?
    private var currentPartial: String = ""
    private(set) var isLoaded: Bool = false
    private var modelId: String

    /// Total audio samples fed in the current segment.
    private var totalSamplesFed: Int = 0

    /// Samples fed since the last decode pass.
    private var samplesSinceLastDecode: Int = 0

    /// Epoch counter — incremented on reset to invalidate in-flight operations.
    private var epoch: UInt64 = 0

    // MARK: - Init

    init(modelId: String = MoonshineStreamingEngine.defaultModelId) {
        self.modelId = modelId
    }

    // MARK: - StreamingSTTEngine Conformance

    func load() async throws {
        NSLog("MoonshineStreamingEngine: loading model %@", modelId)
        do {
            // Note: MoonshineModelLoader.load() uses runBlocking internally
            // for HF Hub download.  This is a known limitation of the library —
            // it blocks the calling thread until download completes.  The actor
            // serialization ensures no concurrent access during the block.
            let loaded = try MoonshineModelLoader.load(from: modelId)
            self.model = loaded
            self.isLoaded = true
            NSLog("MoonshineStreamingEngine: model loaded successfully")
        } catch {
            NSLog("MoonshineStreamingEngine: load failed: %@", error.localizedDescription)
            throw error
        }
    }

    /// Feed audio samples.  Only accumulates into the encoder — does NOT
    /// decode on every call.  The pipeline should call `getPartialTranscript()`
    /// at a controlled rate to trigger decode.
    func feedAudio(_ samples: [Float]) async {
        guard let model else { return }

        // Create stream on first audio chunk.
        if stream == nil {
            let s = model.createStream()
            model.startStream(s)
            stream = s
        }

        guard let stream else { return }
        totalSamplesFed += samples.count
        samplesSinceLastDecode += samples.count

        // Feed audio — Moonshine's encoder processes incrementally.
        // This is fast (~1ms) — only the embedder/frontend runs, not the decoder.
        let chunk = MLXArray(samples)
        model.addAudio(stream, chunk: chunk)
    }

    /// Get the current partial transcript.
    ///
    /// Triggers a decode pass only if enough new audio has accumulated
    /// (every 8000 samples = 500ms).  This prevents GPU monopolization
    /// from decoding on every 36ms chunk.
    func getPartialTranscript() async -> String {
        guard let model, let stream else { return currentPartial }

        // Only decode when enough new audio has accumulated.
        if samplesSinceLastDecode >= Self.decodeIntervalSamples {
            samplesSinceLastDecode = 0
            let text = model.transcribe(stream, isFinal: false)
            if !text.isEmpty {
                currentPartial = text
            }
        }

        return currentPartial
    }

    func getFinalTranscript() async -> String {
        guard let model, let stream else {
            let result = currentPartial
            resetInternal()
            return result
        }

        // Final decode with isFinal: true flushes all frames.
        let finalText = model.transcribe(stream, isFinal: true)
        let result = finalText.isEmpty ? currentPartial : finalText

        resetInternal()
        return result
    }

    func reset() async {
        resetInternal()
    }

    /// Internal reset that doesn't need async (called from getFinalTranscript too).
    private func resetInternal() {
        if let model, let stream {
            model.stopStream(stream)
        }
        epoch &+= 1
        stream = nil
        currentPartial = ""
        totalSamplesFed = 0
        samplesSinceLastDecode = 0
    }

    // MARK: - Diagnostics

    func diagnosticsSummary() -> String {
        """
        MoonshineStreamingEngine:
          loaded: \(isLoaded)
          modelId: \(modelId)
          totalSamplesFed: \(totalSamplesFed)
          currentPartialLength: \(currentPartial.count)
          epoch: \(epoch)
        """
    }
}
