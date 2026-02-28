import Foundation
import GRDB

// MARK: - Types

enum RelationType: String, Sendable, Codable, CaseIterable {
    case family = "family"
    case friend = "friend"
    case colleague = "colleague"
    case romantic = "romantic"
    case acquaintance = "acquaintance"
}

/// Entity type classification.
enum EntityType: String, Sendable, Codable {
    case person = "person"
    case organisation = "organisation"
    case location = "location"
    case skill = "skill"
    case project = "project"
    case concept = "concept"
}

/// Typed edge between two entities.
struct EntityRelationship: Sendable {
    var id: String
    var sourceId: String
    var targetId: String
    /// "works_at" | "knows" | "lives_in" | "manages" | "reports_to"
    var relationType: String
    var confidence: Float
    var startedAt: UInt64?
    var endedAt: UInt64?
    var metadata: String?
    var createdAt: UInt64
    var updatedAt: UInt64
}

struct PersonEntity: Sendable {
    var id: String
    var canonicalName: String
    var aliases: [String]
    var relationType: RelationType?
    var relationLabel: String?
    var notes: String?
    var firstSeenAt: UInt64
    var lastMentionedAt: UInt64
    var mentionCount: Int
    var strengthScore: Float
    var entityType: EntityType
}

struct EntityFact: Sendable {
    var id: String
    var entityId: String
    var factKey: String
    var factValue: String
    var sourceRecordId: String?
    var createdAt: UInt64
    var updatedAt: UInt64
    var confidence: Float
    var startedAt: UInt64?
    var endedAt: UInt64?
    var embedding: [Float]?
}

struct EntityProfile: Sendable {
    var entity: PersonEntity
    var facts: [EntityFact]
    var linkedRecordIds: [String]
}

// MARK: - EntityStore

