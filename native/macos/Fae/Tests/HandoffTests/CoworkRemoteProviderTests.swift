import XCTest
@testable import Fae

private actor PartialCollector {
    private var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }

    func snapshot() -> [String] {
        values
    }
}

final class CoworkRemoteProviderTests: XCTestCase {
    func testOpenAICompatibleRequestUsesShareablePromptAndBearerAuth() throws {
        let request = CoworkProviderRequest(
            model: "gpt-4.1",
            preparedPrompt: preparedPrompt(),
            thinkingLevel: .balanced
        )

        let urlRequest = try OpenAICompatibleCoworkProvider.makeRequest(
            baseURL: "https://api.openai.com",
            apiKey: "secret-key",
            request: request
        )

        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")

        let json = try XCTUnwrap(jsonObject(from: urlRequest))
        XCTAssertEqual(json["model"] as? String, "gpt-4.1")

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, "shareable prompt")

        let metadata = try XCTUnwrap(json["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["user_visible_prompt"] as? String, "visible prompt")
        XCTAssertEqual(metadata["context_scope"] as? String, "shareable_only")
        XCTAssertEqual(metadata["thinking_level"] as? String, FaeThinkingLevel.balanced.rawValue)
        XCTAssertNil(json["reasoning"])
        XCTAssertEqual(json["stream"] as? Bool, false)
    }

    func testOpenRouterRequestAddsReasoningEffortForThinkingLevels() throws {
        let request = CoworkProviderRequest(
            model: "anthropic/claude-sonnet-4.6",
            preparedPrompt: preparedPrompt(),
            thinkingLevel: .deep
        )

        let urlRequest = try OpenAICompatibleCoworkProvider.makeRequest(
            baseURL: "https://openrouter.ai/api",
            apiKey: "secret-key",
            request: request
        )

        let json = try XCTUnwrap(jsonObject(from: urlRequest))
        let reasoning = try XCTUnwrap(json["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "high")
        XCTAssertEqual(reasoning["exclude"] as? Bool, true)
    }

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

    func testAnthropicRequestUsesShareablePromptAndAnthropicHeaders() throws {
        let request = CoworkProviderRequest(
            model: "claude-sonnet-4-6",
            preparedPrompt: preparedPrompt(),
            thinkingLevel: .deep
        )

        let urlRequest = try AnthropicCoworkProvider.makeRequest(
            baseURL: "https://api.anthropic.com",
            apiKey: "sk-ant-test",
            maxTokens: 1024,
            request: request
        )

        XCTAssertEqual(urlRequest.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")

        let json = try XCTUnwrap(jsonObject(from: urlRequest))
        XCTAssertEqual(json["model"] as? String, "claude-sonnet-4-6")
        XCTAssertEqual(json["max_tokens"] as? Int, 1024)

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["content"] as? String, "shareable prompt")
        let metadata = try XCTUnwrap(json["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["thinking_level"] as? String, FaeThinkingLevel.deep.rawValue)
        XCTAssertEqual(json["effort"] as? String, "high")
        XCTAssertEqual(json["stream"] as? Bool, false)
    }

    func testOpenAICompatibleSubmitParsesResponse() async throws {
        let original = CoworkNetworkTransport.loader
        defer { CoworkNetworkTransport.loader = original }

        CoworkNetworkTransport.loader = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            guard url.absoluteString == "https://api.openai.com/v1/chat/completions" else {
                throw URLError(.unsupportedURL)
            }
            let data = """
            {
              "choices": [
                {
                  "message": {
                    "content": "Remote answer"
                  }
                }
              ]
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }

        let provider = OpenAICompatibleCoworkProvider(baseURL: "https://api.openai.com", apiKey: "secret")
        let response = try await provider.submit(
            request: CoworkProviderRequest(model: "gpt-4.1", preparedPrompt: preparedPrompt())
        )

        XCTAssertEqual(response.content, "Remote answer")
        XCTAssertEqual(response.status, "completed")
    }

    func testOpenAICompatibleStreamParsesSSEChunks() async throws {
        let original = CoworkNetworkTransport.streamer
        defer { CoworkNetworkTransport.streamer = original }

        CoworkNetworkTransport.streamer = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let stream = AsyncThrowingStream<String, Error> { continuation in
                continuation.yield("data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}")
                continuation.yield("data: {\"choices\":[{\"delta\":{\"content\":\" world\"}}]}")
                continuation.yield("data: [DONE]")
                continuation.finish()
            }
            return (response, stream)
        }

        let provider = OpenAICompatibleCoworkProvider(baseURL: "https://api.openai.com", apiKey: "secret")
        let partials = PartialCollector()
        let response = try await provider.stream(
            request: CoworkProviderRequest(model: "gpt-4.1", preparedPrompt: preparedPrompt())
        ) { text in
            await partials.append(text)
        }

        let captured = await partials.snapshot()
        XCTAssertEqual(captured, ["Hello", "Hello world"])
        XCTAssertEqual(response.content, "Hello world")
    }

    func testAnthropicSubmitParsesResponse() async throws {
        let original = CoworkNetworkTransport.loader
        defer { CoworkNetworkTransport.loader = original }

        CoworkNetworkTransport.loader = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            guard url.absoluteString == "https://api.anthropic.com/v1/messages" else {
                throw URLError(.unsupportedURL)
            }
            let data = """
            {
              "content": [
                {"type": "text", "text": "Claude answer"}
              ]
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (data, response)
        }

        let provider = AnthropicCoworkProvider(baseURL: "https://api.anthropic.com", apiKey: "sk-ant-test")
        let response = try await provider.submit(
            request: CoworkProviderRequest(model: "claude-sonnet-4-5", preparedPrompt: preparedPrompt())
        )

        XCTAssertEqual(response.content, "Claude answer")
        XCTAssertEqual(response.status, "completed")
    }

    func testAnthropicStreamParsesSSEChunks() async throws {
        let original = CoworkNetworkTransport.streamer
        defer { CoworkNetworkTransport.streamer = original }

        CoworkNetworkTransport.streamer = { request in
            guard let url = request.url else { throw URLError(.badURL) }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let stream = AsyncThrowingStream<String, Error> { continuation in
                continuation.yield("event: content_block_delta")
                continuation.yield("data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Claude\"}}")
                continuation.yield("data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" rocks\"}}")
                continuation.finish()
            }
            return (response, stream)
        }

        let provider = AnthropicCoworkProvider(baseURL: "https://api.anthropic.com", apiKey: "sk-ant-test")
        let partials = PartialCollector()
        let response = try await provider.stream(
            request: CoworkProviderRequest(model: "claude-sonnet-4-5", preparedPrompt: preparedPrompt())
        ) { text in
            await partials.append(text)
        }

        let captured = await partials.snapshot()
        XCTAssertEqual(captured, ["Claude", "Claude rocks"])
        XCTAssertEqual(response.content, "Claude rocks")
    }

    func testRemoteEgressPolicyUsesShareablePrompt() {
        let request = CoworkProviderRequest(model: "any", preparedPrompt: preparedPrompt())
        XCTAssertEqual(
            CoworkPromptEgressPolicy.prompt(for: .openAICompatibleExternal, request: request),
            "shareable prompt"
        )
        XCTAssertEqual(
            CoworkPromptEgressPolicy.prompt(for: .anthropic, request: request),
            "shareable prompt"
        )
        XCTAssertEqual(
            CoworkPromptEgressPolicy.prompt(for: .faeLocalhost, request: request),
            "local prompt"
        )
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
