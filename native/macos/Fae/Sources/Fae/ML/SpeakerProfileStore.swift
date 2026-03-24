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
        /// Path to a reference photo for visual identity. Nil if no photo captured.
        var photoPath: String?
        /// VLM-generated description of the owner's appearance. Nil if not yet described.
        var photoDescription: String?

        enum CodingKeys: String, CodingKey {
            case id, label, displayName, role, embeddings, embeddingDates
            case centroid, enrolledAt, lastSeen, photoPath, photoDescription
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
            lastSeen: Date,
            photoPath: String? = nil,
            photoDescription: String? = nil
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
            self.photoPath = photoPath
            self.photoDescription = photoDescription
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
            photoPath = try c.decodeIfPresent(String.self, forKey: .photoPath)
            photoDescription = try c.decodeIfPresent(String.self, forKey: .photoDescription)
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
    /// Use `excludingRoles` to skip certain profiles (e.g. `.faeSelf` for echo
    /// detection, which should be checked separately).
    func match(embedding: [Float], threshold: Float, excludingRoles: Set<SpeakerRole> = []) -> MatchResult? {
        guard let best = bestMatch(embedding: embedding, excludingRoles: excludingRoles),
              best.similarity >= threshold
        else {
            return nil
        }
        return best
    }

    /// Return the closest enrolled profile regardless of threshold.
    ///
    /// Useful for preview / short-window verification where callers want to apply
    /// custom accept/reject bands around the similarity score.
    func bestMatch(embedding: [Float], excludingRoles: Set<SpeakerRole> = []) -> MatchResult? {
        var best: MatchResult?

        for profile in profiles where !excludingRoles.contains(profile.role) {
            let sim = Self.cosineSimilarity(embedding, profile.centroid)
            if sim > (best?.similarity ?? -.greatestFiniteMagnitude) {
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

    /// Check whether the embedding matches the fae_self profile above `threshold`.
    /// Used for echo detection — separate from general speaker matching.
    ///
    /// Returns nil if the fae_self profile is absent or has a degenerate centroid
    /// (very low variance across embeddings, which causes false matches on all audio).
    func matchesFaeSelf(embedding: [Float], threshold: Float) -> Float? {
        guard let faeSelf = profiles.first(where: { $0.role == .faeSelf }) else { return nil }
        // Health check: a degenerate fae_self centroid (StdDev < 0.06 across
        // embedding dimensions) matches nearly everything, permanently blocking
        // all user speech via echo rejection. Skip the match if pathological.
        if Self.isCentroidDegenerate(faeSelf.centroid) {
            NSLog("SpeakerProfileStore: fae_self centroid is degenerate (low variance) — skipping echo match")
            return nil
        }
        let sim = Self.cosineSimilarity(embedding, faeSelf.centroid)
        return sim >= threshold ? sim : nil
    }

    /// Detect a degenerate centroid: very low standard deviation across dimensions
    /// indicates the embedding has collapsed to near-constant values.
    private static func isCentroidDegenerate(_ centroid: [Float], threshold: Float = 0.06) -> Bool {
        // Only check real embeddings (≥32 dims). Short embeddings in tests are fine.
        guard centroid.count >= 32 else { return false }
        var mean: Float = 0
        vDSP_meanv(centroid, 1, &mean, vDSP_Length(centroid.count))
        var variance: Float = 0
        // Compute mean of squared differences.
        var diff = [Float](repeating: 0, count: centroid.count)
        var negMean = -mean
        vDSP_vsadd(centroid, 1, &negMean, &diff, 1, vDSP_Length(centroid.count))
        vDSP_dotpr(diff, 1, diff, 1, &variance, vDSP_Length(centroid.count))
        variance /= Float(centroid.count)
        let stddev = sqrtf(variance)
        return stddev < threshold
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

    /// Whether an owner profile exists with a compatible embedding dimension.
    /// Returns false if the owner's centroid dimension doesn't match the
    /// encoder's current output, which requires re-enrollment.
    func hasCompatibleOwnerProfile(embeddingDim: Int) -> Bool {
        guard let owner = profiles.first(where: { $0.role == .owner }) else { return false }
        return owner.centroid.count == embeddingDim
    }

    /// Display name for the owner profile, if enrolled.
    func ownerDisplayName() -> String? {
        profiles.first(where: { $0.role == .owner })?.displayName
    }

    /// Whether the owner has a valid reference photo on disk.
    func hasOwnerPhoto() -> Bool {
        guard let path = profiles.first(where: { $0.role == .owner })?.photoPath else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    /// VLM-generated description of the owner's appearance, if available.
    func ownerPhotoDescription() -> String? {
        profiles.first(where: { $0.role == .owner })?.photoDescription
    }

    /// Store a reference photo path and optional description on the owner profile.
    func setOwnerPhoto(path: String, description: String?) {
        guard let idx = profiles.firstIndex(where: { $0.role == .owner }) else { return }
        profiles[idx].photoPath = path
        profiles[idx].photoDescription = description
        persist()
    }

    /// Whether the owner's reference photo is due for a progressive refresh.
    ///
    /// Returns true if no photo exists or the current photo is older than
    /// `refreshIntervalDays`. Used by the camera presence check to silently
    /// update the reference photo over time.
    func isOwnerPhotoDueForRefresh(refreshIntervalDays: Int = 3) -> Bool {
        guard let owner = profiles.first(where: { $0.role == .owner }) else { return false }
        guard let path = owner.photoPath else { return true }

        let fm = FileManager.default
        guard fm.fileExists(atPath: path),
              let attrs = try? fm.attributesOfItem(atPath: path),
              let modified = attrs[.modificationDate] as? Date
        else { return true }

        return Date().timeIntervalSince(modified) > Double(refreshIntervalDays) * 86_400
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

    /// Remove all profiles whose embeddings are incompatible with the current
    /// encoder dimension. This handles model upgrades (e.g. 256→1024 dim)
    /// that make stored embeddings unusable for cosine similarity.
    func clearIncompatibleProfiles(currentDim: Int) {
        let before = profiles.count
        profiles.removeAll { !$0.centroid.isEmpty && $0.centroid.count != currentDim }
        let removed = before - profiles.count
        if removed > 0 {
            NSLog("SpeakerProfileStore: cleared %d profiles with incompatible dimension (expected %d)", removed, currentDim)
            persist()
        }
    }

    /// Remove all speaker profiles (for full onboarding reset / first-contact testing).
    func clearAllProfiles() {
        let count = profiles.count
        profiles.removeAll()
        persist()
        NSLog("SpeakerProfileStore: cleared all %d profiles", count)
    }

    /// Promote an existing profile to owner role.
    ///
    /// Returns true if a profile was promoted, false otherwise.
    /// Never promotes `fae_self`.
    @discardableResult
    func promoteToOwner(label: String) -> Bool {
        guard let idx = profiles.firstIndex(where: { $0.label == label }) else { return false }
        guard profiles[idx].label != "fae_self" else { return false }
        guard profiles[idx].role != .faeSelf else { return false }
        profiles[idx].role = .owner
        persist()
        return true
    }

    /// Set a profile role explicitly.
    ///
    /// Returns true if updated, false if the label was not found.
    @discardableResult
    func setRole(label: String, role: SpeakerRole) -> Bool {
        guard let idx = profiles.firstIndex(where: { $0.label == label }) else { return false }
        profiles[idx].role = role
        persist()
        return true
    }

    /// Migration helper: if no owner exists and exactly one non-`fae_self`
    /// profile exists, promote it to owner.
    ///
    /// Returns the promoted label when applied.
    func promoteSoleHumanProfileToOwnerIfUnambiguous() -> String? {
        guard !hasOwnerProfile() else { return nil }
        let candidates = profiles.filter { $0.role != .faeSelf && $0.label != "fae_self" }
        guard candidates.count == 1 else { return nil }
        let label = candidates[0].label
        guard promoteToOwner(label: label) else { return nil }
        return label
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
