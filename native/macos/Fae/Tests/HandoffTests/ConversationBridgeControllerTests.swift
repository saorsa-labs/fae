import XCTest
@testable import Fae

@MainActor
final class ConversationEventBridgeControllerTests: XCTestCase {
    func testFinalTranscriptionAppendsToConversation() async throws {
        let bridge = ConversationEventBridgeController()
        let subtitle = SubtitleStateController()
        let mainConversation = ConversationRuntimeController()
        bridge.subtitleState = subtitle
        bridge.conversationController = mainConversation

        NotificationCenter.default.post(
            name: .faeTranscription,
            object: nil,
            userInfo: ["text": "Hello Fae", "is_final": true]
        )
        try await flushNotifications()

        XCTAssertEqual(mainConversation.messages.map(\.content), ["Hello Fae"])
        XCTAssertEqual(subtitle.userText, "Hello Fae")
    }

    func testGeneratingAndAssistantStreamingReachConversation() async throws {
        let bridge = ConversationEventBridgeController()
        let mainConversation = ConversationRuntimeController()
        bridge.conversationController = mainConversation

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

        XCTAssertTrue(mainConversation.isGenerating)
        XCTAssertEqual(mainConversation.messages.last?.content, "Streaming reply")
    }

    func testModelLoadedUpdatesLabel() async throws {
        let bridge = ConversationEventBridgeController()
        let mainConversation = ConversationRuntimeController()
        bridge.conversationController = mainConversation

        NotificationCenter.default.post(
            name: .faeModelLoaded,
            object: nil,
            userInfo: ["engine": "llm", "model_id": "mlx-community/Qwen3-4B-4bit"]
        )
        try await flushNotifications()

        XCTAssertEqual(mainConversation.loadedModelLabel, "Qwen3 4B · 4bit")
    }

    func testThinkingTraceFinalizesWhenThinkingEnds() async throws {
        let bridge = ConversationEventBridgeController()
        let mainConversation = ConversationRuntimeController()
        bridge.conversationController = mainConversation

        NotificationCenter.default.post(
            name: .faeAssistantGenerating,
            object: nil,
            userInfo: ["active": true]
        )
        try await flushNotifications()

        NotificationCenter.default.post(
            name: .faeThinkingText,
            object: nil,
            userInfo: ["text": "Local trace", "is_active": true]
        )
        try await flushNotifications()

        NotificationCenter.default.post(
            name: .faeThinkingText,
            object: nil,
            userInfo: ["text": "", "is_active": false]
        )
        try await flushNotifications()

        XCTAssertEqual(mainConversation.completedThinkTrace, "Local trace")
    }

    func testFirstAssistantTokenPromotesLiveThinkingTraceToReplayState() async throws {
        let bridge = ConversationEventBridgeController()
        let mainConversation = ConversationRuntimeController()
        bridge.conversationController = mainConversation

        NotificationCenter.default.post(
            name: .faeAssistantGenerating,
            object: nil,
            userInfo: ["active": true]
        )
        try await flushNotifications()

        NotificationCenter.default.post(
            name: .faeThinkingText,
            object: nil,
            userInfo: ["text": "Local reasoning trace", "is_active": true]
        )
        try await flushNotifications()

        NotificationCenter.default.post(
            name: .faeAssistantMessage,
            object: nil,
            userInfo: ["text": "Visible reply", "is_final": false]
        )
        try await flushNotifications()

        XCTAssertTrue(mainConversation.isStreaming)
        XCTAssertEqual(mainConversation.completedThinkTrace, "Local reasoning trace")
        XCTAssertEqual(mainConversation.streamingThinkText, "")
        XCTAssertEqual(mainConversation.streamingText, "Visible reply")
    }

    func testStartupWarmupStagesKeepProgressVisible() async throws {
        let bridge = ConversationEventBridgeController()
        let subtitle = SubtitleStateController()
        bridge.subtitleState = subtitle

        NotificationCenter.default.post(
            name: .faeRuntimeProgress,
            object: nil,
            userInfo: ["stage": "verify_started"]
        )
        try await flushNotifications()
        XCTAssertEqual(subtitle.progressPercent, 97)
        XCTAssertEqual(subtitle.progressLabel, "Verifying model readiness…")

        NotificationCenter.default.post(
            name: .faeRuntimeProgress,
            object: nil,
            userInfo: ["stage": "verify_complete"]
        )
        try await flushNotifications()
        XCTAssertEqual(subtitle.progressPercent, 98)
        XCTAssertEqual(subtitle.progressLabel, "Models loaded — preparing first response…")

        NotificationCenter.default.post(
            name: .faeRuntimeProgress,
            object: nil,
            userInfo: ["stage": "ready"]
        )
        try await flushNotifications()
        XCTAssertEqual(subtitle.progressPercent, 99)
        XCTAssertEqual(subtitle.progressLabel, "Warming up Fae for the first conversation…")
    }

    private func flushNotifications() async throws {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}
