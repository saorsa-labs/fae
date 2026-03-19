import XCTest
@testable import Fae

final class AdaptiveInterruptionDeciderTests: XCTestCase {

    // MARK: - Helpers

    private func makeInput(
        assistantSpeaking: Bool = true,
        speechStarted: Bool = false,
        isSpeech: Bool = true,
        rms: Float = 0.12,
        overlapDurationMs: Int = 400,
        assistantSpeechElapsedMs: Int = 2000,
        echoSuppression: Bool = false,
        bargeInSuppressed: Bool = false,
        inDenyCooldown: Bool = false,
        peakRms: Float = 0.15,
        consecutiveSpeechChunks: Int = 6
    ) -> InterruptionInput {
        InterruptionInput(
            assistantSpeaking: assistantSpeaking,
            speechStarted: speechStarted,
            isSpeech: isSpeech,
            rms: rms,
            chunkSamples: [Float](repeating: rms, count: 512),
            overlapDurationMs: overlapDurationMs,
            assistantSpeechElapsedMs: assistantSpeechElapsedMs,
            echoSuppression: echoSuppression,
            bargeInSuppressed: bargeInSuppressed,
            inDenyCooldown: inDenyCooldown,
            peakRms: peakRms,
            consecutiveSpeechChunks: consecutiveSpeechChunks
        )
    }

    // MARK: - Legacy Decider Tests

    func testLegacyDeciderIgnoresEchoSuppression() {
        var decider: any InterruptionDeciding = LegacyThresholdInterruptionDecider()
        let input = makeInput(echoSuppression: true)
        let decision = decider.process(input)
        XCTAssertEqual(decision, .ignore(reason: "echo_suppression"))
    }

    func testLegacyDeciderIgnoresBargeInSuppressed() {
        var decider: any InterruptionDeciding = LegacyThresholdInterruptionDecider()
        let input = makeInput(bargeInSuppressed: true)
        let decision = decider.process(input)
        XCTAssertEqual(decision, .ignore(reason: "barge_in_suppressed"))
    }

    func testLegacyDeciderIgnoresDenyCooldown() {
        var decider: any InterruptionDeciding = LegacyThresholdInterruptionDecider()
        let input = makeInput(inDenyCooldown: true)
        let decision = decider.process(input)
        XCTAssertEqual(decision, .ignore(reason: "deny_cooldown"))
    }

    func testLegacyDeciderIgnoresWhenNotSpeaking() {
        var decider: any InterruptionDeciding = LegacyThresholdInterruptionDecider()
        let input = makeInput(assistantSpeaking: false)
        let decision = decider.process(input)
        XCTAssertEqual(decision, .ignore(reason: "not_speaking"))
    }

    func testLegacyDeciderIgnoresHoldoffWindow() {
        var decider: any InterruptionDeciding = LegacyThresholdInterruptionDecider()
        let input = makeInput(assistantSpeechElapsedMs: 200)
        let decision = decider.process(input)
        XCTAssertEqual(decision, .ignore(reason: "holdoff_window"))
    }

    func testLegacyDeciderIgnoresBelowRmsThreshold() {
        var decider: any InterruptionDeciding = LegacyThresholdInterruptionDecider()
        let input = makeInput(rms: 0.02)
        let decision = decider.process(input)
        XCTAssertEqual(decision, .ignore(reason: "below_rms_threshold"))
    }

    func testLegacyDeciderInterruptsOnConfirmation() {
        var decider: any InterruptionDeciding = LegacyThresholdInterruptionDecider(confirmMs: 350)
        let input = makeInput(overlapDurationMs: 400)
        let decision = decider.process(input)
        XCTAssertEqual(decision, .interruptNow(reason: "legacy_threshold_confirmed"))
    }

    func testLegacyDeciderCandidateWhenBelowConfirmation() {
        var decider: any InterruptionDeciding = LegacyThresholdInterruptionDecider(confirmMs: 350)
        let input = makeInput(overlapDurationMs: 200)
        let decision = decider.process(input)
        XCTAssertEqual(decision, .candidate)
    }

    // MARK: - Adaptive Decider Tests

    func testAdaptiveDeciderIgnoresEchoSuppression() {
        var decider: any InterruptionDeciding = AdaptiveInterruptionDecider()
        let input = makeInput(echoSuppression: true)
        let decision = decider.process(input)
        XCTAssertEqual(decision, .ignore(reason: "echo_suppression"))
    }

