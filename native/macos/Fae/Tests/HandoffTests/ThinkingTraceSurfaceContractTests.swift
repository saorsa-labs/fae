import XCTest
@testable import Fae

final class ThinkingTraceSurfaceContractTests: XCTestCase {
    func testMainConversationSurfaceRendersThinkingCrawlAndReplayIcon() throws {
        let source = try loadRepositoryText(relativePath: "native/macos/Fae/Sources/Fae/ConversationScrollView.swift")

        XCTAssertTrue(source.contains("ThinkingCrawlView(text: conversation.streamingThinkText)"))
        XCTAssertTrue(source.contains("ThinkIconBubble(thinkTrace: trace)"))
        XCTAssertTrue(source.contains("conversation.streamingThinkText.isEmpty"))
    }

    func testCoworkSurfaceKeepsThinkingCrawlAndReplayIconHooks() throws {
        let source = try loadRepositoryText(relativePath: "native/macos/Fae/Sources/Fae/Cowork/CoworkWorkspaceView.swift")

        XCTAssertTrue(source.contains("ThinkingCrawlView(text: conversation.streamingThinkText)"))
        XCTAssertTrue(source.contains("ThinkIconBubble(thinkTrace: trace)"))
        XCTAssertTrue(source.contains("conversationBubblesOpacity"))
    }

    private func loadRepositoryText(relativePath: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
