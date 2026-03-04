import Foundation

/// Persistent store for personalized wake-name aliases (e.g. "faeye" -> Fae).
///
/// Keeps a lightweight local profile that improves direct-address detection over time
/// without retraining the base ASR model.
actor WakeWordProfileStore {

    struct AliasRecord: Codable, Sendable {
        let alias: String
        var count: Int
        var lastSeen: Date
        var source: String
    }

    private struct Snapshot: Codable {
        var aliases: [AliasRecord]
    }

    static let baselineAliases = ["faye", "fae", "fea", "fee", "fay", "fey", "fah", "feh"]

    private var learned: [String: AliasRecord] = [:]
    private let storePath: URL

    init(storePath: URL) {
        self.storePath = storePath
        self.learned = Self.load(from: storePath)
    }

    /// Aliases available for wake matching.
    ///
    /// Learned aliases require at least 2 sightings before activation to avoid one-off noise.
    func allAliases() -> [String] {
        let promoted = learned.values
            .filter { $0.count >= 2 }
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs.alias < rhs.alias
                }
                return lhs.count > rhs.count
            }
            .map(\.alias)

        var merged = Set(Self.baselineAliases)
        for alias in promoted {
            merged.insert(alias)
        }
        return merged.sorted { $0.count > $1.count }
    }

    /// Record a wake alias candidate heard from STT/enrollment.
    func recordAliasCandidate(_ alias: String, source: String) {
        guard let normalized = Self.sanitize(alias), Self.isLikelyFaeAlias(normalized) else {
            return
        }

        let now = Date()
        if var existing = learned[normalized] {
            existing.count += 1
            existing.lastSeen = now
            existing.source = source
            learned[normalized] = existing
        } else {
            learned[normalized] = AliasRecord(
                alias: normalized,
                count: 1,
                lastSeen: now,
                source: source
            )
        }
        persist()
    }

    func records() -> [AliasRecord] {
        learned.values.sorted { $0.count > $1.count }
    }

    // MARK: - Persistence

    private func persist() {
        do {
            let dir = storePath.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

            let payload = Snapshot(aliases: learned.values.sorted { $0.alias < $1.alias })
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(payload)
            try data.write(to: storePath, options: [.atomic])
        } catch {
            NSLog("WakeWordProfileStore: persist failed: %@", error.localizedDescription)
        }
    }

    private static func load(from url: URL) -> [String: AliasRecord] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            var map: [String: AliasRecord] = [:]
            for record in snapshot.aliases {
                map[record.alias] = record
            }
            return map
        } catch {
            NSLog("WakeWordProfileStore: load failed: %@", error.localizedDescription)
            return [:]
        }
    }

    // MARK: - Validation

    private static func sanitize(_ raw: String) -> String? {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return nil }
        let chars = lower.filter { $0.isLetter }
        guard !chars.isEmpty else { return nil }
        return String(chars)
    }

    private static func isLikelyFaeAlias(_ alias: String) -> Bool {
        guard alias.count >= 2, alias.count <= 8 else { return false }
        guard alias.first == "f" else { return false }

        let bestDistance = baselineAliases
            .map { editDistance(alias, $0) }
            .min() ?? Int.max
        return bestDistance <= 2
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }

        return previous[b.count]
    }
}
