import Foundation

// MARK: - Types

struct PersonExtraction: Sendable {
    var canonicalName: String?
    var relationType: RelationType?
    var relationLabel: String?
    var facts: [String: String]
}

struct EntityResolution: Sendable {
    var entityId: String
    var canonicalName: String
    var isNewEntity: Bool
    var confidence: Float
}

// MARK: - EdgeExtraction

struct ExtractedEdge: Sendable {
    /// Relation type label for entity_relationships.relationType
    var relationType: String
    /// Name of the target entity (org or location)
    var targetName: String
    /// EntityType of the target
    var targetEntityType: EntityType
}

// MARK: - EntityLinker

/// Resolves person record text to canonical entities.
/// No LLM call in the fast path — extraction is regex/heuristic only.
actor EntityLinker {
    private let entityStore: EntityStore
    private let vectorStore: VectorStore?
    private let embeddingEngine: NeuralEmbeddingEngine?

    init(
        entityStore: EntityStore,
        vectorStore: VectorStore? = nil,
        embeddingEngine: NeuralEmbeddingEngine? = nil
    ) {
        self.entityStore = entityStore
        self.vectorStore = vectorStore
        self.embeddingEngine = embeddingEngine
    }

    // MARK: - Extract

    /// Extract structured fields from a person record text.
    /// Input example: "User knows: my sister Sarah works at Google"
    func extractFields(from personText: String) -> PersonExtraction {
        // Strip common prefixes injected by MemoryOrchestrator.
        let text = personText
            .replacingOccurrences(of: "User knows: ", with: "")
            .replacingOccurrences(of: "User's ", with: "my ")
            .trimmingCharacters(in: .whitespaces)

        let lower = text.lowercased()

        // Relation label → type mapping.
        let labelToType: [(label: String, type: RelationType)] = [
            ("sister", .family), ("brother", .family), ("mom", .family), ("mum", .family),
            ("dad", .family), ("father", .family), ("mother", .family),
            ("daughter", .family), ("son", .family), ("child", .family),
            ("aunt", .family), ("uncle", .family), ("cousin", .family),
            ("grandmother", .family), ("grandfather", .family),
            ("grandma", .family), ("grandpa", .family),
            ("wife", .romantic), ("husband", .romantic), ("partner", .romantic),
            ("girlfriend", .romantic), ("boyfriend", .romantic),
            ("friend", .friend),
            ("boss", .colleague), ("manager", .colleague), ("colleague", .colleague),
            ("coworker", .colleague), ("co-worker", .colleague), ("teacher", .colleague),
        ]

        var detectedLabel: String?
        var detectedType: RelationType?
        var nameCandidate: String?

        for entry in labelToType {
            let label = entry.label
            // "my <label> <name>"
            if lower.hasPrefix("my \(label) ") || lower.hasPrefix("my \(label)'s ") {
                detectedLabel = label
                detectedType = entry.type
                let prefixLen = lower.hasPrefix("my \(label)'s ")
                    ? "my \(label)'s ".count
                    : "my \(label) ".count
                nameCandidate = extractFirstName(from: String(text.dropFirst(prefixLen)))
                break
            }
        }

        // Inline fact extraction (e.g., "works at Google", "lives in London").
        var facts: [String: String] = [:]
        let factPatterns: [(key: String, patterns: [String])] = [
            ("employer", ["works at ", "works for ", "employed at ", "employed by "]),
            ("location", ["lives in ", "based in ", "is from ", "moved to "]),
            ("job", ["is a ", "works as ", "is an "]),
        ]
        for entry in factPatterns {
            for pattern in entry.patterns where lower.contains(pattern) {
                if let range = lower.range(of: pattern) {
                    let after = String(text[range.upperBound...])
                        .components(separatedBy: CharacterSet(charactersIn: ".,;!?\n"))
                        .first?
                        .trimmingCharacters(in: .whitespaces) ?? ""
                    if !after.isEmpty, after.count < 80 {
                        facts[entry.key] = after
                        break
                    }
                }
            }
        }

        return PersonExtraction(
            canonicalName: nameCandidate,
            relationType: detectedType,
            relationLabel: detectedLabel,
            facts: facts
        )
    }

    /// Extract relationship edges (works_at, lives_in, knows) from person text.
    func extractEdges(from personText: String) -> [ExtractedEdge] {
        let text = personText
            .replacingOccurrences(of: "User knows: ", with: "")
            .replacingOccurrences(of: "User's ", with: "my ")
            .trimmingCharacters(in: .whitespaces)
        let lower = text.lowercased()

        var edges: [ExtractedEdge] = []

        let orgPatterns = ["works at ", "works for ", "employed at ", "employed by "]
        for pattern in orgPatterns where lower.contains(pattern) {
            if let range = lower.range(of: pattern) {
                let after = String(text[range.upperBound...])
                    .components(separatedBy: CharacterSet(charactersIn: ".,;!?\n"))
                    .first?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if !after.isEmpty, after.count < 80 {
                    edges.append(ExtractedEdge(
                        relationType: "works_at",
                        targetName: after,
                        targetEntityType: .organisation
                    ))
                }
            }
        }

        let locationPatterns = ["lives in ", "based in ", "moved to "]
        for pattern in locationPatterns where lower.contains(pattern) {
            if let range = lower.range(of: pattern) {
                let after = String(text[range.upperBound...])
                    .components(separatedBy: CharacterSet(charactersIn: ".,;!?\n"))
                    .first?
                    .trimmingCharacters(in: .whitespaces) ?? ""
                if !after.isEmpty, after.count < 80 {
                    edges.append(ExtractedEdge(
                        relationType: "lives_in",
                        targetName: after,
                        targetEntityType: .location
                    ))
                }
            }
        }

        return edges
    }

    // MARK: - Resolve

    /// Resolve person text to a canonical entity, creating one if needed.
    /// Returns nil when no name can be extracted and no match found.
    func resolve(personText: String, conversationContext: String? = nil) async throws -> EntityResolution? {
        let extraction = extractFields(from: personText)
        guard let name = extraction.canonicalName, !name.isEmpty else {
            return nil
        }

        // Check for existing entity first.
        if let existing = try await entityStore.findEntity(byName: name) {
            return EntityResolution(
                entityId: existing.id,
                canonicalName: existing.canonicalName,
                isNewEntity: false,
                confidence: 0.85
            )
        }

        // Create new entity.
        let entity = try await entityStore.findOrCreateEntity(
            canonicalName: name,
            relationType: extraction.relationType,
            relationLabel: extraction.relationLabel
        )
        return EntityResolution(
            entityId: entity.id,
            canonicalName: entity.canonicalName,
            isNewEntity: true,
            confidence: 0.75
        )
    }

    // MARK: - Full Pipeline

    /// Full link pipeline: extract → resolve → bump mention count → link record → upsert facts → edges → recompute strength.
    func linkPersonRecord(text: String, recordId: String, turnId: String) async {
        do {
            let extraction = extractFields(from: text)
            guard let name = extraction.canonicalName, !name.isEmpty else {
                NSLog("EntityLinker: no name extracted from record %@", recordId)
                return
            }

            // Find or create entity.
            let entity = try await entityStore.findOrCreateEntity(
                canonicalName: name,
                relationType: extraction.relationType,
                relationLabel: extraction.relationLabel,
                entityType: .person
            )

            let now = UInt64(Date().timeIntervalSince1970)
            try await entityStore.bumpMentionCount(entityId: entity.id, at: now)
            try await entityStore.linkRecord(entityId: entity.id, memoryRecordId: recordId)

            // Persist extracted facts with temporal versioning.
            for (key, value) in extraction.facts {
                try await entityStore.upsertTemporalFact(
                    entityId: entity.id,
                    key: key,
                    value: value,
                    sourceRecordId: recordId,
                    confidence: 0.75
                )
                // Embed the fact if engine available.
                if let engine = embeddingEngine, let vs = vectorStore {
                    let factText = "\(key): \(value)"
                    if let embedding = try? await engine.embed(text: factText) {
                        let facts = try? await entityStore.factHistory(entityId: entity.id, key: key)
                        if let factId = facts?.first?.id {
                            try? await entityStore.updateFactEmbedding(factId: factId, embedding: embedding)
                            try? await vs.upsertFactEmbedding(factId: factId, embedding: embedding)
                        }
                    }
                }
            }

            // Extract and persist relationship edges.
            let edges = extractEdges(from: text)
            for edge in edges {
                let targetEntity = try await entityStore.findOrCreateEntity(
                    canonicalName: edge.targetName,
                    relationType: nil,
                    relationLabel: nil,
                    entityType: edge.targetEntityType
                )
                try await entityStore.addRelationship(
                    sourceId: entity.id,
                    targetId: targetEntity.id,
                    relationType: edge.relationType,
                    confidence: 0.7
                )
            }

            try await entityStore.recomputeStrengthScore(entityId: entity.id)
            NSLog("EntityLinker: linked record %@ → entity %@ (%@) edges=%d",
                  recordId, entity.id, name, edges.count)
        } catch {
            NSLog("EntityLinker: linkPersonRecord error: %@", error.localizedDescription)
        }
    }

    // MARK: - Private Helpers

    /// Extract first name-like token from text.
    private func extractFirstName(from text: String) -> String? {
        let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        var nameParts: [String] = []
        for word in words {
            let stripped = word.trimmingCharacters(in: CharacterSet(charactersIn: ",.!?;:"))
            if stripped.isEmpty { break }
            guard let first = stripped.first else { break }
            if first.isUppercase || (nameParts.isEmpty && first.isLetter) {
                // Stop at relation/verb words.
                let low = stripped.lowercased()
                let stopWords = ["works", "is", "was", "has", "lives", "moved", "called",
                                 "who", "that", "and", "or", "but", "the", "a", "an"]
                if stopWords.contains(low), !nameParts.isEmpty { break }
                nameParts.append(stripped)
                if nameParts.count >= 2 { break }
            } else {
                break
            }
        }
        return nameParts.isEmpty ? nil : nameParts.joined(separator: " ")
    }
}
