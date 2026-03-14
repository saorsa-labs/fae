import Foundation
import MLXLMCommon

private func repoParts(from modelID: String) -> (org: String, repo: String)? {
    let parts = modelID.split(separator: "/", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return nil }
    return (parts[0], parts[1])
}

private func hasModelPayload(at directory: URL) -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: directory.path) else { return false }
    guard let contents = try? fm.contentsOfDirectory(atPath: directory.path) else {
        return false
    }

    let hasConfig = contents.contains("config.json")
    let hasWeights = contents.contains { $0.hasSuffix(".safetensors") || $0.hasSuffix(".gguf") }
    return hasConfig && hasWeights
}

private func huggingFaceHubCacheDirectory(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> URL {
    if let hubCache = environment["HF_HUB_CACHE"], !hubCache.isEmpty {
        return URL(fileURLWithPath: (hubCache as NSString).expandingTildeInPath, isDirectory: true)
    }

    if let hfHome = environment["HF_HOME"], !hfHome.isEmpty {
        return URL(fileURLWithPath: (hfHome as NSString).expandingTildeInPath, isDirectory: true)
            .appendingPathComponent("hub", isDirectory: true)
    }

    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cache", isDirectory: true)
        .appendingPathComponent("huggingface", isDirectory: true)
        .appendingPathComponent("hub", isDirectory: true)
}

private func cachedHuggingFaceSnapshotDirectory(for modelID: String) -> URL? {
    guard let parts = repoParts(from: modelID) else { return nil }

    let repoDirectory = huggingFaceHubCacheDirectory()
        .appendingPathComponent("models--\(parts.org)--\(parts.repo)", isDirectory: true)
    let refsDirectory = repoDirectory.appendingPathComponent("refs", isDirectory: true)
    let snapshotsDirectory = repoDirectory.appendingPathComponent("snapshots", isDirectory: true)
    let refFile = refsDirectory.appendingPathComponent("main", isDirectory: false)

    if let snapshotRef = try? String(contentsOf: refFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines),
       !snapshotRef.isEmpty
    {
        let snapshotDirectory = snapshotsDirectory.appendingPathComponent(snapshotRef, isDirectory: true)
        if hasModelPayload(at: snapshotDirectory) {
            return snapshotDirectory
        }
    }

    guard let snapshotEntries = try? FileManager.default.contentsOfDirectory(
        at: snapshotsDirectory,
        includingPropertiesForKeys: nil
    ) else {
        return nil
    }

    return snapshotEntries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        .first(where: { hasModelPayload(at: $0) })
}

private func legacyModelCacheDirectory(for modelID: String) -> URL? {
    guard let parts = repoParts(from: modelID) else { return nil }
    let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Caches", isDirectory: true)
        .appendingPathComponent("models", isDirectory: true)
        .appendingPathComponent(parts.org, isDirectory: true)
        .appendingPathComponent(parts.repo, isDirectory: true)
    return hasModelPayload(at: directory) ? directory : nil
}

public func localModelDirectoryURL(from modelID: String) -> URL? {
    let expanded = (modelID as NSString).expandingTildeInPath
    let url = URL(fileURLWithPath: expanded)
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
        return url
    }

    if let snapshotDirectory = cachedHuggingFaceSnapshotDirectory(for: modelID) {
        return snapshotDirectory
    }

    return legacyModelCacheDirectory(for: modelID)
}

private func localModelType(from directory: URL) -> String? {
    let configURL = directory.appendingPathComponent("config.json")
    guard let data = try? Data(contentsOf: configURL),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return nil
    }
    return object["model_type"] as? String
}

public func usesQwenCompatibleToolCallFormat(modelID: String) -> Bool {
    if let directory = localModelDirectoryURL(from: modelID),
       let modelType = localModelType(from: directory)?.lowercased()
    {
        if modelType.contains("qwen") {
            return true
        }
    }

    let lower = modelID.lowercased()
    return lower.contains("qwen")
        || lower.contains("saorsa1-worker")
        || lower.contains("saorsa1-tiny")
}

public enum MLEngineError: LocalizedError {
    case notLoaded(String)
    case loadFailed(String, Error)

    public var errorDescription: String? {
        switch self {
        case .notLoaded(let engine):
            return "\(engine) engine not loaded"
        case .loadFailed(let engine, let error):
            return "\(engine) engine failed to load: \(error.localizedDescription)"
        }
    }
}

public struct LLMMessage: Sendable, Codable, Equatable {
    public enum Role: String, Sendable, Codable {
        case system
        case user
        case assistant
        case tool
    }

