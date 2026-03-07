import XCTest
@testable import Fae

@MainActor
final class EndToEndConversationRoutingFlowTests: XCTestCase {
    func testCoworkToolAndRuntimeEventsStayInCoworkThenResetCleanly() async throws {
        let bridge = ConversationBridgeController()
        let subtitle = SubtitleStateController()
        let mainConversation = ConversationController()
        let coworkConversation = ConversationController()
        bridge.subtitleState = subtitle
        bridge.conversationController = mainConversation
        bridge.coworkConversationController = coworkConversation

        NotificationCenter.default.post(
            name: .faeCoworkConversationRoutingChanged,
            object: nil,
            userInfo: ["active": true]
        )
        try await flushNotifications()

        NotificationCenter.default.post(
            name: .faeToolExecution,
            object: nil,
            userInfo: ["type": "executing", "name": "read"]
        )
        try await flushNotifications()

        XCTAssertEqual(coworkConversation.backgroundToolJobsInFlight, 1)
        XCTAssertEqual(coworkConversation.messages.last?.role, .tool)
        XCTAssertTrue(coworkConversation.messages.last?.content.contains("Working: read") == true)
        XCTAssertTrue(mainConversation.messages.isEmpty)
        XCTAssertTrue(subtitle.toolText.contains("Working: read"))

        NotificationCenter.default.post(
            name: .faeToolExecution,
            object: nil,
            userInfo: ["type": "result", "name": "read", "success": true]
        )
        try await flushNotifications()

        XCTAssertEqual(coworkConversation.backgroundToolJobsInFlight, 0)
        XCTAssertTrue(coworkConversation.messages.last?.content.contains("Done: read") == true)

        mainConversation.beginBackgroundLookup()
        coworkConversation.beginBackgroundLookup()
        NotificationCenter.default.post(
            name: .faeRuntimeState,
            object: nil,
            userInfo: ["event": "runtime.stopped"]
        )
        try await flushNotifications()

        XCTAssertEqual(mainConversation.backgroundToolJobsInFlight, 0)
        XCTAssertEqual(coworkConversation.backgroundToolJobsInFlight, 0)
    }

    func testRouteBackToMainAfterCoworkTurnSendsNewTranscriptToMainConversation() async throws {
        let bridge = ConversationBridgeController()
        let mainConversation = ConversationController()
        let coworkConversation = ConversationController()
        bridge.conversationController = mainConversation
        bridge.coworkConversationController = coworkConversation

        NotificationCenter.default.post(
            name: .faeCoworkConversationRoutingChanged,
            object: nil,
            userInfo: ["active": true]
        )
        try await flushNotifications()
        NotificationCenter.default.post(
            name: .faeTranscription,
            object: nil,
            userInfo: ["text": "cowork turn", "is_final": true]
        )
        try await flushNotifications()

        NotificationCenter.default.post(
            name: .faeCoworkConversationRoutingChanged,
            object: nil,
            userInfo: ["active": false]
        )
        try await flushNotifications()
        NotificationCenter.default.post(
            name: .faeTranscription,
            object: nil,
            userInfo: ["text": "main turn", "is_final": true]
        )
        try await flushNotifications()

        XCTAssertEqual(coworkConversation.messages.map(\.content), ["cowork turn"])
        XCTAssertEqual(mainConversation.messages.map(\.content), ["main turn"])
    }

    private func flushNotifications() async throws {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}
