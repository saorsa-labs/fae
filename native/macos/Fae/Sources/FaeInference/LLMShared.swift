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
    guard hasConfig, hasWeights else { return false }

    // For sharded models, verify ALL shards are present.
    // A partial download (e.g. user killed Fae mid-download) leaves an index
    // file referencing shards that don't exist yet, which crashes in quantize().
    let indexFile = directory.appendingPathComponent("model.safetensors.index.json")
    if fm.fileExists(atPath: indexFile.path) {
        guard let data = try? Data(contentsOf: indexFile),
              let index = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weightMap = index["weight_map"] as? [String: String]
        else {
            return false
        }
        let requiredShards = Set(weightMap.values)
        for shard in requiredShards {
            let shardPath = directory.appendingPathComponent(shard).path
            guard fm.fileExists(atPath: shardPath) else {
                NSLog("hasModelPayload: missing shard %@ in %@", shard, directory.lastPathComponent)
                return false
            }
        }
    }

    return true
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

/// Returns the raw `ToolCallFormat` string value for models that need an explicit
/// format hint, or `nil` to let mlx-swift-lm auto-detect from `config.json` model_type.
///
/// Covers cases where:
/// - The model isn't cached yet (no config.json to read) but the HF ID is recognizable.
/// - The library's `ToolCallFormat.infer(from:)` doesn't match the exact model_type
///   (e.g. `"gemma4"` vs `"gemma"`).
public func toolCallFormatOverride(modelID: String) -> String? {
    if let directory = localModelDirectoryURL(from: modelID),
       let modelType = localModelType(from: directory)?.lowercased()
    {
        if modelType.contains("qwen") { return "xml_function" }
        if modelType.hasPrefix("gemma") { return "gemma" }
    }

    let lower = modelID.lowercased()
    if lower.contains("qwen")
        || lower.contains("saorsa-1.1")
        || lower.contains("saorsa1-worker")
        || lower.contains("saorsa1-tiny")
    {
        return "xml_function"
    }
    if lower.contains("gemma") { return "gemma" }
    return nil
}

/// Legacy convenience — returns `true` when the model should use Qwen's xmlFunction format.
public func usesQwenCompatibleToolCallFormat(modelID: String) -> Bool {
    toolCallFormatOverride(modelID: modelID) == "xml_function"
}

public enum MLEngineError: LocalizedError {
    case notLoaded(String)
    case loadFailed(String, Error)
    case adapterLoadFailed(String)
    case adapterNotCompatible(String)

    public var errorDescription: String? {
        switch self {
        case .notLoaded(let engine):
            return "\(engine) engine not loaded"
        case .loadFailed(let engine, let error):
            return "\(engine) engine failed to load: \(error.localizedDescription)"
        case .adapterLoadFailed(let reason):
            return "Adapter load failed: \(reason)"
        case .adapterNotCompatible(let reason):
            return "Adapter not compatible: \(reason)"
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

    /// Base64-encoded WAV clip attached to the final user message (S18
    /// push-to-talk). Only the daemon engine honours it — the audio-capable
    /// model transcribes and answers in one request; the MLX engine ignores it.
    public var audioWAVBase64: String?

    /// Phase G2: a pinned summary of the conversation turns that were evicted
    /// from the kept window. When non-empty the daemon folds it into a stable
    /// `system ++ pinned_summary` prefix (before the retained turns) so the
    /// prefix cache keeps hitting. Only the daemon engine honours it; the MLX
    /// engine ignores it. `nil`/empty ⇒ no pinned block (today's behaviour).
    public var pinnedSummary: String?

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
        prefillStepSize: Int? = nil,
        audioWAVBase64: String? = nil,
        pinnedSummary: String? = nil
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
        self.audioWAVBase64 = audioWAVBase64
        self.pinnedSummary = pinnedSummary
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
    /// Warm the KV cache by processing the system prompt and message history
    /// without generating any tokens.  The next `generate()` call with a
    /// matching prompt/history prefix will reuse the cache automatically.
    func prefillSession(
        messages: [LLMMessage],
        systemPrompt: String,
        options: GenerationOptions
    ) async throws
    /// Tear down any engine-owned subprocesses, pipes, or transport state.
    func shutdown() async
    var isLoaded: Bool { get }
    var loadState: MLEngineLoadState { get }
    /// Hot-swap the personal LoRA adapter overlay on the running model.
    /// Pass `nil` to unload any currently active adapter and revert to base weights.
    /// Engines that do not support adapters may implement this as a no-op.
    func swapAdapter(to directory: URL?) async throws

    /// Phase G2: fold the given evicted turns (optionally on top of a prior pinned
    /// summary) into a single compact summary, for the main-lane compression
    /// protocol. Returns the summary text, or `nil` when this engine cannot
    /// summarize (no daemon) so the caller hard-truncates instead. Only the daemon
    /// engine implements it; every other engine gets the default no-op below.
    func compactConversation(
        evicted: [LLMMessage],
        priorSummary: String?
    ) async throws -> String?
}

public extension LLMEngine {
    func warmup() async {}

    func synchronizeSession(history: [LLMMessage]) async {}

    func resetSession() async {}

    func prefillSession(
        messages: [LLMMessage],
        systemPrompt: String,
        options: GenerationOptions
    ) async throws {}

    func shutdown() async {}

    func swapAdapter(to directory: URL?) async throws {
        // Default no-op for engines without adapter support.
    }

    func compactConversation(
        evicted: [LLMMessage],
        priorSummary: String?
    ) async throws -> String? {
        // Default: engines without a daemon summarizer cannot compact — the
        // caller falls back to hard truncation.
        nil
    }
}
