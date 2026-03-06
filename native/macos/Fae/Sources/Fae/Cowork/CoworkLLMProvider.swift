import Foundation

struct CoworkProviderConnectionReport: Sendable, Equatable {
    let isReachable: Bool
    let statusText: String
    let discoveredModels: [String]
}

enum CoworkLLMProviderKind: String, CaseIterable, Codable, Sendable {
    case faeLocalhost
    case openAICompatibleExternal
    case anthropic

    var trust: WorkWithFaeProviderTrust {
        switch self {
        case .faeLocalhost:
            return .faeLocalhost
        case .openAICompatibleExternal, .anthropic:
            return .externalOpenAICompatible
        }
    }

    var displayName: String {
        switch self {
        case .faeLocalhost:
            return "Fae Local"
        case .openAICompatibleExternal:
            return "OpenAI-compatible"
        case .anthropic:
            return "Anthropic"
        }
    }

    var shortDescription: String {
        switch self {
        case .faeLocalhost:
            return "Trusted local runtime"
        case .openAICompatibleExternal:
            return "OpenAI, OpenRouter, and compatible endpoints"
        case .anthropic:
            return "Claude models through Anthropic"
        }
    }

    var supportsExecutionNow: Bool {
        true
    }

    var requiresAPIKey: Bool {
        defaultPreset.requiresAPIKey
    }

    var allowsCustomBaseURL: Bool {
        defaultPreset.allowsCustomBaseURL
    }

    var defaultBaseURL: String {
        defaultPreset.defaultBaseURL
    }

    var apiKeyPlaceholder: String {
        defaultPreset.apiKeyPlaceholder
    }

    var setupHint: String {
        defaultPreset.setupHint
    }

    var defaultPreset: CoworkBackendPreset {
        CoworkBackendPresetCatalog.defaultPreset(for: self)
    }
}

struct CoworkBackendPreset: Identifiable, Hashable, Sendable {
    let id: String
    let providerKind: CoworkLLMProviderKind
    let displayName: String
    let shortDescription: String
    let setupHint: String
    let defaultBaseURL: String
    let apiKeyPlaceholder: String
    let suggestedModels: [String]
    let requiresAPIKey: Bool
    let allowsCustomBaseURL: Bool
}

enum CoworkBackendPresetCatalog {
    static let presets: [CoworkBackendPreset] = [
        CoworkBackendPreset(
            id: "fae-local",
            providerKind: .faeLocalhost,
            displayName: "Fae Local",
            shortDescription: "Trusted local runtime",
            setupHint: "Runs entirely on this Mac through Fae's localhost runtime.",
            defaultBaseURL: "http://127.0.0.1:7434",
            apiKeyPlaceholder: "No API key needed",
            suggestedModels: ["fae-agent-local"],
            requiresAPIKey: false,
            allowsCustomBaseURL: false
        ),
        CoworkBackendPreset(
            id: "openai",
            providerKind: .openAICompatibleExternal,
            displayName: "OpenAI",
            shortDescription: "Official OpenAI API",
            setupHint: "Use your OpenAI API key. Fae can discover available models and let you switch between them.",
            defaultBaseURL: "https://api.openai.com",
            apiKeyPlaceholder: "sk-...",
            suggestedModels: ["gpt-4.1", "gpt-4.1-mini", "gpt-4o", "o3-mini"],
            requiresAPIKey: true,
            allowsCustomBaseURL: true
        ),
        CoworkBackendPreset(
            id: "openrouter",
            providerKind: .openAICompatibleExternal,
            displayName: "OpenRouter",
            shortDescription: "Many models behind one OpenAI-compatible API",
            setupHint: "Use OpenRouter when you want broad model choice through one OpenAI-compatible endpoint.",
            defaultBaseURL: "https://openrouter.ai/api",
            apiKeyPlaceholder: "sk-or-v1-...",
            suggestedModels: ["anthropic/claude-opus-4.6", "anthropic/claude-sonnet-4.6", "openai/gpt-4.1", "google/gemini-2.5-pro"],
            requiresAPIKey: true,
            allowsCustomBaseURL: true
        ),
        CoworkBackendPreset(
            id: "custom-openai-compatible",
            providerKind: .openAICompatibleExternal,
            displayName: "Custom OpenAI-compatible",
            shortDescription: "Bring your own compatible endpoint",
            setupHint: "Use this for self-hosted gateways or any provider that exposes an OpenAI-compatible API.",
            defaultBaseURL: "https://api.openai.com",
            apiKeyPlaceholder: "Provider API key",
            suggestedModels: [],
            requiresAPIKey: true,
            allowsCustomBaseURL: true
        ),
        CoworkBackendPreset(
            id: "anthropic",
            providerKind: .anthropic,
            displayName: "Anthropic",
            shortDescription: "Claude models through Anthropic's API",
            setupHint: "Use your Anthropic API key. Fae can test the connection and list available Claude models.",
            defaultBaseURL: "https://api.anthropic.com",
            apiKeyPlaceholder: "sk-ant-...",
            suggestedModels: ["claude-opus-4-6", "claude-sonnet-4-6", "claude-haiku-4-5-20251001"],
            requiresAPIKey: true,
            allowsCustomBaseURL: true
        ),
    ]

