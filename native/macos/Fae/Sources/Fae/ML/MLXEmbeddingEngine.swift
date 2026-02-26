import Foundation

/// Stub embedding engine for Phase 2.
///
/// Returns zero vectors. Replace with actual embedding model
/// (all-MiniLM-L6-v2 or NLEmbedding) for hybrid search.
actor MLXEmbeddingEngine: EmbeddingEngine {
    private(set) var isLoaded: Bool = false

    func load(modelID: String = "stub") async throws {
        // TODO: Load actual embedding model (all-MiniLM-L6-v2 or NLEmbedding)
        isLoaded = true
        NSLog("MLXEmbeddingEngine: stub loaded")
    }

    func embed(text: String) async throws -> [Float] {
        // Return zero vector (384 dimensions to match all-MiniLM-L6-v2).
        [Float](repeating: 0, count: 384)
    }
}
