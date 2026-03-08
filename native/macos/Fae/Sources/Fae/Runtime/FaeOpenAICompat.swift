import Foundation

struct FaeOpenAICompatChatRequest: Decodable {
    struct Message: Decodable {
        struct ContentPart: Decodable {
            struct ImageURL: Decodable {
                let url: String
            }

            let type: String
            let text: String?
            let imageURL: ImageURL?

            enum CodingKeys: String, CodingKey {
                case type
                case text
                case imageURL = "image_url"
            }
        }

        enum Content: Decodable {
            case text(String)
            case parts([ContentPart])

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) {
                    self = .text(text)
                    return
                }
                self = .parts(try container.decode([ContentPart].self))
            }

            var flattenedText: String {
                switch self {
                case .text(let text):
                    return text
                case .parts(let parts):
                    return parts.compactMap { part in
                        if let text = part.text, !text.isEmpty {
                            return text
                        }
                        if let imageURL = part.imageURL?.url, !imageURL.isEmpty {
                            return "[image: \(imageURL)]"
                        }
                        return nil
                    }.joined(separator: "\n")
                }
            }
        }

        let role: String
        let content: Content
    }

    let model: String
    let messages: [Message]
    let stream: Bool?
    let metadata: [String: String]?

    var lastUserText: String? {
        messages
            .reversed()
            .first { $0.role.caseInsensitiveCompare("user") == .orderedSame }?
            .content
            .flattenedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
    }

    var visiblePrompt: String {
        metadata?["user_visible_prompt"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? lastUserText
            ?? ""
    }

    var injectedPrompt: String {
        metadata?["injected_prompt"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? lastUserText
            ?? ""
    }
}

enum FaeOpenAICompatResponseFactory {
    static func chatCompletion(
        id: String,
        model: String,
        content: String,
        finishReason: String,
        faeStatus: String,
        approvalPending: Bool
    ) -> [String: Any] {
        [
            "id": id,
            "object": "chat.completion",
            "created": Int(Date().timeIntervalSince1970),
            "model": model,
            "choices": [
                [
                    "index": 0,
                    "message": [
                        "role": "assistant",
                        "content": content,
                    ],
                    "finish_reason": finishReason,
                ],
            ],
            "usage": [
                "prompt_tokens": 0,
                "completion_tokens": 0,
                "total_tokens": 0,
            ],
            "fae": [
                "status": faeStatus,
                "approval_pending": approvalPending,
            ],
        ]
    }

    static func models(defaultModel: String) -> [String: Any] {
        [
            "object": "list",
            "data": [
                [
                    "id": defaultModel,
                    "object": "model",
                    "owned_by": "fae",
                ],
            ],
        ]
    }
}