    func testAdaptiveDeciderIgnoresHoldoffWindow() {
        var decider: any InterruptionDeciding = AdaptiveInterruptionDecider()
        let input = makeInput(assistantSpeechElapsedMs: 200)
        let decision = decider.process(input)
        XCTAssertEqual(decision, .ignore(reason: "holdoff_window"))
    }

    func testAdaptiveDeciderIgnoresBriefOverlapBurst() {
        var decider: any InterruptionDeciding = AdaptiveInterruptionDecider()
        let input = makeInput(overlapDurationMs: 100, consecutiveSpeechChunks: 1)
        let decision = decider.process(input)
        XCTAssertEqual(decision, .candidate)
    }

    func testAdaptiveDeciderInterruptsOnSustainedSpeech() {
        var decider: any InterruptionDeciding = AdaptiveInterruptionDecider()

        // Feed enough RMS history to establish sustained energy.
        for _ in 0..<5 {
            _ = decider.process(makeInput(
                rms: 0.12,
                overlapDurationMs: 200,
                peakRms: 0.15,
                consecutiveSpeechChunks: 3
            ))
        }

        let input = makeInput(
            rms: 0.12,
            overlapDurationMs: 350,
            peakRms: 0.15,
            consecutiveSpeechChunks: 6
        )
        let decision = decider.process(input)
        XCTAssertEqual(decision, .interruptNow(reason: "adaptive_sustained_speech"))
    }

    func testAdaptiveDeciderInterruptsOnExtendedOverlap() {
        // Use a config where peakRmsRatio is high enough that sustained speech
        // path doesn't fire, but extended overlap does.
        var config = AdaptiveInterruptionConfig()
        config.peakRmsRatio = 3.0  // Require peak 3x above floor — won't be met.
        var decider: any InterruptionDeciding = AdaptiveInterruptionDecider(config: config)

        // Build RMS history for sustained energy.
        for _ in 0..<5 {
            _ = decider.process(makeInput(rms: 0.10, overlapDurationMs: 300))
        }

        let input = makeInput(
            rms: 0.10,
            overlapDurationMs: 500,
            peakRms: 0.14,  // Below 3x floor (0.18), so sustained path skipped.
            consecutiveSpeechChunks: 5
        )
        let decision = decider.process(input)
        XCTAssertEqual(decision, .interruptNow(reason: "adaptive_extended_overlap"))
    }

    func testAdaptiveDeciderInterruptsOnLongOverlap() {
        var decider: any InterruptionDeciding = AdaptiveInterruptionDecider()
        let input = makeInput(
            rms: 0.09,
            overlapDurationMs: 700,
            peakRms: 0.09,
            consecutiveSpeechChunks: 3
        )
        let decision = decider.process(input)
        XCTAssertEqual(decision, .interruptNow(reason: "adaptive_long_overlap"))
    }

    func testAdaptiveDeciderResetClearsState() {
        var decider = AdaptiveInterruptionDecider()

        // Build RMS history.
        for _ in 0..<5 {
            _ = decider.process(makeInput(rms: 0.12, overlapDurationMs: 200))
        }

        decider.reset()

        // After reset, sustained energy check fails — need to rebuild history.
        let input = makeInput(
            rms: 0.12,
            overlapDurationMs: 350,
            peakRms: 0.15,
            consecutiveSpeechChunks: 6
        )
        let decision = decider.process(input)
        // Should be candidate because RMS history was reset (only 1 entry).
        XCTAssertEqual(decision, .candidate)
    }

    func testAdaptiveDeciderIgnoresLowRms() {
        var decider: any InterruptionDeciding = AdaptiveInterruptionDecider()
        let input = makeInput(rms: 0.02, overlapDurationMs: 500, peakRms: 0.03)
        let decision = decider.process(input)
        XCTAssertEqual(decision, .ignore(reason: "below_rms_threshold"))
    }

    // MARK: - PendingBargeIn Accumulation

    func testPendingBargeInTracksNewFields() {
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
        XCTAssertEqual(pending?.consecutiveSpeechChunks, 1)
        XCTAssertEqual(Double(pending?.peakRms ?? 0), 0.12, accuracy: 0.001)

        pending = PipelineCoordinator.advancePendingBargeIn(
            pending: pending,
            speechStarted: false,
            isSpeech: true,
            chunkSamples: chunk,
            rms: 0.18,
            echoSuppression: false,
            bargeInSuppressed: false,
            inDenyCooldown: false
        )
        XCTAssertEqual(pending?.consecutiveSpeechChunks, 2)
        XCTAssertEqual(Double(pending?.peakRms ?? 0), 0.18, accuracy: 0.001)
    }

