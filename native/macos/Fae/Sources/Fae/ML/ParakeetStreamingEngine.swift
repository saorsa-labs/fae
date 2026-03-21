// ParakeetStreamingEngine.swift
// Fae
//
// Streaming speech-to-text engine using Parakeet TDT 0.6B via MLX.
//
// Architecture: This runs as the "fast path" alongside Qwen3-ASR.
// Parakeet TDT is a lighter model (0.6B vs 1.7B) providing independent
// streaming partials on a separate decode cadence. Currently uses
// periodic whole-buffer decode via model.generate() — the entire
// accumulated audio is re-decoded on each pass. True incremental CTC
// decode (skipping already-processed frames) requires exposing the
// encoder's internal state and is deferred as future optimization.
// The 0.6B model is lightweight enough to share the GPU with other
// MLX workloads since it only runs during active speech.
//
// Model: mlx-community/parakeet-tdt-0.6b-v3
// See: Vendor/mlx-audio-swift/Sources/MLXAudioSTT/Models/Parakeet/

import Foundation
import MLX
import MLXAudioSTT

/// Streaming speech-to-text engine wrapping Parakeet TDT via mlx-audio-swift.
///
/// Conforms to `StreamingSTTEngine` to serve as the fast-path ASR in
/// Fae's dual-path pipeline. Audio chunks are accumulated, converted to
/// log-mel spectrograms, and decoded via the Parakeet conformer encoder
/// and TDT/CTC decoder head.
///
/// Usage:
/// ```swift
/// let engine = ParakeetStreamingEngine()
/// try await engine.load()
/// await engine.feedAudio(samples)
/// let partial = await engine.getPartialTranscript()
/// let final = await engine.getFinalTranscript()
/// ```
actor ParakeetStreamingEngine: StreamingSTTEngine {

    // MARK: - Constants

    /// Default HuggingFace model identifier for Parakeet TDT 0.6B v3.
    ///
    /// This model was chosen for its balance of accuracy and size:
    /// - 600M parameters (4-bit quantized ~300MB)
    /// - TDT variant supports frame-independent CTC decoding
    /// - 25 European languages with strong English performance
    /// - Apache 2.0 license
    static let defaultModelID = "mlx-community/parakeet-tdt-0.6b-v3"

    /// Default audio chunk size in samples before triggering a decode pass.
    /// 8000 samples = 500ms at 16kHz. Balances latency vs. decode efficiency.
    static let defaultChunkSamples = 8_000

    /// Minimum audio samples before the first decode pass.
    /// 4000 samples = 250ms at 16kHz. Ensures enough context for meaningful output.
    static let defaultMinChunkSamples = 4_000

    // MARK: - State

    /// The loaded Parakeet model, or nil if not yet loaded.
    private var model: ParakeetModel?

    /// Current engine load state.
    private(set) var loadState: MLEngineLoadState = .notStarted

    /// Accumulated raw audio samples (16kHz mono Float32) for the current segment.
    private var audioBuffer: [Float] = []

    /// Number of audio samples that have been decoded so far.
    /// Used to determine when enough new audio has arrived for another decode pass.
    private var decodedSampleCount: Int = 0

    /// Current partial transcript from the most recent decode pass.
    private var currentPartial: String = ""

    /// Configurable chunk size (samples) before triggering decode.
    private let chunkSamples: Int

    /// Minimum samples before first decode.
    private let minChunkSamples: Int

    // MARK: - Benchmarking

    /// Latency of the most recent decode pass in milliseconds.
    private(set) var lastDecodeLatencyMs: Double?

    /// Total number of decode passes executed in this session.
    private(set) var totalDecodeCount: Int = 0

    /// Cumulative decode time in milliseconds (for computing average).
    private var cumulativeDecodeMs: Double = 0

    /// Peak GPU memory observed during decode (bytes).
    private(set) var peakMemoryBytes: Int = 0

    // MARK: - StreamingSTTEngine Protocol

    /// Whether the engine has been loaded and is ready to process audio.
    var isLoaded: Bool {
        loadState.isLoaded
    }

    // MARK: - Initialization

    /// Create a new Parakeet streaming engine.
    ///
    /// - Parameters:
    ///   - chunkSamples: Audio samples to accumulate before each decode pass.
    ///   - minChunkSamples: Minimum samples before the very first decode pass.
    init(
        chunkSamples: Int = ParakeetStreamingEngine.defaultChunkSamples,
        minChunkSamples: Int = ParakeetStreamingEngine.defaultMinChunkSamples
    ) {
        self.chunkSamples = max(chunkSamples, 1600) // floor at 100ms
        self.minChunkSamples = max(minChunkSamples, 1600)
    }

    // MARK: - Load

    /// Load the Parakeet TDT model from HuggingFace Hub.
    ///
    /// Downloads and caches the model on first call. Subsequent calls
    /// use the cached version. This is a potentially long operation
    /// (~300MB download on first run).
    func load() async throws {
        try await load(modelID: Self.defaultModelID)
    }

    /// Load a specific Parakeet model by HuggingFace repository ID.
    ///
    /// - Parameter modelID: HuggingFace model repository (e.g. "mlx-community/parakeet-tdt-0.6b-v3").
    func load(modelID: String) async throws {
        loadState = .loading
        let cached = Self.isCached(modelID: modelID)
        NSLog("ParakeetStreamingEngine: %@ model %@",
              cached ? "loading from cache" : "downloading",
              modelID)
        do {
            let loaded = try await ParakeetModel.fromPretrained(modelID)
            model = loaded
            loadState = .loaded
            NSLog("ParakeetStreamingEngine: model loaded successfully")
        } catch {
            loadState = .failed(error.localizedDescription)
            NSLog("ParakeetStreamingEngine: load failed: %@", error.localizedDescription)
            throw error
        }
    }

    /// Check if a model is already cached in the local HuggingFace hub cache.
    ///
    /// The standard cache layout is:
    /// `~/.cache/huggingface/hub/models--{org}--{repo}/snapshots/{hash}/`
    static func isCached(modelID: String) -> Bool {
        let parts = modelID.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return false }
        let repoDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--\(parts[0])--\(parts[1])/snapshots")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: repoDir.path) else {
            return false
        }
        return !entries.isEmpty
    }

    // MARK: - Audio Processing

    /// Feed a chunk of audio samples to the engine.
    ///
    /// Audio should be 16kHz mono Float32. Chunks can be any size but
    /// 512 samples (~32ms) is typical for Fae's audio pipeline.
    ///
    /// When enough audio has accumulated (controlled by `chunkSamples`),
    /// a decode pass runs automatically and updates the partial transcript.
    func feedAudio(_ samples: [Float]) async {
        guard !samples.isEmpty, model != nil else { return }

        audioBuffer.append(contentsOf: samples)

        // Determine if we should decode
        let newSamples = audioBuffer.count - decodedSampleCount
        let threshold = decodedSampleCount == 0 ? minChunkSamples : chunkSamples
        guard newSamples >= threshold else { return }

        await runDecode()
    }

    /// Get the current partial transcript.
    ///
    /// Returns the best hypothesis for the audio processed so far.
    /// This text is provisional and may change as more audio arrives.
    func getPartialTranscript() async -> String {
        currentPartial
    }

    /// Get the final transcript for the current segment and reset.
    ///
    /// Runs one final decode on all accumulated audio, returns the result,
    /// then resets internal state for the next segment.
    func getFinalTranscript() async -> String {
        guard model != nil, !audioBuffer.isEmpty else {
            let result = currentPartial
            await reset()
            return result
        }

        // Run a final decode on all accumulated audio
        await runDecode()
        let result = currentPartial
        await reset()
        return result
    }

    /// Reset the engine state, discarding any buffered audio and partial results.
    func reset() async {
        audioBuffer.removeAll(keepingCapacity: true)
        decodedSampleCount = 0
        currentPartial = ""
    }

    // MARK: - Diagnostics

    /// Average decode latency across all passes in this session.
    var averageDecodeLatencyMs: Double {
        totalDecodeCount > 0 ? cumulativeDecodeMs / Double(totalDecodeCount) : 0
    }

    /// Human-readable diagnostics summary for the debug console.
    ///
    /// Returns a multi-line string with model status, decode stats,
    /// and memory usage.
    func diagnosticsSummary() -> String {
        var lines: [String] = []
        lines.append("ParakeetStreamingEngine:")
        lines.append("  loaded: \(isLoaded)")
        lines.append("  decodes: \(totalDecodeCount)")
        if totalDecodeCount > 0 {
            lines.append("  avg latency: \(String(format: "%.1f", averageDecodeLatencyMs))ms")
            if let last = lastDecodeLatencyMs {
                lines.append("  last latency: \(String(format: "%.1f", last))ms")
            }
            lines.append("  peak memory: \(peakMemoryBytes / 1_048_576)MB")
        }
        lines.append("  buffer: \(audioBuffer.count) samples (\(String(format: "%.1f", Double(audioBuffer.count) / 16000.0))s)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Private Decode

    /// Run a decode pass on the current audio buffer.
    private func runDecode() async {
        guard let model else { return }

        let start = CFAbsoluteTimeGetCurrent()

        // Convert buffer to MLXArray and run generation
        let audioArray = MLXArray(audioBuffer)
        let output = model.generate(
            audio: audioArray,
            generationParameters: model.defaultGenerationParameters
        )
        eval(audioArray) // ensure computation completes for timing

        // Extract and clean text
        let text = output.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)

        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000.0

        // Update state
        currentPartial = text
        decodedSampleCount = audioBuffer.count
        lastDecodeLatencyMs = elapsed
        totalDecodeCount += 1
        cumulativeDecodeMs += elapsed

        // Track peak memory
        let currentMemory = MLX.Memory.snapshot().peakMemory
        if Int(currentMemory) > peakMemoryBytes {
            peakMemoryBytes = Int(currentMemory)
        }

        NSLog(
            "ParakeetStreamingEngine: decode #%d in %.1fms, buffer=%.1fs, text=%d chars",
            totalDecodeCount, elapsed,
            Double(audioBuffer.count) / 16000.0,
            text.count
        )
    }
}
