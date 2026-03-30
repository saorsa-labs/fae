import XCTest
@testable import Fae

final class DirectiveTunerTests: XCTestCase {

    // MARK: - Helpers

    private func makeEvent(
        signalType: String,
        userInput: String? = nil,
        assistantOutput: String? = nil,
        fingerprint: String? = nil
    ) -> FeedbackEvent {
        FeedbackEvent(
            id: nil,
            recordedAt: ISO8601DateFormatter().string(from: Date()),
            signalType: signalType,
            turnFingerprint: fingerprint ?? UUID().uuidString,
            userInput: userInput,
            assistantOutput: assistantOutput,
            sentimentScore: nil,
            consumed: false
        )
    }

    // MARK: - Pattern Detection: Repeated Corrections

    func testDetectsRepeatedCorrectionPattern() {
        let events = (0..<4).map { _ in
            makeEvent(signalType: "correction", userInput: "my name is David not Dave")
        }
        let patterns = DirectiveTuner.detectPatterns(events: events)
        XCTAssertEqual(patterns.count, 1)
        XCTAssertEqual(patterns.first?.patternType, .repeatedCorrection)
        XCTAssertEqual(patterns.first?.frequency, 4)
    }

    func testDoesNotDetectCorrectionBelowThreshold() {
        let events = (0..<2).map { _ in
            makeEvent(signalType: "correction", userInput: "my name is David")
        }
        let patterns = DirectiveTuner.detectPatterns(events: events)
        XCTAssertTrue(patterns.isEmpty)
    }

    // MARK: - Pattern Detection: Persistent Re-asks

    func testDetectsPersistentReaskPattern() {
        let events = (0..<6).map { _ in
            makeEvent(signalType: "re_ask", userInput: "what's the weather like today")
        }
        let patterns = DirectiveTuner.detectPatterns(events: events)
        let reaskPatterns = patterns.filter { $0.patternType == .persistentReask }
        XCTAssertEqual(reaskPatterns.count, 1)
        XCTAssertEqual(reaskPatterns.first?.frequency, 6)
    }

    func testDoesNotDetectReaskBelowThreshold() {
        let events = (0..<4).map { _ in
            makeEvent(signalType: "re_ask", userInput: "what time is it")
        }
        let patterns = DirectiveTuner.detectPatterns(events: events)
        let reaskPatterns = patterns.filter { $0.patternType == .persistentReask }
        XCTAssertTrue(reaskPatterns.isEmpty)
    }

    // MARK: - Pattern Detection: Abandonment Cluster

    func testDetectsAbandonmentClusterPattern() {
        let events = (0..<3).map { _ in
            makeEvent(signalType: "abandonment", assistantOutput: "here are some recipes for dinner")
        }
        let patterns = DirectiveTuner.detectPatterns(events: events)
        let abandonmentPatterns = patterns.filter { $0.patternType == .abandonmentCluster }
        XCTAssertEqual(abandonmentPatterns.count, 1)
        XCTAssertEqual(abandonmentPatterns.first?.frequency, 3)
    }

    // MARK: - Pattern Detection: Style Preference

    func testDetectsStylePreferencePattern() {
        let events = (0..<4).map { _ in
            makeEvent(signalType: "praise", userInput: "that was really helpful, thanks!")
        }
        let patterns = DirectiveTuner.detectPatterns(events: events)
        let stylePatterns = patterns.filter { $0.patternType == .stylePreference }
        XCTAssertEqual(stylePatterns.count, 1)
        XCTAssertGreaterThanOrEqual(stylePatterns.first?.frequency ?? 0, 4)
    }

    // MARK: - Pattern Detection: Mixed Events

    func testMixedEventsDetectMultiplePatterns() {
        var events: [FeedbackEvent] = []
        // 4 corrections (above threshold)
        events += (0..<4).map { _ in makeEvent(signalType: "correction", userInput: "use metric units") }
        // 6 re-asks (above threshold)
        events += (0..<6).map { _ in makeEvent(signalType: "re_ask", userInput: "check my calendar") }
        // 2 abandonments (below threshold)
        events += (0..<2).map { _ in makeEvent(signalType: "abandonment", assistantOutput: "joke") }

        let patterns = DirectiveTuner.detectPatterns(events: events)
        let types = Set(patterns.map(\.patternType))
        XCTAssertTrue(types.contains(.repeatedCorrection))
        XCTAssertTrue(types.contains(.persistentReask))
        XCTAssertFalse(types.contains(.abandonmentCluster))
    }

    func testEmptyEventsProducesNoPatterns() {
        let patterns = DirectiveTuner.detectPatterns(events: [])
        XCTAssertTrue(patterns.isEmpty)
    }

    // MARK: - Amendment Generation

    func testGenerateAmendmentReturnsNilForEmptyPatterns() {
        let result = DirectiveTuner.generateAmendment(patterns: [])
        XCTAssertNil(result)
    }

    func testGenerateAmendmentFormatsCorrectly() {
        let patterns = [
            FeedbackPattern(
                patternType: .repeatedCorrection,
                frequency: 5,
                sampleEvidence: "use metric",
                suggestedAmendment: "Always use metric units."
            ),
        ]
        let result = DirectiveTuner.generateAmendment(patterns: patterns)
        XCTAssertNotNil(result)
        XCTAssertTrue(result?.contains("Auto-tuned") ?? false)
        XCTAssertTrue(result?.contains("Always use metric units.") ?? false)
    }

    func testGenerateAmendmentLimitsToTopThreePatterns() {
        let patterns = (0..<5).map { i in
            FeedbackPattern(
                patternType: .repeatedCorrection,
                frequency: i + 1,
                sampleEvidence: "evidence \(i)",
                suggestedAmendment: "amendment \(i)"
            )
        }
        let result = DirectiveTuner.generateAmendment(patterns: patterns)
        XCTAssertNotNil(result)
        // Should contain top 3 by frequency: 5, 4, 3
        XCTAssertTrue(result?.contains("amendment 4") ?? false)
        XCTAssertTrue(result?.contains("amendment 3") ?? false)
        XCTAssertTrue(result?.contains("amendment 2") ?? false)
        XCTAssertFalse(result?.contains("amendment 0") ?? true)
    }

    // MARK: - Amendment Application

    func testApplyAmendmentToEmptyDirective() {
        let result = DirectiveTuner.applyAmendment(
            amendment: "New rule: be concise.",
            currentDirective: nil
        )
        XCTAssertEqual(result, "New rule: be concise.")
    }

    func testApplyAmendmentAppendsToExistingDirective() {
        let result = DirectiveTuner.applyAmendment(
            amendment: "New rule.",
            currentDirective: "Existing directive."
        )
        XCTAssertEqual(result, "Existing directive.\n\nNew rule.")
    }

    func testApplyAmendmentRespectsMaxLength() {
        let longDirective = String(repeating: "x", count: 1990)
        let result = DirectiveTuner.applyAmendment(
            amendment: "This is a long amendment that should be truncated.",
            currentDirective: longDirective
        )
        XCTAssertLessThanOrEqual(result.count, DirectiveTuner.maxDirectiveLength)
    }

    // MARK: - Normalisation

    func testNormaliseGroupKeyLowercasesAndTrims() {
        let result = DirectiveTuner.normaliseGroupKey("  Hello World  ")
        XCTAssertEqual(result, "hello world")
    }

    func testNormaliseGroupKeyTruncatesTo50Chars() {
        let long = String(repeating: "a", count: 100)
        let result = DirectiveTuner.normaliseGroupKey(long)
        XCTAssertEqual(result.count, 50)
    }
}
