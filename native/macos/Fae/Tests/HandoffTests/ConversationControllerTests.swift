import XCTest
import FaeHandoffKit
@testable import Fae

@MainActor
final class ConversationControllerTests: XCTestCase {
    func testHandleUserSentTrimsAppendsAndPostsInjectNotification() async throws {
        let controller = ConversationController()
        let expectation = expectation(forNotification: .faeConversationInjectText, object: nil) { notification in
            notification.userInfo?["text"] as? String == "hello fae"
        }

        controller.handleUserSent("  hello fae  ")

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(controller.messages.map(\.content), ["hello fae"])
        XCTAssertEqual(controller.messages.last?.role, .user)
    }

    func testHandleUserSentIgnoresWhitespaceOnlyInput() {
        let controller = ConversationController()
        controller.handleUserSent("   \n  ")
        XCTAssertTrue(controller.messages.isEmpty)
    }

    func testAppendMessageCapsToLatestTwoHundredMessages() {
        let controller = ConversationController()

        for index in 0..<250 {
            controller.appendMessage(role: .user, content: "message-\(index)")
        }

        XCTAssertEqual(controller.messages.count, 200)
        XCTAssertEqual(controller.messages.first?.content, "message-50")
        XCTAssertEqual(controller.messages.last?.content, "message-249")
    }

    func testReplaceMessagesResetsStreamingFlagsAndKeepsNewestMessages() {
        let controller = ConversationController()
        controller.isGenerating = true
        controller.startStreaming()
        controller.updateStreaming(text: "partial")

        let messages = (0..<220).map { index in
            ChatMessage(role: index.isMultiple(of: 2) ? .user : .assistant, content: "replacement-\(index)")
        }
        controller.replaceMessages(messages)

        XCTAssertEqual(controller.messages.count, 200)
        XCTAssertEqual(controller.messages.first?.content, "replacement-20")
        XCTAssertEqual(controller.messages.last?.content, "replacement-219")
        XCTAssertFalse(controller.isGenerating)
        XCTAssertFalse(controller.isStreaming)
        XCTAssertEqual(controller.streamingText, "")
    }

    func testFinalizeStreamingCommitsAssistantMessageAndClearsState() {
        let controller = ConversationController()
        controller.startStreaming()
        controller.updateStreaming(text: "final answer")

        controller.finalizeStreaming()

        XCTAssertEqual(controller.messages.last?.role, .assistant)
        XCTAssertEqual(controller.messages.last?.content, "final answer")
        XCTAssertFalse(controller.isStreaming)
        XCTAssertEqual(controller.streamingText, "")
    }

    func testCancelStreamingCommitsPartialAssistantMessageAndClearsState() {
        let controller = ConversationController()
        controller.startStreaming()
        controller.updateStreaming(text: "partial answer")

        controller.cancelStreaming()

        XCTAssertEqual(controller.messages.last?.role, .assistant)
        XCTAssertEqual(controller.messages.last?.content, "partial answer")
        XCTAssertFalse(controller.isStreaming)
        XCTAssertEqual(controller.streamingText, "")
    }

    func testRestoreAndClearSnapshotRoundTrip() {
        let controller = ConversationController()
        let snapshot = ConversationSnapshot(
            entries: [SnapshotEntry(role: "user", content: "hello")],
            orbMode: "idle",
            orbFeeling: "warm",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        controller.restore(from: snapshot, device: "MacBook Pro")

        XCTAssertEqual(controller.restoredSnapshot?.entries.count, 1)
        XCTAssertEqual(controller.restoredFromDevice, "MacBook Pro")

        controller.clearRestoredSnapshot()

        XCTAssertNil(controller.restoredSnapshot)
        XCTAssertNil(controller.restoredFromDevice)
    }

    func testHandleLinkDetectedPostsEventWithoutMutatingMessages() async throws {
        let controller = ConversationController()
        let expectation = expectation(forNotification: .faeConversationLinkDetected, object: nil) { notification in
            notification.userInfo?["url"] as? String == "https://example.com/docs"
        }

        controller.handleLinkDetected("  https://example.com/docs  ")

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertTrue(controller.messages.isEmpty)
    }
}
