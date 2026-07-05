import Foundation

/// UX W6: holds large pasted blobs (e.g. a ~20 KB `x0x://agent/…` contact card)
/// OUT of the LLM's context. When the pill paste path detects such a blob it is
/// stashed here under a short opaque id; the LLM only ever sees `paste:<id>`.
///
/// A skill that genuinely needs the bytes (the collaborate skill's contacts
/// import) receives the on-disk spill-file PATH via `run_skill` argument
/// materialization — the blob never travels through the model's tool-call JSON.
///
/// Storage is in-memory (fast) plus a spill file per entry under the Fae cache
/// directory (crash-safety: a paste survives an app restart within its TTL).
/// Bounded: at most `maxEntries` live entries and a 24 h TTL; the oldest entry
/// is evicted when the cap is exceeded and expired entries are pruned lazily.
actor PasteRegistry {
    static let shared = PasteRegistry()

    /// Maximum number of live entries retained.
    static let maxEntries = 10
    /// Time-to-live for a stashed paste.
    static let ttl: TimeInterval = 24 * 60 * 60

    private struct Entry {
        let content: String
        let createdAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let spillDir: URL
    /// Injectable clock so tests can exercise TTL without sleeping.
    private let now: () -> Date

    init(spillDirectory: URL? = nil, now: @escaping () -> Date = Date.init) {
        self.spillDir = spillDirectory
            ?? FaeDirectories.cache.appendingPathComponent("pastes", isDirectory: true)
        self.now = now
        try? FileManager.default.createDirectory(
            at: spillDir, withIntermediateDirectories: true)
    }

    /// Reference form the LLM sees and passes back: `paste:<id>`.
    static func reference(for id: String) -> String { "paste:\(id)" }

    /// Extract the id from a `paste:<id>` reference, or nil if it is not one.
    /// The id must be a non-empty run of url-safe characters and nothing else.
    static func id(fromReference ref: String) -> String? {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("paste:") else { return nil }
        let id = String(trimmed.dropFirst("paste:".count))
        guard !id.isEmpty,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" })
        else { return nil }
        return id
    }

    /// Stash `content`, returning its opaque id. Writes the spill file and prunes.
    @discardableResult
    func store(_ content: String) -> String {
        prune()
        let id = Self.newID()
        entries[id] = Entry(content: content, createdAt: now())
        let path = spillPathURL(for: id)
        try? content.write(to: path, atomically: true, encoding: .utf8)
        // Enforce the cap AFTER inserting so the newest entry always survives.
        evictOverCap()
        return id
    }

    /// Resolve a stashed paste's content by id, or nil if missing/expired.
    /// Falls back to the spill file (crash recovery) when not in memory.
    func resolve(_ id: String) -> String? {
        if let entry = entries[id] {
            guard !isExpired(entry.createdAt) else {
                remove(id)
                return nil
            }
            return entry.content
        }
        // Crash recovery: read from the spill file if it is still within TTL.
        let path = spillPathURL(for: id)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path.path),
              let modified = attrs[.modificationDate] as? Date,
              !isExpired(modified),
              let content = try? String(contentsOf: path, encoding: .utf8)
        else { return nil }
        return content
    }

    /// The on-disk spill-file path for a valid entry, or nil if missing/expired.
    /// Used by `run_skill` argument materialization to hand a skill the bytes
    /// by path (never by value through the model).
    func spillPath(_ id: String) -> String? {
        guard resolve(id) != nil else { return nil }
        return spillPathURL(for: id).path
    }

    /// Test/reset helper: number of live (non-expired) entries.
    func liveCount() -> Int {
        prune()
        return entries.count
    }

    // MARK: - Internals

    private func spillPathURL(for id: String) -> URL {
        spillDir.appendingPathComponent("\(id).txt")
    }

    private func isExpired(_ createdAt: Date) -> Bool {
        now().timeIntervalSince(createdAt) > Self.ttl
    }

    private func remove(_ id: String) {
        entries[id] = nil
        try? FileManager.default.removeItem(at: spillPathURL(for: id))
    }

    /// Drop expired entries (and their spill files).
    private func prune() {
        for (id, entry) in entries where isExpired(entry.createdAt) {
            remove(id)
        }
    }

    /// Evict oldest entries until at most `maxEntries` remain.
    private func evictOverCap() {
        guard entries.count > Self.maxEntries else { return }
        let ordered = entries.sorted { $0.value.createdAt < $1.value.createdAt }
        for (id, _) in ordered.prefix(entries.count - Self.maxEntries) {
            remove(id)
        }
    }

    private static func newID() -> String {
        // 12 url-safe hex chars — short enough to read back, wide enough to avoid
        // collision within a 10-entry window.
        UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
    }
}
