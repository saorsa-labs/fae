import XCTest
@testable import Fae

// MARK: - Helper: create InterruptionInput

private func makeInterruptionInput(
    assistantSpeaking: Bool = true,
    speechStarted: Bool = true,
    isSpeech: Bool = true,
    rms: Float = 0.5,
    chunkSamples: [Float] = [],
    overlapDurationMs: Int = 500,
    assistantSpeechElapsedMs: Int = 500,
    echoSuppression: Bool = false,
    bargeInSuppressed: Bool = false,
    inDenyCooldown: Bool = false,
    peakRms: Float = 0.5,
    consecutiveSpeechChunks: Int = 5,
    partialTranscript: String? = nil,
    partialWordCount: Int = 0,
    hasInterruptKeyword: Bool = false
) -> InterruptionInput {
    InterruptionInput(
        assistantSpeaking: assistantSpeaking,
        speechStarted: speechStarted,
        isSpeech: isSpeech,
        rms: rms,
        chunkSamples: chunkSamples,
        overlapDurationMs: overlapDurationMs,
        assistantSpeechElapsedMs: assistantSpeechElapsedMs,
        echoSuppression: echoSuppression,
        bargeInSuppressed: bargeInSuppressed,
        inDenyCooldown: inDenyCooldown,
        peakRms: peakRms,
        consecutiveSpeechChunks: consecutiveSpeechChunks,
        partialTranscript: partialTranscript,
        partialWordCount: partialWordCount,
        hasInterruptKeyword: hasInterruptKeyword
    )
}

private func makeInterruptionOutcome(interruptedText: String? = "Hello world") -> InterruptionOutcome {
    InterruptionOutcome(
        interruptedAt: Date(),
        generationID: UUID(),
        interruptedText: interruptedText,
        spokenFraction: 0.5
    )
}

// MARK: - FalseInterruptionRecovery Tests

final class FalseInterruptionRecoveryTests: XCTestCase {

    private func makeRecovery(timeoutMs: Int = 1800, enabled: Bool = true) -> FalseInterruptionRecovery {
        FalseInterruptionRecovery(timeoutMs: timeoutMs, enabled: enabled)
    }

    func testDefaultState() {
        let r = makeRecovery()
        XCTAssertNil(r.lastInterruption)
        XCTAssertFalse(r.observing)
        XCTAssertFalse(r.playbackWasPaused)
    }

    func testDisabledDoesNotRecord() {
        var r = makeRecovery(enabled: false)
        r.recordInterruption(outcome: makeInterruptionOutcome())
        XCTAssertFalse(r.observing)
        XCTAssertNil(r.lastInterruption)
    }

    func testDisabledReturnsNoAction() {
        var r = makeRecovery(enabled: false)
        XCTAssertEqual(r.checkTimeout(), .noAction)
    }

    func testRecordStartsObserving() {
        var r = makeRecovery()
        r.recordInterruption(outcome: makeInterruptionOutcome())
        XCTAssertTrue(r.observing)
        XCTAssertNotNil(r.lastInterruption)
    }

    func testRecordWithPausedTrue() {
        var r = makeRecovery()
        r.recordInterruption(outcome: makeInterruptionOutcome(), paused: true)
        XCTAssertTrue(r.playbackWasPaused)
    }

    func testRecordWithPausedFalse() {
        var r = makeRecovery()
        r.recordInterruption(outcome: makeInterruptionOutcome(), paused: false)
        XCTAssertFalse(r.playbackWasPaused)
    }

    func testFollowUpStopsObserving() {
        var r = makeRecovery()
        r.recordInterruption(outcome: makeInterruptionOutcome())
        r.recordFollowUpSpeech()
        XCTAssertFalse(r.observing)
        XCTAssertFalse(r.playbackWasPaused)
    }

    func testNoActionWhenNotObserving() {
        var r = makeRecovery()
        XCTAssertEqual(r.checkTimeout(), .noAction)
    }

    func testStillObservingBeforeTimeout() {
        var r = makeRecovery(timeoutMs: 5000)
        r.recordInterruption(outcome: makeInterruptionOutcome())
        let now = Date().addingTimeInterval(1)
        XCTAssertEqual(r.checkTimeout(now: now), .stillObserving)
    }

