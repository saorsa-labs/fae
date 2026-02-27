import Foundation

/// In-memory LRU cache for search results.
///
/// Keyed by normalized (query, engine-set) pairs. Thread-safe via actor isolation.
actor SearchCache {
    struct CacheKey: Hashable, Sendable {
        let query: String
        let engineHash: Int
    }

    struct CacheEntry: Sendable {
        let results: [SearchResult]
        let insertedAt: Date
    }

    /// Maximum cache entries before LRU eviction.
    static let maxEntries = 100

    private var entries: [CacheKey: CacheEntry] = [:]
    private var accessOrder: [CacheKey] = []

    /// Look up cached results. Returns nil if not found or expired.
    func get(key: CacheKey, ttlSeconds: TimeInterval) -> [SearchResult]? {
        guard ttlSeconds > 0 else { return nil }
        guard let entry = entries[key] else { return nil }

        let age = Date().timeIntervalSince(entry.insertedAt)
        if age > ttlSeconds {
            // Expired — remove.
            entries.removeValue(forKey: key)
            accessOrder.removeAll { $0 == key }
            return nil
        }

        // Move to end of access order (most recently used).
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
        return entry.results
    }

    /// Store results in cache.
    func insert(key: CacheKey, results: [SearchResult]) {
        // Evict LRU if at capacity.
        while entries.count >= Self.maxEntries, let oldest = accessOrder.first {
            entries.removeValue(forKey: oldest)
            accessOrder.removeFirst()
        }

        entries[key] = CacheEntry(results: results, insertedAt: Date())
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }

    /// Build a cache key from a query and engine list.
    static func makeKey(query: String, engines: [SearchEngine]) -> CacheKey {
        let normalizedQuery = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // Sort engine names for order-independent hashing.
        let engineHash = engines.map(\.rawValue).sorted().joined(separator: ",").hashValue
        return CacheKey(query: normalizedQuery, engineHash: engineHash)
    }

    /// Clear all cached entries.
    func clear() {
        entries.removeAll()
        accessOrder.removeAll()
    }

    /// Current number of cached entries.
    var count: Int { entries.count }
}
