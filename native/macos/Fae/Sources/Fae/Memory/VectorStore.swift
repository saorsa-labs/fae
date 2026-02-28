import Foundation
import GRDB
// CSQLiteVecCore is registered per-connection in SQLiteMemoryStore.
// VectorStore uses vec0 virtual tables via pure SQL through GRDB.

/// ANN vector search backed by sqlite-vec vec0 virtual tables.
/// Shares the DatabaseQueue from SQLiteMemoryStore — no second connection.
///
/// sqlite-vec is registered globally via sqlite_vec_core_init() in SQLiteMemoryStore.init.
/// After that, vec0 virtual tables work in any DatabaseQueue opened against the same file.
actor VectorStore {
    private let dbQueue: DatabaseQueue
    private(set) var embeddingDim: Int = 0

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Schema

    /// Create vec0 virtual tables if they don't exist.
    func ensureSchema(embeddingDim: Int) throws {
        guard embeddingDim > 0 else { return }
        self.embeddingDim = embeddingDim
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS memory_vec USING vec0(
                    record_id TEXT PRIMARY KEY,
                    embedding FLOAT[\(embeddingDim)]
                )
                """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS fact_vec USING vec0(
                    fact_id TEXT PRIMARY KEY,
                    embedding FLOAT[\(embeddingDim)]
                )
                """)
        }
    }

    /// Drop and recreate both vec0 tables — called when embedding model changes.
    func rebuild(embeddingDim: Int) throws {
        self.embeddingDim = embeddingDim
        try dbQueue.write { db in
            try db.execute(sql: "DROP TABLE IF EXISTS memory_vec")
            try db.execute(sql: "DROP TABLE IF EXISTS fact_vec")
            try db.execute(sql: """
                CREATE VIRTUAL TABLE memory_vec USING vec0(
                    record_id TEXT PRIMARY KEY,
                    embedding FLOAT[\(embeddingDim)]
                )
                """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE fact_vec USING vec0(
                    fact_id TEXT PRIMARY KEY,
                    embedding FLOAT[\(embeddingDim)]
                )
                """)
        }
    }

    // MARK: - Record Embeddings

    func upsertRecordEmbedding(recordId: String, embedding: [Float]) throws {
        guard embeddingDim > 0, embedding.count == embeddingDim else { return }
        let blob = floatsToBlob(embedding)
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO memory_vec(record_id, embedding) VALUES (?, ?)",
                arguments: [recordId, blob]
            )
        }
    }

    func searchRecords(queryEmbedding: [Float], limit: Int) throws -> [(id: String, distance: Float)] {
        guard embeddingDim > 0, queryEmbedding.count == embeddingDim else { return [] }
        let blob = floatsToBlob(queryEmbedding)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT record_id, distance
                    FROM memory_vec
                    WHERE embedding MATCH ?
                    ORDER BY distance
                    LIMIT ?
                    """,
                arguments: [blob, limit]
            )
            return rows.compactMap { row -> (id: String, distance: Float)? in
                guard let id = row["record_id"] as? String,
                      let dist = row["distance"] as? Double
                else { return nil }
                return (id: id, distance: Float(dist))
            }
        }
    }

    // MARK: - Fact Embeddings

    func upsertFactEmbedding(factId: String, embedding: [Float]) throws {
        guard embeddingDim > 0, embedding.count == embeddingDim else { return }
        let blob = floatsToBlob(embedding)
        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO fact_vec(fact_id, embedding) VALUES (?, ?)",
                arguments: [factId, blob]
            )
        }
    }

    func searchFacts(queryEmbedding: [Float], limit: Int) throws -> [(id: String, distance: Float)] {
        guard embeddingDim > 0, queryEmbedding.count == embeddingDim else { return [] }
        let blob = floatsToBlob(queryEmbedding)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT fact_id, distance
                    FROM fact_vec
                    WHERE embedding MATCH ?
                    ORDER BY distance
                    LIMIT ?
                    """,
                arguments: [blob, limit]
            )
            return rows.compactMap { row -> (id: String, distance: Float)? in
                guard let id = row["fact_id"] as? String,
                      let dist = row["distance"] as? Double
                else { return nil }
                return (id: id, distance: Float(dist))
            }
        }
    }

    // MARK: - Private

    private func floatsToBlob(_ floats: [Float]) -> Data {
        floats.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}
