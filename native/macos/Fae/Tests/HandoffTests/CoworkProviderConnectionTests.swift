import XCTest
@testable import Fae

final class CoworkProviderConnectionTests: XCTestCase {
    func testOpenAICompatibleModelParsingExtractsIDs() {
        let data = """
        {
          "object": "list",
          "data": [
            {"id": "gpt-4.1"},
            {"id": "openrouter/sonnet"}
          ]
        }
        """.data(using: .utf8)!

        XCTAssertEqual(
            CoworkProviderConnectionTester.parseModelIDs(from: data),
            ["gpt-4.1", "openrouter/sonnet"]
        )
    }

    func testAnthropicModelParsingAlsoExtractsIDs() {
        let data = """
        {
          "data": [
            {"id": "claude-sonnet-4-5"},
            {"id": "claude-opus-4-1"}
          ]
        }
        """.data(using: .utf8)!

        XCTAssertEqual(
            CoworkProviderConnectionTester.parseModelIDs(from: data),
            ["claude-sonnet-4-5", "claude-opus-4-1"]
        )
    }

    func testProviderKindMetadataReflectsAuthExpectations() {
        XCTAssertFalse(CoworkLLMProviderKind.faeLocalhost.requiresAPIKey)
        XCTAssertEqual(CoworkLLMProviderKind.faeLocalhost.defaultBaseURL, "http://127.0.0.1:7434")

        XCTAssertTrue(CoworkLLMProviderKind.openAICompatibleExternal.requiresAPIKey)
        XCTAssertEqual(CoworkLLMProviderKind.openAICompatibleExternal.defaultBaseURL, "https://api.openai.com")
        XCTAssertEqual(CoworkLLMProviderKind.openAICompatibleExternal.displayName, "OpenAI-compatible")

        XCTAssertTrue(CoworkLLMProviderKind.anthropic.requiresAPIKey)
        XCTAssertEqual(CoworkLLMProviderKind.anthropic.defaultBaseURL, "https://api.anthropic.com")
    }

    func testBackendPresetCatalogIncludesUserFriendlyBackends() {
        let ids = Set(CoworkBackendPresetCatalog.presets.map(\.id))
        XCTAssertTrue(ids.contains("fae-local"))
        XCTAssertTrue(ids.contains("openai"))
        XCTAssertTrue(ids.contains("openrouter"))
        XCTAssertTrue(ids.contains("custom-openai-compatible"))
        XCTAssertTrue(ids.contains("anthropic"))
    }

    func testNormalizedBaseURLFallsBackWhenBlank() {
        XCTAssertEqual(
            CoworkProviderConnectionTester.normalizedBaseURL("   ", fallback: "https://api.openai.com"),
            "https://api.openai.com"
        )
        XCTAssertEqual(
            CoworkProviderConnectionTester.normalizedBaseURL("https://openrouter.ai/api", fallback: "https://api.openai.com"),
            "https://openrouter.ai/api"
        )
    }
}
