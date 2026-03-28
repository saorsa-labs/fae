import AVFoundation
import Combine
import Foundation
@testable import Fae

// MARK: - Mock STT Engine

actor MockSTTEngine: STTEngine {
    var isLoaded: Bool = true
    var loadState: MLEngineLoadState = .loaded
    var transcription: String = "hello world"
    var latencyMs: UInt64 = 0

    func load(modelID: String) async throws {}

    func transcribe(samples: [Float], sampleRate: Int) async throws -> STTResult {
        if latencyMs > 0 {
            try await Task.sleep(nanoseconds: latencyMs * 1_000_000)
        }
        return STTResult(text: transcription, language: "en", confidence: 0.95)
    }
}

// MARK: - Mock LLM Engine

actor MockLLMEngine: LLMEngine {
    var isLoaded: Bool = true
    var loadState: MLEngineLoadState = .loaded
    var tokens: [String] = ["Hello", " there", "!"]
    var tokenDelayMs: UInt64 = 0
    var generateCallCount: Int = 0

    func load(modelID: String) async throws {}

    func generate(
        messages: [LLMMessage],
        systemPrompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        generateCallCount += 1
        let capturedTokens = tokens
        let delayMs = tokenDelayMs
        return AsyncThrowingStream { continuation in
            Task {
                for token in capturedTokens {
                    if delayMs > 0 {
                        try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    }
                    continuation.yield(.text(token))
                }
                continuation.finish()
            }
        }
    }
}

// MARK: - Mock TTS Engine

actor MockTTSEngine: TTSEngine {
    var isLoaded: Bool = true
    var isVoiceLoaded: Bool = false
    var loadState: MLEngineLoadState = .loaded
    var synthesizedTexts: [String] = []
    var chunkDelayMs: UInt64 = 0

    func load(modelID: String) async throws {}

    func synthesize(text: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        synthesizedTexts.append(text)
        let delayMs = chunkDelayMs
        return AsyncThrowingStream { continuation in
            Task {
                guard let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)
                else {
                    continuation.finish()
                    return
                }
                buffer.frameLength = 160
                if delayMs > 0 {
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                }
                continuation.yield(buffer)
                continuation.finish()
            }
        }
    }
}

// MARK: - Mock Speaker Embedding Engine

actor MockSpeakerEmbeddingEngine: SpeakerEmbeddingEngine {
    var isLoaded: Bool = true
    var loadState: MLEngineLoadState = .loaded
    var isOwner: Bool = true

    func load() async throws {}

    func embed(audio: [Float], sampleRate: Int) async throws -> [Float] {
        if isOwner {
            return [Float](repeating: 1.0, count: 1024)
        } else {
            return [Float](repeating: -1.0, count: 1024)
        }
    }
}

// MARK: - Mock Tool

struct MockTool: Tool {
    let name: String
    let description: String = "A mock tool for testing"
    let parametersSchema: String = "{}"
    let riskLevel: ToolRiskLevel
    let requiresApproval: Bool

    var resultJSON: String = "{\"result\": \"ok\"}"

    func execute(input: [String: Any]) async throws -> ToolResult {
        .success(resultJSON)
    }
}

// MARK: - Failing Mock Tool

struct FailingMockTool: Tool {
    let name: String
    let description: String = "A tool that always fails"
    let parametersSchema: String = "{}"
    let riskLevel: ToolRiskLevel = .low
    let requiresApproval: Bool = false

    func execute(input: [String: Any]) async throws -> ToolResult {
        .error("Tool execution failed")
    }
}

// MARK: - Slow Mock Tool

struct SlowMockTool: Tool {
    let name: String
    let description: String = "A tool with configurable delay"
    let parametersSchema: String = "{}"
    let riskLevel: ToolRiskLevel = .low
    let requiresApproval: Bool = false
    let delayMs: UInt64

    func execute(input: [String: Any]) async throws -> ToolResult {
        try await Task.sleep(nanoseconds: delayMs * 1_000_000)
        return .success("{\"result\": \"delayed_ok\"}")
    }
}

// MARK: - Mock Receipt Store

