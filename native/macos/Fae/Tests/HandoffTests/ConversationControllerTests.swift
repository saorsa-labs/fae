import XCTest
import FaeHandoffKit
@testable import Fae

@MainActor
final class ConversationRuntimeControllerTests: XCTestCase {
    func testHandleUserSentTrimsAppendsAndPostsInjectNotification() async throws {
        let controller = ConversationRuntimeController()
        let expectation = expectation(forNotification: .faeConversationInjectText, object: nil) { notification in
            notification.userInfo?["text"] as? String == "hello fae"
        }

        controller.handleUserSent("  hello fae  ")

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertEqual(controller.messages.map(\.content), ["hello fae"])
        XCTAssertEqual(controller.messages.last?.role, .user)
    }

    func testHandleUserSentIgnoresWhitespaceOnlyInput() {
        let controller = ConversationRuntimeController()
        controller.handleUserSent("   \n  ")
        XCTAssertTrue(controller.messages.isEmpty)
    }

    func testAppendMessageCapsToLatestTwoHundredMessages() {
        let controller = ConversationRuntimeController()

        for index in 0..<250 {
            controller.appendMessage(role: .user, content: "message-\(index)")
        }

        XCTAssertEqual(controller.messages.count, 200)
        XCTAssertEqual(controller.messages.first?.content, "message-50")
        XCTAssertEqual(controller.messages.last?.content, "message-249")
    }

    func testReplaceMessagesResetsStreamingFlagsAndKeepsNewestMessages() {
        let controller = ConversationRuntimeController()
        controller.isGenerating = true
        controller.startStreaming()
        controller.updateStreaming(text: "partial")
        controller.appendThinkingTrace("trace")
        controller.completedThinkTrace = "previous trace"

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
        XCTAssertEqual(controller.streamingThinkText, "")
        XCTAssertNil(controller.completedThinkTrace)
    }

    func testFinalizeStreamingCommitsAssistantMessageAndClearsState() {
        let controller = ConversationRuntimeController()
        controller.startStreaming()
        controller.updateStreaming(text: "final answer")

        controller.finalizeStreaming()

        XCTAssertEqual(controller.messages.last?.role, .assistant)
        XCTAssertEqual(controller.messages.last?.content, "final answer")
        XCTAssertFalse(controller.isStreaming)
        XCTAssertEqual(controller.streamingText, "")
    }

    func testCancelStreamingCommitsPartialAssistantMessageAndClearsState() {
        let controller = ConversationRuntimeController()
        controller.startStreaming()
        controller.updateStreaming(text: "partial answer")

        controller.cancelStreaming()

        XCTAssertEqual(controller.messages.last?.role, .assistant)
        XCTAssertEqual(controller.messages.last?.content, "partial answer")
        XCTAssertFalse(controller.isStreaming)
        XCTAssertEqual(controller.streamingText, "")
    }

    func testStartStreamingReplyFinalizesThinkingTraceIntoReplayState() {
        let controller = ConversationRuntimeController()
        controller.beginThinkingTurn(placeholderTrace: "Preparing context")
        controller.appendThinkingTrace("\nWaiting for first tokens")

        controller.startStreamingReply()

        XCTAssertTrue(controller.isGenerating)
        XCTAssertTrue(controller.isStreaming)
        XCTAssertEqual(controller.streamingThinkText, "")
        XCTAssertEqual(
            controller.completedThinkTrace,
            "Preparing context\nWaiting for first tokens"
        )
    }

    func testBeginThinkingTurnClearsPreviousTraceAndStreamingState() {
        let controller = ConversationRuntimeController()
        controller.completedThinkTrace = "previous trace"
        controller.startStreaming()
        controller.updateStreaming(text: "partial reply")

        controller.beginThinkingTurn(placeholderTrace: "Fresh trace")

        XCTAssertTrue(controller.isGenerating)
        XCTAssertFalse(controller.isStreaming)
        XCTAssertEqual(controller.streamingText, "")
        XCTAssertEqual(controller.streamingThinkText, "Fresh trace")
        XCTAssertNil(controller.completedThinkTrace)
    }

    func testRestoreAndClearSnapshotRoundTrip() {
        let controller = ConversationRuntimeController()
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

    // MARK: - Per-Message Model Metadata (Phase 1.1)

    func testAppendMessageStoresModelIDAndProviderKind() {
        let controller = ConversationRuntimeController()
        controller.appendMessage(role: .assistant, content: "reply", modelID: "gpt-4o", providerKind: "openAICompatibleExternal")
        XCTAssertEqual(controller.messages.last?.modelID, "gpt-4o")
        XCTAssertEqual(controller.messages.last?.providerKind, "openAICompatibleExternal")
    }

    func testAppendMessageNilMetadataForUserMessages() {
        let controller = ConversationRuntimeController()
        controller.appendMessage(role: .user, content: "hello")
        XCTAssertNil(controller.messages.last?.modelID)
        XCTAssertNil(controller.messages.last?.providerKind)
    }

    func testFinalizeStreamingPreservesModelMetadata() {
        let controller = ConversationRuntimeController()
        controller.startStreaming()
        controller.updateStreaming(text: "streamed response")
        controller.finalizeStreaming(modelID: "claude-opus-4-6", providerKind: "anthropic")
        XCTAssertEqual(controller.messages.last?.modelID, "claude-opus-4-6")
        XCTAssertEqual(controller.messages.last?.providerKind, "anthropic")
        XCTAssertFalse(controller.isStreaming)
    }

    func testCancelStreamingPreservesModelMetadata() {
        let controller = ConversationRuntimeController()
        controller.startStreaming()
        controller.updateStreaming(text: "partial answer")
        controller.cancelStreaming(modelID: "gpt-4o", providerKind: "openAICompatibleExternal")
        XCTAssertEqual(controller.messages.last?.modelID, "gpt-4o")
        XCTAssertEqual(controller.messages.last?.providerKind, "openAICompatibleExternal")
    }

    func testFinalizeStreamingWithNilMetadataLeavesFieldsNil() {
        let controller = ConversationRuntimeController()
        controller.startStreaming()
        controller.updateStreaming(text: "no metadata")
        controller.finalizeStreaming()
        XCTAssertNil(controller.messages.last?.modelID)
        XCTAssertNil(controller.messages.last?.providerKind)
    }

    func testHandleLinkDetectedPostsEventWithoutMutatingMessages() async throws {
        let controller = ConversationRuntimeController()
        let expectation = expectation(forNotification: .faeConversationLinkDetected, object: nil) { notification in
            notification.userInfo?["url"] as? String == "https://example.com/docs"
        }

        controller.handleLinkDetected("  https://example.com/docs  ")

        await fulfillment(of: [expectation], timeout: 1.0)
        XCTAssertTrue(controller.messages.isEmpty)
    }
}
