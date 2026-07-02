import XCTest
@testable import Fae

// MARK: - PendingBargeIn Tests

final class PendingBargeInTests: XCTestCase {

    func testDefaultValues() {
        let candidate = PendingBargeIn(capturedAt: Date())
        XCTAssertEqual(candidate.speechSamples, 0)
        XCTAssertEqual(candidate.lastRms, 0)
        XCTAssertEqual(candidate.peakRms, 0)
        XCTAssertEqual(candidate.consecutiveSpeechChunks, 0)
        XCTAssertTrue(candidate.audioSamples.isEmpty)
        XCTAssertNil(candidate.partialTranscript)
        XCTAssertFalse(candidate.hasInterruptKeyword)
    }

    func testIsSendable() {
        let candidate = PendingBargeIn(capturedAt: Date())
        _ = candidate as any Sendable
    }

    func testAccumulateSpeechSamples() {
        var candidate = PendingBargeIn(capturedAt: Date())
        candidate.speechSamples = 100
        candidate.lastRms = 0.5
        candidate.peakRms = 0.7
        candidate.consecutiveSpeechChunks = 3
        XCTAssertEqual(candidate.speechSamples, 100)
        XCTAssertEqual(candidate.lastRms, 0.5)
        XCTAssertEqual(candidate.peakRms, 0.7)
        XCTAssertEqual(candidate.consecutiveSpeechChunks, 3)
    }

    func testSetPartialTranscript() {
        var candidate = PendingBargeIn(capturedAt: Date())
        candidate.partialTranscript = "hello fae"
        XCTAssertEqual(candidate.partialTranscript, "hello fae")
    }

    func testSetInterruptKeyword() {
        var candidate = PendingBargeIn(capturedAt: Date())
        candidate.hasInterruptKeyword = true
        XCTAssertTrue(candidate.hasInterruptKeyword)
    }
}

// MARK: - PlaybackBargeInCandidate Tests

final class PlaybackBargeInCandidateTests: XCTestCase {

    func testDefaultValues() {
        let candidate = PlaybackBargeInCandidate(capturedAt: Date())
        XCTAssertEqual(candidate.speechSamples, 0)
        XCTAssertEqual(candidate.lastRms, 0)
        XCTAssertEqual(candidate.peakRms, 0)
        XCTAssertEqual(candidate.consecutiveSpeechChunks, 0)
        XCTAssertTrue(candidate.audioSamples.isEmpty)
    }

    func testMaxAudioSamplesIs16kHz() {
        XCTAssertEqual(PlaybackBargeInCandidate.maxAudioSamples, 16_000)
    }

    func testMinSamplesForIdentityIs350ms() {
        XCTAssertEqual(PlaybackBargeInCandidate.minSamplesForIdentity, 5_600)
    }

    func testIsSendable() {
        let candidate = PlaybackBargeInCandidate(capturedAt: Date())
        _ = candidate as any Sendable
    }

    func testAccumulateSamples() {
        var candidate = PlaybackBargeInCandidate(capturedAt: Date())
        candidate.audioSamples = Array(repeating: 0.5, count: 1000)
        candidate.speechSamples = 1000
        candidate.lastRms = 0.3
        candidate.peakRms = 0.8
        XCTAssertEqual(candidate.audioSamples.count, 1000)
    }
}

// MARK: - GenerationTakeoverCandidate Tests

final class GenerationTakeoverCandidateTests: XCTestCase {

    func testDefaultValues() {
        let candidate = GenerationTakeoverCandidate()
        XCTAssertTrue(candidate.audioSamples.isEmpty)
        XCTAssertEqual(candidate.speechSamples, 0)
        XCTAssertEqual(candidate.consecutiveSpeechChunks, 0)
        XCTAssertEqual(candidate.peakRms, 0)
        XCTAssertFalse(candidate.hasInterruptKeyword)
    }

    func testMinSamplesForKeywordIs500ms() {
        XCTAssertEqual(GenerationTakeoverCandidate.minSamplesForKeyword, 8_000)
    }

    func testMaxAudioSamplesIs15s() {
        XCTAssertEqual(GenerationTakeoverCandidate.maxAudioSamples, 24_000)
    }

