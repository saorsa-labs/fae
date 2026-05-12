import XCTest
@testable import Fae

// MARK: - BargeInDecisions Tests (pure functions)

final class BargeInDecisionsTests: XCTestCase {

    // MARK: - shouldTrackBargeIn

    func testShouldTrackWhenSpeaking() {
        XCTAssertTrue(BargeInDecisions.shouldTrackBargeIn(assistantSpeaking: true))
    }

    func testShouldNotTrackWhenNotSpeaking() {
        XCTAssertFalse(BargeInDecisions.shouldTrackBargeIn(assistantSpeaking: false))
    }

    // MARK: - shouldTrackGenerationTakeover

    func testTrackTakeoverWhenGeneratingSilently() {
        XCTAssertTrue(BargeInDecisions.shouldTrackGenerationTakeover(
            assistantSpeaking: false,
            assistantGenerating: true
        ))
    }

    func testNotTrackTakeoverWhenSpeaking() {
        XCTAssertFalse(BargeInDecisions.shouldTrackGenerationTakeover(
            assistantSpeaking: true,
            assistantGenerating: true
        ))
    }

    func testNotTrackTakeoverWhenNotGenerating() {
        XCTAssertFalse(BargeInDecisions.shouldTrackGenerationTakeover(
            assistantSpeaking: false,
            assistantGenerating: false
        ))
    }

    // MARK: - shouldAllowBargeInInterrupt

    func testAllowInterruptWhenSpeaking() {
        XCTAssertTrue(BargeInDecisions.shouldAllowBargeInInterrupt(
            assistantSpeaking: true,
            assistantGenerating: true
        ))
    }

    func testDisallowInterruptWhenNotSpeaking() {
        XCTAssertFalse(BargeInDecisions.shouldAllowBargeInInterrupt(
            assistantSpeaking: false,
            assistantGenerating: true
        ))
    }

    // MARK: - shouldStartDeferredFollowUp

    func testStartFollowUpWhenIdleNoOrigin() {
        XCTAssertTrue(BargeInDecisions.shouldStartDeferredFollowUp(
            originTurnID: nil,
            currentTurnID: "turn-1",
            assistantSpeaking: false,
            assistantGenerating: false
        ))
    }

    func testBlockFollowUpWhenSpeaking() {
        XCTAssertFalse(BargeInDecisions.shouldStartDeferredFollowUp(
            originTurnID: "turn-1",
            currentTurnID: "turn-1",
            assistantSpeaking: true,
            assistantGenerating: false
        ))
    }

    func testBlockFollowUpWhenGenerating() {
        XCTAssertFalse(BargeInDecisions.shouldStartDeferredFollowUp(
            originTurnID: "turn-1",
            currentTurnID: "turn-1",
            assistantSpeaking: false,
            assistantGenerating: true
        ))
    }

    func testAllowFollowUpWhenTurnMatches() {
        XCTAssertTrue(BargeInDecisions.shouldStartDeferredFollowUp(
            originTurnID: "turn-1",
            currentTurnID: "turn-1",
            assistantSpeaking: false,
            assistantGenerating: false
        ))
    }

    func testBlockFollowUpWhenTurnMismatch() {
        XCTAssertFalse(BargeInDecisions.shouldStartDeferredFollowUp(
            originTurnID: "turn-1",
            currentTurnID: "turn-2",
            assistantSpeaking: false,
            assistantGenerating: false
        ))
    }

    // MARK: - coalescedDeferredProactiveTaskIDs

    func testCoalesceAddsNewTask() {
        let result = BargeInDecisions.coalescedDeferredProactiveTaskIDs(
            existing: ["task-1"],
            incomingTaskID: "task-2"
        )
        XCTAssertEqual(result, ["task-1", "task-2"])
    }

    func testCoalesceDeduplicates() {
        let result = BargeInDecisions.coalescedDeferredProactiveTaskIDs(
            existing: ["task-1", "task-2"],
            incomingTaskID: "task-1"
        )
        XCTAssertEqual(result, ["task-2", "task-1"])
    }

    func testCoalesceEmptyExisting() {
        let result = BargeInDecisions.coalescedDeferredProactiveTaskIDs(
            existing: [],
            incomingTaskID: "task-1"
        )
        XCTAssertEqual(result, ["task-1"])
    }

