import Foundation
import MLX
import MLXEmbedders

// MARK: - Tier

enum EmbeddingModelTier: String, Sendable {
    case large  = "mlx-community/Qwen3-Embedding-8B-4bit"
    case medium = "mlx-community/Qwen3-Embedding-4B-4bit"
    case small  = "mlx-community/Qwen3-Embedding-0.6B-4bit"
    case hash   = "foundation-hash-384"

    var dimension: Int {
        switch self {
        case .large:  return 4096
        case .medium: return 2048
        case .small:  return 1024
        case .hash:   return 384
        }
    }

    static func recommendedTier(
        ramGB: Int,
        prefersLowResidentMemory: Bool = false
    ) -> EmbeddingModelTier {
        if prefersLowResidentMemory {
            if ramGB >= 16 { return .small }
            return .hash
        }
        if ramGB >= 64 { return .medium }
        if ramGB >= 32 { return .small }
        if ramGB >= 16 { return .small }
        return .hash
    }
}

// MARK: - NeuralEmbeddingEngine

/// Tiered neural embedding engine using Qwen3-Embedding models via MLXEmbedders.
/// Falls back to MLXEmbeddingEngine (hash-based) if model load fails or RAM < 16 GB.
actor NeuralEmbeddingEngine: EmbeddingEngine {
    private(set) var isLoaded: Bool = false
    private(set) var loadState: MLEngineLoadState = .notStarted
    private(set) var currentTier: EmbeddingModelTier = .hash
    private var container: MLXEmbedders.ModelContainer?
    private let fallback = MLXEmbeddingEngine()

    private static let queryPrefix =
        "Instruct: Represent this sentence for retrieval.\nQuery: "

    // MARK: - EmbeddingEngine conformance

    func load(modelID: String) async throws {
        let tier = EmbeddingModelTier(rawValue: modelID) ?? .hash
        await loadTier(tier)
    }

    // MARK: - Primary API

    func loadTier(_ tier: EmbeddingModelTier) async {
        currentTier = tier
        guard tier != .hash else {
            do {
                try await fallback.load(modelID: tier.rawValue)
            } catch {
                NSLog("NeuralEmbeddingEngine: fallback load failed: %@",
                      error.localizedDescription)
            }
            isLoaded = true
            loadState = .loaded
            NSLog("NeuralEmbeddingEngine: using MLXEmbeddingEngine fallback")
            return
        }
        loadState = .loading
        do {
            let config = MLXEmbedders.ModelConfiguration(id: tier.rawValue)
            container = try await MLXEmbedders.loadModelContainer(
                configuration: config
            ) { progress in
                NSLog("NeuralEmbeddingEngine: loading %.0f%%",
                      progress.fractionCompleted * 100)
            }
            isLoaded = true
            loadState = .loaded
            NSLog("NeuralEmbeddingEngine: loaded %@ (dim=%d)",
                  tier.rawValue, tier.dimension)
        } catch {
            NSLog("NeuralEmbeddingEngine: load failed (%@), falling back to hash",
                  error.localizedDescription)
            currentTier = .hash
            do {
                try await fallback.load(modelID: EmbeddingModelTier.hash.rawValue)
            } catch {
                NSLog("NeuralEmbeddingEngine: fallback load also failed: %@",
                      error.localizedDescription)
            }
            isLoaded = true
            loadState = .loaded
        }
    }

    var embeddingDimension: Int { currentTier.dimension }
    var currentModelId: String { currentTier.rawValue }

    /// Embed a document text (no query instruction prefix).
    func embed(text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [Float](repeating: 0, count: currentTier.dimension)
        }
        return try await embedInternal(text: trimmed)
    }

    /// Embed a query string with the retrieval instruction prefix.
    func embedQuery(_ text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return [Float](repeating: 0, count: currentTier.dimension)
        }
        return try await embedInternal(text: Self.queryPrefix + trimmed)
    }

    /// Batch-embed multiple document texts.
    func embedBatch(texts: [String]) async throws -> [[Float]] {
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            results.append(try await embed(text: text))
        }
        return results
    }

    // MARK: - Private

    private func embedInternal(text: String) async throws -> [Float] {
        guard let container, currentTier != .hash else {
            return try await fallback.embed(text: text)
        }

        // Capture tier dimension before crossing actor boundary.
        let dim = currentTier.dimension

        return try await container.perform { (model, tokenizer, pooler) throws -> [Float] in
            // Tokenize.
            let tokenIds = tokenizer.encode(text: text)
            guard !tokenIds.isEmpty else {
                return [Float](repeating: 0, count: dim)
            }

            // Build input tensor [1, seq_len].
            let inputTensor = MLXArray(tokenIds.map { Int32($0) })[.newAxis]

            // Build attention mask (all 1s).
            let seqLen = tokenIds.count
            let mask = MLXArray.ones([1, seqLen], dtype: .float32)

            // Run the embedding model.
            let output = model(
                inputTensor,
                positionIds: nil,
                tokenTypeIds: nil,
                attentionMask: mask
            )

            // Pool and L2-normalize. The pooler strategy is loaded from the model's
            // 1_Pooling/config.json; Qwen3-Embedding models use last-token pooling.
            let pooled = pooler(output, mask: mask, normalize: true)

            // Force evaluation before leaving the perform closure (MLXArray is not Sendable).
            eval(pooled)

            return pooled.asArray(Float.self)
        }
    }
}