    func testResumePlaybackWhenPausedAndTimeout() {
        var r = makeRecovery(timeoutMs: 100)
        r.recordInterruption(outcome: makeInterruptionOutcome(), paused: true)
        let after = Date().addingTimeInterval(1)
        XCTAssertEqual(r.checkTimeout(now: after), .resumePlayback)
    }

    func testFalseInterruptionWhenNotPausedAndTimeout() {
        var r = makeRecovery(timeoutMs: 100)
        r.recordInterruption(outcome: makeInterruptionOutcome(interruptedText: "Hello world"), paused: false)
        let after = Date().addingTimeInterval(1)
        switch r.checkTimeout(now: after) {
        case .falseInterruption(let repair):
            XCTAssertFalse(repair.isEmpty)
        default:
            XCTFail("Expected falseInterruption")
        }
    }

    func testFollowUpPreventsFalseInterruption() {
        var r = makeRecovery(timeoutMs: 100)
        r.recordInterruption(outcome: makeInterruptionOutcome(), paused: false)
        r.recordFollowUpSpeech()
        let after = Date().addingTimeInterval(1)
        XCTAssertEqual(r.checkTimeout(now: after), .noAction)
    }

    func testCancelStopsObserving() {
        var r = makeRecovery()
        r.recordInterruption(outcome: makeInterruptionOutcome())
        r.cancel()
        XCTAssertFalse(r.observing)
        XCTAssertFalse(r.playbackWasPaused)
    }

    // MARK: - buildRepairUtterance

    func testRepairWithNilText() {
        let repair = FalseInterruptionRecovery.buildRepairUtterance(interruptedText: nil)
        XCTAssertTrue(repair.contains("Sorry"))
        XCTAssertTrue(repair.contains("jumping in"))
    }

    func testRepairWithEmptyText() {
        let repair = FalseInterruptionRecovery.buildRepairUtterance(interruptedText: "")
        XCTAssertTrue(repair.contains("Sorry"))
    }

    func testRepairWithShortText() {
        let repair = FalseInterruptionRecovery.buildRepairUtterance(interruptedText: "Hello world")
        XCTAssertTrue(repair.contains("Hello world"))
        XCTAssertTrue(repair.contains("jumping in"))
    }

    func testRepairWithFiveWords() {
        let repair = FalseInterruptionRecovery.buildRepairUtterance(interruptedText: "One two three four five")
        XCTAssertTrue(repair.contains("One two three four five"))
    }

    func testRepairWithLongTextTruncates() {
        let longText = "This is a very long sentence with many words that should be truncated to show only the last eight words"
        let repair = FalseInterruptionRecovery.buildRepairUtterance(interruptedText: longText)
        XCTAssertTrue(repair.contains("…"))
        XCTAssertFalse(repair.contains("This is a very"))
        XCTAssertTrue(repair.contains("last eight words"))
    }

    // MARK: - Result equatable

    func testResultEquatable() {
        XCTAssertEqual(FalseInterruptionResult.noAction, .noAction)
        XCTAssertEqual(FalseInterruptionResult.stillObserving, .stillObserving)
        XCTAssertEqual(FalseInterruptionResult.resumePlayback, .resumePlayback)
        XCTAssertEqual(FalseInterruptionResult.falseInterruption(repair: "x"), .falseInterruption(repair: "x"))
        XCTAssertNotEqual(FalseInterruptionResult.noAction, .stillObserving)
    }

    func testIsSendable() {
        let r = makeRecovery()
        _ = r as any Sendable
    }
}

// MARK: - InterruptionOutcome Tests

final class InterruptionOutcomeTests: XCTestCase {

    func testCreateWithText() {
        let o = InterruptionOutcome(interruptedAt: Date(), generationID: UUID(), interruptedText: "hello", spokenFraction: 0.3)
        XCTAssertEqual(o.interruptedText, "hello")
        XCTAssertEqual(o.spokenFraction, 0.3)
    }