    func testPendingBargeInResetsConsecutiveOnSpeechGap() {
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
        XCTAssertEqual(pending?.consecutiveSpeechChunks, 1)

        // Non-speech gap.
        pending = PipelineCoordinator.advancePendingBargeIn(
            pending: pending,
            speechStarted: false,
            isSpeech: false,
            chunkSamples: chunk,
            rms: 0.01,
            echoSuppression: false,
            bargeInSuppressed: false,
            inDenyCooldown: false
        )
        XCTAssertEqual(pending?.consecutiveSpeechChunks, 0)
    }

    // MARK: - False Interruption Recovery

    func testFalseInterruptionRecoveryDetectsTimeout() {
        var recovery = FalseInterruptionRecovery(timeoutMs: 100, enabled: true)
        let outcome = InterruptionOutcome(
            interruptedAt: Date(),
            generationID: nil,
            interruptedText: "I was explaining how the system works",
            spokenFraction: 0.3
        )
        recovery.recordInterruption(outcome: outcome)
        XCTAssertTrue(recovery.observing)

        // Still within window.
        let earlyResult = recovery.checkTimeout(now: Date().addingTimeInterval(0.05))
        XCTAssertEqual(earlyResult, .stillObserving)

        // After timeout.
        let lateResult = recovery.checkTimeout(now: Date().addingTimeInterval(0.2))
        if case .falseInterruption(let repair) = lateResult {
            XCTAssertTrue(repair.contains("jumping in"))
        } else {
            XCTFail("Expected falseInterruption, got \(lateResult)")
        }
        XCTAssertFalse(recovery.observing)
    }

    func testFalseInterruptionRecoveryConfirmsFollowUp() {
        var recovery = FalseInterruptionRecovery(timeoutMs: 100, enabled: true)
        let outcome = InterruptionOutcome(
            interruptedAt: Date(),
            generationID: nil,
            interruptedText: "test",
            spokenFraction: 0
        )
        recovery.recordInterruption(outcome: outcome)
        recovery.recordFollowUpSpeech()
        XCTAssertFalse(recovery.observing)

        let result = recovery.checkTimeout(now: Date().addingTimeInterval(0.2))
        XCTAssertEqual(result, .noAction)
    }

    func testFalseInterruptionRecoveryDisabledProducesNoAction() {
        var recovery = FalseInterruptionRecovery(timeoutMs: 100, enabled: false)
        let outcome = InterruptionOutcome(
            interruptedAt: Date(),
            generationID: nil,
            interruptedText: "test",
            spokenFraction: 0
        )
        recovery.recordInterruption(outcome: outcome)
        XCTAssertFalse(recovery.observing)
    }

    func testRepairUtteranceWithNoText() {
        let repair = FalseInterruptionRecovery.buildRepairUtterance(interruptedText: nil)
        XCTAssertTrue(repair.contains("jumping in"))
        XCTAssertTrue(repair.contains("What were you going to say"))
    }

    func testRepairUtteranceWithShortText() {
        let repair = FalseInterruptionRecovery.buildRepairUtterance(interruptedText: "Hello there")
        XCTAssertTrue(repair.contains("Hello there"))
    }

    func testRepairUtteranceWithLongTextTruncates() {
        let longText = "The quick brown fox jumps over the lazy dog and then runs into the forest where it meets a rabbit"
        let repair = FalseInterruptionRecovery.buildRepairUtterance(interruptedText: longText)
        XCTAssertTrue(repair.contains("…"))
        // Should contain the tail ~8 words.
        XCTAssertTrue(repair.contains("rabbit"))
    }

    // MARK: - InterruptionDecision Equatable

    func testInterruptionDecisionEquality() {
        XCTAssertEqual(InterruptionDecision.candidate, InterruptionDecision.candidate)
        XCTAssertEqual(
            InterruptionDecision.ignore(reason: "test"),
            InterruptionDecision.ignore(reason: "test")
        )
        XCTAssertNotEqual(
            InterruptionDecision.ignore(reason: "a"),
            InterruptionDecision.ignore(reason: "b")
        )
        XCTAssertNotEqual(
            InterruptionDecision.candidate,
            InterruptionDecision.ignore(reason: "test")
        )
    }
}
