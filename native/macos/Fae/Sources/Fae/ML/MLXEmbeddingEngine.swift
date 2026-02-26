import Foundation

/// Deterministic Foundation-only embedding engine.
///
/// Uses hashed token projections into a fixed 384-dim vector, then L2 normalizes.
/// This provides stable, non-zero semantic-ish vectors without external ML deps.
actor MLXEmbeddingEngine: EmbeddingEngine {
    private(set) var isLoaded: Bool = false
    private(set) var loadState: MLEngineLoadState = .notStarted
    private var loadedModelID: String = "foundation-hash-384"

    func load(modelID: String = "foundation-hash-384") async throws {
        loadState = .loading
        loadedModelID = modelID
        isLoaded = true
        loadState = .loaded
        NSLog("MLXEmbeddingEngine: loaded backend='foundation-hash' model='%@'", modelID)
    }

    func embed(text: String) async throws -> [Float] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [Float](repeating: 0, count: 384) }

        // Lazy-load to keep call sites simple and resilient.
        if !isLoaded {
            try await load(modelID: loadedModelID)
        }

        let dim = 384
        var vector = [Float](repeating: 0, count: dim)

        let tokens = tokenize(trimmed)
        if tokens.isEmpty { return vector }

        for token in tokens {
            // Two deterministic hashes for index/sign selection.
            let h1 = fnv1a64(token)
            let h2 = fnv1a64("\(token)#")
            let index = Int(h1 % UInt64(dim))
            let sign: Float = (h2 & 1) == 0 ? 1.0 : -1.0

            // Small deterministic magnitude based on token hash.
            let magBucket = Float((h1 >> 8) % 1000) / 1000.0 // [0, 0.999]
            let magnitude = 0.5 + magBucket // [0.5, 1.499]
            vector[index] += sign * magnitude
        }

        // L2 normalize for cosine compatibility.
        let norm = sqrt(vector.reduce(Float(0)) { $0 + ($1 * $1) })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    private func tokenize(_ text: String) -> [String] {
        let scalars = text.lowercased().unicodeScalars
        var current = String.UnicodeScalarView()
        var out: [String] = []

        for s in scalars {
            if CharacterSet.alphanumerics.contains(s) || s == "'" || s == "-" {
                current.append(s)
            } else if !current.isEmpty {
                out.append(String(current))
                current.removeAll(keepingCapacity: true)
            }
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }

    /// FNV-1a 64-bit hash for deterministic token hashing.
    private func fnv1a64(_ text: String) -> UInt64 {
        let prime: UInt64 = 1_099_511_628_211
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }
}
