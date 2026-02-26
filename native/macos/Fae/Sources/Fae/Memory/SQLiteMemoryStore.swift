import Foundation
import GRDB

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

        dbQueue = try DatabaseQueue(path: path)
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try Self.applySchema(db)
        }

        NSLog("SQLiteMemoryStore: opened at %@", path)
    }

    // MARK: - Schema

    private static func applySchema(_ db: Database) throws {
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
                metadata         TEXT
            )
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
        tags: [String]
    ) throws -> MemoryRecord {
        let now = UInt64(Date().timeIntervalSince1970)
        let record = MemoryRecord(
            id: newMemoryId(prefix: kind.rawValue),
            kind: kind,
            status: .active,
            text: String(text.prefix(MemoryConstants.maxRecordTextLen)),
            confidence: min(max(confidence, 0), 1),
            sourceTurnId: sourceTurnId,
            tags: tags,
            createdAt: now,
            updatedAt: now
        )

        try dbQueue.write { db in
            let tagsJSON = Self.encodeTags(tags)
            try db.execute(
                sql: """
                    INSERT INTO memory_records
                        (id, kind, status, text, confidence, source_turn_id, tags, supersedes,
                         created_at, updated_at, importance_score, stale_after_secs, metadata)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    record.id, record.kind.rawValue, record.status.rawValue,
                    record.text, Double(record.confidence), record.sourceTurnId,
                    tagsJSON, record.supersedes,
                    record.createdAt, record.updatedAt,
                    record.importanceScore.map { Double($0) },
                    record.staleAfterSecs, record.metadata,
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

    // MARK: - Search (Lexical)

    func search(query: String, limit: Int, includeInactive: Bool = false) throws -> [MemorySearchHit] {
        let records = try listRecords(includeInactive: includeInactive)
        let queryTokens = tokenizeForSearch(query)

        var hits = records.map { record in
            MemorySearchHit(record: record, score: scoreRecord(record, queryTokens: queryTokens))
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(limit))
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

    // MARK: - Private Helpers

    private static func recordFromRow(_ row: Row) -> MemoryRecord {
        let tagsStr: String = row["tags"]
        let tags = decodeTags(tagsStr)

        return MemoryRecord(
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
            metadata: row["metadata"]
        )
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
        db: Database, op: MemoryAuditOp, targetId: String?, note: String
    ) throws {
        let now = UInt64(Date().timeIntervalSince1970)
        try db.execute(
            sql: "INSERT INTO memory_audit (id, op, target_id, note, at) VALUES (?, ?, ?, ?, ?)",
            arguments: [newMemoryId(prefix: "audit"), op.rawValue, targetId, note, now]
        )
    }
}
