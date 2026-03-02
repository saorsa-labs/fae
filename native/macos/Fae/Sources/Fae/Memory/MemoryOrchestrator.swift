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
    private let embeddingEngine: NeuralEmbeddingEngine?
    private let vectorStore: VectorStore?
    private let entityLinker: EntityLinker?
    private let entityStore: EntityStore?

    init(
        store: SQLiteMemoryStore,
        config: FaeConfig.MemoryConfig,
        entityLinker: EntityLinker? = nil,
        entityStore: EntityStore? = nil,
        vectorStore: VectorStore? = nil,
        embeddingEngine: NeuralEmbeddingEngine? = nil
    ) {
        self.store = store
        self.config = config
        self.vectorStore = vectorStore
        self.embeddingEngine = embeddingEngine
        self.entityLinker = entityLinker
        self.entityStore = entityStore
    }

    // MARK: - Recall

    /// Build a memory context string for injection into the LLM system prompt.
    func recall(query: String) async -> String? {
        guard config.enabled else { return nil }

        do {
            // Entity-enriched recall: detect person-centric queries first.
            let entityContext = await buildEntityContext(for: query)

            let limit = max(config.maxRecallResults, 1)
            let hits = try await store.search(query: query, limit: limit)
            let rerankedHits = await rerankHitsIfPossible(query: query, hits: hits)

            guard !rerankedHits.isEmpty else { return nil }

            let minConfidence: Float = 0.5
            let now = UInt64(Date().timeIntervalSince1970)

            // Filter out stale records (past their staleAfterSecs expiry).
            let freshHits = rerankedHits.filter { hit in
                guard let staleSecs = hit.record.staleAfterSecs,
                      hit.record.createdAt > 0
                else { return true }
                return (hit.record.createdAt + staleSecs) > now
            }

            // Split durable vs episode hits.
            let durableHits = freshHits.filter {
                $0.record.kind != .episode && $0.record.confidence >= minConfidence
            }
            let episodeHits = freshHits.filter {
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

            guard !lines.isEmpty || entityContext != nil else { return nil }

            var contextParts: [String] = []
            if let entitySection = entityContext {
                contextParts.append(entitySection)
            }
            if !lines.isEmpty {
                contextParts.append(lines.joined(separator: "\n"))
            }
            return "<memory_context>\n" + contextParts.joined(separator: "\n") + "\n</memory_context>"
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
        assistantText: String,
        speakerId: String? = nil,
        utteranceTimestamp: Date? = nil
    ) async -> MemoryCaptureReport {
        guard config.enabled else { return MemoryCaptureReport() }

        // Encode utterance timestamp into metadata JSON for all records in this turn.
        let timestampMetadata: String?
        if let ts = utteranceTimestamp {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let json = "{\"utterance_at\":\"\(iso.string(from: ts))\"}"
            timestampMetadata = json
        } else {
            timestampMetadata = nil
        }

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
                tags: ["turn"],
                importanceScore: 0.30,
                staleAfterSecs: 7_776_000,  // 90 days
                speakerId: speakerId,
                metadata: timestampMetadata
            )
            report.episodeId = episode.id

            // Embed the new record non-blocking.
            if let engine = embeddingEngine, let vs = vectorStore {
                let recordId = episode.id
                let textToEmbed = episodeText
                Task {
                    if let embedding = try? await engine.embed(text: textToEmbed) {
                        try? await vs.upsertRecordEmbedding(recordId: recordId, embedding: embedding)
                    }
                }
            }

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
                        tags: ["remembered"],
                        importanceScore: 0.80,
                        speakerId: speakerId,
                        metadata: timestampMetadata
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
                    report: &report,
                    speakerId: speakerId,
                    metadata: timestampMetadata
                )
            }

            // 5. Parse preference statements.
            if let pref = extractPreference(from: lower, fullText: userText) {
                // Check for contradiction with existing preferences.
                try await supersedeContradiction(
                    tag: "preference", newText: pref, sourceTurnId: turnId
                )
                _ = try await store.insertRecord(
                    kind: .profile,
                    text: pref,
                    confidence: MemoryConstants.profilePreferenceConfidence,
                    sourceTurnId: turnId,
                    tags: ["preference"],
                    importanceScore: 0.85,
                    speakerId: speakerId,
                    metadata: timestampMetadata
                )
                report.extractedCount += 1
            }

            // 6. Parse interest statements.
            if let interest = extractInterest(from: lower, fullText: userText) {
                _ = try await store.insertRecord(
                    kind: .interest,
                    text: interest,
                    confidence: MemoryConstants.profilePreferenceConfidence,
                    sourceTurnId: turnId,
                    tags: ["interest"],
                    importanceScore: 0.70,
                    speakerId: speakerId,
                    metadata: timestampMetadata
                )
                report.extractedCount += 1
            }

            // 7. Parse commitment statements (deadlines, promises).
            if let commitment = extractCommitment(from: lower, fullText: userText) {
                _ = try await store.insertRecord(
                    kind: .commitment,
                    text: commitment,
                    confidence: MemoryConstants.factConversationalConfidence,
                    sourceTurnId: turnId,
                    tags: ["commitment"],
                    importanceScore: 0.90,
                    staleAfterSecs: 2_592_000,  // 30 days
                    speakerId: speakerId,
                    metadata: timestampMetadata
                )
                report.extractedCount += 1
            }

            // 8. Parse event mentions (birthdays, anniversaries, dates).
            if let event = extractEvent(from: lower, fullText: userText) {
                _ = try await store.insertRecord(
                    kind: .event,
                    text: event,
                    confidence: MemoryConstants.factConversationalConfidence,
                    sourceTurnId: turnId,
                    tags: ["event"],
                    importanceScore: 0.85,
                    staleAfterSecs: 604_800,  // 7 days
                    speakerId: speakerId,
                    metadata: timestampMetadata
                )
                report.extractedCount += 1
            }

            // 9. Parse person mentions (relationships, people).
            if let person = extractPerson(from: lower, fullText: userText) {
                let personRecord = try await store.insertRecord(
                    kind: .person,
                    text: person,
                    confidence: MemoryConstants.factConversationalConfidence,
                    sourceTurnId: turnId,
                    tags: ["person"],
                    importanceScore: 0.75,
                    speakerId: speakerId,
                    metadata: timestampMetadata
                )
                report.extractedCount += 1

                // Fire async entity linking (non-blocking).
                if let linker = entityLinker {
                    let recordId = personRecord.id
                    Task {
                        await linker.linkPersonRecord(
                            text: person,
                            recordId: recordId,
                            turnId: turnId
                        )
                    }
                }
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

    /// Hybrid ANN + FTS5 reranking (0.60 ANN + 0.40 lexical).
    /// Falls back to lexical ordering when vectorStore or embeddingEngine not ready.
    private func rerankHitsIfPossible(query: String, hits: [MemorySearchHit]) async -> [MemorySearchHit] {
        guard !hits.isEmpty else { return [] }

        // ANN hybrid path — preferred when vectorStore + loaded engine available.
        if let vs = vectorStore, let engine = embeddingEngine, await engine.isLoaded {
            do {
                let queryEmbedding = try await engine.embedQuery(query)
                let annResults = try await vs.searchRecords(
                    queryEmbedding: queryEmbedding,
                    limit: hits.count * 3
                )

                // Build ANN score lookup: recordId → similarity in [0, 1].
                // sqlite-vec returns cosine distance in [0, 2]; convert to similarity.
                var annScores: [String: Float] = [:]
                for (id, distance) in annResults {
                    annScores[id] = max(0, 1.0 - (distance / 2.0))
                }

                var reranked: [MemorySearchHit] = []
                reranked.reserveCapacity(hits.count)
                for hit in hits {
                    let ann = annScores[hit.record.id] ?? 0.0
                    let blended = 0.60 * ann + 0.40 * hit.score
                    reranked.append(MemorySearchHit(record: hit.record, score: blended))
                }
                reranked.sort { $0.score > $1.score }
                return reranked
            } catch {
                NSLog("MemoryOrchestrator: ANN rerank error (falling back): %@",
                      error.localizedDescription)
            }
        }

        return hits
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

    /// Supersede contradicting records for a given tag when new text diverges semantically.
    private func supersedeContradiction(tag: String, newText: String, sourceTurnId: String) async throws {
        let existing = try await store.findActiveByTag(tag)
        guard !existing.isEmpty else { return }

        guard let engine = embeddingEngine, await engine.isLoaded else {
            // No semantic engine — skip contradiction detection.
            return
        }

        do {
            let newEmbedding = try await engine.embed(text: newText)

            for old in existing {
                let oldEmbedding: [Float]
                if let cached = old.cachedEmbedding, !cached.isEmpty {
                    oldEmbedding = cached
                } else {
                    oldEmbedding = try await engine.embed(text: old.text)
                }
                let similarity = cosineSimilarity(newEmbedding, oldEmbedding)
                if similarity < 0.5 {
                    // Low similarity with same tag = contradiction → supersede.
                    _ = try await store.supersedeRecord(
                        oldId: old.id,
                        newText: newText,
                        confidence: old.confidence,
                        sourceTurnId: sourceTurnId,
                        tags: old.tags,
                        note: "contradiction detected (cosine=\(String(format: "%.2f", similarity)))"
                    )
                    NSLog("MemoryOrchestrator: superseded contradicting record %@ (tag=%@, cos=%.2f)",
                          old.id, tag, similarity)
                }
            }
        } catch {
            NSLog("MemoryOrchestrator: contradiction check error: %@", error.localizedDescription)
        }
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
        report: inout MemoryCaptureReport,
        importanceScore: Float = 1.0,
        speakerId: String? = nil,
        metadata: String? = nil
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
                tags: allTags,
                importanceScore: importanceScore,
                speakerId: speakerId,
                metadata: metadata
            )
            report.extractedCount += 1
        }
    }

    /// Extract a name from statements like "my name is X", "call me X".
    ///
    /// Deliberately avoids generic patterns like "I'm X" which create frequent
    /// false positives during normal conversation.
    private func extractName(from lower: String, fullText: String) -> String? {
        let patterns = [
            "my name is ", "my name's ", "call me ",
            "you can call me ", "people call me ",
        ]
        for pattern in patterns {
            if let range = lower.range(of: pattern) {
                let after = fullText[range.upperBound...]
                let candidate = after.prefix(while: { $0.isLetter || $0 == " " || $0 == "-" || $0 == "'" })
                    .trimmingCharacters(in: .whitespaces)
                if isLikelyHumanName(candidate) {
                    return candidate
                }
            }
        }
        return nil
    }

    private func isLikelyHumanName(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 50 else { return false }

        let words = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !words.isEmpty, words.count <= 4 else { return false }

        let blockedTokens: Set<String> = [
            "in", "my", "own", "kitchen", "here", "there", "home",
            "doing", "good", "fine", "okay", "ok", "the", "a", "an",
        ]

        for word in words {
            let lowered = word.lowercased()
            if blockedTokens.contains(lowered) { return false }
            if word.rangeOfCharacter(from: CharacterSet.decimalDigits) != nil { return false }
            if word.count < 2 { return false }
        }

        return true
    }

    /// Extract preference statements like "I prefer X", "I like X".
    private func extractPreference(from lower: String, fullText: String) -> String? {
        extractFirstMatch(
            from: lower, fullText: fullText,
            patterns: ["i prefer ", "i like ", "i love ", "i enjoy ",
                       "i hate ", "i dislike ", "i don't like "],
            anchorAtUpperBound: false,
            resultPrefix: "User says: "
        )
    }

    /// Extract interest statements like "I'm interested in X", "I'm passionate about X".
    private func extractInterest(from lower: String, fullText: String) -> String? {
        extractFirstMatch(
            from: lower, fullText: fullText,
            patterns: ["i'm interested in ", "i am interested in ",
                       "i'm passionate about ", "i am passionate about ",
                       "i'm into ", "i am into ",
                       "i'm fascinated by ", "i am fascinated by ",
                       "i'm curious about ", "i am curious about ",
                       "my hobby is ", "my hobbies are "],
            anchorAtUpperBound: true,
            minLength: 3,
            resultPrefix: "User is interested in: "
        )
    }

    /// Extract commitment statements like "I need to X by Y", "deadline is".
    private func extractCommitment(from lower: String, fullText: String) -> String? {
        extractFirstMatch(
            from: lower, fullText: fullText,
            patterns: ["i need to ", "i have to ", "i must ",
                       "i should ", "i promised to ",
                       "deadline is ", "the deadline is ",
                       "due by ", "due on ", "due date is ",
                       "i committed to ", "i agreed to "],
            anchorAtUpperBound: false,
            maxLength: 300,
            resultPrefix: "User commitment: "
        )
    }

    /// Extract event mentions like "my birthday is", "anniversary on".
    private func extractEvent(from lower: String, fullText: String) -> String? {
        extractFirstMatch(
            from: lower, fullText: fullText,
            patterns: ["my birthday is ", "birthday is on ",
                       "anniversary is ", "anniversary on ",
                       "wedding is ", "wedding on ",
                       "graduation is ", "graduation on ",
                       "appointment on ", "appointment is ",
                       "meeting on ", "event on ",
                       "party on ", "dinner on ",
                       "trip on ", "flight on ", "vacation on "],
            anchorAtUpperBound: false,
            resultPrefix: "User event: "
        )
    }

    /// Extract person mentions like "my sister X", "my friend X works at".
    private func extractPerson(from lower: String, fullText: String) -> String? {
        extractFirstMatch(
            from: lower, fullText: fullText,
            patterns: ["my wife ", "my husband ", "my partner ",
                       "my sister ", "my brother ", "my mom ", "my mum ", "my dad ",
                       "my daughter ", "my son ", "my child ",
                       "my friend ", "my colleague ", "my coworker ", "my co-worker ",
                       "my boss ", "my manager ", "my teacher ",
                       "my girlfriend ", "my boyfriend ",
                       "my uncle ", "my aunt ", "my cousin ",
                       "my grandmother ", "my grandfather ", "my grandma ", "my grandpa "],
            anchorAtUpperBound: false,
            resultPrefix: "User knows: "
        )
    }

    /// Shared pattern-match extractor for memory capture functions.
    ///
    /// Searches `lower` for the first matching trigger phrase, then captures text from
    /// `fullText` starting at the pattern boundary.
    ///
    /// - Parameters:
    ///   - lower: Lowercased user text used for case-insensitive pattern matching.
    ///   - fullText: Original text used for the captured content (preserves original casing).
    ///   - patterns: Trigger phrases to match.
    ///   - anchorAtUpperBound: `true` to capture text *after* the pattern; `false` to include it.
    ///   - maxLength: Maximum character length for the captured result.
    ///   - minLength: Minimum character length required for a valid match (default 1).
    ///   - resultPrefix: Prepended to the captured text in the returned string.
    private func extractFirstMatch(
        from lower: String,
        fullText: String,
        patterns: [String],
        anchorAtUpperBound: Bool,
        maxLength: Int = 200,
        minLength: Int = 1,
        resultPrefix: String
    ) -> String? {
        for pattern in patterns {
            if lower.contains(pattern),
               let range = lower.range(of: pattern)
            {
                let start = anchorAtUpperBound ? range.upperBound : range.lowerBound
                let result = String(fullText[start...].prefix(maxLength))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !result.isEmpty, result.count >= minLength {
                    return "\(resultPrefix)\(result)"
                }
            }
        }
        return nil
    }

    // MARK: - Entity Context

    /// Build entity-enriched context section for person-centric queries.
    private func buildEntityContext(for query: String) async -> String? {
        guard let entityStore else { return nil }
        guard let match = PersonQueryDetector.detectPersonQuery(in: query) else { return nil }

        do {
            var profiles: [EntityProfile] = []

            if let org = match.targetOrganisation {
                // "Who works at X?" — find people connected via works_at edge.
                let people = try await entityStore.findEntities(
                    connectedTo: org, via: "works_at"
                )
                for person in people.prefix(5) {
                    if let profile = try await entityStore.entityProfile(id: person.id) {
                        profiles.append(profile)
                    }
                }
            } else if let loc = match.targetLocation {
                // "Who lives in X?" — find people connected via lives_in edge.
                let people = try await entityStore.findEntities(
                    connectedTo: loc, via: "lives_in"
                )
                for person in people.prefix(5) {
                    if let profile = try await entityStore.entityProfile(id: person.id) {
                        profiles.append(profile)
                    }
                }
            } else if let name = match.targetName,
                      let entity = try await entityStore.findEntity(byName: name),
                      let profile = try await entityStore.entityProfile(id: entity.id)
            {
                profiles.append(profile)
            } else if let label = match.targetRelationLabel {
                // No name — find by relation label (first strong match).
                let candidates = try await entityStore.staleEntities(
                    olderThanDays: 0,
                    priorityOrder: RelationType.allCases
                )
                for candidate in candidates where candidate.relationLabel == label {
                    if let profile = try await entityStore.entityProfile(id: candidate.id) {
                        profiles.append(profile)
                        break
                    }
                }
            }

            guard !profiles.isEmpty else { return nil }

            // Format profiles with resolved relationship edges.
            var sections: [String] = []
            var totalChars = 0
            for profile in profiles {
                let edges = try await resolvedEdges(for: profile.entity.id, entityStore: entityStore)
                let section = EntityContextFormatter.format(
                    profile: profile,
                    linkedRecords: [],
                    edges: edges
                )
                if totalChars + section.count > MemoryConstants.entityMaxContextChars,
                   !sections.isEmpty { break }
                sections.append(section)
                totalChars += section.count
            }
            let formatted = sections.joined(separator: "\n")
            return formatted.isEmpty ? nil : formatted
        } catch {
            NSLog("MemoryOrchestrator: buildEntityContext error: %@", error.localizedDescription)
            return nil
        }
    }

    /// Resolve relationship edges for an entity into formatted edges (with target canonical names).
    private func resolvedEdges(
        for entityId: String,
        entityStore: EntityStore
    ) async throws -> [EntityContextFormatter.FormattedEdge] {
        let rels = try await entityStore.relationships(forEntityId: entityId)
        var result: [EntityContextFormatter.FormattedEdge] = []
        for rel in rels.prefix(6) {
            if let target = try? await entityStore.findEntity(byId: rel.targetId) {
                result.append(EntityContextFormatter.FormattedEdge(
                    relationType: rel.relationType,
                    targetName: target.canonicalName,
                    startedAt: rel.startedAt,
                    endedAt: rel.endedAt
                ))
            }
        }
        return result
    }
}
