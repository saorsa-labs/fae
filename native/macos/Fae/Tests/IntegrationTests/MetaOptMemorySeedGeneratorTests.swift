import XCTest
@testable import Fae

final class MetaOptMemorySeedGeneratorTests: XCTestCase {

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

    // MARK: - isToolRelated

    func testIsToolRelatedYes() {
        let event = makeEvent(signalType: "tool_execution", userInput: nil, assistantOutput: nil)
        XCTAssertTrue(MetaOptMemorySeedGenerator.isToolRelated(event))
    }

    func testIsToolRelatedNo() {
        let event = makeEvent(signalType: "praise", userInput: "hello", assistantOutput: nil)
        XCTAssertFalse(MetaOptMemorySeedGenerator.isToolRelated(event))
    }

    // MARK: - isScheduleRelated

    func testIsScheduleRelatedYes() {
        let event = makeEvent(signalType: "scheduler_update", userInput: nil, assistantOutput: nil)
        XCTAssertTrue(MetaOptMemorySeedGenerator.isScheduleRelated(event))
    }

    func testIsScheduleRelatedNo() {
        let event = makeEvent(signalType: "praise", userInput: "hello", assistantOutput: nil)
        XCTAssertFalse(MetaOptMemorySeedGenerator.isScheduleRelated(event))
    }

    // MARK: - isSerializationRelated

    func testIsSerializationRelatedYes() {
        let event = makeEvent(signalType: "correction", userInput: "the JSON was malformed", assistantOutput: nil)
        XCTAssertTrue(MetaOptMemorySeedGenerator.isSerializationRelated(event))
    }

    func testIsSerializationRelatedNo() {
        let event = makeEvent(signalType: "praise", userInput: "hello world", assistantOutput: nil)
        XCTAssertFalse(MetaOptMemorySeedGenerator.isSerializationRelated(event))
    }
}
