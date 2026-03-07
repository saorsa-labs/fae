import Foundation
import XCTest
@testable import Fae

@MainActor
final class ThinkingLevelCoworkParityTests: XCTestCase {
    func testReasoningHintsMapThinkingLevelsAcrossProviders() {
        let openAIFast = CoworkReasoningHints.openAICompatibleReasoning(
            baseURL: "https://openrouter.ai/api",
            model: "anthropic/claude-sonnet-4.6",
            level: .fast
        )
        let openAIBalanced = CoworkReasoningHints.openAICompatibleReasoning(
            baseURL: "https://openrouter.ai/api",
            model: "anthropic/claude-sonnet-4.6",
            level: .balanced
        )
        let openAIDeep = CoworkReasoningHints.openAICompatibleReasoning(
            baseURL: "https://openrouter.ai/api",
            model: "anthropic/claude-sonnet-4.6",
            level: .deep
        )

        XCTAssertEqual(openAIFast?["effort"] as? String, "low")
        XCTAssertEqual(openAIBalanced?["effort"] as? String, "medium")
        XCTAssertEqual(openAIDeep?["effort"] as? String, "high")
        XCTAssertEqual(openAIDeep?["exclude"] as? Bool, true)

        XCTAssertEqual(CoworkReasoningHints.anthropicEffort(model: "claude-sonnet-4-6", level: .fast), "low")
        XCTAssertEqual(CoworkReasoningHints.anthropicEffort(model: "claude-sonnet-4-6", level: .balanced), "medium")
        XCTAssertEqual(CoworkReasoningHints.anthropicEffort(model: "claude-sonnet-4-6", level: .deep), "high")
        XCTAssertNil(CoworkReasoningHints.anthropicEffort(model: "claude-haiku-4-5-20251001", level: .deep))
    }

    func testProviderRequestsCarryThinkingLevelMetadata() throws {
        let openAIRequest = CoworkProviderRequest(
            model: "gpt-4.1",
            preparedPrompt: preparedPrompt(),
            thinkingLevel: .balanced
        )
        let openAIURLRequest = try OpenAICompatibleCoworkProvider.makeRequest(
            baseURL: "https://api.openai.com",
            apiKey: "secret-key",
            request: openAIRequest
        )
        let openAIJSON = try XCTUnwrap(jsonObject(from: openAIURLRequest))
        let openAIMetadata = try XCTUnwrap(openAIJSON["metadata"] as? [String: Any])
        XCTAssertEqual(openAIMetadata["thinking_level"] as? String, FaeThinkingLevel.balanced.rawValue)
        XCTAssertNil(openAIJSON["reasoning"])

        let anthropicRequest = CoworkProviderRequest(
            model: "claude-sonnet-4-6",
            preparedPrompt: preparedPrompt(),
            thinkingLevel: .deep
        )
        let anthropicURLRequest = try AnthropicCoworkProvider.makeRequest(
            baseURL: "https://api.anthropic.com",
            apiKey: "sk-ant-test",
            maxTokens: 1024,
            request: anthropicRequest
        )
        let anthropicJSON = try XCTUnwrap(jsonObject(from: anthropicURLRequest))
        let anthropicMetadata = try XCTUnwrap(anthropicJSON["metadata"] as? [String: Any])
        XCTAssertEqual(anthropicMetadata["thinking_level"] as? String, FaeThinkingLevel.deep.rawValue)
        XCTAssertEqual(anthropicJSON["effort"] as? String, "high")
    }

    func testCoworkControllerThinkingLevelControlsDelegateToFaeCore() async throws {
        let core = FaeCore()
        let controller = CoworkWorkspaceController(
            faeCore: core,
            conversation: ConversationController(),
            runtimeDescriptor: nil
        )

        controller.setThinkingLevel(.deep)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(core.thinkingLevel, .deep)
        XCTAssertTrue(core.thinkingEnabled)

        controller.cycleThinkingLevel()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(core.thinkingLevel, .fast)
        XCTAssertFalse(core.thinkingEnabled)
    }

    private func preparedPrompt() -> WorkWithFaePreparedPrompt {
        WorkWithFaePreparedPrompt(
            userVisiblePrompt: "visible prompt",
            faeLocalPrompt: "local prompt",
            shareablePrompt: "shareable prompt",
            containsLocalOnlyContext: true
        )
    }

    private func jsonObject(from request: URLRequest) throws -> [String: Any]? {
        guard let body = request.httpBody else { return nil }
        return try JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}
