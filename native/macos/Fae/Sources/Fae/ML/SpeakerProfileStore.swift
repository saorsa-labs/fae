import Accelerate
import Foundation

/// Speaker role in the voice identity system.
enum SpeakerRole: String, Sendable, Codable, CaseIterable {
    case owner = "owner"
    case trusted = "trusted"
    case guest = "guest"
    case faeSelf = "fae_self"
}

/// Summary of a speaker profile for UI display.
struct SpeakerProfileSummary: Sendable {
    let id: String
    let displayName: String
    let role: SpeakerRole
    let enrollmentCount: Int
    let lastSeen: Date
}

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
        var displayName: String
        var role: SpeakerRole
        var embeddings: [[Float]]
        /// Per-embedding timestamps (parallel to `embeddings`). Nil for legacy profiles.
        var embeddingDates: [Date]?
        var centroid: [Float]
        let enrolledAt: Date
        var lastSeen: Date

        enum CodingKeys: String, CodingKey {
            case id, label, displayName, role, embeddings, embeddingDates
            case centroid, enrolledAt, lastSeen
        }

        init(
            id: String,
            label: String,
            displayName: String,
            role: SpeakerRole,
            embeddings: [[Float]],
            embeddingDates: [Date]?,
            centroid: [Float],
            enrolledAt: Date,
            lastSeen: Date
        ) {
            self.id = id
            self.label = label
            self.displayName = displayName
            self.role = role
            self.embeddings = embeddings
            self.embeddingDates = embeddingDates
            self.centroid = centroid
            self.enrolledAt = enrolledAt
            self.lastSeen = lastSeen
        }

        /// Backwards-compatible decoder: legacy profiles without `displayName`/`role`
        /// get sensible defaults based on their label.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            label = try c.decode(String.self, forKey: .label)
            displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
                ?? Self.defaultDisplayName(for: label)
            role = try c.decodeIfPresent(SpeakerRole.self, forKey: .role)
                ?? Self.defaultRole(for: label)
            embeddings = try c.decode([[Float]].self, forKey: .embeddings)
            embeddingDates = try c.decodeIfPresent([Date].self, forKey: .embeddingDates)
            centroid = try c.decode([Float].self, forKey: .centroid)
            enrolledAt = try c.decode(Date.self, forKey: .enrolledAt)
            lastSeen = try c.decode(Date.self, forKey: .lastSeen)
        }

        private static func defaultDisplayName(for label: String) -> String {
            switch label {
            case "owner": return "Owner"
            case "fae_self": return "Fae"
            default: return label.capitalized
            }
        }

        private static func defaultRole(for label: String) -> SpeakerRole {
            switch label {
            case "owner": return .owner
            case "fae_self": return .faeSelf
            default: return .guest
            }
        }
    }

    struct MatchResult: Sendable {
        let profileId: String
        let label: String
        let displayName: String
        let role: SpeakerRole
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
                best = MatchResult(
                    profileId: profile.id,
                    label: profile.label,
                    displayName: profile.displayName,
                    role: profile.role,
                    similarity: sim
                )
            }
        }

        return best
    }

    /// Check whether the embedding matches the owner profile above `threshold`.
    func isOwner(embedding: [Float], threshold: Float) -> Bool {
        guard let ownerProfile = profiles.first(where: { $0.role == .owner }) else {
            return false
        }
        return Self.cosineSimilarity(embedding, ownerProfile.centroid) >= threshold
    }

    /// Whether an owner profile exists.
    func hasOwnerProfile() -> Bool {
        profiles.contains { $0.role == .owner }
    }

    /// Display name for the owner profile, if enrolled.
    func ownerDisplayName() -> String? {
        profiles.first(where: { $0.role == .owner })?.displayName
    }

    /// Display name for a profile by label.
    func displayName(for label: String) -> String? {
        profiles.first(where: { $0.label == label })?.displayName
    }

    // MARK: - Enrollment

    /// Enroll a new speaker or add an embedding to an existing profile.
    func enroll(label: String, embedding: [Float], role: SpeakerRole = .guest, displayName: String? = nil) {
        let now = Date()
        if let idx = profiles.firstIndex(where: { $0.label == label }) {
            appendEmbedding(embedding, to: idx, date: now)
        } else {
            let name = displayName ?? label.capitalized
            profiles.append(SpeakerProfile(
                id: UUID().uuidString,
                label: label,
                displayName: name,
                role: role,
                embeddings: [embedding],
                embeddingDates: [now],
                centroid: embedding,
                enrolledAt: now,
                lastSeen: now
            ))
        }
        persist()
    }

    /// Enroll a speaker with multiple embeddings at once (e.g. from guided enrollment).
    func bulkEnroll(label: String, embeddings: [[Float]], role: SpeakerRole, displayName: String) {
        guard !embeddings.isEmpty else { return }
        let now = Date()
        let dates = Array(repeating: now, count: embeddings.count)
        let centroid = Self.averageEmbeddings(embeddings)

        if let idx = profiles.firstIndex(where: { $0.label == label }) {
            for emb in embeddings {
                appendEmbedding(emb, to: idx, date: now)
            }
            profiles[idx].displayName = displayName
            profiles[idx].role = role
        } else {
            profiles.append(SpeakerProfile(
                id: UUID().uuidString,
                label: label,
                displayName: displayName,
                role: role,
                embeddings: embeddings,
                embeddingDates: dates,
                centroid: centroid,
                enrolledAt: now,
                lastSeen: now
            ))
        }
        persist()
    }

    /// Rename a speaker's display name.
    func rename(label: String, newDisplayName: String) {
        guard let idx = profiles.firstIndex(where: { $0.label == label }) else { return }
        profiles[idx].displayName = newDisplayName
        persist()
    }

    /// Summaries of all enrolled profiles for UI display.
    func profileSummaries() -> [SpeakerProfileSummary] {
        profiles.map { profile in
            SpeakerProfileSummary(
                id: profile.id,
                displayName: profile.displayName,
                role: profile.role,
                enrollmentCount: profile.embeddings.count,
                lastSeen: profile.lastSeen
            )
        }
    }

    /// Compute consistency score between embeddings (average pairwise cosine similarity).
    /// Returns 1.0 for single embeddings, 0.0 for empty sets.
    static func consistencyScore(_ embeddings: [[Float]]) -> Float {
        guard embeddings.count > 1 else { return embeddings.isEmpty ? 0 : 1.0 }
        var total: Float = 0
        var count: Float = 0
        for i in 0..<embeddings.count {
            for j in (i + 1)..<embeddings.count {
                total += cosineSimilarity(embeddings[i], embeddings[j])
                count += 1
            }
        }
        return count > 0 ? total / count : 0
    }

    /// Add an embedding to an existing profile only if below the enrollment cap.
    ///
    /// Used for progressive enrollment — silently strengthens known profiles.
    func enrollIfBelowMax(label: String, embedding: [Float], max: Int) {
        guard let idx = profiles.firstIndex(where: { $0.label == label }) else { return }
        guard profiles[idx].embeddings.count < max else { return }
        appendEmbedding(embedding, to: idx, date: Date())
        persist()
    }

    /// Append an embedding (and its date) to the profile at `idx` and recompute its centroid.
    private func appendEmbedding(_ embedding: [Float], to idx: Int, date: Date) {
        profiles[idx].embeddings.append(embedding)
        var dates = profiles[idx].embeddingDates ?? []
        dates.append(date)
        profiles[idx].embeddingDates = dates
        profiles[idx].centroid = Self.averageEmbeddings(profiles[idx].embeddings)
        profiles[idx].lastSeen = date
    }

    /// Remove a speaker profile by label.
    func remove(label: String) {
        profiles.removeAll { $0.label == label }
        persist()
    }

    /// Remove all owner profiles (for onboarding reset).
    func clearOwnerProfile() {
        profiles.removeAll { $0.role == .owner }
        persist()
    }

    /// Prune embeddings older than `maxAgeDays` from all profiles.
    ///
    /// Prevents centroid drift as a speaker's voice changes over time.
    /// Profiles with no timestamps (legacy) are left untouched. Profiles
    /// are never deleted — only their oldest embeddings are removed.
    func pruneStaleEmbeddings(maxAgeDays: Int = 180) {
        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86_400)
        var changed = false

        for idx in profiles.indices {
            guard let dates = profiles[idx].embeddingDates,
                  dates.count == profiles[idx].embeddings.count
            else { continue }

            // Keep embeddings newer than cutoff, but always retain at least 1.
            var keepIndices = [Int]()
            for (i, date) in dates.enumerated() where date >= cutoff {
                keepIndices.append(i)
            }
            // Always keep the most recent embedding even if all are stale.
            if keepIndices.isEmpty, let lastIdx = dates.indices.last {
                keepIndices = [lastIdx]
            }

            if keepIndices.count < profiles[idx].embeddings.count {
                let prunedCount = profiles[idx].embeddings.count - keepIndices.count
                profiles[idx].embeddings = keepIndices.map { profiles[idx].embeddings[$0] }
                profiles[idx].embeddingDates = keepIndices.map { dates[$0] }
                profiles[idx].centroid = Self.averageEmbeddings(profiles[idx].embeddings)
                changed = true
                NSLog("SpeakerProfileStore: pruned %d stale embeddings from '%@'",
                      prunedCount, profiles[idx].label)
            }
        }

        if changed { persist() }
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
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
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