/// GRDB actor managing entity tables (entities, entity_mentions, entity_facts).
/// Shares the DatabaseQueue from SQLiteMemoryStore — no second connection.
actor EntityStore {
    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Find

    /// Find entity by its unique ID.
    func findEntity(byId id: String) throws -> PersonEntity? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM entities WHERE id = ?", arguments: [id])
            else { return nil }
            return Self.entityFromRow(row)
        }
    }

    /// Find entity by name: exact match, then prefix match, then Levenshtein ≤ 2.
    func findEntity(byName name: String) throws -> PersonEntity? {
        let lower = name.lowercased()
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM entities ORDER BY mention_count DESC")
            // Exact match first.
            for row in rows {
                let entity = Self.entityFromRow(row)
                let candidateLower = entity.canonicalName.lowercased()
                if candidateLower == lower { return entity }
                for alias in entity.aliases where alias.lowercased() == lower { return entity }
            }
            // Prefix match.
            for row in rows {
                let entity = Self.entityFromRow(row)
                let candidateLower = entity.canonicalName.lowercased()
                if candidateLower.hasPrefix(lower) || lower.hasPrefix(candidateLower) { return entity }
                for alias in entity.aliases {
                    let aliasLower = alias.lowercased()
                    if aliasLower.hasPrefix(lower) || lower.hasPrefix(aliasLower) { return entity }
                }
            }
            // Levenshtein ≤ 2 for short names.
            if lower.count <= 8 {
                for row in rows {
                    let entity = Self.entityFromRow(row)
                    let candidateLower = entity.canonicalName.lowercased()
                    if levenshteinDistance(lower, candidateLower) <= 2 { return entity }
                    for alias in entity.aliases where levenshteinDistance(lower, alias.lowercased()) <= 2 {
                        return entity
                    }
                }
            }
            return nil
        }
    }

    /// Find or create a canonical entity. Returns existing entity if name matches.
    func findOrCreateEntity(
        canonicalName: String,
        relationType: RelationType?,
        relationLabel: String?,
        entityType: EntityType = .person
    ) throws -> PersonEntity {
        if let existing = try findEntity(byName: canonicalName) {
            return existing
        }
        let now = UInt64(Date().timeIntervalSince1970)
        let entity = PersonEntity(
            id: newEntityId(),
            canonicalName: canonicalName,
            aliases: [],
            relationType: relationType,
            relationLabel: relationLabel,
            notes: nil,
            firstSeenAt: now,
            lastMentionedAt: now,
            mentionCount: 0,
            strengthScore: 0.0,
            entityType: entityType
        )
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO entities
                        (id, canonical_name, aliases, relation_type, relation_label, notes,
                         first_seen_at, last_mentioned_at, mention_count, strength_score, entity_type)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    entity.id, entity.canonicalName, "[]",
                    entity.relationType?.rawValue, entity.relationLabel, entity.notes,
                    entity.firstSeenAt, entity.lastMentionedAt,
                    entity.mentionCount, Double(entity.strengthScore),
                    entity.entityType.rawValue,
                ]
            )
        }
        return entity
    }

    // MARK: - Profile

    /// Returns full profile: entity + facts + linked record IDs.
    func entityProfile(id: String) throws -> EntityProfile? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db, sql: "SELECT * FROM entities WHERE id = ?", arguments: [id]
            ) else { return nil }
            let entity = Self.entityFromRow(row)
            let factRows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM entity_facts WHERE entity_id = ? ORDER BY fact_key",
                arguments: [id]
            )
            let facts = factRows.map { Self.factFromRow($0) }
            let mentionRows = try Row.fetchAll(
                db,
                sql: "SELECT memory_record_id FROM entity_mentions WHERE entity_id = ?",
                arguments: [id]
            )
            let linkedIds = mentionRows.compactMap { $0["memory_record_id"] as? String }
            return EntityProfile(entity: entity, facts: facts, linkedRecordIds: linkedIds)
        }
    }

    /// Returns entities for the given IDs.
    func entities(ids: [String]) throws -> [PersonEntity] {
        guard !ids.isEmpty else { return [] }
        return try dbQueue.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM entities WHERE id IN (\(placeholders))",
                arguments: StatementArguments(ids)
            )
            return rows.map { Self.entityFromRow($0) }
        }
    }

    // MARK: - Update

    func bumpMentionCount(entityId: String, at timestamp: UInt64) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE entities
                    SET mention_count = mention_count + 1, last_mentioned_at = ?
                    WHERE id = ?
                    """,
                arguments: [timestamp, entityId]
            )
        }
    }

    func updateEntity(_ entity: PersonEntity) throws {
        let aliasesJSON = (try? JSONEncoder().encode(entity.aliases))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE entities SET
                        canonical_name = ?, aliases = ?, relation_type = ?, relation_label = ?,
                        notes = ?, last_mentioned_at = ?, mention_count = ?, strength_score = ?
                    WHERE id = ?
                    """,
                arguments: [
                    entity.canonicalName, aliasesJSON,
                    entity.relationType?.rawValue, entity.relationLabel,
                    entity.notes, entity.lastMentionedAt,
                    entity.mentionCount, Double(entity.strengthScore),
                    entity.id,
                ]
            )
        }
    }

    // MARK: - Links

    func linkRecord(entityId: String, memoryRecordId: String) throws {
        let now = UInt64(Date().timeIntervalSince1970)
        let exists = try dbQueue.read { db -> Bool in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT id FROM entity_mentions WHERE entity_id = ? AND memory_record_id = ?",
                arguments: [entityId, memoryRecordId]
            )
            return row != nil
        }
        guard !exists else { return }
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO entity_mentions (id, entity_id, memory_record_id, created_at) VALUES (?, ?, ?, ?)",
                arguments: [newEntityId(), entityId, memoryRecordId, now]
            )
        }
    }

    // MARK: - Facts

    func upsertFact(entityId: String, key: String, value: String, sourceRecordId: String?) throws {
        let now = UInt64(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            let existing = try Row.fetchOne(
                db,
                sql: "SELECT id FROM entity_facts WHERE entity_id = ? AND fact_key = ?",
                arguments: [entityId, key]
            )
            if let existingId = existing?["id"] as? String {
                try db.execute(
                    sql: "UPDATE entity_facts SET fact_value = ?, source_record_id = ?, updated_at = ? WHERE id = ?",
                    arguments: [value, sourceRecordId, now, existingId]
                )
            } else {
                try db.execute(
                    sql: """
                        INSERT INTO entity_facts
                            (id, entity_id, fact_key, fact_value, source_record_id, created_at, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [newEntityId(), entityId, key, value, sourceRecordId, now, now]
                )
            }
        }
    }

    // MARK: - Relationships

    func addRelationship(
        sourceId: String,
        targetId: String,
        relationType: String,
        confidence: Float = 0.7,
        startedAt: UInt64? = nil,
        endedAt: UInt64? = nil
    ) throws {
        let now = UInt64(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT OR IGNORE INTO entity_relationships
                        (id, source_id, target_id, relation_type, confidence,
                         started_at, ended_at, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    newEntityId(), sourceId, targetId, relationType, Double(confidence),
                    startedAt, endedAt, now, now,
                ]
            )
        }
    }

    func relationships(forEntityId entityId: String) throws -> [EntityRelationship] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM entity_relationships
                    WHERE source_id = ? OR target_id = ?
                    ORDER BY created_at DESC
                    """,
                arguments: [entityId, entityId]
            )
            return rows.map { Self.relationshipFromRow($0) }
        }
    }

    func findEntities(connectedTo targetName: String, via relationType: String) throws -> [PersonEntity] {
        // Find target entity first, then find all source entities linked to it.
        guard let target = try findEntity(byName: targetName) else { return [] }
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT e.* FROM entities e
                    INNER JOIN entity_relationships r ON r.source_id = e.id
                    WHERE r.target_id = ? AND r.relation_type = ? AND r.ended_at IS NULL
                    ORDER BY e.strength_score DESC
                    """,
                arguments: [target.id, relationType]
            )
            return rows.map { Self.entityFromRow($0) }
        }
    }

    // MARK: - Temporal Facts

    /// Upsert a fact with temporal versioning.
    /// If an active fact with the same key exists and the value differs, it is closed (ended_at = now).
    /// A new row is inserted as the current fact.
    func upsertTemporalFact(
        entityId: String,
        key: String,
        value: String,
        startedAt: UInt64? = nil,
        endedAt: UInt64? = nil,
        sourceRecordId: String?,
        confidence: Float = 0.7
    ) throws {
        let now = UInt64(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            // Find existing active fact with same key.
            let existing = try Row.fetchOne(
                db,
                sql: "SELECT * FROM entity_facts WHERE entity_id = ? AND fact_key = ? AND ended_at IS NULL",
                arguments: [entityId, key]
            )
            if let existing {
                let existingValue: String = existing["fact_value"]
                if existingValue == value {
                    // Same value — nothing to do.
                    return
                }
                // Close existing fact.
                let existingId: String = existing["id"]
                try db.execute(
                    sql: "UPDATE entity_facts SET ended_at = ?, updated_at = ? WHERE id = ?",
                    arguments: [now, now, existingId]
                )
            }
            // Insert new current fact.
            try db.execute(
                sql: """
                    INSERT INTO entity_facts
                        (id, entity_id, fact_key, fact_value, source_record_id,
                         created_at, updated_at, confidence, started_at, ended_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    newEntityId(), entityId, key, value, sourceRecordId,
                    now, now, Double(confidence), startedAt ?? now, endedAt,
                ]
            )
        }
    }

    func temporalFact(entityId: String, key: String, at timestamp: UInt64) throws -> EntityFact? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM entity_facts
                    WHERE entity_id = ? AND fact_key = ?
                      AND (started_at IS NULL OR started_at <= ?)
                      AND (ended_at IS NULL OR ended_at > ?)
                    ORDER BY started_at DESC
                    LIMIT 1
                    """,
                arguments: [entityId, key, timestamp, timestamp]
            )
            return row.map { Self.factFromRow($0) }
        }
    }

    func factHistory(entityId: String, key: String) throws -> [EntityFact] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM entity_facts
                    WHERE entity_id = ? AND fact_key = ?
                    ORDER BY started_at DESC
                    """,
                arguments: [entityId, key]
            )
            return rows.map { Self.factFromRow($0) }
        }
    }

    // MARK: - Embedding Backfill Support

    func allFactsForEmbedding() throws -> [(id: String, entityId: String, key: String, value: String)] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, entity_id, fact_key, fact_value FROM entity_facts
                    WHERE embedding IS NULL AND ended_at IS NULL
                    ORDER BY created_at ASC
                    """
            )
            return rows.map { row in
                (
                    id: row["id"] as String,
                    entityId: row["entity_id"] as String,
                    key: row["fact_key"] as String,
                    value: row["fact_value"] as String
                )
            }
        }
    }

    func updateFactEmbedding(factId: String, embedding: [Float]) throws {
        let data = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE entity_facts SET embedding = ? WHERE id = ?",
                arguments: [data, factId]
            )
        }
    }

    // MARK: - Strength Score

    /// Recompute and persist strength score: typeWeight × (0.5 × recencyDecay + 0.5 × frequencyScore).
    func recomputeStrengthScore(entityId: String) throws {
        guard let row = try dbQueue.read({ db in
            try Row.fetchOne(db, sql: "SELECT * FROM entities WHERE id = ?", arguments: [entityId])
        }) else { return }

        let entity = Self.entityFromRow(row)
        let now = Double(Date().timeIntervalSince1970)
        let lastMentioned = Double(entity.lastMentionedAt)
        let daysSinceMention = lastMentioned > 0
            ? Float((now - lastMentioned) / Double(MemoryConstants.secsPerDay))
            : Float(MemoryConstants.entityStrengthDecayHalfLifeDays)

        let typeWeight: Float = switch entity.relationType {
        case .family, .romantic: 1.0
        case .friend: 0.85
        case .colleague: 0.70
        case .acquaintance: 0.40
        case nil: 0.50
        }

        let halfLife = MemoryConstants.entityStrengthDecayHalfLifeDays
        let recencyDecay = exp(-0.693 * daysSinceMention / halfLife)
        let frequencyScore = min(Float(entity.mentionCount) / 20.0, 1.0)
        let strength = typeWeight * (0.5 * recencyDecay + 0.5 * frequencyScore)

        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE entities SET strength_score = ? WHERE id = ?",
                arguments: [Double(strength), entityId]
            )
        }
    }

    // MARK: - Stale Entities

    /// Return entities not mentioned in the last `olderThanDays` days, ordered by relation priority.
    func staleEntities(olderThanDays: Int, priorityOrder: [RelationType]) throws -> [PersonEntity] {
        let cutoff = UInt64(Date().timeIntervalSince1970) - UInt64(max(olderThanDays, 0)) * 86_400
        let rows = try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM entities
                    WHERE last_mentioned_at > 0 AND last_mentioned_at < ?
                    ORDER BY strength_score DESC
                    """,
                arguments: [cutoff]
            )
        }
        let all = rows.map { Self.entityFromRow($0) }
        return all.sorted { lhs, rhs in
            let li = lhs.relationType.flatMap { priorityOrder.firstIndex(of: $0) } ?? priorityOrder.count
            let ri = rhs.relationType.flatMap { priorityOrder.firstIndex(of: $0) } ?? priorityOrder.count
            if li != ri { return li < ri }
            return lhs.strengthScore > rhs.strengthScore
        }
    }

    // MARK: - Backfill

    func allEntitiesForBackfill() throws -> [PersonEntity] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM entities ORDER BY first_seen_at ASC")
            return rows.map { Self.entityFromRow($0) }
        }
    }

    // MARK: - Schema Meta

    func metaValue(key: String) throws -> String? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db, sql: "SELECT value FROM schema_meta WHERE key = ?", arguments: [key]
            )
            return row?["value"] as? String
        }
    }

    func setMetaValue(key: String, value: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)",
                arguments: [key, value]
            )
        }
    }

    // MARK: - Private Helpers

    private static func entityFromRow(_ row: Row) -> PersonEntity {
        let aliasesStr: String = row["aliases"] ?? "[]"
        let aliases: [String]
        if let data = aliasesStr.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data)
        {
            aliases = decoded
        } else {
            aliases = []
        }
        let entityTypeStr: String? = row["entity_type"]
        return PersonEntity(
            id: row["id"],
            canonicalName: row["canonical_name"],
            aliases: aliases,
            relationType: (row["relation_type"] as? String).flatMap { RelationType(rawValue: $0) },
            relationLabel: row["relation_label"],
            notes: row["notes"],
            firstSeenAt: UInt64(row["first_seen_at"] as Int64),
            lastMentionedAt: UInt64(row["last_mentioned_at"] as Int64),
            mentionCount: row["mention_count"] as Int,
            strengthScore: Float(row["strength_score"] as Double),
            entityType: entityTypeStr.flatMap { EntityType(rawValue: $0) } ?? .person
        )
    }

    private static func factFromRow(_ row: Row) -> EntityFact {
        var embedding: [Float]?
        if let data = row["embedding"] as? Data, !data.isEmpty {
            embedding = data.withUnsafeBytes { buf in
                guard let base = buf.baseAddress else { return nil }
                let count = data.count / MemoryLayout<Float>.size
                return Array(UnsafeBufferPointer(
                    start: base.assumingMemoryBound(to: Float.self),
                    count: count
                ))
            }
        }
        return EntityFact(
            id: row["id"],
            entityId: row["entity_id"],
            factKey: row["fact_key"],
            factValue: row["fact_value"],
            sourceRecordId: row["source_record_id"],
            createdAt: UInt64(row["created_at"] as Int64),
            updatedAt: UInt64(row["updated_at"] as Int64),
            confidence: (row["confidence"] as? Double).map { Float($0) } ?? 0.7,
            startedAt: (row["started_at"] as? Int64).map { UInt64($0) },
            endedAt: (row["ended_at"] as? Int64).map { UInt64($0) },
            embedding: embedding
        )
    }

    private static func relationshipFromRow(_ row: Row) -> EntityRelationship {
        EntityRelationship(
            id: row["id"],
            sourceId: row["source_id"],
            targetId: row["target_id"],
            relationType: row["relation_type"],
            confidence: Float(row["confidence"] as Double),
            startedAt: (row["started_at"] as? Int64).map { UInt64($0) },
            endedAt: (row["ended_at"] as? Int64).map { UInt64($0) },
            metadata: row["metadata"],
            createdAt: UInt64(row["created_at"] as Int64),
            updatedAt: UInt64(row["updated_at"] as Int64)
        )
    }
}

// MARK: - Helpers

private func newEntityId() -> String {
    let nanos = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
    return "ent-\(nanos)-\(UInt32.random(in: 0 ..< 100_000))"
}

private func levenshteinDistance(_ s: String, _ t: String) -> Int {
    let sArr = Array(s), tArr = Array(t)
    let m = sArr.count, n = tArr.count
    if m == 0 { return n }
    if n == 0 { return m }
    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
    for i in 0...m { dp[i][0] = i }
    for j in 0...n { dp[0][j] = j }
    for i in 1...m {
        for j in 1...n {
            dp[i][j] = sArr[i-1] == tArr[j-1]
                ? dp[i-1][j-1]
                : 1 + min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1])
        }
    }
    return dp[m][n]
}