    static func preset(id: String?) -> CoworkBackendPreset? {
        guard let id else { return nil }
        return presets.first(where: { $0.id == id })
    }

    static func presets(for providerKind: CoworkLLMProviderKind) -> [CoworkBackendPreset] {
        presets.filter { $0.providerKind == providerKind }
    }

    static func defaultPreset(for providerKind: CoworkLLMProviderKind) -> CoworkBackendPreset {
        presets(for: providerKind).first ?? presets[0]
    }
}

struct CoworkProviderRequest: Sendable {
    let model: String
    let preparedPrompt: WorkWithFaePreparedPrompt
}

struct CoworkProviderResponse: Sendable {
    let content: String
    let status: String
}

enum CoworkProviderError: LocalizedError {
    case unavailable
    case invalidResponse
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "The Work with Fae provider is unavailable."
        case .invalidResponse:
            return "The provider returned an invalid response."
        case .rejected(let reason):
            return reason
        }
    }
}

protocol CoworkLLMProvider: Sendable {
    var kind: CoworkLLMProviderKind { get }
    func submit(request: CoworkProviderRequest) async throws -> CoworkProviderResponse
}

protocol CoworkStreamingProvider: CoworkLLMProvider {
    func stream(
        request: CoworkProviderRequest,
        onPartialText: @escaping @Sendable (String) async -> Void
    ) async throws -> CoworkProviderResponse
}

enum CoworkNetworkTransport {
    typealias Loader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias Streamer = @Sendable (URLRequest) async throws -> (URLResponse, AsyncThrowingStream<String, Error>)

    static var loader: Loader = { request in
        try await URLSession.shared.data(for: request)
    }

    static var streamer: Streamer = { request in
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let lines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
        return (response, lines)
    }
}

enum CoworkPromptEgressPolicy {
    static func prompt(for providerKind: CoworkLLMProviderKind, request: CoworkProviderRequest) -> String {
        switch providerKind {
        case .faeLocalhost:
            return request.preparedPrompt.faeLocalPrompt
        case .openAICompatibleExternal, .anthropic:
            return request.preparedPrompt.shareablePrompt
        }
    }

    static func statusText(for request: CoworkProviderRequest) -> String {
        request.preparedPrompt.containsLocalOnlyContext
            ? "Local-only workspace context stayed on this Mac; only shareable context was sent."
            : "Only shareable workspace context was sent."
    }
}

