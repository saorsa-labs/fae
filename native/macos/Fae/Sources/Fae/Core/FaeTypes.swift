import AVFoundation
import Foundation

// MARK: - LLM Messages (distinct from UI ChatMessage in ConversationController)

struct LLMMessage: Sendable, Codable {
    enum Role: String, Sendable, Codable { case system, user, assistant, tool }
    let role: Role
    let content: String
    let toolCallID: String?
    let name: String?
    let tag: String?

    init(role: Role, content: String, toolCallID: String? = nil, name: String? = nil, tag: String? = nil) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.name = name
        self.tag = tag
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
    /// Wall-clock time when speech onset was detected by the VAD.
    let capturedAt: Date
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
    /// Wall-clock time when the utterance was captured (propagated from VAD onset).
    var capturedAt: Date? = nil
}

struct GenerationOptions: Sendable {
    var temperature: Float = 0.7
    var topP: Float = 0.9
    var maxTokens: Int = 2048
    var repetitionPenalty: Float? = 1.1
    /// When true, pass `enable_thinking: false` to the model's chat template.
    /// Required for Qwen3.5-35B-A3B which does not support `/no_think` per-turn.
    var suppressThinking: Bool = true
    /// Native tool specs for MLX tool calling (ToolSpec = `[String: any Sendable]`).
    /// When set, passed to `UserInput.tools` so the chat template enables tool calling mode.
    var tools: [[String: any Sendable]]?

    // MARK: - KV Cache Optimization (Phase 1)

    /// Maximum KV cache size in tokens. When set, uses RotatingKVCache for
    /// bounded memory usage regardless of conversation length. nil = unlimited.
    var maxKVSize: Int?

    /// Quantization bits for KV cache (4 or 8). Reduces KV memory by 4x or 2x respectively.
    /// Requires Flash Attention (available on Apple Silicon). nil = no quantization (f16).
    var kvBits: Int? = 4

    /// Group size for KV cache quantization. Default 64 matches Ollama/mistral.rs.
    var kvGroupSize: Int = 64

    /// Token count after which to begin quantizing the KV cache. Keeps initial
    /// context at full precision for better quality. Default 512.
    var quantizedKVStart: Int = 512

    /// Number of tokens to consider for repetition penalty. Larger windows
    /// catch more repetition patterns. Default 64 (up from MLX default of 20).
    var repetitionContextSize: Int = 64

    /// Prefill step size for chunked prompt processing. Smaller values reduce
    /// memory spikes for large prompts; larger values speed up prefill.
    /// Auto-tuned based on model size if nil.
    var prefillStepSize: Int? = nil
}
