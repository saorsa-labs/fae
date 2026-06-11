import XCTest
@testable import Fae

final class CoworkLLMProviderTests: XCTestCase {

    // MARK: - CoworkBackendPresetCatalog

    func testPresetNil() {
        let preset = CoworkBackendPresetCatalog.preset(id: nil)
        XCTAssertNil(preset)
    }

    func testPresetUnknown() {
        let preset = CoworkBackendPresetCatalog.preset(id: "nonexistent-id")
        XCTAssertNil(preset)
    }

    func testPresetsForKind() {
        let presets = CoworkBackendPresetCatalog.presets(for: .openAICompatibleExternal)
        XCTAssertFalse(presets.isEmpty)
    }

    func testDefaultPreset() {
        let preset = CoworkBackendPresetCatalog.defaultPreset(for: .openAICompatibleExternal)
        XCTAssertFalse(preset.id.isEmpty)
    }

    // MARK: - CoworkReasoningHints

    func testOpenAIReasoningO1() {
        let reasoning = CoworkReasoningHints.openAICompatibleReasoning(
            baseURL: "https://api.openai.com", model: "o1-preview", level: .fast
        )
        XCTAssertNotNil(reasoning)
    }

    func testOpenAIReasoningNonReasoning() {
        let reasoning = CoworkReasoningHints.openAICompatibleReasoning(
            baseURL: "https://api.example.com", model: "gpt-3.5-turbo", level: .fast
        )
        XCTAssertNil(reasoning)
    }

    func testOpenAIReasoningOpenRouter() {
        let reasoning = CoworkReasoningHints.openAICompatibleReasoning(
            baseURL: "https://openrouter.ai/api", model: "any-model", level: .balanced
        )
        XCTAssertNotNil(reasoning)
    }

    func testAnthropicEffortOpus() {
        let effort = CoworkReasoningHints.anthropicEffort(
            model: "claude-opus-4-5", level: .deep
        )
        XCTAssertNotNil(effort)
    }

    func testAnthropicEffortNonSupported() {
        let effort = CoworkReasoningHints.anthropicEffort(
            model: "claude-haiku", level: .fast
        )
        XCTAssertNil(effort)
    }

    // MARK: - CoworkSSEParser

    func testPayloadFromDataLine() {
        let payload = CoworkSSEParser.payload(from: "data: {\"content\":\"hello\"}")
        XCTAssertEqual(payload, "{\"content\":\"hello\"}")
    }

    func testPayloadFromEmptyLine() {
        let payload = CoworkSSEParser.payload(from: "")
        XCTAssertNil(payload)
    }

    // MARK: - CoworkNetworkTransport

    func testNormalizedBaseURLWithTrailingSlash() {
        // normalizedBaseURL only trims whitespace and applies the fallback —
        // a trailing slash is preserved (URL path appending tolerates it).
        let url = CoworkProviderConnectionTester.normalizedBaseURL("  https://api.example.com/  ", fallback: "https://fallback.com")
        XCTAssertEqual(url, "https://api.example.com/")
    }

    func testNormalizedBaseURLEmpty() {
        let url = CoworkProviderConnectionTester.normalizedBaseURL("", fallback: "https://fallback.com")
        XCTAssertEqual(url, "https://fallback.com")
    }

    func testParseModelIDs() throws {
        let json = #"{"data":[{"id":"model-1"},{"id":"model-2"}]}"#
        let data = json.data(using: .utf8)!
        let models = CoworkProviderConnectionTester.parseModelIDs(from: data)
        XCTAssertEqual(models.count, 2)
    }

    func testParseModelIDSEmpty() {
        let models = CoworkProviderConnectionTester.parseModelIDs(from: Data())
        XCTAssertTrue(models.isEmpty)
    }

    // MARK: - CoworkPromptEgressPolicy

    func testStatusTextShareableOnly() {
        let prompt = WorkWithFaePreparedPrompt(
            userVisiblePrompt: "visible",
            faeLocalPrompt: "local",
            shareablePrompt: "shareable",
            containsLocalOnlyContext: false,
            shareableExport: nil
        )
        let request = CoworkProviderRequest(model: "test", preparedPrompt: prompt)
        let status = CoworkPromptEgressPolicy.statusText(for: request)
        XCTAssertTrue(status.contains("shareable"))
    }

    // MARK: - errorMessage (OpenAICompatibleCoworkProvider)

    func testErrorMessageString() {
        let json = "{\"error\": \"Rate limit exceeded\"}"
        let data = json.data(using: .utf8)!
        let msg = OpenAICompatibleCoworkProvider.errorMessage(from: data)
        XCTAssertEqual(msg, "Rate limit exceeded")
    }

    func testErrorMessageObject() {
        let json = "{\"error\": {\"message\": \"Invalid API key\"}}"
        let data = json.data(using: .utf8)!
        let msg = OpenAICompatibleCoworkProvider.errorMessage(from: data)
        XCTAssertEqual(msg, "Invalid API key")
    }

    func testErrorMessageNone() {
        let json = "{\"choices\": []}"
        let data = json.data(using: .utf8)!
        let msg = OpenAICompatibleCoworkProvider.errorMessage(from: data)
        XCTAssertNil(msg)
    }

    func testErrorMessageInvalidJSON() {
        let msg = OpenAICompatibleCoworkProvider.errorMessage(from: "not json".data(using: .utf8)!)
        XCTAssertNil(msg)
    }
}