enum CoworkSSEParser {
    static func payload(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("data:") else { return nil }
        return trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CoworkProviderConnectionTester {
    static func testConnection(
        providerKind: CoworkLLMProviderKind,
        runtimeDescriptor: FaeLocalRuntimeDescriptor?,
        baseURL: String?,
        apiKey: String?
    ) async throws -> CoworkProviderConnectionReport {
        switch providerKind {
        case .faeLocalhost:
            guard let runtimeDescriptor else {
                return CoworkProviderConnectionReport(
                    isReachable: false,
                    statusText: "Fae localhost runtime is unavailable.",
                    discoveredModels: []
                )
            }
            var request = URLRequest(url: runtimeDescriptor.baseURL.appendingPathComponent("health"))
            request.httpMethod = "GET"
            let (data, response) = try await CoworkNetworkTransport.loader(request)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                return CoworkProviderConnectionReport(
                    isReachable: false,
                    statusText: "Fae localhost did not respond successfully.",
                    discoveredModels: []
                )
            }
            let payload = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            let pipeline = payload["pipeline"] as? String ?? "unknown"
            return CoworkProviderConnectionReport(
                isReachable: true,
                statusText: "Connected to Fae localhost (pipeline: \(pipeline)).",
                discoveredModels: [runtimeDescriptor.defaultModel]
            )

        case .openAICompatibleExternal:
            let targetBaseURL = normalizedBaseURL(baseURL, fallback: providerKind.defaultBaseURL)
            guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return CoworkProviderConnectionReport(
                    isReachable: false,
                    statusText: "Add an API key before testing this provider.",
                    discoveredModels: []
                )
            }
            return try await testOpenAICompatibleModels(baseURL: targetBaseURL, apiKey: apiKey)

        case .anthropic:
            let targetBaseURL = normalizedBaseURL(baseURL, fallback: providerKind.defaultBaseURL)
            guard let apiKey, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return CoworkProviderConnectionReport(
                    isReachable: false,
                    statusText: "Add an Anthropic API key before testing this provider.",
                    discoveredModels: []
                )
            }
            return try await testAnthropicModels(baseURL: targetBaseURL, apiKey: apiKey)
        }
    }

    static func normalizedBaseURL(_ baseURL: String?, fallback: String) -> String {
        let trimmed = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false ? trimmed : nil) ?? fallback
    }

    private static func testOpenAICompatibleModels(baseURL: String, apiKey: String) async throws -> CoworkProviderConnectionReport {
        guard let url = URL(string: baseURL)?.appendingPathComponent("v1/models") else {
            throw CoworkProviderError.rejected("The provider URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await CoworkNetworkTransport.loader(request)
        guard let http = response as? HTTPURLResponse else {
            throw CoworkProviderError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw CoworkProviderError.rejected("The provider rejected the API key or endpoint (HTTP \(http.statusCode)).")
        }
        let models = parseModelIDs(from: data)
        return CoworkProviderConnectionReport(
            isReachable: true,
            statusText: models.isEmpty ? "Connected successfully." : "Connected. Found \(models.count) models.",
            discoveredModels: models
        )
    }

    private static func testAnthropicModels(baseURL: String, apiKey: String) async throws -> CoworkProviderConnectionReport {
        guard let url = URL(string: baseURL)?.appendingPathComponent("v1/models") else {
            throw CoworkProviderError.rejected("The Anthropic URL is invalid.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let (data, response) = try await CoworkNetworkTransport.loader(request)
        guard let http = response as? HTTPURLResponse else {
            throw CoworkProviderError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw CoworkProviderError.rejected("Anthropic rejected the API key or endpoint (HTTP \(http.statusCode)).")
        }
        let models = parseModelIDs(from: data)
        return CoworkProviderConnectionReport(
            isReachable: true,
            statusText: models.isEmpty ? "Connected to Anthropic." : "Connected. Found \(models.count) Anthropic models.",
            discoveredModels: models
        )
    }

    static func parseModelIDs(from data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]]
        else {
            return []
        }
        return dataArray.compactMap { item in
            (item["id"] as? String) ?? (item["name"] as? String)
        }
    }
}

struct FaeLocalhostCoworkProvider: CoworkLLMProvider {
    let descriptor: FaeLocalRuntimeDescriptor

    var kind: CoworkLLMProviderKind { .faeLocalhost }

    func submit(request: CoworkProviderRequest) async throws -> CoworkProviderResponse {
        var urlRequest = URLRequest(url: descriptor.baseURL.appendingPathComponent("v1/chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(descriptor.bearerToken)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "model": request.model,
            "messages": [
                [
                    "role": "user",
                    "content": CoworkPromptEgressPolicy.prompt(for: .faeLocalhost, request: request),
                ],
            ],
            "metadata": [
                "user_visible_prompt": request.preparedPrompt.userVisiblePrompt,
                "injected_prompt": request.preparedPrompt.faeLocalPrompt,
                "context_scope": request.preparedPrompt.containsLocalOnlyContext ? "local_only" : "shareable",
            ],
        ]

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await CoworkNetworkTransport.loader(urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CoworkProviderError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw CoworkProviderError.rejected(message ?? "Fae localhost request failed.")
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String
        else {
            throw CoworkProviderError.invalidResponse
        }

        let fae = json["fae"] as? [String: Any]
        let status = fae?["status"] as? String ?? "completed"
        return CoworkProviderResponse(content: content, status: status)
    }
}

struct OpenAICompatibleCoworkProvider: CoworkLLMProvider, CoworkStreamingProvider {
    let baseURL: String
    let apiKey: String

    var kind: CoworkLLMProviderKind { .openAICompatibleExternal }

    func submit(request: CoworkProviderRequest) async throws -> CoworkProviderResponse {
        let urlRequest = try Self.makeRequest(baseURL: baseURL, apiKey: apiKey, request: request)
        let (data, response) = try await CoworkNetworkTransport.loader(urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CoworkProviderError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw CoworkProviderError.rejected(Self.errorMessage(from: data) ?? "Remote OpenAI-compatible request failed.")
        }
        return try Self.parseResponse(data)
    }

    func stream(
        request: CoworkProviderRequest,
        onPartialText: @escaping @Sendable (String) async -> Void
    ) async throws -> CoworkProviderResponse {
        let urlRequest = try Self.makeRequest(baseURL: baseURL, apiKey: apiKey, request: request, stream: true)
        let (response, lines) = try await CoworkNetworkTransport.streamer(urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CoworkProviderError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw CoworkProviderError.rejected("Remote OpenAI-compatible stream failed (HTTP \(httpResponse.statusCode)).")
        }

        var accumulated = ""
        for try await line in lines {
            guard let payload = CoworkSSEParser.payload(from: line) else { continue }
            if payload == "[DONE]" { break }
            if let delta = Self.parseStreamingDelta(payload: payload), !delta.isEmpty {
                accumulated += delta
                await onPartialText(accumulated)
            }
        }

        guard !accumulated.isEmpty else {
            throw CoworkProviderError.invalidResponse
        }
        return CoworkProviderResponse(content: accumulated, status: "completed")
    }

    static func makeRequest(baseURL: String, apiKey: String, request: CoworkProviderRequest, stream: Bool = false) throws -> URLRequest {
        guard let url = URL(string: CoworkProviderConnectionTester.normalizedBaseURL(baseURL, fallback: CoworkLLMProviderKind.openAICompatibleExternal.defaultBaseURL))?.appendingPathComponent("v1/chat/completions") else {
            throw CoworkProviderError.rejected("The provider URL is invalid.")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": request.model,
            "stream": stream,
            "messages": [
                [
                    "role": "user",
                    "content": CoworkPromptEgressPolicy.prompt(for: .openAICompatibleExternal, request: request),
                ],
            ],
            "metadata": [
                "user_visible_prompt": request.preparedPrompt.userVisiblePrompt,
                "context_scope": request.preparedPrompt.containsLocalOnlyContext ? "shareable_only" : "shareable",
            ],
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return urlRequest
    }

    static func parseResponse(_ data: Data) throws -> CoworkProviderResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = parseContent(message["content"])
        else {
            throw CoworkProviderError.invalidResponse
        }
        return CoworkProviderResponse(content: content, status: "completed")
    }

    static func parseStreamingDelta(payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let delta = firstChoice["delta"] as? [String: Any]
        else {
            return nil
        }
        return parseContent(delta["content"])
    }

    static func parseContent(_ raw: Any?) -> String? {
        if let text = raw as? String {
            return text
        }
        if let parts = raw as? [[String: Any]] {
            let combined = parts.compactMap { part -> String? in
                if let text = part["text"] as? String { return text }
                if let type = part["type"] as? String, type == "text", let text = part["content"] as? String { return text }
                return nil
            }.joined(separator: "\n")
            return combined.isEmpty ? nil : combined
        }
        return nil
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? String {
            return error
        }
        if let error = json["error"] as? [String: Any] {
            return error["message"] as? String
        }
        return nil
    }
}

struct AnthropicCoworkProvider: CoworkLLMProvider, CoworkStreamingProvider {
    let baseURL: String
    let apiKey: String
    let maxTokens: Int

    init(baseURL: String, apiKey: String, maxTokens: Int = 8192) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.maxTokens = maxTokens
    }

    var kind: CoworkLLMProviderKind { .anthropic }

    func submit(request: CoworkProviderRequest) async throws -> CoworkProviderResponse {
        let urlRequest = try Self.makeRequest(baseURL: baseURL, apiKey: apiKey, maxTokens: maxTokens, request: request)
        let (data, response) = try await CoworkNetworkTransport.loader(urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CoworkProviderError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw CoworkProviderError.rejected(Self.errorMessage(from: data) ?? "Anthropic request failed.")
        }
        return try Self.parseResponse(data)
    }

    func stream(
        request: CoworkProviderRequest,
        onPartialText: @escaping @Sendable (String) async -> Void
    ) async throws -> CoworkProviderResponse {
        let urlRequest = try Self.makeRequest(baseURL: baseURL, apiKey: apiKey, maxTokens: maxTokens, request: request, stream: true)
        let (response, lines) = try await CoworkNetworkTransport.streamer(urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CoworkProviderError.invalidResponse
        }
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw CoworkProviderError.rejected("Anthropic stream failed (HTTP \(httpResponse.statusCode)).")
        }

        var accumulated = ""
        for try await line in lines {
            guard let payload = CoworkSSEParser.payload(from: line) else { continue }
            if let delta = Self.parseStreamingDelta(payload: payload), !delta.isEmpty {
                accumulated += delta
                await onPartialText(accumulated)
            }
        }

        guard !accumulated.isEmpty else {
            throw CoworkProviderError.invalidResponse
        }
        return CoworkProviderResponse(content: accumulated, status: "completed")
    }

    static func makeRequest(baseURL: String, apiKey: String, maxTokens: Int, request: CoworkProviderRequest, stream: Bool = false) throws -> URLRequest {
        guard let url = URL(string: CoworkProviderConnectionTester.normalizedBaseURL(baseURL, fallback: CoworkLLMProviderKind.anthropic.defaultBaseURL))?.appendingPathComponent("v1/messages") else {
            throw CoworkProviderError.rejected("The Anthropic URL is invalid.")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": request.model,
            "max_tokens": maxTokens,
            "stream": stream,
            "messages": [
                [
                    "role": "user",
                    "content": CoworkPromptEgressPolicy.prompt(for: .anthropic, request: request),
                ],
            ],
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        return urlRequest
    }

    static func parseResponse(_ data: Data) throws -> CoworkProviderResponse {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let parts = json["content"] as? [[String: Any]]
        else {
            throw CoworkProviderError.invalidResponse
        }
        let content = parts.compactMap { part -> String? in
            guard let type = part["type"] as? String, type == "text" else { return nil }
            return part["text"] as? String
        }.joined(separator: "\n")
        guard !content.isEmpty else {
            throw CoworkProviderError.invalidResponse
        }
        return CoworkProviderResponse(content: content, status: "completed")
    }

    static func parseStreamingDelta(payload: String) -> String? {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        if let delta = json["delta"] as? [String: Any],
           let type = delta["type"] as? String,
           type == "text_delta"
        {
            return delta["text"] as? String
        }

        if let type = json["type"] as? String,
           type == "content_block_delta",
           let delta = json["delta"] as? [String: Any],
           let deltaType = delta["type"] as? String,
           deltaType == "text_delta"
        {
            return delta["text"] as? String
        }

        return nil
    }

    private static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let error = json["error"] as? String {
            return error
        }
        if let error = json["error"] as? [String: Any] {
            return error["message"] as? String
        }
        return nil
    }
}

enum CoworkProviderFactory {
    static func provider(for agent: WorkWithFaeAgentProfile, runtimeDescriptor: FaeLocalRuntimeDescriptor?) throws -> any CoworkLLMProvider {
        switch agent.providerKind {
        case .faeLocalhost:
            guard let runtimeDescriptor else {
                throw CoworkProviderError.rejected("Fae localhost runtime is unavailable.")
            }
            return FaeLocalhostCoworkProvider(descriptor: runtimeDescriptor)
        case .openAICompatibleExternal:
            guard let credentialKey = agent.credentialKey,
                  let apiKey = CredentialManager.retrieve(key: credentialKey),
                  !apiKey.isEmpty
            else {
                throw CoworkProviderError.rejected("Add an API key for \(agent.backendDisplayName) before sending prompts.")
            }
            let baseURL = CoworkProviderConnectionTester.normalizedBaseURL(agent.baseURL, fallback: agent.providerKind.defaultBaseURL)
            return OpenAICompatibleCoworkProvider(baseURL: baseURL, apiKey: apiKey)
        case .anthropic:
            guard let credentialKey = agent.credentialKey,
                  let apiKey = CredentialManager.retrieve(key: credentialKey),
                  !apiKey.isEmpty
            else {
                throw CoworkProviderError.rejected("Add an API key for \(agent.backendDisplayName) before sending prompts.")
            }
            let baseURL = CoworkProviderConnectionTester.normalizedBaseURL(agent.baseURL, fallback: agent.providerKind.defaultBaseURL)
            return AnthropicCoworkProvider(baseURL: baseURL, apiKey: apiKey)
        }
    }
}