    func testCoalesceRemovesAllDuplicates() {
        let result = BargeInDecisions.coalescedDeferredProactiveTaskIDs(
            existing: ["task-1", "task-1", "task-2"],
            incomingTaskID: "task-1"
        )
        XCTAssertEqual(result, ["task-2", "task-1"])
    }

    // MARK: - advancePendingBargeIn

    func testCreateNewCandidateWhenSpeechStarts() {
        let result = BargeInDecisions.advancePendingBargeIn(
            pending: nil,
            speechStarted: true,
            isSpeech: true,
            chunkSamples: [0.1, 0.2, 0.3],
            rms: 0.5,
            echoSuppression: false,
            bargeInSuppressed: false,
            inDenyCooldown: false
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.lastRms, 0.5)
        XCTAssertEqual(result?.peakRms, 0.5)
    }

    func testNoCandidateWhenEchoSuppressed() {
        let result = BargeInDecisions.advancePendingBargeIn(
            pending: nil,
            speechStarted: true,
            isSpeech: true,
            chunkSamples: [0.1],
            rms: 0.5,
            echoSuppression: true,
            bargeInSuppressed: false,
            inDenyCooldown: false
        )
        XCTAssertNil(result)
    }

    func testNoCandidateWhenBargeInSuppressed() {
        let result = BargeInDecisions.advancePendingBargeIn(
            pending: nil,
            speechStarted: true,
            isSpeech: true,
            chunkSamples: [0.1],
            rms: 0.5,
            echoSuppression: false,
            bargeInSuppressed: true,
            inDenyCooldown: false
        )
        XCTAssertNil(result)
    }

    func testNoCandidateWhenInDenyCooldown() {
        let result = BargeInDecisions.advancePendingBargeIn(
            pending: nil,
            speechStarted: true,
            isSpeech: true,
            chunkSamples: [0.1],
            rms: 0.5,
            echoSuppression: false,
            bargeInSuppressed: false,
            inDenyCooldown: true
        )
        XCTAssertNil(result)
    }

    func testAdvanceExistingCandidate() {
        var existing = PendingBargeIn(capturedAt: Date(), lastRms: 0.3, peakRms: 0.4)
        let result = BargeInDecisions.advancePendingBargeIn(
            pending: existing,
            speechStarted: false,
            isSpeech: true,
            chunkSamples: Array(repeating: Float(0.1), count: 100),
            rms: 0.6,
            echoSuppression: false,
            bargeInSuppressed: false,
            inDenyCooldown: false
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.speechSamples, 100)
        XCTAssertEqual(result?.lastRms, 0.6)
        XCTAssertEqual(result?.peakRms, 0.6) // Higher than previous 0.4
        XCTAssertEqual(result?.consecutiveSpeechChunks, 1)
    }

    func testPeakRmsTracksMaximum() {
        var existing = PendingBargeIn(capturedAt: Date(), peakRms: 0.9)
        let result = BargeInDecisions.advancePendingBargeIn(
            pending: existing,
            speechStarted: false,
            isSpeech: true,
            chunkSamples: Array(repeating: Float(0.1), count: 50),
            rms: 0.3, // Lower than peak
            echoSuppression: false,
            bargeInSuppressed: false,
            inDenyCooldown: false
        )
        XCTAssertEqual(result?.peakRms, 0.9) // Should keep the higher value
    }

    func testNonSpeechResetsConsecutiveChunks() {
        var existing = PendingBargeIn(capturedAt: Date())
        existing.consecutiveSpeechChunks = 5
        let result = BargeInDecisions.advancePendingBargeIn(
            pending: existing,
            speechStarted: false,
            isSpeech: false,
            chunkSamples: [],
            rms: 0.01,
            echoSuppression: false,
            bargeInSuppressed: false,
            inDenyCooldown: false
        )
        XCTAssertEqual(result?.consecutiveSpeechChunks, 0)
    }

    func testAudioSamplesCappedAt16k() {
        var existing = PendingBargeIn(capturedAt: Date())
        existing.audioSamples = Array(repeating: Float(0.0), count: 15_900)
        let chunk = Array(repeating: Float(0.1), count: 2_000)
        let result = BargeInDecisions.advancePendingBargeIn(
            pending: existing,
            speechStarted: false,
            isSpeech: true,
            chunkSamples: chunk,
            rms: 0.5,
            echoSuppression: false,
            bargeInSuppressed: false,
            inDenyCooldown: false
        )
        // Should cap at 16,000 total
        XCTAssertLessThanOrEqual(result?.audioSamples.count ?? 0, 16_000)
    }

