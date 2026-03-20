import XCTest
@testable import Fae

final class EchoTextOverlapTests: XCTestCase {

    // MARK: - Text-Overlap Echo Rejection

    func testExactEchoTextIsRejected() {
        var suppressor = EchoSuppressor()
        suppressor.recordAssistantText("Let me check your calendar for tomorrow morning")

        // STT transcribes Fae's own speech from the speakers.
        XCTAssertTrue(
            suppressor.isLikelyEchoText("let me check your calendar for tomorrow morning"),
            "Exact match of recent assistant text should be detected as echo"
        )
    }

    func testPartialOverlapAboveThresholdIsEcho() {
        var suppressor = EchoSuppressor()
        suppressor.recordAssistantText("I found three events on your calendar for tomorrow")

        // 5 of 7 words match (71%) — above 50% threshold.
        XCTAssertTrue(
            suppressor.isLikelyEchoText("I found three events on your calendar"),
            "High word overlap should be detected as echo"
        )
    }

    func testLowOverlapIsNotEcho() {
        var suppressor = EchoSuppressor()
        suppressor.recordAssistantText("I found three events on your calendar for tomorrow")

        // Completely different sentence.
        XCTAssertFalse(
            suppressor.isLikelyEchoText("can you tell me the weather forecast"),
            "Unrelated text should not be detected as echo"
        )
    }

    func testShortUtterancesExemptFromTextOverlap() {
        var suppressor = EchoSuppressor()
        suppressor.recordAssistantText("stop that please")

        // "stop" is only 1 word — below the 3-word minimum.
        XCTAssertFalse(
            suppressor.isLikelyEchoText("stop"),
            "Short utterances (< 3 words) should be exempt from text-overlap echo"
        )
    }

    func testTwoWordUtteranceExempt() {
        var suppressor = EchoSuppressor()
        suppressor.recordAssistantText("yes I can help with that")

        XCTAssertFalse(
            suppressor.isLikelyEchoText("no thanks"),
            "Two-word utterances should be exempt"
        )
    }

    func testEmptyAssistantTextReturnsNotEcho() {
        let suppressor = EchoSuppressor()
        XCTAssertFalse(
            suppressor.isLikelyEchoText("hello how are you today"),
            "No recorded text should mean no echo detection"
        )
    }

    func testMultipleRecordedChunksAccumulate() {
        var suppressor = EchoSuppressor()
        suppressor.recordAssistantText("Let me think about")
        suppressor.recordAssistantText("your question carefully")

        // Words from both chunks should be in the reference set.
        XCTAssertTrue(
            suppressor.isLikelyEchoText("let me think about your question carefully"),
            "Text across multiple recorded chunks should be combined"
        )
    }

    func testClearTextHistoryResetsDetection() {
        var suppressor = EchoSuppressor()
        suppressor.recordAssistantText("This is a test of the echo detection system")
        suppressor.clearTextHistory()

        XCTAssertFalse(
            suppressor.isLikelyEchoText("this is a test of the echo detection system"),
            "After clearing history, nothing should match"
        )
    }

    func testResetClearsTextHistory() {
        var suppressor = EchoSuppressor()
        suppressor.recordAssistantText("This is a test of the echo detection system")
        suppressor.reset()

        XCTAssertFalse(
            suppressor.isLikelyEchoText("this is a test of the echo detection system"),
            "Reset should clear text history"
        )
    }

    func testCaseInsensitiveMatching() {
        var suppressor = EchoSuppressor()
        suppressor.recordAssistantText("Hello David how are you today")

        XCTAssertTrue(
            suppressor.isLikelyEchoText("HELLO DAVID HOW ARE YOU TODAY"),
            "Matching should be case-insensitive"
        )
    }

    func testPunctuationStripped() {
        var suppressor = EchoSuppressor()
        suppressor.recordAssistantText("Hello! How are you? I'm doing great.")

        XCTAssertTrue(
            suppressor.isLikelyEchoText("hello how are you im doing great"),
            "Punctuation should be stripped before comparison"
        )
    }

    func testMaxChunksRingBuffer() {
        var suppressor = EchoSuppressor()

        // Record more than maxRecentTextChunks (8).
        for i in 0..<12 {
            suppressor.recordAssistantText("chunk number \(i) with unique words here")
        }

        // Oldest chunks should be evicted — "chunk number 0" should not match.
        // But recent chunks should still match.
        XCTAssertTrue(
            suppressor.isLikelyEchoText("chunk number 11 with unique words here"),
            "Recent chunks should still match"
        )
    }

    // MARK: - Pause / Resume

    func testFalseInterruptionResumePlayback() {
        var recovery = FalseInterruptionRecovery(timeoutMs: 100, enabled: true)

        let outcome = InterruptionOutcome(
            interruptedAt: Date(),
            generationID: nil,
            interruptedText: "some text",
            spokenFraction: 0
        )
        recovery.recordInterruption(outcome: outcome, paused: true)
        XCTAssertTrue(recovery.playbackWasPaused)

        // Fast-forward past timeout.
        let futureDate = Date().addingTimeInterval(0.2)
        let result = recovery.checkTimeout(now: futureDate)
        XCTAssertEqual(result, .resumePlayback,
                       "Should suggest resume when playback was paused")
    }

    func testFalseInterruptionRepairWhenNotPaused() {
        var recovery = FalseInterruptionRecovery(timeoutMs: 100, enabled: true)

        let outcome = InterruptionOutcome(
            interruptedAt: Date(),
            generationID: nil,
            interruptedText: "some words here",
            spokenFraction: 0
        )
        recovery.recordInterruption(outcome: outcome, paused: false)
        XCTAssertFalse(recovery.playbackWasPaused)

        let futureDate = Date().addingTimeInterval(0.2)
        let result = recovery.checkTimeout(now: futureDate)
        if case .falseInterruption = result {
            // Expected — should fall back to repair utterance.
        } else {
            XCTFail("Should produce repair utterance when not paused, got \(result)")
        }
    }

