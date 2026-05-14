import XCTest
@testable import Fae

final class MetaOptSkillGeneratorTests: XCTestCase {

    private func makeEvent(userInput: String?, assistantOutput: String?) -> FeedbackEvent {
        FeedbackEvent(
            id: nil, recordedAt: "2025-01-01T00:00:00Z", signalType: "praise",
            turnFingerprint: "abc123", userInput: userInput, assistantOutput: assistantOutput,
            sentimentScore: 0.5, consumed: false
        )
    }

    // MARK: - isToolRelated

    func testIsToolRelatedYes() {
        let event = makeEvent(userInput: "use the calendar tool", assistantOutput: nil)
        XCTAssertTrue(MetaOptSkillGenerator.isToolRelated(event))
    }

    func testIsToolRelatedNo() {
        let event = makeEvent(userInput: "hello world", assistantOutput: nil)
        XCTAssertFalse(MetaOptSkillGenerator.isToolRelated(event))
    }

    // MARK: - isSerializationRelated

    func testIsSerializationRelatedYes() {
        let event = makeEvent(userInput: "fix the JSON format", assistantOutput: nil)
        XCTAssertTrue(MetaOptSkillGenerator.isSerializationRelated(event))
    }

    func testIsSerializationRelatedNo() {
        let event = makeEvent(userInput: "tell me a joke", assistantOutput: nil)
        XCTAssertFalse(MetaOptSkillGenerator.isSerializationRelated(event))
    }
}
