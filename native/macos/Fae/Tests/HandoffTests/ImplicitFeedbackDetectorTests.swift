import XCTest
@testable import Fae

final class ImplicitFeedbackDetectorTests: XCTestCase {

    // MARK: - Helpers

    private func userTurn(_ content: String, interrupted: Bool = false) -> FeedbackAnalysisTurn {
        FeedbackAnalysisTurn(role: "user", content: content, wasInterrupted: interrupted)
    }

    private func assistantTurn(_ content: String) -> FeedbackAnalysisTurn {
        FeedbackAnalysisTurn(role: "assistant", content: content, wasInterrupted: false)
    }

    private func hasSignal(_ signals: [DetectedSignal], type: String) -> Bool {
        signals.contains { $0.signalType == type }
    }

    // MARK: - Interruption

    func testInterruptionDetectedFromFlag() {
        let signals = ImplicitFeedbackDetector.detect(
            currentTurn: userTurn("stop, never mind"),
            previousTurns: [assistantTurn("Let me explain how to...")],
            wasInterrupted: true
        )
        XCTAssertTrue(hasSignal(signals, type: "interruption"))
        let signal = signals.first { $0.signalType == "interruption" }
        XCTAssertGreaterThan(signal?.confidence ?? 0, 0.9)
    }

    func testNoInterruptionWhenFlagFalse() {
        let signals = ImplicitFeedbackDetector.detect(
            currentTurn: userTurn("tell me more"),
            previousTurns: [assistantTurn("Here is some info")],
            wasInterrupted: false
        )
        XCTAssertFalse(hasSignal(signals, type: "interruption"))
    }

    // MARK: - Praise

