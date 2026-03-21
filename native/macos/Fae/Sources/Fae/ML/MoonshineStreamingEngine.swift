import Foundation
import MLX
import MoonshineMLX

/// Streaming ASR engine using Moonshine V2 (native Swift MLX).
///
/// Wraps kylehowells/moonshine-mlx to conform to Fae's ``StreamingSTTEngine``
/// protocol.  Provides true incremental decode — each `feedAudio()` call
/// processes only the new audio, not the full buffer.
///
/// Model variants (HuggingFace repo IDs):
/// - `UsefulSensors/moonshine-streaming-tiny` (43M, ~50ms first partial)
/// - `UsefulSensors/moonshine-streaming-small` (147M, ~150ms first partial)
/// - `UsefulSensors/moonshine-streaming-medium` (245M, ~260ms first partial)
///
/// Auto-downloads from HuggingFace on first use (~300MB for tiny).
actor MoonshineStreamingEngine: StreamingSTTEngine {

    // MARK: - Configuration

    /// Default model — tiny gives the best latency for streaming partials.
    static let defaultModelId = "UsefulSensors/moonshine-streaming-tiny"

    // MARK: - State

    private var model: MoonshineModel?
    private var stream: StreamingState?
    private var currentPartial: String = ""
    private(set) var isLoaded: Bool = false
    private var modelId: String

    /// Total audio samples fed in the current segment (for diagnostics).
    private var totalSamplesFed: Int = 0

    // MARK: - Init

    init(modelId: String = MoonshineStreamingEngine.defaultModelId) {
        self.modelId = modelId
    }

    // MARK: - StreamingSTTEngine Conformance

    func load() async throws {
        NSLog("MoonshineStreamingEngine: loading model %@", modelId)
        do {
            let loaded = try MoonshineModelLoader.load(from: modelId)
            self.model = loaded
            self.isLoaded = true
            NSLog("MoonshineStreamingEngine: model loaded successfully")
        } catch {
            NSLog("MoonshineStreamingEngine: load failed: %@", error.localizedDescription)
            throw error
        }
    }

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

        // Feed audio — Moonshine processes incrementally via its encoder embedder.
        let chunk = MLXArray(samples)
        model.addAudio(stream, chunk: chunk)

        // Get partial transcript.
        let text = model.transcribe(stream, isFinal: false)
        if !text.isEmpty {
            currentPartial = text
        }
    }

    func getPartialTranscript() async -> String {
        currentPartial
    }

    func getFinalTranscript() async -> String {
        guard let model, let stream else {
            let result = currentPartial
            await reset()
            return result
        }

        // Get final transcript with isFinal: true.
        let finalText = model.transcribe(stream, isFinal: true)
        let result = finalText.isEmpty ? currentPartial : finalText

        await reset()
        return result
    }

    func reset() async {
        if let model, let stream {
            model.stopStream(stream)
        }
        stream = nil
        currentPartial = ""
        totalSamplesFed = 0
    }

    // MARK: - Diagnostics

    func diagnosticsSummary() -> String {
        """
        MoonshineStreamingEngine:
          loaded: \(isLoaded)
          modelId: \(modelId)
          totalSamplesFed: \(totalSamplesFed)
          currentPartialLength: \(currentPartial.count)
        """
    }
}
