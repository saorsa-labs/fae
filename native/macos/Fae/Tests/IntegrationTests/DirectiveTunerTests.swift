import XCTest
@testable import Fae

final class DirectiveTunerTests: XCTestCase {

    private func makeEvent(signalType: String, userInput: String?, assistantOutput: String?) -> FeedbackEvent {
        FeedbackEvent(
            id: nil,
            recordedAt: "2025-01-01T00:00:00Z",
            signalType: signalType,
            turnFingerprint: "abc123",
            userInput: userInput,
            assistantOutput: assistantOutput,
            sentimentScore: 0.5,
            consumed: false
        )
    }

    // MARK: - normaliseGroupKey

    func testNormaliseGroupKey() {
        let key = DirectiveTuner.normaliseGroupKey("  Hello World!  ")
        XCTAssertEqual(key, "hello world!")
    }

    func testNormaliseGroupKeyLongText() {
        let longText = String.init(repeating: "a", count: 100)
        let key = DirectiveTuner.normaliseGroupKey(longText)
        XCTAssertEqual(key.count, 50)
    }

    // MARK: - groupByContent

    func testGroupByContent() {
        let events = [
            makeEvent(signalType: "praise", userInput: "hello", assistantOutput: nil),
            makeEvent(signalType: "praise", userInput: "hello", assistantOutput: nil),
            makeEvent(signalType: "correction", userInput: "goodbye", assistantOutput: nil),
        ]
        let groups = DirectiveTuner.groupByContent(events, keyPath: \.userInput)
        XCTAssertEqual(groups["hello"]?.count, 2)
        XCTAssertEqual(groups["goodbye"]?.count, 1)
    }

    func testGroupByContentEmpty() {
        let groups = DirectiveTuner.groupByContent([], keyPath: \.userInput)
        XCTAssertTrue(groups.isEmpty)
    }
}
