import Foundation

enum CoworkLLMProviderKind: String, Sendable {
    case faeLocalhost
    case openAICompatibleExternal

    var trust: WorkWithFaeProviderTrust {
        switch self {
        case .faeLocalhost:
            return .faeLocalhost
        case .openAICompatibleExternal:
            return .externalOpenAICompatible
        }
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
                    "content": request.preparedPrompt.faeLocalPrompt,
                ],
            ],
            "metadata": [
                "user_visible_prompt": request.preparedPrompt.userVisiblePrompt,
                "injected_prompt": request.preparedPrompt.faeLocalPrompt,
                "context_scope": request.preparedPrompt.containsLocalOnlyContext ? "local_only" : "shareable",
            ],
        ]

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
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
