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
        consecutiveSpeechChunks: Int = 6,
        partialTranscript: String? = nil,
        partialWordCount: Int = 0,
        hasInterruptKeyword: Bool = false
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
            consecutiveSpeechChunks: consecutiveSpeechChunks,
            partialTranscript: partialTranscript,
            partialWordCount: partialWordCount,
            hasInterruptKeyword: hasInterruptKeyword
        )
    }

    // MARK: - Legacy Decider Tests

    func testLegacyDeciderDoublesConfirmDuringEcho() {
        // Echo suppression is now a signal, not a hard gate.
        // During echo, confirm time is doubled (200→400ms).
        var decider: any InterruptionDeciding = LegacyThresholdInterruptionDecider(confirmMs: 200)
        // 300ms overlap — enough without echo (200ms) but not with echo (400ms).
        let input = makeInput(overlapDurationMs: 300, echoSuppression: true)
        let decision = decider.process(input)
        XCTAssertEqual(decision, .candidate)

        // 450ms overlap — enough even with doubled threshold.
        let input2 = makeInput(overlapDurationMs: 450, echoSuppression: true)
        let decision2 = decider.process(input2)
        XCTAssertEqual(decision2, .interruptNow(reason: "legacy_threshold_confirmed"))
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
        // Default holdoff is 200ms — 100ms is within the window.
        let input = makeInput(assistantSpeechElapsedMs: 100)
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

    func testAdaptiveDeciderRaisesBarDuringEcho() {
        // Echo suppression raises the evidence bar — requires transcript evidence
        // or very long overlap (3x minOverlapMs = 450ms).
        var decider: any InterruptionDeciding = AdaptiveInterruptionDecider()

        // Build RMS history.
        for _ in 0..<5 {
            _ = decider.process(makeInput(rms: 0.12, overlapDurationMs: 200))
        }

        // 300ms acoustic-only during echo → candidate (below 3x threshold).
        let input = makeInput(
            overlapDurationMs: 300,
            echoSuppression: true,
            peakRms: 0.15,
            consecutiveSpeechChunks: 4
        )
        let decision = decider.process(input)
        XCTAssertEqual(decision, .candidate)
    }

    func testAdaptiveDeciderAllowsInterruptDuringEchoWithTranscript() {
        // With transcript evidence, echo suppression doesn't block.
        var decider: any InterruptionDeciding = AdaptiveInterruptionDecider()

        for _ in 0..<5 {
            _ = decider.process(makeInput(rms: 0.12, overlapDurationMs: 150))
        }

        let input = makeInput(
            overlapDurationMs: 200,
            echoSuppression: true,
            peakRms: 0.15,
            consecutiveSpeechChunks: 3,
            partialTranscript: "actually stop",
            partialWordCount: 2
        )
        let decision = decider.process(input)
        XCTAssertEqual(decision, .interruptNow(reason: "adaptive_transcript_boosted"))
    }

    func testAdaptiveDeciderKeywordBypassesEcho() {
        // Keywords always fire, even during echo suppression.
        var decider: any InterruptionDeciding = AdaptiveInterruptionDecider()
        let input = makeInput(
            overlapDurationMs: 150,
            echoSuppression: true,
            consecutiveSpeechChunks: 2,
            hasInterruptKeyword: true
        )
        let decision = decider.process(input)
        XCTAssertEqual(decision, .interruptNow(reason: "interrupt_keyword"))
    }

    func testAdaptiveDeciderIgnoresHoldoffWindow() {
        var decider: any InterruptionDeciding = AdaptiveInterruptionDecider()
        // Default holdoff is 200ms — 100ms is within the window.
        let input = makeInput(assistantSpeechElapsedMs: 100)
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
        config.peakRmsRatio = 5.0  // Require peak 5x above floor (0.04*5=0.20) — won't be met.
        var decider: any InterruptionDeciding = AdaptiveInterruptionDecider(config: config)

        // Build RMS history for sustained energy.
        for _ in 0..<5 {
            _ = decider.process(makeInput(rms: 0.10, overlapDurationMs: 200))
        }

        let input = makeInput(
            rms: 0.10,
            overlapDurationMs: 350,  // >= minOverlapMs (150) + 150 = 300
            peakRms: 0.14,  // Below 5x floor (0.20), so sustained path skipped.
            consecutiveSpeechChunks: 3
        )
        let decision = decider.process(input)
        XCTAssertEqual(decision, .interruptNow(reason: "adaptive_extended_overlap"))
    }

    func testAdaptiveDeciderInterruptsOnLongOverlap() {
        // Use a config where peak ratio blocks sustained and extended paths.
        var config = AdaptiveInterruptionConfig()
        config.peakRmsRatio = 5.0  // Blocks sustained path.
        var decider: any InterruptionDeciding = AdaptiveInterruptionDecider(config: config)
        let input = makeInput(
            rms: 0.09,
            overlapDurationMs: 350,  // >= minOverlapMs * 2 = 300
            peakRms: 0.09,  // Below 5x floor — blocks sustained and extended.
            consecutiveSpeechChunks: 3
        )
        let decision = decider.process(input)
        XCTAssertEqual(decision, .interruptNow(reason: "adaptive_long_overlap"))
    }

    func testAdaptiveDeciderResetClearsState() {
        var decider = AdaptiveInterruptionDecider()

        // Build RMS history.
        for _ in 0..<5 {
            _ = decider.process(makeInput(rms: 0.12, overlapDurationMs: 100))
        }

        decider.reset()

        // After reset, sustained energy check fails — need to rebuild history.
        // Use overlap below the extended threshold to avoid that path.
        let input = makeInput(
            rms: 0.12,
            overlapDurationMs: 160,  // Above minOverlapMs (150) but below extended (300).
            peakRms: 0.15,
            consecutiveSpeechChunks: 3
        )
        let decision = decider.process(input)
        // Should be candidate because RMS history was reset (only 1 entry, need ≥3).
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

    // MARK: - Phase 2b: Semantic Signals

    func testAdaptiveDeciderInterruptsOnKeyword() {
        var decider: any InterruptionDeciding = AdaptiveInterruptionDecider()
        let input = makeInput(
            overlapDurationMs: 150,
            consecutiveSpeechChunks: 2,
            hasInterruptKeyword: true
        )
        let decision = decider.process(input)
        XCTAssertEqual(decision, .interruptNow(reason: "interrupt_keyword"))
    }

    func testAdaptiveDeciderSuppressesBackchannel() {
        var decider: any InterruptionDeciding = AdaptiveInterruptionDecider()
        let input = makeInput(
            overlapDurationMs: 400,
            peakRms: 0.15,
            consecutiveSpeechChunks: 6,
            partialTranscript: "yeah",
            partialWordCount: 1
        )
        let decision = decider.process(input)
        XCTAssertEqual(decision, .ignore(reason: "backchannel_suppressed"))
    }

    func testAdaptiveDeciderAllowsLongBackchannel() {
        var decider: any InterruptionDeciding = AdaptiveInterruptionDecider()

        // Build RMS history for sustained energy.
        for _ in 0..<5 {
            _ = decider.process(makeInput(rms: 0.12, overlapDurationMs: 500))
        }

        // Very long overlap even with backchannel — falls through to acoustic paths.
        let input = makeInput(
            overlapDurationMs: 1000,
            peakRms: 0.15,
            consecutiveSpeechChunks: 6,
            partialTranscript: "yeah",
            partialWordCount: 1
        )
        let decision = decider.process(input)
        // Should fire via adaptive_sustained_speech since backchannel threshold (900ms) is passed.
        XCTAssertEqual(decision, .interruptNow(reason: "adaptive_sustained_speech"))
    }

    func testAdaptiveDeciderTranscriptBoostedInterrupt() {
        var decider: any InterruptionDeciding = AdaptiveInterruptionDecider()

        // Build RMS history.
        for _ in 0..<5 {
            _ = decider.process(makeInput(rms: 0.12, overlapDurationMs: 150))
        }

        // 200ms overlap with transcript evidence — lower than normal 300ms threshold.
        let input = makeInput(
            rms: 0.12,
            overlapDurationMs: 200,
            peakRms: 0.15,
            consecutiveSpeechChunks: 3,
            partialTranscript: "actually I wanted",
            partialWordCount: 3
        )
        let decision = decider.process(input)
        XCTAssertEqual(decision, .interruptNow(reason: "adaptive_transcript_boosted"))
    }

    func testAdaptiveDeciderTranscriptBoostIgnoresBackchannel() {
        var decider: any InterruptionDeciding = AdaptiveInterruptionDecider()

        for _ in 0..<5 {
            _ = decider.process(makeInput(rms: 0.12, overlapDurationMs: 150))
        }

        // Backchannel word should NOT get transcript boost.
        let input = makeInput(
            rms: 0.12,
            overlapDurationMs: 200,
            peakRms: 0.15,
            consecutiveSpeechChunks: 3,
            partialTranscript: "okay",
            partialWordCount: 1
        )
        let decision = decider.process(input)
        XCTAssertEqual(decision, .ignore(reason: "backchannel_suppressed"))
    }

    // MARK: - Backchannel Classifier

    func testBackchannelClassifierDetectsCommonPhrases() {
        XCTAssertTrue(BackchannelClassifier.isBackchannel("yeah"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("mhm"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("uh-huh"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("okay"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("right"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("Wow"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("  Yeah  "))
    }

    func testBackchannelClassifierRejectsRealSpeech() {
        XCTAssertFalse(BackchannelClassifier.isBackchannel("actually I wanted to say"))
        XCTAssertFalse(BackchannelClassifier.isBackchannel("stop that"))
        XCTAssertFalse(BackchannelClassifier.isBackchannel("yeah but actually"))
        XCTAssertFalse(BackchannelClassifier.isBackchannel(nil))
        XCTAssertFalse(BackchannelClassifier.isBackchannel(""))
    }

    func testBackchannelClassifierHandlesPunctuation() {
        XCTAssertTrue(BackchannelClassifier.isBackchannel("yeah."))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("okay!"))
        XCTAssertTrue(BackchannelClassifier.isBackchannel("right?"))
    }

    // MARK: - Milestone 4: Transcript-Aware Endpointing

    func testSilenceThresholdShortensForCompleteUtterance() {
        let result = PipelineCoordinator.silenceThresholdMs(
            assistantSpeaking: false,
            gateState: .active,
            inFollowup: true,
            hasPendingSemanticTurn: false,
            configMinSilenceMs: 1000,
            bargeInSilenceMs: 600,
            lastPartialTranscript: "What time is it?"
        )
        // Complete utterance → config minimum (1000), NOT conversational floor (1800).
        XCTAssertEqual(result, 1000)
    }

    func testSilenceThresholdLengthensForIncompleteUtterance() {
        let result = PipelineCoordinator.silenceThresholdMs(
            assistantSpeaking: false,
            gateState: .active,
            inFollowup: true,
            hasPendingSemanticTurn: false,
            configMinSilenceMs: 1000,
            bargeInSilenceMs: 600,
            lastPartialTranscript: "set a timer for"
        )
        // Incomplete utterance → at least 2200ms.
        XCTAssertGreaterThanOrEqual(result, 2200)
    }

    func testSilenceThresholdVeryPatientForContinuationCue() {
        let result = PipelineCoordinator.silenceThresholdMs(
            assistantSpeaking: false,
            gateState: .active,
            inFollowup: true,
            hasPendingSemanticTurn: false,
            configMinSilenceMs: 1000,
            bargeInSilenceMs: 600,
            lastPartialTranscript: "hold on"
        )
        // Continuation cue → at least 3000ms.
        XCTAssertGreaterThanOrEqual(result, 3000)
    }

    func testSilenceThresholdIgnoresTranscriptWhenAssistantSpeaking() {
        let result = PipelineCoordinator.silenceThresholdMs(
            assistantSpeaking: true,
            gateState: .active,
            inFollowup: true,
            hasPendingSemanticTurn: false,
            configMinSilenceMs: 1000,
            bargeInSilenceMs: 600,
            lastPartialTranscript: "hold on"
        )
        // While assistant speaking, always use bargeInSilenceMs.
        XCTAssertEqual(result, 600)
    }

    func testSilenceThresholdFallsBackWithoutTranscript() {
        let result = PipelineCoordinator.silenceThresholdMs(
            assistantSpeaking: false,
            gateState: .active,
            inFollowup: true,
            hasPendingSemanticTurn: false,
            configMinSilenceMs: 1000,
            bargeInSilenceMs: 600,
            lastPartialTranscript: nil
        )
        // No transcript → conversational floor (1800).
        XCTAssertEqual(result, 1800)
    }
}