    func testNilPendingWithNoSpeechStart() {
        let result = BargeInDecisions.advancePendingBargeIn(
            pending: nil,
            speechStarted: false,
            isSpeech: true,
            chunkSamples: [0.1],
            rms: 0.5,
            echoSuppression: false,
            bargeInSuppressed: false,
            inDenyCooldown: false
        )
        XCTAssertNil(result)
    }
}

// MARK: - BargeInState Tests

final class BargeInStateTests: XCTestCase {

    private func makeState() -> BargeInState {
        BargeInState(
            interruptionDecider: LegacyThresholdInterruptionDecider(),
            falseInterruptionRecovery: FalseInterruptionRecovery(timeoutMs: 1800, enabled: true)
        )
    }

    func testDefaultValues() {
        let state = makeState()
        XCTAssertNil(state.pendingBargeIn)
        XCTAssertFalse(state.isSuppressed)
        XCTAssertNil(state.playbackCandidate)
        XCTAssertFalse(state.playbackWakeWordDetected)
        XCTAssertFalse(state.playbackInterruptKeywordDetected)
        XCTAssertNil(state.denyCooldownUntil)
        XCTAssertNil(state.pendingNarrationReceiptId)
        XCTAssertNil(state.generationTakeoverCandidate)
        XCTAssertEqual(state.lastAssistantTextBuffer, "")
    }

    func testDenyCooldownSeconds() {
        XCTAssertEqual(BargeInState.denyCooldownSeconds, 2.0)
    }

    func testIsInDenyCooldownFalseByDefault() {
        let state = makeState()
        XCTAssertFalse(state.isInDenyCooldown)
    }

    func testStartDenyCooldown() {
        var state = makeState()
        state.startDenyCooldown()
        XCTAssertTrue(state.isInDenyCooldown)
    }

    func testDenyCooldownExpires() async {
        var state = makeState()
        state.startDenyCooldown()
        XCTAssertTrue(state.isInDenyCooldown)
        // Wait for cooldown to expire
        try? await Task.sleep(nanoseconds: 2_500_000_000) // 2.5s
        XCTAssertFalse(state.isInDenyCooldown)
    }

    func testResetPlaybackState() {
        var state = makeState()
        state.playbackCandidate = PlaybackBargeInCandidate(capturedAt: Date())
        state.playbackWakeWordDetected = true
        state.playbackInterruptKeywordDetected = true

        state.resetPlaybackState()

        XCTAssertNil(state.playbackCandidate)
        XCTAssertFalse(state.playbackWakeWordDetected)
        XCTAssertFalse(state.playbackInterruptKeywordDetected)
    }

    func testClearAll() {
        var state = makeState()
        state.pendingBargeIn = PendingBargeIn(capturedAt: Date())
        state.isSuppressed = true
        state.playbackCandidate = PlaybackBargeInCandidate(capturedAt: Date())
        state.playbackWakeWordDetected = true
        state.playbackInterruptKeywordDetected = true
        state.startDenyCooldown()
        state.generationTakeoverCandidate = GenerationTakeoverCandidate()
        state.lastAssistantTextBuffer = "some text"
        state.pendingNarrationReceiptId = "receipt-1"

        state.clearAll()

        XCTAssertNil(state.pendingBargeIn)
        XCTAssertFalse(state.isSuppressed)
        XCTAssertNil(state.playbackCandidate)
        XCTAssertFalse(state.playbackWakeWordDetected)
        XCTAssertFalse(state.playbackInterruptKeywordDetected)
        XCTAssertNil(state.denyCooldownUntil)
        XCTAssertNil(state.generationTakeoverCandidate)
        XCTAssertEqual(state.lastAssistantTextBuffer, "")
        XCTAssertNil(state.pendingNarrationReceiptId)
    }

    func testSetSuppression() {
        var state = makeState()
        state.isSuppressed = true
        XCTAssertTrue(state.isSuppressed)
        state.isSuppressed = false
        XCTAssertFalse(state.isSuppressed)
    }

    func testSetPendingNarrationReceiptId() {
        var state = makeState()
        state.pendingNarrationReceiptId = "receipt-42"
        XCTAssertEqual(state.pendingNarrationReceiptId, "receipt-42")
    }
}
