import AVFoundation
import Foundation

// MARK: - LLM Messages (distinct from UI ChatMessage in ConversationController)

struct LLMMessage: Sendable, Codable {
    enum Role: String, Sendable, Codable { case system, user, assistant, tool }
    let role: Role
    let content: String
    let toolCallID: String?
    let name: String?

    init(role: Role, content: String, toolCallID: String? = nil, name: String? = nil) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.name = name
    }
}

// MARK: - Audio Types

struct AudioChunk: Sendable {
    let samples: [Float]
    let sampleRate: Int
}

struct SpeechSegment: Sendable {
    let samples: [Float]
    let sampleRate: Int
    let durationSeconds: Double
}

// MARK: - Pipeline Types

struct SentenceChunk: Sendable {
    let text: String
    let isFinal: Bool
}

struct ConversationTurn: Sendable {
    let userText: String
    let assistantText: String
    let timestamp: Date
    let toolsUsed: [String]
}

// MARK: - ML Types

struct STTResult: Sendable {
    let text: String
    let language: String?
    let confidence: Float?
}

struct GenerationOptions: Sendable {
    var temperature: Float = 0.7
    var topP: Float = 0.9
    var maxTokens: Int = 2048
    var repetitionPenalty: Float? = 1.1
    /// When true, pass `enable_thinking: false` to the model's chat template.
    /// Required for Qwen3.5-35B-A3B which does not support `/no_think` per-turn.
    var suppressThinking: Bool = true
}