/// In-memory mock receipt store for testing. No SQLite, no disk I/O.
actor MockReceiptStore {
    struct StoredReceipt: @unchecked Sendable {
        let id: String
        let toolName: String
        let arguments: [String: Any]
        let preStatePath: String?
        let preStateBlob: Data?
        let speakerId: String?
        let sessionId: String?
        let turnId: String?
        var undoneAt: Date?
        var undoError: String?

        var isUndone: Bool { undoneAt != nil }
    }

    private(set) var receipts: [String: StoredReceipt] = [:]
    private(set) var createCallCount: Int = 0
    private(set) var undoCallCount: Int = 0
    private(set) var lastReceiptId: String?

    /// Whether to simulate a create failure.
    var shouldFailCreate: Bool = false

    /// Create a receipt in memory. Returns nil when shouldFailCreate is true.
    @discardableResult
    func createReceipt(
        toolName: String,
        arguments: [String: Any],
        preStatePath: String?,
        preStateBlob: Data?,
        speakerId: String?,
        sessionId: String?,
        turnId: String?
    ) -> String? {
        createCallCount += 1
        guard !shouldFailCreate else { return nil }

        let id = UUID().uuidString
        let receipt = StoredReceipt(
            id: id,
            toolName: toolName,
            arguments: arguments,
            preStatePath: preStatePath,
            preStateBlob: preStateBlob,
            speakerId: speakerId,
            sessionId: sessionId,
            turnId: turnId
        )
        receipts[id] = receipt
        lastReceiptId = id
        return id
    }

    /// Undo a receipt by ID. Returns error if not found, already undone, or no pre-state.
    func undo(receiptId: String) -> Result<Void, ReceiptStoreError> {
        undoCallCount += 1
        guard var receipt = receipts[receiptId] else {
            return .failure(.receiptNotFound)
        }
        if receipt.isUndone {
            return .failure(.alreadyUndone)
        }
        // Restore file if pre-state path + blob available.
        if let path = receipt.preStatePath {
            let fm = FileManager.default
            if let blob = receipt.preStateBlob {
                do {
                    try blob.write(to: URL(fileURLWithPath: path), options: .atomic)
                } catch {
                    receipt.undoError = error.localizedDescription
                    receipts[receiptId] = receipt
                    return .failure(.restoreFailed(error.localizedDescription))
                }
            } else {
                // No blob → file was new → delete it
                if fm.fileExists(atPath: path) {
                    do {
                        try fm.removeItem(atPath: path)
                    } catch {
                        receipt.undoError = error.localizedDescription
                        receipts[receiptId] = receipt
                        return .failure(.restoreFailed(error.localizedDescription))
                    }
                }
            }
        }
        receipt.undoneAt = Date()
        receipts[receiptId] = receipt
        return .success(())
    }

    /// All receipt IDs in insertion order (newest last).
    var allReceiptIds: [String] {
        receipts.keys.sorted { (receipts[$0]?.id ?? "") < (receipts[$1]?.id ?? "") }
    }

    func reset() {
        receipts = [:]
        createCallCount = 0
        undoCallCount = 0
        lastReceiptId = nil
        shouldFailCreate = false
    }
}

// MARK: - Mock Receipt Capturing Tool

/// A write-class mock tool that records receipt metadata after execution.
/// Used to test receipt creation without hitting a real SQLite store.
struct MockReceiptCapturingTool: Tool {
    let name: String
    let description: String = "A mock write tool that captures receipt metadata"
    let parametersSchema: String = "{}"
    let riskLevel: ToolRiskLevel
    let requiresApproval: Bool

    var resultJSON: String = "{\"result\": \"ok\"}"

    func execute(input: [String: Any]) async throws -> ToolResult {
        .success(resultJSON)
    }
}

// MARK: - Event Collector

/// Subscribes to FaeEventBus and captures events for assertions.
actor EventCollector {
    private var events: [FaeEvent] = []
    private var cancellable: AnyCancellable?

    func start(bus: FaeEventBus) {
        let collector = self
        cancellable = bus.subject.sink { event in
            Task { await collector.record(event) }
        }
    }

    func record(_ event: FaeEvent) {
        events.append(event)
    }

    func allEvents() -> [FaeEvent] {
        events
    }

    func clear() {
        events.removeAll()
    }
}
