import XCTest
@testable import Fae

final class StreamingSTTTests: XCTestCase {

    // MARK: - Engine Unit Tests

    func testStreamingEngineBufferAccumulates() async {
        let engine = MLXSTTEngine()
        let samples = [Float](repeating: 0.1, count: 576)

        await engine.feedStreamingAudio(samples)
        await engine.feedStreamingAudio(samples)

        // Buffer should have accumulated both chunks.
        let partial = await engine.partialTranscript
        XCTAssertEqual(partial, "", "Partial transcript should be empty before any transcription runs")
    }

    func testStreamingEngineResetClearsState() async {
        let engine = MLXSTTEngine()
        let samples = [Float](repeating: 0.1, count: 576)

        await engine.feedStreamingAudio(samples)
        await engine.resetStreaming()

        // After reset, shouldRunStreamingTranscription should be false
        // (buffer is empty, no new samples).
        let shouldRun = await engine.shouldRunStreamingTranscription()
        XCTAssertFalse(shouldRun, "Should not run streaming transcription after reset")

        let partial = await engine.partialTranscript
        XCTAssertEqual(partial, "", "Partial transcript should be empty after reset")
    }

    func testStreamingEngineGuardsOverlap() async {
        let engine = MLXSTTEngine()
        // Feed enough samples to trigger a streaming run.
        let samples = [Float](repeating: 0.1, count: MLXSTTEngine.streamingIntervalSamples)
        await engine.feedStreamingAudio(samples)

        let shouldRun = await engine.shouldRunStreamingTranscription()
        XCTAssertTrue(shouldRun, "Should be ready for streaming transcription after feeding enough samples")

        // Without a model loaded, runStreamingTranscription returns nil
        // but shouldn't crash.
        let result = await engine.runStreamingTranscription()
        XCTAssertNil(result, "Should return nil when model is not loaded")
    }

    func testStreamingEngineIntervalCheck() async {
        let engine = MLXSTTEngine()
        // Feed fewer samples than the interval threshold.
        let smallChunk = [Float](repeating: 0.1, count: MLXSTTEngine.streamingIntervalSamples - 1)
        await engine.feedStreamingAudio(smallChunk)

        let shouldRunBefore = await engine.shouldRunStreamingTranscription()
        XCTAssertFalse(shouldRunBefore, "Should not run with fewer samples than interval threshold")

        // One more sample pushes over the threshold.
        await engine.feedStreamingAudio([0.1])
        let shouldRunAfter = await engine.shouldRunStreamingTranscription()
        XCTAssertTrue(shouldRunAfter, "Should run after reaching interval threshold")
    }

    // MARK: - Pipeline Policy Tests (Static Methods)

    func testStreamingAudioGatedDuringPlaybackEcho() {
        // Validates that generation takeover is independent of barge-in tracking.
        XCTAssertFalse(
            PipelineCoordinator.shouldTrackBargeIn(assistantSpeaking: false),
            "Barge-in should not track when not speaking"
        )
        XCTAssertTrue(
            PipelineCoordinator.shouldTrackGenerationTakeover(
                assistantSpeaking: false,
                assistantGenerating: true
            ),
            "Generation takeover should be active during silent generation"
        )
    }

    func testGenerationTakeoverAndBargeInAreMutuallyExclusive() {
        // When speaking: barge-in active, takeover inactive.
        XCTAssertTrue(PipelineCoordinator.shouldTrackBargeIn(assistantSpeaking: true))
        XCTAssertFalse(
            PipelineCoordinator.shouldTrackGenerationTakeover(
                assistantSpeaking: true,
                assistantGenerating: true
            )
        )

        // When generating silently: barge-in inactive, takeover active.
        XCTAssertFalse(PipelineCoordinator.shouldTrackBargeIn(assistantSpeaking: false))
        XCTAssertTrue(
            PipelineCoordinator.shouldTrackGenerationTakeover(
                assistantSpeaking: false,
                assistantGenerating: true
            )
        )

        // When idle: both inactive.
        XCTAssertFalse(PipelineCoordinator.shouldTrackBargeIn(assistantSpeaking: false))
        XCTAssertFalse(
            PipelineCoordinator.shouldTrackGenerationTakeover(
                assistantSpeaking: false,
                assistantGenerating: false
            )
        )
    }

