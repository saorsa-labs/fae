import XCTest
@testable import Fae

final class ConversationStateTaggingTests: XCTestCase {

    func testRemoveMessagesByTagPreservesOtherHistory() async {
        let state = ConversationStateTracker()

        await state.addUserMessage("proactive-user", tag: "proactive-1")
        await state.addAssistantMessage("proactive-assistant", tag: "proactive-1")
        await state.addUserMessage("normal-user")
        await state.addAssistantMessage("normal-assistant")

        await state.removeMessages(taggedWith: "proactive-1")

        let history = await state.history
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].content, "normal-user")
        XCTAssertEqual(history[1].content, "normal-assistant")
    }

    func testRemoveMessagesByTagRefreshesLastAssistantText() async {
        let state = ConversationStateTracker()

        await state.addAssistantMessage("older")
        await state.addAssistantMessage("proactive", tag: "proactive-2")

        await state.removeMessages(taggedWith: "proactive-2")

        let last = await state.lastAssistantText
        XCTAssertEqual(last, "older")
    }
}
