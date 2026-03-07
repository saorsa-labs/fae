import XCTest
@testable import Fae

@MainActor
final class ConversationBridgeControllerTests: XCTestCase {
    func testCoworkRoutingSendsFinalTranscriptionToCoworkConversation() async throws {
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
            name: .faeTranscription,
            object: nil,
            userInfo: ["text": "Hello from cowork", "is_final": true]
        )
        try await flushNotifications()

        XCTAssertEqual(coworkConversation.messages.map(\.content), ["Hello from cowork"])
        XCTAssertTrue(mainConversation.messages.isEmpty)
        XCTAssertEqual(subtitle.userText, "Hello from cowork")
    }

    func testDisablingCoworkRoutingReturnsEventsToMainConversation() async throws {
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
            name: .faeCoworkConversationRoutingChanged,
            object: nil,
            userInfo: ["active": false]
        )
        try await flushNotifications()

        NotificationCenter.default.post(
            name: .faeTranscription,
            object: nil,
            userInfo: ["text": "Back to main", "is_final": true]
        )
        try await flushNotifications()

        XCTAssertEqual(mainConversation.messages.map(\.content), ["Back to main"])
        XCTAssertTrue(coworkConversation.messages.isEmpty)
    }

    func testGeneratingAndAssistantStreamingStayOnActiveRoute() async throws {
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
            name: .faeAssistantGenerating,
            object: nil,
            userInfo: ["active": true]
        )
        try await flushNotifications()

        NotificationCenter.default.post(
            name: .faeAssistantMessage,
            object: nil,
            userInfo: ["text": "Streaming reply", "is_final": true]
        )
        try await flushNotifications()

        XCTAssertTrue(coworkConversation.isGenerating)
        XCTAssertEqual(coworkConversation.messages.last?.content, "Streaming reply")
        XCTAssertTrue(mainConversation.messages.isEmpty)
        XCTAssertFalse(mainConversation.isGenerating)
    }

    func testModelLoadedUpdatesMainAndCoworkLabels() async throws {
        let bridge = ConversationBridgeController()
        let mainConversation = ConversationController()
        let coworkConversation = ConversationController()
        bridge.conversationController = mainConversation
        bridge.coworkConversationController = coworkConversation

        NotificationCenter.default.post(
            name: .faeModelLoaded,
            object: nil,
            userInfo: ["engine": "llm", "model_id": "mlx-community/Qwen3-4B-4bit"]
        )
        try await flushNotifications()

        XCTAssertEqual(mainConversation.loadedModelLabel, "Qwen3 4B · 4bit")
        XCTAssertEqual(coworkConversation.loadedModelLabel, "Qwen3 4B · 4bit")
    }

    func testRapidRouteSwitchDeliversToLatestConversationOnly() async throws {
        let bridge = ConversationBridgeController()
        let mainConversation = ConversationController()
        let coworkConversation = ConversationController()
        bridge.conversationController = mainConversation
        bridge.coworkConversationController = coworkConversation

        for isActive in [true, false, true, false, false] {
            NotificationCenter.default.post(
                name: .faeCoworkConversationRoutingChanged,
                object: nil,
                userInfo: ["active": isActive]
            )
        }
        try await flushNotifications()

        NotificationCenter.default.post(
            name: .faeTranscription,
            object: nil,
            userInfo: ["text": "latest route wins", "is_final": true]
        )
        try await flushNotifications()

        XCTAssertEqual(mainConversation.messages.map(\.content), ["latest route wins"])
        XCTAssertTrue(coworkConversation.messages.isEmpty)
    }

    func testRepeatedRouteFlipsKeepUserAndAssistantTurnsBoundToActiveConversation() async throws {
        let bridge = ConversationBridgeController()
        let mainConversation = ConversationController()
        let coworkConversation = ConversationController()
        bridge.conversationController = mainConversation
        bridge.coworkConversationController = coworkConversation

        var expectedMain: [String] = []
        var expectedCowork: [String] = []

        for turn in 1...18 {
            let routesToCowork = turn.isMultiple(of: 2)
            NotificationCenter.default.post(
                name: .faeCoworkConversationRoutingChanged,
                object: nil,
                userInfo: ["active": routesToCowork]
            )
            try await flushNotifications()

            NotificationCenter.default.post(
                name: .faeTranscription,
                object: nil,
                userInfo: ["text": "user-\(turn)", "is_final": true]
            )
            try await flushNotifications()

            NotificationCenter.default.post(
                name: .faeAssistantGenerating,
                object: nil,
                userInfo: ["active": true]
            )
            try await flushNotifications()

            NotificationCenter.default.post(
                name: .faeAssistantMessage,
                object: nil,
                userInfo: ["text": "assistant-\(turn)", "is_final": true]
            )
            try await flushNotifications()

            NotificationCenter.default.post(
                name: .faeAssistantGenerating,
                object: nil,
                userInfo: ["active": false]
            )
            try await flushNotifications()

            if routesToCowork {
                expectedCowork.append(contentsOf: ["user-\(turn)", "assistant-\(turn)"])
            } else {
                expectedMain.append(contentsOf: ["user-\(turn)", "assistant-\(turn)"])
            }

            XCTAssertEqual(mainConversation.messages.map(\.content), expectedMain)
            XCTAssertEqual(coworkConversation.messages.map(\.content), expectedCowork)
            XCTAssertFalse(mainConversation.isGenerating)
            XCTAssertFalse(coworkConversation.isGenerating)
        }
    }

    private func flushNotifications() async throws {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}