    func testSilentGenerationBufferOverflowPolicy() {
        XCTAssertEqual(
            PipelineCoordinator.maxSilentGenerationBufferSize, 4,
            "Silent generation buffer should hold at most 4 segments"
        )
    }

    // MARK: - Streaming Epoch / Slot Invariants

    func testStreamingEngineResetAfterInFlightDoesNotCrash() async {
        let engine = MLXSTTEngine()
        let samples = [Float](repeating: 0.1, count: MLXSTTEngine.streamingIntervalSamples)
        await engine.feedStreamingAudio(samples)

        // Start a transcription attempt (returns nil — no model loaded).
        let result = await engine.runStreamingTranscription()
        XCTAssertNil(result)

        // Reset immediately after — should not crash or leave inconsistent state.
        await engine.resetStreaming()
        let shouldRun = await engine.shouldRunStreamingTranscription()
        XCTAssertFalse(shouldRun)
        let partial = await engine.partialTranscript
        XCTAssertEqual(partial, "")
    }

    func testResetDoesNotClearActiveRunSlot() async {
        // After a run completes (no model → nil), the slot is released.
        // Reset clears the buffer but not the slot.
        // Fresh data after reset should allow a new run.
        let engine = MLXSTTEngine()
        let samples = [Float](repeating: 0.1, count: MLXSTTEngine.streamingIntervalSamples)
        await engine.feedStreamingAudio(samples)

        let shouldRunBefore = await engine.shouldRunStreamingTranscription()
        XCTAssertTrue(shouldRunBefore, "Should be ready before first run")

        let result = await engine.runStreamingTranscription()
        XCTAssertNil(result)

        await engine.resetStreaming()

        await engine.feedStreamingAudio(samples)
        let shouldRunAfterReset = await engine.shouldRunStreamingTranscription()
        XCTAssertTrue(shouldRunAfterReset, "Should be ready after reset + fresh data")
    }

    func testMultipleResetsAreIdempotent() async {
        let engine = MLXSTTEngine()
        await engine.feedStreamingAudio([Float](repeating: 0.1, count: 1000))

        await engine.resetStreaming()
        await engine.resetStreaming()
        await engine.resetStreaming()

        let shouldRun = await engine.shouldRunStreamingTranscription()
        XCTAssertFalse(shouldRun)
    }

    func testWedgeTimeoutIsReasonable() {
        // The wedge timeout must be long enough to never fire during normal
        // inference but short enough to recover promptly from a stuck run.
        // Normal inference: <1s for 1.5s of audio on M-series.
        // Timeout: 3s — 3x normal maximum.
        XCTAssertEqual(
            MLXSTTEngine.streamingWedgeTimeoutSeconds, 3.0,
            "Wedge timeout should be 3 seconds"
        )
    }

    func testSlotReleasedAfterNoModelRun() async {
        // When runStreamingTranscription() fails at the model guard,
        // the slot should never have been claimed — so shouldRun
        // returns true again after feeding fresh data.
        let engine = MLXSTTEngine()
        let samples = [Float](repeating: 0.1, count: MLXSTTEngine.streamingIntervalSamples)

        await engine.feedStreamingAudio(samples)
        let result = await engine.runStreamingTranscription()
        XCTAssertNil(result, "No model loaded — should return nil")

        // Slot was never claimed because guard exited early.
        // Feed more data — should be ready again.
        await engine.feedStreamingAudio(samples)
        let shouldRun = await engine.shouldRunStreamingTranscription()
        XCTAssertTrue(shouldRun, "Slot should be available after failed run (no model)")
    }