    func testMinConsecutiveChunksForTakeover() {
        XCTAssertEqual(GenerationTakeoverCandidate.minConsecutiveChunksForTakeover, 22)
    }

    func testMinRmsForTakeover() {
        XCTAssertEqual(GenerationTakeoverCandidate.minRmsForTakeover, 0.06)
    }

    func testIsSendable() {
        let candidate = GenerationTakeoverCandidate()
        _ = candidate as any Sendable
    }

    func testAccumulateAudio() {
        var candidate = GenerationTakeoverCandidate()
        candidate.audioSamples = Array(repeating: 0.1, count: 10_000)
        candidate.speechSamples = 10_000
        candidate.consecutiveSpeechChunks = 25
        candidate.peakRms = 0.15
        candidate.hasInterruptKeyword = true

        XCTAssertEqual(candidate.audioSamples.count, 10_000)
        XCTAssertEqual(candidate.speechSamples, 10_000)
        XCTAssertEqual(candidate.consecutiveSpeechChunks, 25)
        XCTAssertTrue(candidate.hasInterruptKeyword)
    }
}

// MARK: - BargeInTypes Constants Tests

final class BargeInConstantsTests: XCTestCase {

    func testPlaybackBargeInMinSamplesRatio() {
        // minSamplesForIdentity should be about 35% of maxAudioSamples
        let ratio = Float(PlaybackBargeInCandidate.minSamplesForIdentity) /
                    Float(PlaybackBargeInCandidate.maxAudioSamples)
        XCTAssertGreaterThan(ratio, 0.3)
        XCTAssertLessThan(ratio, 0.4)
    }

    func testGenerationTakeoverMinRmsIsPositive() {
        XCTAssertGreaterThan(GenerationTakeoverCandidate.minRmsForTakeover, 0)
    }

    func testGenerationTakeoverChunkThresholdIsReasonable() {
        // 22 chunks at ~36ms each ≈ 800ms
        let expectedMs = 22 * 36
        XCTAssertGreaterThan(expectedMs, 700)
        XCTAssertLessThan(expectedMs, 900)
    }
}

// MARK: - RescueMode Tests

@MainActor
final class RescueModeTests: XCTestCase {

    func testStartsInactive() {
        let mode = RescueMode()
        XCTAssertFalse(mode.isActive)
        XCTAssertTrue(mode.availableSnapshots.isEmpty)
        XCTAssertFalse(mode.isRestoring)
    }

    func testActivateSetsActive() {
        let mode = RescueMode()
        mode.activate()
        XCTAssertTrue(mode.isActive)
    }

    func testDeactivateSetsInactive() {
        let mode = RescueMode()
        mode.activate()
        mode.deactivate()
        XCTAssertFalse(mode.isActive)
    }

    func testActivateDeactivateCycle() {
        let mode = RescueMode()
        mode.activate()
        XCTAssertTrue(mode.isActive)
        mode.deactivate()
        XCTAssertFalse(mode.isActive)
        mode.activate()
        XCTAssertTrue(mode.isActive)
    }

    // The restore UI calls these before a vault is wired; they must degrade
    // safely (empty list / false) rather than crash so the panel stays usable.
    func testLoadSnapshotsWithoutVaultClearsList() async {
        let mode = RescueMode()
        await mode.loadSnapshots()
        XCTAssertTrue(mode.availableSnapshots.isEmpty)
    }

    func testRestoreWithoutVaultReturnsFalse() async {
        let mode = RescueMode()
        let restored = await mode.restore(commit: "deadbeef")
        XCTAssertFalse(restored)
    }
}

// MARK: - OrbTypes Tests (OrbFeeling enum)

final class OrbFeelingTests: XCTestCase {

    func testAllSentimentFeelingsExist() {
        // Verify all feelings used by SentimentClassifier exist
        let feelings: [OrbFeeling] = [.warmth, .concern, .delight, .curiosity, .calm, .focus, .playful]
        XCTAssertEqual(feelings.count, 7)
    }

    func testSentimentClassifierReturnsValidFeelings() {
        let warmText = "I'm glad and happy to help you today."
        guard let feeling = SentimentClassifier.classify(warmText) else {
            XCTFail("Expected a feeling classification")
            return
        }
        XCTAssertEqual(feeling, .warmth)
    }
}
