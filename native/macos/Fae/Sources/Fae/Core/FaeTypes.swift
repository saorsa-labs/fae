import AVFoundation
import FaeInference
import Foundation

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

enum FaeThinkingLevel: String, CaseIterable, Codable, Identifiable, Sendable {
    case fast
    case balanced
    case deep

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast:
            return "Fast"
        case .balanced:
            return "Balanced"
        case .deep:
            return "Deep"
        }
    }

    var systemImage: String {
        switch self {
        case .fast:
            return "bolt.fill"
        case .balanced:
            return "sparkles"
        case .deep:
            return "brain.head.profile"
        }
    }

    var shortDescription: String {
        switch self {
        case .fast:
            return "Minimize deliberate reasoning for the quickest response."
        case .balanced:
            return "Use normal reasoning for a balanced speed/quality tradeoff."
        case .deep:
            return "Use deeper reasoning and a larger local response budget for hard tasks."
        }
    }

    var enablesThinking: Bool {
        self != .fast
    }

    var openAIReasoningEffort: String {
        switch self {
        case .fast:
            return "low"
        case .balanced:
            return "medium"
        case .deep:
            return "high"
        }
    }

    var anthropicEffort: String {
        switch self {
        case .fast:
            return "low"
        case .balanced:
            return "medium"
        case .deep:
            return "high"
        }
    }

    var localReasoningDirective: String? {
        switch self {
        case .fast:
            return nil
        case .balanced:
            return nil
        case .deep:
            return "Reason more deliberately than usual. Verify assumptions, compare alternatives, and prefer completeness over speed for this turn."
        }
    }

    var additionalLocalMaxTokens: Int {
        switch self {
        case .fast, .balanced:
            return 0
        case .deep:
            return 2048
        }
    }

    var next: FaeThinkingLevel {
        switch self {
        case .fast:
            return .balanced
        case .balanced:
            return .deep
        case .deep:
            return .fast
        }
    }
}

struct STTResult: Sendable {
    let text: String
    let language: String?
    let confidence: Float?
    /// Wall-clock time when the utterance was captured (propagated from VAD onset).
    var capturedAt: Date? = nil
}