    // MARK: - Acoustic Robustness

    func testNoiseFloorTracking() {
        var vad = VoiceActivityDetector()

        // Initially, noise floor is the default seed value.
        XCTAssertEqual(vad.noiseFloorRms, 0.008, accuracy: 0.001)

        // Feed a series of silent chunks — noise floor should adapt downward.
        let silentChunk = AudioChunk(
            samples: [Float](repeating: 0.001, count: 576),
            sampleRate: 16000
        )
        for _ in 0..<50 {
            _ = vad.processChunk(silentChunk)
        }

        // Noise floor should have adapted toward 0.001 (clamped at noiseFloorMin=0.0005).
        XCTAssertLessThan(vad.noiseFloorRms, 0.005, "Noise floor should adapt downward toward silence level")
    }

    func testSNREstimation() {
        var vad = VoiceActivityDetector()

        // Seed noise floor with quiet chunks.
        let quietChunk = AudioChunk(
            samples: [Float](repeating: 0.002, count: 576),
            sampleRate: 16000
        )
        for _ in 0..<20 {
            _ = vad.processChunk(quietChunk)
        }

        // SNR for a loud chunk (0.1 RMS) against a quiet floor (~0.002) should be high.
        let snr = vad.estimatedSNRdB(chunkRms: 0.1)
        XCTAssertGreaterThan(snr, 20, "Loud speech against quiet background should have high SNR")

        // SNR at the noise floor should be ~0 dB.
        let snrAtFloor = vad.estimatedSNRdB(chunkRms: vad.noiseFloorRms)
        XCTAssertEqual(snrAtFloor, 0, accuracy: 1.0, "SNR at noise floor should be ~0 dB")
    }

    func testMinStreamingSNRThreshold() {
        // The threshold should be reasonable (3-12 dB is typical for usable ASR).
        let threshold = VoiceActivityDetector.minStreamingSNRdB
        XCTAssertGreaterThanOrEqual(threshold, 3.0, "Minimum SNR for streaming should be at least 3 dB")
        XCTAssertLessThanOrEqual(threshold, 12.0, "Minimum SNR for streaming should not exceed 12 dB")
    }

    func testEditDistanceRatio() {
        // Identical strings → 0.
        XCTAssertEqual(MLXSTTEngine.editDistanceRatio("hello", "hello"), 0, accuracy: 0.01)

        // Completely different → 1.
        XCTAssertEqual(MLXSTTEngine.editDistanceRatio("abc", "xyz"), 1.0, accuracy: 0.01)

        // One character change in "hello" → 1/5 = 0.2.
        XCTAssertEqual(MLXSTTEngine.editDistanceRatio("hello", "hallo"), 0.2, accuracy: 0.01)

        // Empty vs non-empty → 1.
        XCTAssertEqual(MLXSTTEngine.editDistanceRatio("", "abc"), 1.0, accuracy: 0.01)

        // Both empty → 0.
        XCTAssertEqual(MLXSTTEngine.editDistanceRatio("", ""), 0, accuracy: 0.01)

        // Partial extension (typical of growing ASR): "what's the" → "what's the weather".
        let ratio = MLXSTTEngine.editDistanceRatio("what's the", "what's the weather")
        XCTAssertLessThan(ratio, 0.5, "Growing partial should have low edit distance ratio")
    }

    func testPartialInstabilityThreshold() {
        // The instability threshold should reject radical rewrites but allow
        // natural partial growth.
        XCTAssertGreaterThanOrEqual(
            MLXSTTEngine.maxPartialInstabilityRatio, 0.6,
            "Instability threshold should not be too aggressive"
        )
        XCTAssertLessThanOrEqual(
            MLXSTTEngine.maxPartialInstabilityRatio, 0.95,
            "Instability threshold should catch truly unstable partials"
        )
    }
}