    func testCreateWithNilText() {
        let o = InterruptionOutcome(interruptedAt: Date(), generationID: nil, interruptedText: nil, spokenFraction: 0)
        XCTAssertNil(o.interruptedText)
        XCTAssertNil(o.generationID)
    }

    func testIsSendable() {
        let o = InterruptionOutcome(interruptedAt: Date(), generationID: UUID(), interruptedText: "t", spokenFraction: 0.5)
        _ = o as any Sendable
    }
}

// MARK: - BackchannelClassifier Tests

final class BackchannelClassifierTests: XCTestCase {

    func testDetectsBackchannels() {
        XCTAssertTrue(BackchannelClassifier.isBackchannel("yeah"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("mm"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("uh-huh"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("yep"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("ok"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("sure"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("wow"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("hmm"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("gotcha"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("nice"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("cool"))
    }

    func testDetectsFillers() {
        XCTAssertTrue(BackchannelClassifier.isBackchannel("um"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("uh"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("er"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("erm"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("eh"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("like"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("so"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("well"))
    }

    func testDetectsNonSpeechSounds() {
        XCTAssertTrue(BackchannelClassifier.isBackchannel("oh"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("ooh"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("aah"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("ha"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("hm"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("ugh"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("phew"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("whoa"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("oops"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("heh"))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(BackchannelClassifier.isBackchannel("YEAH"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("Yeah"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("OK"))
    }

    func testStripsPunctuation() {
        XCTAssertTrue(BackchannelClassifier.isBackchannel("yeah!"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("ok."))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("wow?"))
        // Compound utterances are not pure backchannels — the user is
        // actually speaking, so they may trigger an interrupt.
        XCTAssertFalse(BackchannelClassifier.isBackchannel("sure, yeah."))
    }

    func testTrimsWhitespace() {
        XCTAssertTrue(BackchannelClassifier.isBackchannel("  yeah  "))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("\tyep\n"))
    }

    func testRejectsNil() {
        XCTAssertFalse(BackchannelClassifier.isBackchannel(nil))
    }

    func testRejectsEmpty() {
        XCTAssertFalse(BackchannelClassifier.isBackchannel(""))
    }

    func testRejectsNonBackchannel() {
        XCTAssertFalse(BackchannelClassifier.isBackchannel("stop fae"))
        XCTAssertFalse(BackchannelClassifier.isBackchannel("I need help with my code"))
        XCTAssertFalse(BackchannelClassifier.isBackchannel("open the file please"))
    }

    func testRejectsMultiWordNonBackchannel() {
        XCTAssertFalse(BackchannelClassifier.isBackchannel("yeah I think so"))
        XCTAssertFalse(BackchannelClassifier.isBackchannel("ok but wait"))
    }

    func testPhrasesSetIsNotEmpty() {
        XCTAssertGreaterThan(BackchannelClassifier.phrases.count, 20)
    }

    func testYouKnowAndIMean() {
        XCTAssertTrue(BackchannelClassifier.isBackchannel("you know"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("i mean"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("let me"))
    }
}

// MARK: - AdaptiveInterruptionConfig Tests

final class AdaptiveInterruptionConfigTests: XCTestCase {

    func testDefaultValues() {
        let config = AdaptiveInterruptionConfig()
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.minOverlapMs, 150)
        XCTAssertEqual(config.rmsSustainFloor, 0.04)
        XCTAssertEqual(config.minSustainedChunks, 2)
        XCTAssertEqual(config.falseInterruptionTimeoutMs, 1200)
        XCTAssertTrue(config.recoverFalseInterruptions)
        XCTAssertEqual(config.peakRmsRatio, 1.2)
    }

    func testIsCodable() {
        var config = AdaptiveInterruptionConfig()
        config.enabled = false
        config.minOverlapMs = 300

        let data = try! JSONEncoder().encode(config)
        let decoded = try! JSONDecoder().decode(AdaptiveInterruptionConfig.self, from: data)
        XCTAssertFalse(decoded.enabled)
        XCTAssertEqual(decoded.minOverlapMs, 300)
    }

    func testIsSendable() {
        let config = AdaptiveInterruptionConfig()
        _ = config as any Sendable
    }

    func testCustomValues() {
        var config = AdaptiveInterruptionConfig()
        config.enabled = false
        config.minOverlapMs = 500
        config.rmsSustainFloor = 0.1
        config.minSustainedChunks = 5
        config.falseInterruptionTimeoutMs = 3000
        config.recoverFalseInterruptions = false
        config.peakRmsRatio = 2.0

        XCTAssertFalse(config.enabled)
        XCTAssertEqual(config.minOverlapMs, 500)
        XCTAssertEqual(config.rmsSustainFloor, 0.1)
        XCTAssertEqual(config.minSustainedChunks, 5)
        XCTAssertEqual(config.falseInterruptionTimeoutMs, 3000)
        XCTAssertFalse(config.recoverFalseInterruptions)
        XCTAssertEqual(config.peakRmsRatio, 2.0)
    }
}

// MARK: - LegacyThresholdInterruptionDecider Tests

final class LegacyThresholdInterruptionDeciderTests: XCTestCase {

    func testDefaultInit() {
        let _ = LegacyThresholdInterruptionDecider()
    }

    func testIgnoreWhenBargeInSuppressed() {
        var d = LegacyThresholdInterruptionDecider()
        let input = makeInterruptionInput(bargeInSuppressed: true)
        switch d.process(input) {
        case .ignore(let reason): XCTAssertEqual(reason, "barge_in_suppressed")
        default: XCTFail("Expected ignore")
        }
    }

    func testIgnoreWhenInDenyCooldown() {
        var d = LegacyThresholdInterruptionDecider()
        let input = makeInterruptionInput(inDenyCooldown: true)
        switch d.process(input) {
        case .ignore(let reason): XCTAssertEqual(reason, "deny_cooldown")
        default: XCTFail("Expected ignore")
        }
    }

    func testIgnoreWhenNotSpeaking() {
        var d = LegacyThresholdInterruptionDecider()
        let input = makeInterruptionInput(assistantSpeaking: false)
        switch d.process(input) {
        case .ignore(let reason): XCTAssertEqual(reason, "not_speaking")
        default: XCTFail("Expected ignore")
        }
    }

    func testIgnoreDuringHoldoff() {
        var d = LegacyThresholdInterruptionDecider()
        let input = makeInterruptionInput(assistantSpeechElapsedMs: 100)
        switch d.process(input) {
        case .ignore(let reason): XCTAssertEqual(reason, "holdoff_window")
        default: XCTFail("Expected ignore")
        }
    }

    func testIgnoreBelowRMS() {
        var d = LegacyThresholdInterruptionDecider()
        let input = makeInterruptionInput(rms: 0.01)
        switch d.process(input) {
        case .ignore(let reason): XCTAssertEqual(reason, "below_rms_threshold")
        default: XCTFail("Expected ignore")
        }
    }

    func testInterruptWhenThresholdMet() {
        var d = LegacyThresholdInterruptionDecider(confirmMs: 200, minRms: 0.08)
        let input = makeInterruptionInput(overlapDurationMs: 300)
        switch d.process(input) {
        case .interruptNow: break
        default: XCTFail("Expected interruptNow")
        }
    }

    func testCandidateWhenBelowConfirmTime() {
        var d = LegacyThresholdInterruptionDecider(confirmMs: 500, minRms: 0.08)
        let input = makeInterruptionInput(overlapDurationMs: 200)
        switch d.process(input) {
        case .candidate: break
        default: XCTFail("Expected candidate")
        }
    }

    func testEchoSuppressionDoublesConfirmTime() {
        var d = LegacyThresholdInterruptionDecider(confirmMs: 200, minRms: 0.08)
        let input = makeInterruptionInput(overlapDurationMs: 300, echoSuppression: true)
        switch d.process(input) {
        case .candidate: break // 300ms < 400ms doubled threshold
        default: XCTFail("Expected candidate with echo")
        }
    }

    func testResetDoesNotCrash() {
        var d = LegacyThresholdInterruptionDecider()
        d.reset()
    }

    func testExactThresholdInterrupts() {
        // confirmMs=200, sampleRate=16000 → need 3200 samples = 200ms overlap
        var d = LegacyThresholdInterruptionDecider(confirmMs: 200, minRms: 0.08)
        let input = makeInterruptionInput(overlapDurationMs: 200)
        switch d.process(input) {
        case .interruptNow: break // exactly at threshold → interrupt
        default: XCTFail("Expected interruptNow at exact threshold")
        }
    }

    func testJustBelowThresholdIsCandidate() {
        var d = LegacyThresholdInterruptionDecider(confirmMs: 200, minRms: 0.08)
        let input = makeInterruptionInput(overlapDurationMs: 199)
        switch d.process(input) {
        case .candidate: break
        default: XCTFail("Expected candidate just below threshold")
        }
    }

    func testCustomHoldoff() {
        var d = LegacyThresholdInterruptionDecider(assistantStartHoldoffMs: 500)
        let input = makeInterruptionInput(assistantSpeechElapsedMs: 300)
        switch d.process(input) {
        case .ignore(let reason): XCTAssertEqual(reason, "holdoff_window")
        default: XCTFail("Expected holdoff ignore")
        }
    }

    func testCustomMinRMS() {
        var d = LegacyThresholdInterruptionDecider(minRms: 0.5)
        let input = makeInterruptionInput(rms: 0.3)
        switch d.process(input) {
        case .ignore(let reason): XCTAssertEqual(reason, "below_rms_threshold")
        default: XCTFail("Expected below RMS ignore")
        }
    }
}

// MARK: - InterruptionDecision Tests

final class InterruptionDecisionTests: XCTestCase {

    func testCandidateEqualsCandidate() {
        XCTAssertEqual(InterruptionDecision.candidate, .candidate)
    }

    func testIgnoreEqualsSameReason() {
        XCTAssertEqual(InterruptionDecision.ignore(reason: "test"), .ignore(reason: "test"))
    }

    func testIgnoreNotEqualsDifferentReason() {
        XCTAssertNotEqual(InterruptionDecision.ignore(reason: "a"), .ignore(reason: "b"))
    }

    func testInterruptNowEqualsSameReason() {
        XCTAssertEqual(InterruptionDecision.interruptNow(reason: "test"), .interruptNow(reason: "test"))
    }

    func testInterruptNowNotEqualsDifferentReason() {
        XCTAssertNotEqual(InterruptionDecision.interruptNow(reason: "a"), .interruptNow(reason: "b"))
    }

    func testDifferentCasesNotEqual() {
        XCTAssertNotEqual(InterruptionDecision.candidate, .ignore(reason: "x"))
        XCTAssertNotEqual(InterruptionDecision.candidate, .interruptNow(reason: "x"))
        XCTAssertNotEqual(InterruptionDecision.ignore(reason: "x"), .interruptNow(reason: "x"))
    }

    func testIsSendable() {
        let d: InterruptionDecision = .candidate
        _ = d as any Sendable
    }
}

// MARK: - AdaptiveInterruptionDecider Tests

final class AdaptiveInterruptionDeciderTests: XCTestCase {

    func testDefaultInit() {
        let _ = AdaptiveInterruptionDecider()
    }

    func testIgnoreWhenBargeInSuppressed() {
        var d = AdaptiveInterruptionDecider()
        let input = makeInterruptionInput(bargeInSuppressed: true)
        switch d.process(input) {
        case .ignore: break // Should ignore
        default: XCTFail("Expected ignore when suppressed")
        }
    }

    func testIgnoreWhenInDenyCooldown() {
        var d = AdaptiveInterruptionDecider()
        let input = makeInterruptionInput(inDenyCooldown: true)
        switch d.process(input) {
        case .ignore: break
        default: XCTFail("Expected ignore in cooldown")
        }
    }

    func testResetDoesNotCrash() {
        var d = AdaptiveInterruptionDecider()
        d.reset()
    }

    func testIsSendableConfig() {
        let config = AdaptiveInterruptionConfig()
        _ = config as any Sendable
    }
}
