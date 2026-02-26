import Foundation

/// Orchestrates memory recall and capture for the voice pipeline.
///
/// Before each LLM generation: `recall(query:)` retrieves relevant context.
/// After each completed turn: `capture(turnId:userText:assistantText:)` extracts
/// and persists durable memories (profile, facts) plus episode records.
///
/// Replaces: `src/memory/jsonl.rs` (MemoryOrchestrator)
actor MemoryOrchestrator {
    private let store: SQLiteMemoryStore
    private let config: FaeConfig.MemoryConfig
    private let embeddingEngine: MLXEmbeddingEngine

    init(store: SQLiteMemoryStore, config: FaeConfig.MemoryConfig) {
        self.store = store
        self.config = config
        self.embeddingEngine = MLXEmbeddingEngine()
    }

    // MARK: - Recall

    /// Build a memory context string for injection into the LLM system prompt.
    func recall(query: String) async -> String? {
        guard config.enabled else { return nil }

        do {
            let limit = max(config.maxRecallResults, 1)
            let hits = try await store.search(query: query, limit: limit)
            let rerankedHits = await rerankHitsIfPossible(query: query, hits: hits)

            guard !rerankedHits.isEmpty else { return nil }

            let minConfidence: Float = 0.5

            // Split durable vs episode hits.
            let durableHits = rerankedHits.filter {
                $0.record.kind != .episode && $0.record.confidence >= minConfidence
            }
            let episodeHits = rerankedHits.filter {
                $0.record.kind == .episode
                    && $0.score >= MemoryConstants.episodeThresholdLexical
            }

            guard !durableHits.isEmpty || !episodeHits.isEmpty else { return nil }

            var lines: [String] = []
            let maxChars = 2000

            // Durable records first.
            for hit in durableHits {
                let line = "- [\(hit.record.kind.rawValue) \(String(format: "%.2f", hit.record.confidence))] \(hit.record.text)"
                if lines.joined(separator: "\n").count + line.count > maxChars { break }
                lines.append(line)
            }

            // Then episodes (max 3).
            for hit in episodeHits.prefix(3) {
                let line = "- [episode \(String(format: "%.2f", hit.record.confidence))] \(hit.record.text)"
                if lines.joined(separator: "\n").count + line.count > maxChars { break }
                lines.append(line)
            }

            guard !lines.isEmpty else { return nil }
            return "<memory_context>\n" + lines.joined(separator: "\n") + "\n</memory_context>"
        } catch {
            NSLog("MemoryOrchestrator: recall error: %@", error.localizedDescription)
            return nil
        }
    }

    // MARK: - Capture

    /// Extract and persist memories from a completed conversation turn.
    func capture(
        turnId: String,
        userText: String,
        assistantText: String
    ) async -> MemoryCaptureReport {
        guard config.enabled else { return MemoryCaptureReport() }

        var report = MemoryCaptureReport()

        do {
            // 1. Always insert episode record.
            let episodeText: String
            if assistantText.isEmpty {
                episodeText = "User: \(userText)"
            } else {
                episodeText = "User: \(userText)\nAssistant: \(assistantText)"
            }
            let episode = try await store.insertRecord(
                kind: .episode,
                text: episodeText,
                confidence: MemoryConstants.episodeConfidence,
                sourceTurnId: turnId,
                tags: ["turn"]
            )
            report.episodeId = episode.id

            let lower = userText.lowercased()

            // 2. Parse forget commands.
            if lower.hasPrefix("forget ") {
                let query = String(userText.dropFirst(7)).trimmingCharacters(in: .whitespaces)
                let forgotCount = try await forgetMatching(query: query)
                report.forgottenCount += forgotCount
            }

            // 3. Parse "remember ..." commands.
            if lower.hasPrefix("remember ") {
                let fact = String(userText.dropFirst(9)).trimmingCharacters(in: .whitespaces)
                if !fact.isEmpty {
                    _ = try await store.insertRecord(
                        kind: .fact,
                        text: fact,
                        confidence: MemoryConstants.factRememberConfidence,
                        sourceTurnId: turnId,
                        tags: ["remembered"]
                    )
                    report.extractedCount += 1
                }
            }

            // 4. Parse name statements.
            if let name = extractName(from: lower, fullText: userText) {
                try await upsertProfile(
                    tag: "name",
                    text: "Primary user name is \(name).",
                    confidence: MemoryConstants.profileNameConfidence,
                    sourceTurnId: turnId,
                    allTags: ["name", "identity"],
                    report: &report
                )
            }

            // 5. Parse preference statements.
            if let pref = extractPreference(from: lower, fullText: userText) {
                _ = try await store.insertRecord(
                    kind: .profile,
                    text: pref,
                    confidence: MemoryConstants.profilePreferenceConfidence,
                    sourceTurnId: turnId,
                    tags: ["preference"]
                )
                report.extractedCount += 1
            }

        } catch {
            NSLog("MemoryOrchestrator: capture error: %@", error.localizedDescription)
        }

        return report
    }

    // MARK: - Garbage Collection

    /// Apply retention policy to episode records.
    func garbageCollect(retentionDays: UInt64 = 90) async -> Int {
        do {
            return try await store.applyRetentionPolicy(retentionDays: retentionDays)
        } catch {
            NSLog("MemoryOrchestrator: gc error: %@", error.localizedDescription)
            return 0
        }
    }

    // MARK: - Private Helpers

    /// Blend lexical and semantic ranking, with safe fallback to lexical ordering.
    private func rerankHitsIfPossible(query: String, hits: [MemorySearchHit]) async -> [MemorySearchHit] {
        guard !hits.isEmpty else { return [] }

        do {
            if !(await embeddingEngine.isLoaded) {
                try await embeddingEngine.load(modelID: "foundation-hash-384")
            }

            let queryEmbedding = try await embeddingEngine.embed(text: query)
            let queryNorm = l2Norm(queryEmbedding)
            guard queryNorm > 0 else { return hits }

            let lexicalWeight: Float = 0.70
            let semanticWeight: Float = 0.30

            var reranked: [MemorySearchHit] = []
            reranked.reserveCapacity(hits.count)

            for hit in hits {
                let recordEmbedding = try await embeddingEngine.embed(text: hit.record.text)
                let semantic = cosineSimilarity(queryEmbedding, recordEmbedding)
                let blended = (lexicalWeight * hit.score) + (semanticWeight * semantic)
                reranked.append(MemorySearchHit(record: hit.record, score: blended))
            }

            reranked.sort { $0.score > $1.score }
            return reranked
        } catch {
            NSLog("MemoryOrchestrator: semantic rerank fallback: %@", error.localizedDescription)
            return hits
        }
    }

    private func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Float {
        let length = min(lhs.count, rhs.count)
        guard length > 0 else { return 0 }

        var dot: Float = 0
        var lhsSq: Float = 0
        var rhsSq: Float = 0

        for i in 0 ..< length {
            let a = lhs[i]
            let b = rhs[i]
            dot += a * b
            lhsSq += a * a
            rhsSq += b * b
        }

        let denom = sqrt(lhsSq) * sqrt(rhsSq)
        guard denom > 0 else { return 0 }
        return dot / denom
    }

    private func l2Norm(_ vector: [Float]) -> Float {
        sqrt(vector.reduce(Float(0)) { $0 + ($1 * $1) })
    }

    /// Forget records matching a query.
    private func forgetMatching(query: String) async throws -> Int {
        let hits = try await store.search(query: query, limit: 5)
        var count = 0
        for hit in hits where hit.score > 0.5 {
            try await store.forgetSoftRecord(id: hit.record.id, note: "user requested forget")
            count += 1
        }
        return count
    }

    /// Upsert a profile record by tag — supersede existing if found.
    private func upsertProfile(
        tag: String,
        text: String,
        confidence: Float,
        sourceTurnId: String,
        allTags: [String],
        report: inout MemoryCaptureReport
    ) async throws {
        let existing = try await store.findActiveByTag(tag)

        if let old = existing.first {
            _ = try await store.supersedeRecord(
                oldId: old.id,
                newText: text,
                confidence: confidence,
                sourceTurnId: sourceTurnId,
                tags: allTags,
                note: "updated \(tag)"
            )
            report.supersededCount += 1
        } else {
            _ = try await store.insertRecord(
                kind: .profile,
                text: text,
                confidence: confidence,
                sourceTurnId: sourceTurnId,
                tags: allTags
            )
            report.extractedCount += 1
        }
    }

    /// Extract a name from statements like "my name is X", "I'm X", "call me X".
    private func extractName(from lower: String, fullText: String) -> String? {
        let patterns = [
            "my name is ", "i'm ", "call me ", "i am ",
            "my name's ", "you can call me ", "people call me ",
        ]
        for pattern in patterns {
            if lower.contains(pattern),
               let range = lower.range(of: pattern)
            {
                let after = fullText[range.upperBound...]
                let name = after.prefix(while: { $0.isLetter || $0 == " " || $0 == "-" })
                    .trimmingCharacters(in: .whitespaces)
                if !name.isEmpty, name.count < 50 {
                    return name
                }
            }
        }
        return nil
    }

    /// Extract preference statements like "I prefer X", "I like X".
    private func extractPreference(from lower: String, fullText: String) -> String? {
        let patterns = [
            "i prefer ", "i like ", "i love ", "i enjoy ",
            "i hate ", "i dislike ", "i don't like ",
        ]
        for pattern in patterns {
            if lower.contains(pattern),
               let range = lower.range(of: pattern)
            {
                let after = fullText[range.lowerBound...]
                let pref = String(after.prefix(200))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !pref.isEmpty {
                    return "User says: \(pref)"
                }
            }
        }
        return nil
    }
}
