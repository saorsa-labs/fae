import Foundation

actor MemoryDigestService {
    private static let stopWords: Set<String> = [
        "the", "and", "for", "with", "that", "this", "from", "have", "your", "about",
        "into", "they", "them", "their", "there", "would", "could", "should", "while",
        "where", "when", "what", "which", "using", "used", "been", "were", "will",
        "just", "than", "then", "over", "under", "into", "after", "before", "through",
        "across", "also", "because", "still", "need", "needs", "want", "wants", "today",
        "tomorrow", "yesterday", "user", "assistant", "fae", "memory", "imported",
    ]

    private let store: SQLiteMemoryStore

    init(store: SQLiteMemoryStore) {
        self.store = store
    }

    func generateDigest(now: Date = Date()) async throws -> MemoryRecord? {
        let candidates = try await digestCandidates(now: now)
        guard candidates.count >= 2 else { return nil }

        let sourceRecordIDs = candidates.map(\.id).sorted()
        guard try await shouldGenerateDigest(sourceRecordIDs: sourceRecordIDs) else {
            return nil
        }

        let digest = try await store.insertRecord(
            kind: .digest,
            text: Self.renderDigest(from: candidates, now: now),
            confidence: 0.79,
            sourceTurnId: "memory_digest",
            tags: ["derived", "digest", "reflection"],
            importanceScore: 0.82,
            staleAfterSecs: 604_800,
            metadata: Self.digestMetadataJSON(sourceRecordIDs: sourceRecordIDs, generatedAt: now)
        )

        for sourceRecordID in sourceRecordIDs {
            try await store.linkRecordSource(
                recordId: digest.id,
                sourceRecordId: sourceRecordID,
                role: .digestSupport
            )
        }
        return digest
    }

    private func digestCandidates(now: Date) async throws -> [MemoryRecord] {
        let cutoff = UInt64(max(0, now.addingTimeInterval(-(72 * 3600)).timeIntervalSince1970))
        let recent = try await store.recentRecords(limit: 120)

        let filtered = recent.filter { record in
            guard record.kind != .digest else { return false }
            guard record.updatedAt >= cutoff else { return false }
            if record.kind == .episode, !record.tags.contains("proactive"), !record.tags.contains("imported") {
                return false
            }
            return record.tags.contains("imported")
                || record.tags.contains("proactive")
                || record.kind == .commitment
                || record.kind == .event
                || record.kind == .person
                || record.kind == .interest
                || record.kind == .fact
        }

        return Array(filtered.prefix(8))
    }

    private func shouldGenerateDigest(sourceRecordIDs: [String]) async throws -> Bool {
        let digestKey = Self.digestSourceKey(sourceRecordIDs)
        let recentDigests = try await store.findActiveByKind(.digest, limit: 200)

        for digest in recentDigests {
            let priorIDs = Self.digestSourceRecordIDs(from: digest.metadata)
            if Self.digestSourceKey(priorIDs) == digestKey {
                return false
            }
        }
        return true
    }

    private static func renderDigest(from records: [MemoryRecord], now: Date) -> String {
        let themes = dominantThemes(from: records)
        let highlights = records.prefix(4).map(renderHighlight)
        let openLoops = records
            .filter { $0.kind == .commitment || $0.kind == .event }
            .prefix(2)
            .map(renderOpenLoop)

        var sections = ["Recent memory digest (\(timestampFormatter.string(from: now)))"]
        if !themes.isEmpty {
            sections.append("Themes: \(themes.joined(separator: ", ")).")
        }
        if !highlights.isEmpty {
            sections.append("Signals:\n" + highlights.joined(separator: "\n"))
        }
        if !openLoops.isEmpty {
            sections.append("Open loops:\n" + openLoops.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func renderHighlight(record: MemoryRecord) -> String {
        let source = sourceLabel(for: record)
        let snippet = compactSnippet(from: record.text, maxLength: 160)
        return "- [\(source)] \(snippet)"
    }

    private static func renderOpenLoop(record: MemoryRecord) -> String {
        "- \(compactSnippet(from: record.text, maxLength: 120))"
    }

    private static func sourceLabel(for record: MemoryRecord) -> String {
        if let sourceType = metadataValue(for: record, key: "source_type"), !sourceType.isEmpty {
            return sourceType.replacingOccurrences(of: "_", with: " ")
        }
        if record.tags.contains("proactive") {
            return "proactive"
        }
        return record.kind.rawValue
    }

    private static func dominantThemes(from records: [MemoryRecord]) -> [String] {
        var counts: [String: Int] = [:]
        for record in records {
            let uniqueTokens = Set(tokenizeForSearch(record.text))
            for token in uniqueTokens where token.count >= 4 && !stopWords.contains(token) {
                counts[token, default: 0] += 1
            }
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(4)
            .map(\.key)
    }

    private static func compactSnippet(from text: String, maxLength: Int) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= maxLength {
            return collapsed
        }
        return String(collapsed.prefix(maxLength - 3)).trimmingCharacters(in: .whitespaces) + "..."
    }

    private static func digestMetadataJSON(sourceRecordIDs: [String], generatedAt: Date) -> String? {
        let payload: [String: Any] = [
            "generated_at": isoFormatter.string(from: generatedAt),
            "source_record_ids": sourceRecordIDs,
            "source_record_key": digestSourceKey(sourceRecordIDs),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func digestSourceRecordIDs(from metadata: String?) -> [String] {
        guard let metadata,
              let data = metadata.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ids = dict["source_record_ids"] as? [String]
        else {
            return []
        }
        return ids
    }

    private static func digestSourceKey(_ sourceRecordIDs: [String]) -> String {
        sourceRecordIDs.sorted().joined(separator: "|")
    }

    private static func metadataValue(for record: MemoryRecord, key: String) -> String? {
        guard let metadata = record.metadata,
              let data = metadata.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return dict[key] as? String
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