    public let role: Role
    public let content: String
    public let toolCallID: String?
    public let name: String?
    public let tag: String?

    public init(
        role: Role,
        content: String,
        toolCallID: String? = nil,
        name: String? = nil,
        tag: String? = nil
    ) {
        self.role = role
        self.content = content
        self.toolCallID = toolCallID
        self.name = name
        self.tag = tag
    }
}

public enum LLMStreamEvent: Sendable {
    case text(String)
    case info(GenerateCompletionInfo)
    case toolCall(ToolCall)
}

public struct GenerationOptions: Sendable {
    public var temperature: Float
    public var topP: Float
    public var maxTokens: Int
    public var repetitionPenalty: Float?
    /// When true, pass `enable_thinking: false` to the model's chat template.
    /// Required for Qwen3.5-35B-A3B which does not support `/no_think` per-turn.
    public var suppressThinking: Bool
    /// Native tool specs for MLX tool calling (ToolSpec = `[String: any Sendable]`).
    /// When set, passed to `UserInput.tools` so the chat template enables tool calling mode.
    public var tools: [[String: any Sendable]]?

    /// Per-turn ephemeral context that should be attached to the newly appended
    /// conversation delta rather than baked into the stable system prompt.
    public var turnContextPrefix: String?

    /// Effective model context window in tokens for this generation.
    /// Used to clamp `maxTokens` against the exact prepared prompt length.
    public var contextLimitTokens: Int?

    /// Maximum KV cache size in tokens. When set, uses RotatingKVCache for
    /// bounded memory usage regardless of conversation length. nil = unlimited.
    public var maxKVSize: Int?

    /// Quantization bits for KV cache (4 or 8). Reduces KV memory by 4x or 2x respectively.
    /// Requires Flash Attention (available on Apple Silicon). nil = no quantization (f16).
    public var kvBits: Int?

    /// Group size for KV cache quantization. Default 64 matches Ollama/mistral.rs.
    public var kvGroupSize: Int

    /// Token count after which to begin quantizing the KV cache. Keeps initial
    /// context at full precision for better quality. Default 512.
    public var quantizedKVStart: Int

    /// Number of tokens to consider for repetition penalty. Larger windows
    /// catch more repetition patterns. Default 64 (up from MLX default of 20).
    public var repetitionContextSize: Int

    /// Prefill step size for chunked prompt processing. Smaller values reduce
    /// memory spikes for large prompts; larger values speed up prefill.
    /// Auto-tuned based on model size if nil.
    public var prefillStepSize: Int?

    public init(
        temperature: Float = 0.7,
        topP: Float = 0.9,
        maxTokens: Int = 2048,
        repetitionPenalty: Float? = 1.1,
        suppressThinking: Bool = true,
        tools: [[String: any Sendable]]? = nil,
        turnContextPrefix: String? = nil,
        contextLimitTokens: Int? = nil,
        maxKVSize: Int? = nil,
        kvBits: Int? = 4,
        kvGroupSize: Int = 64,
        quantizedKVStart: Int = 512,
        repetitionContextSize: Int = 64,
        prefillStepSize: Int? = nil
    ) {
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.repetitionPenalty = repetitionPenalty
        self.suppressThinking = suppressThinking
        self.tools = tools
        self.turnContextPrefix = turnContextPrefix
        self.contextLimitTokens = contextLimitTokens
        self.maxKVSize = maxKVSize
        self.kvBits = kvBits
        self.kvGroupSize = kvGroupSize
        self.quantizedKVStart = quantizedKVStart
        self.repetitionContextSize = repetitionContextSize
        self.prefillStepSize = prefillStepSize
    }
}

public enum MLEngineLoadState: Sendable {
    case notStarted
    case loading
    case loaded
    case failed(String)

    public var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }

    public var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

public protocol LLMEngine: Actor {
    func load(modelID: String) async throws
    func generate(
        messages: [LLMMessage],
        systemPrompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<LLMStreamEvent, Error>
    /// Run a minimal warmup inference to pre-compile Metal shaders.
    func warmup() async
    /// Mark the session cache as authoritative for the supplied conversation history.
    func synchronizeSession(history: [LLMMessage]) async
    /// Clear any retained prompt/session cache state.
    func resetSession() async
    /// Tear down any engine-owned subprocesses, pipes, or transport state.
    func shutdown() async
    var isLoaded: Bool { get }
    var loadState: MLEngineLoadState { get }
}

public extension LLMEngine {
    func warmup() async {}

    func synchronizeSession(history: [LLMMessage]) async {}

    func resetSession() async {}

    func shutdown() async {}
}
