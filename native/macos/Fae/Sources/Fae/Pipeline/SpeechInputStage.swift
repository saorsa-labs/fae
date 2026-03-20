import Foundation

/// Manages the speech segment queue and streaming audio feeding for the voice pipeline.
///
/// Extracted from `PipelineCoordinator` to reduce its state variable count and
/// encapsulate the bounded speech segment queue, streaming STT feeding, and
/// wake word detection into a cohesive unit.
///
/// This type is owned by `PipelineCoordinator` (not a separate actor) so that
/// all state mutations remain on the coordinator's actor context — no async
/// boundary changes from the original code.
final class SpeechInputStage: @unchecked Sendable {

    // MARK: - Speech Segment Queue

    /// Task running the speech segment processing loop.
    private var speechSegmentTask: Task<Void, Never>?

    /// Continuation for enqueuing speech segments into the bounded async stream.
    private var speechSegmentContinuation: AsyncStream<SpeechSegment>.Continuation?

    /// Maximum number of buffered speech segments before backpressure drops occur.
    static let speechSegmentQueueDepth = 6

    /// Running count of segments dropped due to backpressure (diagnostic).
    private(set) var speechSegmentsDroppedForBackpressure: Int = 0

    // MARK: - Streaming Wake Detection

    /// Audio samples accumulated for streaming acoustic wake word detection.
    var streamingWakeSamples: [Float] = []

    /// Number of samples last evaluated by the wake detector (stride gate).
    var streamingWakeLastEvaluatedSamples: Int = 0

    /// Most recent acoustic wake detection result from the streaming evaluator.
    var streamingWakeDetection: WakeWordAcousticDetector.Detection?

    /// Sample stride between acoustic wake evaluations.
    static let acousticWakeEvalStrideSamples = 4_800

    // MARK: - Streaming STT State

    /// Epoch counter for streaming ASR sessions. Incremented on every reset
    /// so that in-flight results from a previous session are silently dropped.
    private(set) var streamingEpoch: UInt64 = 0

    /// Last partial transcript from streaming STT, used for transcript-aware endpointing.
    var lastStreamingPartialTranscript: String?

    // MARK: - Init

    init() {}

    // MARK: - Speech Segment Queue Management

    /// Start the bounded speech segment processing loop.
    ///
    /// Segments enqueued via ``enqueueSpeechSegment(_:handler:debugConsole:)`` are
    /// forwarded to `handler` on the caller's actor context.
    ///
    /// - Parameter handler: Async closure invoked for each dequeued segment.
    func startSpeechSegmentProcessingLoop(
        handler: @escaping @Sendable (SpeechSegment) async -> Void
    ) {
        guard speechSegmentTask == nil else { return }

        NSLog("SpeechInputStage: speech segment queue started (depth=%d)", Self.speechSegmentQueueDepth)

        let stream = AsyncStream<SpeechSegment>(
            bufferingPolicy: .bufferingNewest(Self.speechSegmentQueueDepth)
        ) { continuation in
            self.speechSegmentContinuation = continuation
        }

        speechSegmentTask = Task {
            for await segment in stream {
                guard !Task.isCancelled else { break }
                await handler(segment)
            }
        }
    }

    /// Stop the speech segment processing loop and await task completion.
    func stopSpeechSegmentProcessingLoop() async {
        speechSegmentContinuation?.finish()
        speechSegmentContinuation = nil
        speechSegmentTask?.cancel()
        await speechSegmentTask?.value
        speechSegmentTask = nil
        NSLog("SpeechInputStage: speech segment queue stopped")
    }

    /// Enqueue a speech segment into the bounded queue.
    ///
    /// When the queue is full (backpressure), the oldest segment is dropped and
    /// the drop count is incremented. When the queue is not yet started, the
    /// segment is dispatched directly to the handler as a fallback.
    ///
    /// - Parameters:
    ///   - segment: The completed speech segment from VAD.
    ///   - handler: Fallback handler when the queue is not initialized.
    ///   - debugConsole: Optional debug console for logging.
    func enqueueSpeechSegment(
        _ segment: SpeechSegment,
        fallbackHandler: @escaping @Sendable (SpeechSegment) async -> Void,
        debugConsole: DebugConsoleController?
    ) {
        guard let continuation = speechSegmentContinuation else {
            // Queue not initialized — process synchronously as a safe fallback.
            Task { await fallbackHandler(segment) }
            return
        }

        let result = continuation.yield(segment)
        switch result {
        case .enqueued:
            debugLog(debugConsole, .pipeline, "Speech segment enqueued dur=\(String(format: "%.2f", segment.durationSeconds))s")
        case .dropped:
            speechSegmentsDroppedForBackpressure += 1
            NSLog("SpeechInputStage: dropped speech segment due to backpressure (count=%d)", speechSegmentsDroppedForBackpressure)
            NSLog("phase1.audio_backpressure_drop_count=%d", speechSegmentsDroppedForBackpressure)
            debugLog(debugConsole, .pipeline, "Speech segment dropped (backpressure) count=\(speechSegmentsDroppedForBackpressure)")
        case .terminated:
            NSLog("SpeechInputStage: speech segment queue terminated — processing synchronously")
            Task { await fallbackHandler(segment) }
        @unknown default:
            Task { await fallbackHandler(segment) }
        }
    }

    /// Whether the speech segment processing loop is running.
    var isRunning: Bool { speechSegmentTask != nil }

    // MARK: - Streaming Epoch

    /// Increment the streaming epoch to invalidate in-flight transcription results.
    func incrementStreamingEpoch() {
        streamingEpoch &+= 1
    }

    // MARK: - Streaming Wake Detection

    /// Reset the streaming wake detector state for a new segment.
    func resetStreamingWakeDetector() {
        streamingWakeSamples.removeAll(keepingCapacity: true)
        streamingWakeLastEvaluatedSamples = 0
        streamingWakeDetection = nil
    }
}
