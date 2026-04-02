import XCTest
@testable import Fae

final class StreamingSTTTests: XCTestCase {

    // MARK: - Engine Unit Tests (StreamingInferenceSession)

    func testStreamingSessionNotActiveWithoutModel() async {
        let engine = MLXSTTEngine()
        let isStreaming = await engine.isStreaming
        XCTAssertFalse(isStreaming, "Should not be streaming without a loaded model")
    }

    func testFeedAudioSafeWithoutSession() async {
        let engine = MLXSTTEngine()
        // Feeding audio without a session should not crash.
        await engine.feedStreamingAudio([Float](repeating: 0.1, count: 576))
        await engine.feedStreamingAudio([Float](repeating: 0.1, count: 576))
        let isStreaming = await engine.isStreaming
        XCTAssertFalse(isStreaming, "Should not be streaming after feeding without model")
    }

    func testResetStreamingClearsSession() async {
        let engine = MLXSTTEngine()
        await engine.feedStreamingAudio([Float](repeating: 0.1, count: 576))
        await engine.resetStreaming()
        let isStreaming = await engine.isStreaming
        XCTAssertFalse(isStreaming, "Should not be streaming after reset")
    }

    func testStartStreamingRequiresModel() async {
        let engine = MLXSTTEngine()
        // Without a loaded model, startStreamingSession should be a no-op.
        await engine.startStreamingSession()
        let isStreaming = await engine.isStreaming
        XCTAssertFalse(isStreaming, "Should not start streaming without a loaded model")
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

    // MARK: - Streaming Session Lifecycle

    func testMultipleResetsAreIdempotent() async {
        let engine = MLXSTTEngine()
        await engine.feedStreamingAudio([Float](repeating: 0.1, count: 1000))

        await engine.resetStreaming()
        await engine.resetStreaming()
        await engine.resetStreaming()

        let isStreaming = await engine.isStreaming
        XCTAssertFalse(isStreaming, "Multiple resets should leave engine in clean state")
    }

    func testCancelStreamingSessionSafe() async {
        let engine = MLXSTTEngine()
        // Cancel without ever starting should not crash.
        await engine.cancelStreamingSession()
        let isStreaming = await engine.isStreaming
        XCTAssertFalse(isStreaming)
    }

    func testStopStreamingSessionSafe() async {
        let engine = MLXSTTEngine()
        // Stop without ever starting should not crash.
        await engine.stopStreamingSession()
        let isStreaming = await engine.isStreaming
        XCTAssertFalse(isStreaming)
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

    func testPreprocessForASRDoesNotCrash() {
        // Verify audio preprocessing handles edge cases without crashing.
        var empty: [Float] = []
        MLXSTTEngine.preprocessForASR(&empty, sampleRate: 16000)
        XCTAssertTrue(empty.isEmpty)

        var silence = [Float](repeating: 0, count: 576)
        MLXSTTEngine.preprocessForASR(&silence, sampleRate: 16000)
        // All-zero input should remain all-zero (peak < 0.001 threshold).
        XCTAssertEqual(silence.reduce(0, +), 0, accuracy: 0.001)

        var normal = [Float](repeating: 0.5, count: 576)
        MLXSTTEngine.preprocessForASR(&normal, sampleRate: 16000)
        // Peak-normalized to 0.707 — all samples should be ~0.707.
        let peak = normal.lazy.map { abs($0) }.max() ?? 0
        XCTAssertLessThanOrEqual(peak, 0.71, "Peak should be normalized to ~-3dBFS")
    }
}
