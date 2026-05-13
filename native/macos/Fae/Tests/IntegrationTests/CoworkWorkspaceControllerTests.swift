import XCTest
@testable import Fae

@MainActor final class CoworkWorkspaceControllerTests: XCTestCase {

    // MARK: - workspaceConversationMessage(from:)

    func testWorkspaceConversationMessage() {
        let chatMsg = ChatMessage(
            id: UUID(), role: .user, content: "Hello",
            timestamp: Date(), modelID: nil, providerKind: nil
        )
        let convMsg = CoworkWorkspaceController.workspaceConversationMessage(from: chatMsg)
        XCTAssertEqual(convMsg.role, "user")
        XCTAssertEqual(convMsg.content, "Hello")
    }

    // MARK: - chatMessage(from:)

    func testChatMessageFromWorkWithFae() {
        let convMsg = WorkWithFaeConversationMessage(id: UUID(), role: "assistant", content: "Hi there")
        let chatMsg = CoworkWorkspaceController.chatMessage(from: convMsg)
        XCTAssertNotNil(chatMsg)
        XCTAssertEqual(chatMsg?.role, .assistant)
        XCTAssertEqual(chatMsg?.content, "Hi there")
    }

    func testChatMessageInvalidRole() {
        let convMsg = WorkWithFaeConversationMessage(id: UUID(), role: "invalid_role", content: "test")
        let chatMsg = CoworkWorkspaceController.chatMessage(from: convMsg)
        XCTAssertNil(chatMsg)
    }
}