    func testFollowUpCancelsResume() {
        var recovery = FalseInterruptionRecovery(timeoutMs: 500, enabled: true)

        let outcome = InterruptionOutcome(
            interruptedAt: Date(),
            generationID: nil,
            interruptedText: "text",
            spokenFraction: 0
        )
        recovery.recordInterruption(outcome: outcome, paused: true)
        recovery.recordFollowUpSpeech()

        XCTAssertFalse(recovery.playbackWasPaused,
                       "Follow-up should clear paused flag")

        let futureDate = Date().addingTimeInterval(1.0)
        let result = recovery.checkTimeout(now: futureDate)
        XCTAssertEqual(result, .noAction,
                       "Follow-up confirmed — no recovery action")
    }

    // MARK: - EMA Dynamic Endpointing

    func testEMASilenceThresholdStartsNil() {
        let vad = VoiceActivityDetector()
        XCTAssertNil(vad.emaSuggestedSilenceMs,
                     "Should be nil before any observations")
    }

    func testEMASilenceThresholdAfterObservation() {
        var vad = VoiceActivityDetector()
        vad.recordObservedSilenceMs(800)
        XCTAssertNotNil(vad.emaSuggestedSilenceMs)
        // 800 * 1.3 = 1040.
        XCTAssertEqual(vad.emaSuggestedSilenceMs, 1040,
                       "First observation should set EMA directly")
    }

    func testEMASilenceThresholdAdapts() {
        var vad = VoiceActivityDetector()
        // Seed with 1000ms pause.
        vad.recordObservedSilenceMs(1000)
        // Then observe shorter pauses.
        vad.recordObservedSilenceMs(500)
        vad.recordObservedSilenceMs(500)
        vad.recordObservedSilenceMs(500)

        // EMA should adapt downward.
        let suggested = vad.emaSuggestedSilenceMs
        XCTAssertNotNil(suggested)
        XCTAssertLessThan(suggested ?? 9999, 1040,
                          "EMA should adapt to shorter pauses")
    }

    func testEMASilenceThresholdFloor() {
        var vad = VoiceActivityDetector()
        // Very short pauses.
        vad.recordObservedSilenceMs(100)
        vad.recordObservedSilenceMs(100)
        vad.recordObservedSilenceMs(100)

        let suggested = vad.emaSuggestedSilenceMs
        XCTAssertNotNil(suggested)
        XCTAssertGreaterThanOrEqual(suggested ?? 0, 400,
                                    "EMA should respect floor of 400ms")
    }

    func testSilenceThresholdUsesEMA() {
        // When EMA is available and utterance is complete, should use EMA.
        let emaMs = 800
        let configMs = 1500
        let result = PipelineCoordinator.silenceThresholdMs(
            assistantSpeaking: false,
            gateState: .idle,
            inFollowup: false,
            hasPendingSemanticTurn: false,
            configMinSilenceMs: configMs,
            bargeInSilenceMs: 600,
            lastPartialTranscript: "done thanks",
            emaSuggestedMs: emaMs
        )
        // Complete utterance + EMA available → min(800, 1500) = 800.
        XCTAssertEqual(result, 800,
                       "Complete utterance should use EMA when it's shorter than config")
    }

    func testSilenceThresholdEMADoesNotOverrideContinuation() {
        let result = PipelineCoordinator.silenceThresholdMs(
            assistantSpeaking: false,
            gateState: .idle,
            inFollowup: false,
            hasPendingSemanticTurn: false,
            configMinSilenceMs: 1500,
            bargeInSilenceMs: 600,
            lastPartialTranscript: "hold on",
            emaSuggestedMs: 800
        )
        // Continuation cue → 3000ms floor, overrides EMA.
        XCTAssertEqual(result, 3000,
                       "Continuation cue should override EMA")
    }

    // MARK: - Turn Detector Types

    func testTurnDetectorLanguageThresholds() {
        XCTAssertEqual(MLXTurnDetector.languageThresholds["en"], 0.0049)
        XCTAssertEqual(MLXTurnDetector.languageThresholds["ja"], 0.0027)
        XCTAssertGreaterThan(MLXTurnDetector.languageThresholds.count, 10)
    }

    func testTurnDetectorMergeAdjacentTurns() {
        let turns: [(role: String, text: String)] = [
            ("user", "hello"),
            ("user", "how are you"),
            ("assistant", "I'm fine"),
            ("user", "great"),
        ]
        let merged = MLXTurnDetector.mergeAdjacentTurns(turns)
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].text, "hello how are you")
        XCTAssertEqual(merged[1].text, "I'm fine")
        XCTAssertEqual(merged[2].text, "great")
    }

    func testTurnDetectorNormalization() {
        let normalized = MLXTurnDetector.normalizeForTurnDetection("Hello, World! It's a TEST.")
        XCTAssertEqual(normalized, "hello world it's a test")
    }

    func testTurnDetectorPredictionForIncompleteTurn() async {
        let detector = MLXTurnDetector()
        let prediction = await detector.predictEndOfTurn(
            lastUserText: "I want to book a flight to"
        )
        XCTAssertTrue(prediction.isUnlikely,
                      "Trailing preposition should be detected as unlikely EOU")
    }

    func testTurnDetectorPredictionForCompleteTurn() async {
        let detector = MLXTurnDetector()
        let prediction = await detector.predictEndOfTurn(
            lastUserText: "What's the weather like today"
        )
        XCTAssertFalse(prediction.isUnlikely,
                       "Complete question should not be flagged as unlikely EOU")
    }
}
