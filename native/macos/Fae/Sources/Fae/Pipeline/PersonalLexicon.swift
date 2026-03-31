import Foundation

/// Single source of truth for user vocabulary used in post-ASR correction.
///
/// Stores canonical names and their known misspellings/ASR garbles. Persisted as JSON
/// at `~/Library/Application Support/fae/personal_lexicon.json`. The
/// `DynamicVocabularyCorrector` consumes these entries when rebuilding its cache.
///
/// Sources that feed into the lexicon:
/// - User corrections ("my name is X not Y")
/// - Contacts and Calendar harvesting (Phase 2.2)
/// - Entity graph names from memory
/// - Speaker profile names
///
/// Thread-safe via actor isolation.
actor PersonalLexicon {

    // MARK: - Types

    /// A single vocabulary entry representing a canonical word/name and its known variants.
    struct Entry: Codable, Sendable, Equatable {
        /// The correct spelling/form of the word or name.
        let canonical: String

        /// Known ASR misrecognitions or alternative spellings.
        var variants: [String]

        /// Where this entry came from (e.g. "correction", "contact", "calendar", "entity", "speaker").
        let source: String

        /// When this entry was first added.
        let createdAt: Date

        /// When this entry was last updated (e.g. new variants added).
        var updatedAt: Date
    }

    /// Snapshot of the lexicon for external consumers (e.g. DynamicVocabularyCorrector).
    struct Snapshot: Sendable {
        /// All entries in the lexicon.
        let entries: [Entry]

        /// When the snapshot was taken.
        let timestamp: Date
    }

    // MARK: - State

    private var entries: [String: Entry] = [:]  // keyed by canonical.lowercased()
    private let fileURL: URL
    private var isDirty = false

    // MARK: - Init

    /// Create a lexicon with the default persistence path.
    init() {
        self.fileURL = FaeDirectories.personalLexiconFile
    }

    /// Create a lexicon with a custom file path (for testing).
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    // MARK: - Lifecycle

    /// Load entries from disk. Safe to call multiple times; overwrites in-memory state.
    func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            NSLog("PersonalLexicon: no file at %@, starting empty", fileURL.path)
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let decoded = try JSONDecoder.lexiconDecoder.decode([Entry].self, from: data)
            entries = [:]
            for entry in decoded {
                entries[entry.canonical.lowercased()] = entry
            }
            isDirty = false
            NSLog("PersonalLexicon: loaded %d entries from %@", entries.count, fileURL.lastPathComponent)
        } catch {
            NSLog("PersonalLexicon: failed to load — %@", error.localizedDescription)
        }
    }

    /// Persist current entries to disk. No-op if nothing has changed since last save.
    func save() {
        guard isDirty else { return }
        do {
            let sorted = entries.values.sorted { $0.canonical.lowercased() < $1.canonical.lowercased() }
            let data = try JSONEncoder.lexiconEncoder.encode(sorted)
            try data.write(to: fileURL, options: .atomic)
            isDirty = false
            NSLog("PersonalLexicon: saved %d entries", entries.count)
        } catch {
            NSLog("PersonalLexicon: save failed — %@", error.localizedDescription)
        }
    }

    // MARK: - CRUD

    /// Add or update a vocabulary entry. If the canonical form already exists,
    /// new variants are merged (deduped) and `updatedAt` is refreshed.
    ///
    /// - Parameters:
    ///   - canonical: The correct spelling of the word/name.
    ///   - variants: Known ASR garbles or alternative spellings.
    ///   - source: Origin of this entry (e.g. "correction", "contact").
    func upsert(canonical: String, variants: [String] = [], source: String) {
        let key = canonical.lowercased()
        guard !key.isEmpty else { return }

        let now = Date()
        if var existing = entries[key] {
            // Merge variants, dedup.
            let existingSet = Set(existing.variants.map { $0.lowercased() })
            let novel = variants.filter { !existingSet.contains($0.lowercased()) && $0.lowercased() != key }
            if !novel.isEmpty {
                existing.variants.append(contentsOf: novel)
                existing.updatedAt = now
                entries[key] = existing
                isDirty = true
            }
        } else {
            // New entry — filter out the canonical form itself from variants.
            let filtered = variants.filter { $0.lowercased() != key }
            entries[key] = Entry(
                canonical: canonical,
                variants: filtered,
                source: source,
                createdAt: now,
                updatedAt: now
            )
            isDirty = true
        }
    }

    /// Remove an entry by canonical form.
    ///
    /// - Returns: The removed entry, or nil if not found.
    @discardableResult
    func remove(canonical: String) -> Entry? {
        let key = canonical.lowercased()
        guard let removed = entries.removeValue(forKey: key) else { return nil }
        isDirty = true
        return removed
    }

    /// Look up an entry by canonical form.
    func lookup(canonical: String) -> Entry? {
        entries[canonical.lowercased()]
    }

    /// Return a snapshot of all entries for consumption by DynamicVocabularyCorrector.
    func snapshot() -> Snapshot {
        Snapshot(entries: Array(entries.values), timestamp: Date())
    }

    /// Total number of entries.
    var count: Int { entries.count }

    /// All canonical forms currently in the lexicon.
    var allCanonicals: [String] {
        entries.values.map(\.canonical)
    }

    // MARK: - Bulk Operations

    /// Merge multiple entries at once (e.g. from a harvest).
    /// Deduplicates against existing entries. Returns the number of new entries added.
    @discardableResult
    func mergeAll(_ newEntries: [(canonical: String, variants: [String], source: String)]) -> Int {
        var added = 0
        for entry in newEntries {
            let key = entry.canonical.lowercased()
            guard !key.isEmpty else { continue }
            let wasMissing = entries[key] == nil
            upsert(canonical: entry.canonical, variants: entry.variants, source: entry.source)
            if wasMissing { added += 1 }
        }
        return added
    }
}

// MARK: - JSON Coding Helpers

private extension JSONDecoder {
    static let lexiconDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension JSONEncoder {
    static let lexiconEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}
