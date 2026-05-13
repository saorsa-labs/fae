import XCTest
@testable import Fae

final class MetaOptHypothesisGeneratorTests: XCTestCase {

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
        XCTAssertTrue(MetaOptHypothesisGenerator.isToolRelated(event))
    }

    func testIsToolRelatedNo() {
        let event = makeEvent(signalType: "praise", userInput: "hello", assistantOutput: nil)
        XCTAssertFalse(MetaOptHypothesisGenerator.isToolRelated(event))
    }

    // MARK: - isSerializationRelated

    func testIsSerializationRelatedYes() {
        let event = makeEvent(signalType: "correction", userInput: "the JSON was malformed", assistantOutput: nil)
        XCTAssertTrue(MetaOptHypothesisGenerator.isSerializationRelated(event))
    }

    func testIsSerializationRelatedNo() {
        let event = makeEvent(signalType: "praise", userInput: "hello world", assistantOutput: nil)
        XCTAssertFalse(MetaOptHypothesisGenerator.isSerializationRelated(event))
    }

    // MARK: - directiveAlreadyContains

    func testDirectiveAlreadyContainsYes() {
        XCTAssertTrue(MetaOptHypothesisGenerator.directiveAlreadyContains(
            "Be concise and helpful", keywords: ["concise"]
        ))
    }

    func testDirectiveAlreadyContainsNo() {
        XCTAssertFalse(MetaOptHypothesisGenerator.directiveAlreadyContains(
            "Be helpful", keywords: ["quantum physics"]
        ))
    }

    func testDirectiveAlreadyContainsNil() {
        XCTAssertFalse(MetaOptHypothesisGenerator.directiveAlreadyContains(
            nil, keywords: ["anything"]
        ))
    }
}
