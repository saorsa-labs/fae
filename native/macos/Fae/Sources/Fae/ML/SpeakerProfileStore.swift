import Accelerate
import Foundation

/// Manages enrolled speaker profiles for voice identity verification.
///
/// Stores speaker embeddings and matches incoming audio against known profiles
/// using cosine similarity. Profiles are persisted as JSON at
/// `~/Library/Application Support/fae/speakers.json`.
///
/// Thread-safe via actor isolation.
actor SpeakerProfileStore {

    // MARK: - Types

    struct SpeakerProfile: Codable, Sendable {
        let id: String
        var label: String
        var embeddings: [[Float]]
        var centroid: [Float]
        let enrolledAt: Date
        var lastSeen: Date
    }

    struct MatchResult: Sendable {
        let profileId: String
        let label: String
        let similarity: Float
    }

    // MARK: - State

    private var profiles: [SpeakerProfile] = []
    private let storePath: URL

    // MARK: - Init

    init(storePath: URL) {
        self.storePath = storePath
        // Load profiles synchronously during init (nonisolated context).
        self.profiles = Self.loadProfiles(from: storePath)
    }

    // MARK: - Matching

    /// Match an embedding against enrolled profiles.
    ///
    /// Returns the best match above `threshold`, or `nil` if no profile matches.
    func match(embedding: [Float], threshold: Float) -> MatchResult? {
        var best: MatchResult?

        for profile in profiles {
            let sim = Self.cosineSimilarity(embedding, profile.centroid)
            if sim >= threshold, sim > (best?.similarity ?? 0) {
                best = MatchResult(profileId: profile.id, label: profile.label, similarity: sim)
            }
        }

        return best
    }

    /// Check whether the embedding matches the "owner" profile above `threshold`.
    func isOwner(embedding: [Float], threshold: Float) -> Bool {
        guard let ownerProfile = profiles.first(where: { $0.label == "owner" }) else {
            return false
        }
        return Self.cosineSimilarity(embedding, ownerProfile.centroid) >= threshold
    }

    /// Whether an "owner" profile exists.
    func hasOwnerProfile() -> Bool {
        profiles.contains { $0.label == "owner" }
    }

    // MARK: - Enrollment

    /// Enroll a new speaker or add an embedding to an existing profile.
    func enroll(label: String, embedding: [Float]) {
        if let idx = profiles.firstIndex(where: { $0.label == label }) {
            profiles[idx].embeddings.append(embedding)
            profiles[idx].centroid = Self.averageEmbeddings(profiles[idx].embeddings)
            profiles[idx].lastSeen = Date()
        } else {
            let profile = SpeakerProfile(
                id: UUID().uuidString,
                label: label,
                embeddings: [embedding],
                centroid: embedding,
                enrolledAt: Date(),
                lastSeen: Date()
            )
            profiles.append(profile)
        }
        persist()
    }

    /// Add an embedding to an existing profile only if below the enrollment cap.
    ///
    /// Used for progressive enrollment — silently strengthens known profiles.
    func enrollIfBelowMax(label: String, embedding: [Float], max: Int) {
        guard let idx = profiles.firstIndex(where: { $0.label == label }) else { return }
        guard profiles[idx].embeddings.count < max else { return }

        profiles[idx].embeddings.append(embedding)
        profiles[idx].centroid = Self.averageEmbeddings(profiles[idx].embeddings)
        profiles[idx].lastSeen = Date()
        persist()
    }

    /// Remove a speaker profile by label.
    func remove(label: String) {
        profiles.removeAll { $0.label == label }
        persist()
    }

    /// All enrolled profile labels.
    var enrolledLabels: [String] {
        profiles.map(\.label)
    }

    /// Number of enrollment embeddings for a profile.
    func enrollmentCount(for label: String) -> Int {
        profiles.first(where: { $0.label == label })?.embeddings.count ?? 0
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let dir = storePath.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(profiles)
            try data.write(to: storePath, options: .atomic)
        } catch {
            NSLog("SpeakerProfileStore: persist failed: %@", error.localizedDescription)
        }
    }

    /// Load profiles from JSON on disk (nonisolated, safe to call from init).
    private static func loadProfiles(from url: URL) -> [SpeakerProfile] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }

        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let profiles = try decoder.decode([SpeakerProfile].self, from: data)
            NSLog("SpeakerProfileStore: loaded %d profiles from disk", profiles.count)
            return profiles
        } catch {
            NSLog("SpeakerProfileStore: load failed: %@", error.localizedDescription)
            return []
        }
    }

    // MARK: - Vector Math

    /// Cosine similarity between two vectors.
    private static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))

        let denom = sqrtf(normA) * sqrtf(normB)
        return denom > 1e-10 ? dot / denom : 0
    }

    /// Compute the centroid (element-wise mean) of a set of embeddings.
    private static func averageEmbeddings(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        let dim = first.count
        guard embeddings.count > 1 else { return first }

        var sum = [Float](repeating: 0, count: dim)
        for emb in embeddings {
            guard emb.count == dim else { continue }
            vDSP_vadd(sum, 1, emb, 1, &sum, 1, vDSP_Length(dim))
        }

        var divisor = Float(embeddings.count)
        vDSP_vsdiv(sum, 1, &divisor, &sum, 1, vDSP_Length(dim))
        return sum
    }
}