    func testPraiseDetectedFromThanks() {
        let signal = ImplicitFeedbackDetector.detectPraise(in: "Thanks, that's exactly what I needed!")
        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.signalType, "praise")
    }

    func testPraiseDetectedFromGreat() {
        let signal = ImplicitFeedbackDetector.detectPraise(in: "Great, that helps a lot")
        XCTAssertNotNil(signal)
    }

    func testPraiseDetectedFromPerfect() {
        let signal = ImplicitFeedbackDetector.detectPraise(in: "Perfect!")
        XCTAssertNotNil(signal)
    }

    func testNoPraiseInNormalConversation() {
        let signal = ImplicitFeedbackDetector.detectPraise(in: "What is the weather today?")
        XCTAssertNil(signal)
    }

    // MARK: - Follow-Through

    func testFollowThroughDetectedFromConfirmation() {
        let signal = ImplicitFeedbackDetector.detectFollowThrough(
            userMessage: "I did that and it worked!",
            assistantResponse: "Try restarting the service"
        )
        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.signalType, "follow_through")
    }

    func testFollowThroughDetectedFromInstallation() {
        let signal = ImplicitFeedbackDetector.detectFollowThrough(
            userMessage: "I installed the package you suggested",
            assistantResponse: "You should install package X"
        )
        XCTAssertNotNil(signal)
    }

    func testNoFollowThroughWithoutAssistantResponse() {
        let signal = ImplicitFeedbackDetector.detectFollowThrough(
            userMessage: "I did something",
            assistantResponse: nil
        )
        XCTAssertNil(signal)
    }

    // MARK: - Re-Ask

    func testReAskDetectedForRephrasedQuestion() {
        // Use phrases with significant word overlap but not identical.
        let signal = ImplicitFeedbackDetector.detectReAsk(
            currentQuery: "How do I configure the network settings on my machine?",
            previousQueries: ["How do I configure the network settings?"]
        )
        XCTAssertNotNil(signal, "Rephrased question should be detected as re_ask")
        XCTAssertEqual(signal?.signalType, "re_ask")
    }

    func testNoReAskForDifferentQuestions() {
        let signal = ImplicitFeedbackDetector.detectReAsk(
            currentQuery: "What is the weather today?",
            previousQueries: ["How do I configure the network?"]
        )
        XCTAssertNil(signal)
    }

    func testNoReAskForIdenticalQuestion() {
        // Identical text has similarity ~1.0 which is > 0.95, so not a rephrase.
        let signal = ImplicitFeedbackDetector.detectReAsk(
            currentQuery: "What time is it?",
            previousQueries: ["What time is it?"]
        )
        XCTAssertNil(signal)
    }

    // MARK: - Abandonment

    func testAbandonmentDetectedWhenTopicDropped() {
        let signal = ImplicitFeedbackDetector.detectAbandonment(
            currentMessage: "Remind me to buy groceries tomorrow",
            previousQuery: "How do I fix the compilation error in my Rust code?",
            assistantResponse: "The error is likely caused by a missing lifetime annotation"
        )
        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.signalType, "abandonment")
    }

    func testNoAbandonmentWhenPreviousWasNotQuestion() {
        let signal = ImplicitFeedbackDetector.detectAbandonment(
            currentMessage: "Something else entirely",
            previousQuery: "I like cats",
            assistantResponse: "Cats are great!"
        )
        XCTAssertNil(signal)
    }

    // MARK: - Topic Change

    func testTopicChangeDetectedInFullPipeline() {
        let signals = ImplicitFeedbackDetector.detect(
            currentTurn: userTurn("Play some music please"),
            previousTurns: [
                assistantTurn("The capital of France is Paris."),
                userTurn("Tell me about France"),
            ],
            wasInterrupted: false
        )
        // Should detect topic_change or abandonment (both are valid for unrelated follow-up).
        let hasTopic = hasSignal(signals, type: "topic_change") || hasSignal(signals, type: "abandonment")
        XCTAssertTrue(hasTopic, "Expected topic_change or abandonment signal")
    }

    // MARK: - Silence Acceptance

    func testSilenceAcceptanceAfterTimeout() {
        let signal = ImplicitFeedbackDetector.detectSilenceAcceptance(
            lastAssistantResponse: "Here is the answer to your question.",
            secondsSinceResponse: 45
        )
        XCTAssertNotNil(signal)
        XCTAssertEqual(signal?.signalType, "silence_acceptance")
    }

    func testNoSilenceAcceptanceBeforeTimeout() {
        let signal = ImplicitFeedbackDetector.detectSilenceAcceptance(
            lastAssistantResponse: "Here is the answer.",
            secondsSinceResponse: 10
        )
        XCTAssertNil(signal)
    }

    func testNoSilenceAcceptanceForEmptyResponse() {
        let signal = ImplicitFeedbackDetector.detectSilenceAcceptance(
            lastAssistantResponse: "",
            secondsSinceResponse: 60
        )
        XCTAssertNil(signal)
    }

    // MARK: - Text Similarity

    func testTextSimilarityIdenticalTexts() {
        let sim = ImplicitFeedbackDetector.textSimilarity(
            "hello world foo bar",
            "hello world foo bar"
        )
        XCTAssertEqual(sim, 1.0, accuracy: 0.01)
    }

    func testTextSimilarityCompletelyDifferent() {
        let sim = ImplicitFeedbackDetector.textSimilarity(
            "the quick brown fox",
            "apple banana cherry date"
        )
        XCTAssertLessThan(sim, 0.1)
    }

    func testTextSimilarityPartialOverlap() {
        let sim = ImplicitFeedbackDetector.textSimilarity(
            "how do I configure the network",
            "how can I set up the network"
        )
        XCTAssertGreaterThanOrEqual(sim, 0.1)
        XCTAssertLessThan(sim, 1.0)
    }

    // MARK: - No False Positives

    func testNormalConversationProducesNoNegativeSignals() {
        let signals = ImplicitFeedbackDetector.detect(
            currentTurn: userTurn("Can you tell me more about the topic details?"),
            previousTurns: [
                assistantTurn("The topic has several interesting aspects."),
                userTurn("Can you tell me about the topic?"),
            ],
            wasInterrupted: false
        )
        // A natural follow-up with high overlap should not trigger abandonment or topic_change.
        let abandonmentSignals = signals.filter {
            $0.signalType == "abandonment"
        }
        XCTAssertTrue(abandonmentSignals.isEmpty, "Follow-up should not trigger abandonment, got: \(signals.map(\.signalType))")
    }
}
