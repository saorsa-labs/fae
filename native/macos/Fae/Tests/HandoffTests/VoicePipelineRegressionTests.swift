import XCTest
@testable import Fae

final class VoicePipelineRegressionTests: XCTestCase {

    func testVadApplyConfigurationRecalculatesDerivedThresholds() {
        var vad = VoiceActivityDetector(sampleRate: 16_000)
        var config = FaeConfig.VadConfig()
        config.minSilenceDurationMs = 640
        config.speechPadMs = 96
        config.minSpeechDurationMs = 320
        config.maxSpeechDurationMs = 2_400

        vad.applyConfiguration(config)
        let derived = vad.debugDerivedThresholds

        XCTAssertEqual(derived.preRollMax, 1_536)
        XCTAssertEqual(derived.silenceSamplesThreshold, 10_240)
        XCTAssertEqual(derived.minSpeechSamples, 5_120)
        XCTAssertEqual(derived.maxSpeechSamples, 38_400)
    }

    func testBargeInCandidateAccumulatesAcrossSpeechChunks() {
        let chunk = [Float](repeating: 0.12, count: 512)

        var pending = PipelineCoordinator.advancePendingBargeIn(
            pending: nil,
            speechStarted: true,
            isSpeech: true,
            chunkSamples: chunk,
            rms: 0.12,
            echoSuppression: false,
            bargeInSuppressed: false,
            inDenyCooldown: false
        )
        XCTAssertEqual(pending?.speechSamples, 512)
        XCTAssertEqual(pending?.audioSamples.count, 512)

        pending = PipelineCoordinator.advancePendingBargeIn(
            pending: pending,
            speechStarted: false,
            isSpeech: true,
            chunkSamples: chunk,
            rms: 0.11,
            echoSuppression: false,
            bargeInSuppressed: false,
            inDenyCooldown: false
        )
        XCTAssertEqual(pending?.speechSamples, 1_024)
        XCTAssertEqual(pending?.audioSamples.count, 1_024)
        XCTAssertEqual(Double(pending?.lastRms ?? 0), 0.11, accuracy: 0.0001)
    }

    func testDeferredFollowUpStartsOnlyForSameTurnWhenIdle() {
        XCTAssertTrue(
            PipelineCoordinator.shouldStartDeferredFollowUp(
                originTurnID: "turn-a",
                currentTurnID: "turn-a",
                assistantSpeaking: false,
                assistantGenerating: false
            )
        )
        XCTAssertFalse(
            PipelineCoordinator.shouldStartDeferredFollowUp(
                originTurnID: "turn-a",
                currentTurnID: "turn-b",
                assistantSpeaking: false,
                assistantGenerating: false
            )
        )
        XCTAssertFalse(
            PipelineCoordinator.shouldStartDeferredFollowUp(
                originTurnID: "turn-a",
                currentTurnID: "turn-a",
                assistantSpeaking: false,
                assistantGenerating: true
            )
        )
    }
}
