import Foundation
import GRDB
import SQLiteVec

/// SQLite-backed memory store using GRDB.
///
/// Replaces: `src/memory/sqlite.rs` (SqliteMemoryRepository)
actor SQLiteMemoryStore {
    private let dbQueue: DatabaseQueue

    /// Open or create the memory database at the given path.
    init(path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true
        )

        // Register sqlite-vec globally so vec0 virtual tables are available in all connections.
        try SQLiteVec.initialize()

        dbQueue = try DatabaseQueue(path: path)
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try Self.applySchema(db)
        }

        NSLog("SQLiteMemoryStore: opened at %@", path)
    }

    // MARK: - Schema

    private static func applySchema(_ db: GRDB.Database) throws {
        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS schema_meta (
                key   TEXT PRIMARY KEY,
                value TEXT NOT NULL
            )
            """)
        try db.execute(
            sql: "INSERT OR IGNORE INTO schema_meta (key, value) VALUES (?, ?)",
            arguments: ["schema_version", String(MemoryConstants.schemaVersion)]
        )

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS memory_records (
                id               TEXT PRIMARY KEY,
                kind             TEXT NOT NULL,
                status           TEXT NOT NULL DEFAULT 'active',
                text             TEXT NOT NULL,
                confidence       REAL NOT NULL DEFAULT 0.5,
                source_turn_id   TEXT,
                tags             TEXT NOT NULL DEFAULT '[]',
                supersedes       TEXT,
                created_at       INTEGER NOT NULL DEFAULT 0,
                updated_at       INTEGER NOT NULL DEFAULT 0,
                importance_score REAL,
                stale_after_secs INTEGER,
                metadata         TEXT,
                embedding        BLOB
            )
            """)

        // Migration: add embedding column if missing (v3 → v4).
        let columns = try Row.fetchAll(db, sql: "PRAGMA table_info(memory_records)")
        let columnNames = Set(columns.compactMap { $0["name"] as? String })
        if !columnNames.contains("embedding") {
            try db.execute(sql: "ALTER TABLE memory_records ADD COLUMN embedding BLOB")
        }

        // FTS5 full-text index for fast candidate selection.
        try db.execute(sql: """
            CREATE VIRTUAL TABLE IF NOT EXISTS memory_fts USING fts5(
                text, content='memory_records', content_rowid='rowid'
            )
            """)

        // Triggers to keep FTS in sync.
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS memory_fts_insert AFTER INSERT ON memory_records BEGIN
                INSERT INTO memory_fts(rowid, text) VALUES (new.rowid, new.text);
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS memory_fts_delete AFTER DELETE ON memory_records BEGIN
                INSERT INTO memory_fts(memory_fts, rowid, text) VALUES('delete', old.rowid, old.text);
            END
            """)
        try db.execute(sql: """
            CREATE TRIGGER IF NOT EXISTS memory_fts_update AFTER UPDATE OF text ON memory_records BEGIN
                INSERT INTO memory_fts(memory_fts, rowid, text) VALUES('delete', old.rowid, old.text);
                INSERT INTO memory_fts(rowid, text) VALUES (new.rowid, new.text);
            END
            """)
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_records_status ON memory_records(status)")
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_records_kind ON memory_records(kind)")
        try db.execute(
            sql: "CREATE INDEX IF NOT EXISTS idx_records_updated_at ON memory_records(updated_at)"
        )

        try db.execute(sql: """
            CREATE TABLE IF NOT EXISTS memory_audit (
                id        TEXT PRIMARY KEY,
                op        TEXT NOT NULL,
                target_id TEXT,
                note      TEXT NOT NULL,
                at        INTEGER NOT NULL DEFAULT 0
            )
            """)
        try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_audit_at ON memory_audit(at)")

        // Migration: add entity tables (v4 → v5).
        let tableNames = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            .compactMap { $0["name"] as? String }
        if !tableNames.contains("entities") {
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS entities (
                    id                TEXT PRIMARY KEY,
                    canonical_name    TEXT NOT NULL,
                    aliases           TEXT NOT NULL DEFAULT '[]',
                    relation_type     TEXT,
                    relation_label    TEXT,
                    notes             TEXT,
                    first_seen_at     INTEGER NOT NULL DEFAULT 0,
                    last_mentioned_at INTEGER NOT NULL DEFAULT 0,
                    mention_count     INTEGER NOT NULL DEFAULT 0,
                    strength_score    REAL    NOT NULL DEFAULT 0.0
                )
                """)
            try db.execute(
                sql: "CREATE INDEX IF NOT EXISTS idx_entities_canonical ON entities(canonical_name)"
            )
            try db.execute(
                sql: "CREATE INDEX IF NOT EXISTS idx_entities_last_mentioned ON entities(last_mentioned_at)"
            )

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS entity_mentions (
                    id               TEXT PRIMARY KEY,
                    entity_id        TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
                    memory_record_id TEXT NOT NULL,
                    created_at       INTEGER NOT NULL DEFAULT 0
                )
                """)
            try db.execute(
                sql: "CREATE INDEX IF NOT EXISTS idx_entity_mentions_entity ON entity_mentions(entity_id)"
            )

            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS entity_facts (
                    id               TEXT PRIMARY KEY,
                    entity_id        TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
                    fact_key         TEXT NOT NULL,
                    fact_value       TEXT NOT NULL,
                    source_record_id TEXT,
                    created_at       INTEGER NOT NULL DEFAULT 0,
                    updated_at       INTEGER NOT NULL DEFAULT 0
                )
                """)
            try db.execute(
                sql: "CREATE UNIQUE INDEX IF NOT EXISTS idx_entity_facts_unique ON entity_facts(entity_id, fact_key)"
            )

            // Update schema version.
            try db.execute(
                sql: "INSERT OR REPLACE INTO schema_meta (key, value) VALUES ('schema_version', '5')"
            )
        }

        // Migration: v5 → v6 — entity_type, temporal entity_facts, entity_relationships.
        let tableNamesV6 = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            .compactMap { $0["name"] as? String }
        if !tableNamesV6.contains("entity_relationships") {
            // Add entity_type to entities (organisation | location | person | skill | project | concept).
            let entityColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(entities)")
                .compactMap { $0["name"] as? String }
            if !entityColumns.contains("entity_type") {
                try db.execute(
                    sql: "ALTER TABLE entities ADD COLUMN entity_type TEXT NOT NULL DEFAULT 'person'"
                )
            }

            // Add temporal and confidence columns to entity_facts.
            let factColumns = try Row.fetchAll(db, sql: "PRAGMA table_info(entity_facts)")
                .compactMap { $0["name"] as? String }
            if !factColumns.contains("confidence") {
                try db.execute(sql: "ALTER TABLE entity_facts ADD COLUMN confidence REAL NOT NULL DEFAULT 0.7")
            }
            if !factColumns.contains("started_at") {
                try db.execute(sql: "ALTER TABLE entity_facts ADD COLUMN started_at INTEGER")
            }
            if !factColumns.contains("ended_at") {
                try db.execute(sql: "ALTER TABLE entity_facts ADD COLUMN ended_at INTEGER")
            }
            if !factColumns.contains("embedding") {
                try db.execute(sql: "ALTER TABLE entity_facts ADD COLUMN embedding BLOB")
            }

            // Remove the unique constraint on (entity_id, fact_key) so temporal history is allowed.
            // SQLite doesn't support DROP INDEX while keeping the rest, so we rely on INSERT OR IGNORE
            // not being used in the temporal path. The unique index remains for non-temporal upsert.

            // Create entity_relationships table.
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS entity_relationships (
                    id             TEXT PRIMARY KEY,
                    source_id      TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
                    target_id      TEXT NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
                    relation_type  TEXT NOT NULL,
                    confidence     REAL NOT NULL DEFAULT 0.7,
                    started_at     INTEGER,
                    ended_at       INTEGER,
                    metadata       TEXT,
                    created_at     INTEGER NOT NULL DEFAULT 0,
                    updated_at     INTEGER NOT NULL DEFAULT 0,
                    UNIQUE(source_id, target_id, relation_type)
                )
                """)
            try db.execute(
                sql: "CREATE INDEX IF NOT EXISTS idx_relationships_source ON entity_relationships(source_id)"
            )
            try db.execute(
                sql: "CREATE INDEX IF NOT EXISTS idx_relationships_target ON entity_relationships(target_id)"
            )
            try db.execute(
                sql: "CREATE INDEX IF NOT EXISTS idx_relationships_type ON entity_relationships(relation_type)"
            )

            // schema_meta entries for embedding model tracking.
            try db.execute(
                sql: "INSERT OR IGNORE INTO schema_meta (key, value) VALUES ('embedding_model_id', '')"
            )
            try db.execute(
                sql: "INSERT OR IGNORE INTO schema_meta (key, value) VALUES ('embedding_model_dim', '0')"
            )

            // Update schema version.
            try db.execute(
                sql: "INSERT OR REPLACE INTO schema_meta (key, value) VALUES ('schema_version', '6')"
            )
        }

        // Migration: v6 → v7 — speaker_id on memory_records.
        let recordColumnsV7 = try Row.fetchAll(db, sql: "PRAGMA table_info(memory_records)")
            .compactMap { $0["name"] as? String }
        if !recordColumnsV7.contains("speaker_id") {
            try db.execute(sql: "ALTER TABLE memory_records ADD COLUMN speaker_id TEXT")
            try db.execute(
                sql: "CREATE INDEX IF NOT EXISTS idx_records_speaker ON memory_records(speaker_id)"
            )
            try db.execute(
                sql: "INSERT OR REPLACE INTO schema_meta (key, value) VALUES ('schema_version', '7')"
            )
        }

        // vec0 virtual tables are created lazily by VectorStore after embedding dimension is known.
    }

    // MARK: - Integrity

    func integrityCheck() throws {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "PRAGMA quick_check")
            for row in rows {
                let result: String = row[0]
                if result != "ok" {
                    NSLog("SQLiteMemoryStore: integrity issue: %@", result)
                }
            }
        }
    }

    // MARK: - Insert

    func insertRecord(
        kind: MemoryKind,
        text: String,
        confidence: Float,
        sourceTurnId: String?,
        tags: [String],
        importanceScore: Float? = nil,
        staleAfterSecs: UInt64? = nil,
        embedding: [Float]? = nil,
        speakerId: String? = nil
    ) throws -> MemoryRecord {
        let now = UInt64(Date().timeIntervalSince1970)
        var record = MemoryRecord(
            id: newMemoryId(prefix: kind.rawValue),
            kind: kind,
            status: .active,
            text: String(text.prefix(MemoryConstants.maxRecordTextLen)),
            confidence: min(max(confidence, 0), 1),
            sourceTurnId: sourceTurnId,
            tags: tags,
            createdAt: now,
            updatedAt: now,
            importanceScore: importanceScore,
            staleAfterSecs: staleAfterSecs
        )
        record.speakerId = speakerId

        let embeddingData: Data? = embedding.map { floats in
            floats.withUnsafeBufferPointer { Data(buffer: $0) }
        }

        try dbQueue.write { db in
            let tagsJSON = Self.encodeTags(tags)
            try db.execute(
                sql: """
                    INSERT INTO memory_records
                        (id, kind, status, text, confidence, source_turn_id, tags, supersedes,
                         created_at, updated_at, importance_score, stale_after_secs, metadata,
                         embedding, speaker_id)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    record.id, record.kind.rawValue, record.status.rawValue,
                    record.text, Double(record.confidence), record.sourceTurnId,
                    tagsJSON, record.supersedes,
                    record.createdAt, record.updatedAt,
                    record.importanceScore.map { Double($0) },
                    record.staleAfterSecs, record.metadata,
                    embeddingData, record.speakerId,
                ]
            )

            // Audit
            try Self.insertAudit(
                db: db, op: .insert, targetId: record.id, note: "inserted \(kind.rawValue)"
            )
        }

        return record
    }

    // MARK: - Supersede

    func supersedeRecord(
        oldId: String,
        newText: String,
        confidence: Float,
        sourceTurnId: String?,
        tags: [String],
        note: String
    ) throws -> MemoryRecord {
        let now = UInt64(Date().timeIntervalSince1970)
        var newRecord = MemoryRecord(
            id: "",
            kind: .fact,
            text: newText,
            confidence: confidence,
            sourceTurnId: sourceTurnId,
            tags: tags,
            supersedes: oldId,
            createdAt: now,
            updatedAt: now
        )

        try dbQueue.write { db in
            // Get old record's kind
            if let row = try Row.fetchOne(db, sql: "SELECT kind FROM memory_records WHERE id = ?", arguments: [oldId]) {
                let kindStr: String = row["kind"]
                newRecord.kind = MemoryKind(rawValue: kindStr) ?? .fact
            }
            newRecord.id = newMemoryId(prefix: newRecord.kind.rawValue)

            // Mark old as superseded
            try db.execute(
                sql: "UPDATE memory_records SET status = 'superseded', updated_at = ? WHERE id = ?",
                arguments: [now, oldId]
            )

            // Insert new
            let tagsJSON = Self.encodeTags(tags)
            try db.execute(
                sql: """
                    INSERT INTO memory_records
                        (id, kind, status, text, confidence, source_turn_id, tags, supersedes,
                         created_at, updated_at, importance_score, stale_after_secs, metadata)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    newRecord.id, newRecord.kind.rawValue, newRecord.status.rawValue,
                    newRecord.text, Double(newRecord.confidence), newRecord.sourceTurnId,
                    tagsJSON, newRecord.supersedes,
                    newRecord.createdAt, newRecord.updatedAt,
                    nil as Double?, nil as UInt64?, nil as String?,
                ]
            )

            try Self.insertAudit(db: db, op: .supersede, targetId: oldId, note: note)
        }

        return newRecord
    }

    // MARK: - Patch

    func patchRecord(id: String, newText: String, note: String) throws {
        let now = UInt64(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE memory_records SET text = ?, updated_at = ? WHERE id = ?",
                arguments: [newText, now, id]
            )
            try Self.insertAudit(db: db, op: .patch, targetId: id, note: note)
        }
    }

    // MARK: - Forget

    func forgetSoftRecord(id: String, note: String) throws {
        let now = UInt64(Date().timeIntervalSince1970)
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE memory_records SET status = 'forgotten', updated_at = ? WHERE id = ?",
                arguments: [now, id]
            )
            try Self.insertAudit(db: db, op: .forgetSoft, targetId: id, note: note)
        }
    }

    // MARK: - Search (FTS5 + Lexical Scoring)

    func search(query: String, limit: Int, includeInactive: Bool = false) throws -> [MemorySearchHit] {
        let queryTokens = tokenizeForSearch(query)

        // Try FTS5 candidate selection first for efficiency.
        let candidates: [MemoryRecord]
        if !queryTokens.isEmpty {
            candidates = try ftsSearch(query: query, limit: max(limit * 5, 50), includeInactive: includeInactive)
        } else {
            candidates = []
        }

        // Fall back to full scan if FTS returned too few results or query is empty.
        let records: [MemoryRecord]
        if candidates.count < limit {
            records = try listRecords(includeInactive: includeInactive)
        } else {
            records = candidates
        }

        var hits = records.map { record in
            MemorySearchHit(record: record, score: scoreRecord(record, queryTokens: queryTokens))
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(limit))
    }

    /// FTS5-based candidate selection — returns records matching the query text.
    private func ftsSearch(query: String, limit: Int, includeInactive: Bool) throws -> [MemoryRecord] {
        try dbQueue.read { db in
            // Escape FTS5 special characters and form a simple query.
            let ftsQuery = tokenizeForSearch(query).joined(separator: " OR ")
            guard !ftsQuery.isEmpty else { return [] }

            let statusFilter = includeInactive ? "" : "AND r.status = 'active'"
            let sql = """
                SELECT r.* FROM memory_records r
                INNER JOIN memory_fts f ON f.rowid = r.rowid
                WHERE memory_fts MATCH ?
                \(statusFilter)
                ORDER BY rank
                LIMIT ?
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [ftsQuery, limit])
            return rows.map { Self.recordFromRow($0) }
        }
    }

    // MARK: - List

    func listRecords(includeInactive: Bool = false) throws -> [MemoryRecord] {
        try dbQueue.read { db in
            let sql: String
            if includeInactive {
                sql = "SELECT * FROM memory_records ORDER BY updated_at DESC"
            } else {
                sql = "SELECT * FROM memory_records WHERE status = 'active' ORDER BY updated_at DESC"
            }
            let rows = try Row.fetchAll(db, sql: sql)
            return rows.map { Self.recordFromRow($0) }
        }
    }

    /// Find active records with a specific tag.
    func findActiveByTag(_ tag: String) throws -> [MemoryRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM memory_records
                    WHERE status = 'active' AND tags LIKE ?
                    ORDER BY updated_at DESC
                    """,
                arguments: ["%\"\(tag)\"%"]
            )
            return rows.map { Self.recordFromRow($0) }
        }
    }

    /// Find active records of a specific kind.
    func findActiveByKind(_ kind: MemoryKind, limit: Int = 20) throws -> [MemoryRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM memory_records
                    WHERE status = 'active' AND kind = ?
                    ORDER BY updated_at DESC
                    LIMIT ?
                    """,
                arguments: [kind.rawValue, limit]
            )
            return rows.map { Self.recordFromRow($0) }
        }
    }

    /// Fetch the most recent active records, ordered by updated_at descending.
    func recentRecords(limit: Int) throws -> [MemoryRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM memory_records
                    WHERE status = 'active'
                    ORDER BY updated_at DESC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
            return rows.map { Self.recordFromRow($0) }
        }
    }

    // MARK: - Retention

    func applyRetentionPolicy(retentionDays: UInt64) throws -> Int {
        guard retentionDays > 0 else { return 0 }
        let cutoff = UInt64(Date().timeIntervalSince1970) - (retentionDays * 86_400)

        return try dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE memory_records SET status = 'forgotten'
                    WHERE kind = 'episode' AND status = 'active' AND updated_at < ?
                    """,
                arguments: [cutoff]
            )
            return db.changesCount
        }
    }

    // MARK: - Record Count

    func recordCount() throws -> Int {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM memory_records WHERE status = 'active'"
            )
            return row?[0] as? Int ?? 0
        }
    }

    // MARK: - Database Path

    var databasePath: String {
        dbQueue.path
    }

    // MARK: - Shared Database Queue (for EntityStore)

    /// Exposes the underlying DatabaseQueue so EntityStore can share the same connection.
    var sharedDatabaseQueue: DatabaseQueue {
        dbQueue
    }

    // MARK: - Person Records (for backfill)

    /// Fetch all active person records for entity backfill migration.
    func findPersonRecords(limit: Int = 1000) throws -> [MemoryRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM memory_records
                    WHERE status = 'active' AND kind = 'person'
                    ORDER BY created_at ASC
                    LIMIT ?
                    """,
                arguments: [limit]
            )
            return rows.map { Self.recordFromRow($0) }
        }
    }

    // MARK: - Paged Active Records (for embedding backfill)

    /// Fetch a page of active records ordered by created_at ascending.
    func allActiveRecords(pageSize: Int, offset: Int) throws -> [MemoryRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM memory_records
                    WHERE status = 'active'
                    ORDER BY created_at ASC
                    LIMIT ? OFFSET ?
                    """,
                arguments: [pageSize, offset]
            )
            return rows.map { Self.recordFromRow($0) }
        }
    }

    // MARK: - Speaker Query

    /// Find active records associated with a specific speaker.
    func findBySpeaker(id: String, limit: Int = 50) throws -> [MemoryRecord] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM memory_records
                    WHERE status = 'active' AND speaker_id = ?
                    ORDER BY updated_at DESC
                    LIMIT ?
                    """,
                arguments: [id, limit]
            )
            return rows.map { Self.recordFromRow($0) }
        }
    }

    // MARK: - Schema Meta

    /// Read a value from the schema_meta key-value table.
    func readSchemaMeta(_ key: String) throws -> String? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT value FROM schema_meta WHERE key = ?",
                arguments: [key]
            )
            return row?["value"] as? String
        }
    }

    /// Write a value to the schema_meta key-value table.
    func writeSchemaMeta(_ key: String, value: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO schema_meta (key, value) VALUES (?, ?)",
                arguments: [key, value]
            )
        }
    }

    // MARK: - Private Helpers

    private static func recordFromRow(_ row: Row) -> MemoryRecord {
        let tagsStr: String = row["tags"]
        let tags = decodeTags(tagsStr)

        var cachedEmbedding: [Float]?
        if let data = row["embedding"] as? Data, !data.isEmpty {
            cachedEmbedding = data.withUnsafeBytes { buffer in
                guard let baseAddress = buffer.baseAddress else { return nil }
                let count = data.count / MemoryLayout<Float>.size
                let floatBuffer = baseAddress.assumingMemoryBound(to: Float.self)
                return Array(UnsafeBufferPointer(start: floatBuffer, count: count))
            }
        }

        var record = MemoryRecord(
            id: row["id"],
            kind: MemoryKind(rawValue: row["kind"] as String) ?? .fact,
            status: MemoryStatus(rawValue: row["status"] as String) ?? .active,
            text: row["text"],
            confidence: Float(row["confidence"] as Double),
            sourceTurnId: row["source_turn_id"],
            tags: tags,
            supersedes: row["supersedes"],
            createdAt: UInt64(row["created_at"] as Int64),
            updatedAt: UInt64(row["updated_at"] as Int64),
            importanceScore: (row["importance_score"] as Double?).map { Float($0) },
            staleAfterSecs: (row["stale_after_secs"] as Int64?).map { UInt64($0) },
            metadata: row["metadata"],
            cachedEmbedding: cachedEmbedding
        )
        record.speakerId = row["speaker_id"]
        return record
    }

    private static func encodeTags(_ tags: [String]) -> String {
        guard let data = try? JSONEncoder().encode(tags),
              let str = String(data: data, encoding: .utf8)
        else { return "[]" }
        return str
    }

    private static func decodeTags(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let tags = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return tags
    }

    private static func insertAudit(
        db: GRDB.Database, op: MemoryAuditOp, targetId: String?, note: String
    ) throws {
        let now = UInt64(Date().timeIntervalSince1970)
        try db.execute(
            sql: "INSERT INTO memory_audit (id, op, target_id, note, at) VALUES (?, ?, ?, ?, ?)",
            arguments: [newMemoryId(prefix: "audit"), op.rawValue, targetId, note, now]
        )
    }
}
