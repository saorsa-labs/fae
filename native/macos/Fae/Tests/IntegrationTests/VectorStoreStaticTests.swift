import XCTest
import GRDB
import CSQLiteVecCore
@testable import Fae

/// Coverage for VectorStore.swift (was 0% covered). The actor wraps sqlite-vec
/// virtual tables; we register the extension on an in-memory GRDB DatabaseQueue
/// (mirroring SQLiteMemoryStore.init's prepareDatabase hook) so the full
/// ensureSchema → upsert → search cycle runs without a temp file.
final class VectorStoreStaticTests: XCTestCase {

    private func makeStore(dim: Int) async throws -> VectorStore {
        var config = Configuration()
        config.prepareDatabase { db in
            let rawDB = db.sqliteConnection
            let rc = sqlite_vec_register(rawDB)
            guard rc == 0 else {
                throw NSError(domain: "VecTest", code: Int(rc), userInfo: [
                    NSLocalizedDescriptionKey: "sqlite-vec register failed: \(rc)",
                ])
            }
        }
        let dbQueue = try DatabaseQueue(configuration: config)
        let store = VectorStore(dbQueue: dbQueue)
        try await store.ensureSchema(embeddingDim: dim)
        return store
    }

    func testEnsureSchemaIgnoresZeroDim() async throws {
        var config = Configuration()
        config.prepareDatabase { db in
            _ = sqlite_vec_register(db.sqliteConnection)
        }
        let dbQueue = try DatabaseQueue(configuration: config)
        let store = VectorStore(dbQueue: dbQueue)
        try await store.ensureSchema(embeddingDim: 0) // guarded no-op
        XCTAssertTrue(true) // didn't throw
    }

    func testUpsertAndSearchRecordsFindsNearest() async throws {
        let store = try await makeStore(dim: 3)
        try await store.upsertRecordEmbedding(recordId: "r1", embedding: [1.0, 0.0, 0.0])
        try await store.upsertRecordEmbedding(recordId: "r2", embedding: [0.0, 1.0, 0.0])
        try await store.upsertRecordEmbedding(recordId: "r3", embedding: [0.9, 0.1, 0.0])

        let results = try await store.searchRecords(queryEmbedding: [1.0, 0.0, 0.0], limit: 2)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.id, "r1")
    }

    func testUpsertRecordReplacesExisting() async throws {
        let store = try await makeStore(dim: 2)
        try await store.upsertRecordEmbedding(recordId: "x", embedding: [1.0, 0.0])
        try await store.upsertRecordEmbedding(recordId: "x", embedding: [0.0, 1.0]) // replace
        let results = try await store.searchRecords(queryEmbedding: [0.0, 1.0], limit: 5)
        XCTAssertEqual(results.filter { $0.id == "x" }.count, 1)
    }

    func testUpsertRejectsWrongDim() async throws {
        let store = try await makeStore(dim: 3)
        try await store.upsertRecordEmbedding(recordId: "bad", embedding: [1.0, 0.0]) // wrong dim, no-op
        let results = try await store.searchRecords(queryEmbedding: [1.0, 0.0, 0.0], limit: 5)
        XCTAssertFalse(results.contains { $0.id == "bad" })
    }

    func testSearchRecordsEmptyStore() async throws {
        let store = try await makeStore(dim: 2)
        let results = try await store.searchRecords(queryEmbedding: [1.0, 0.0], limit: 5)
        XCTAssertEqual(results.count, 0)
    }

    func testUpsertAndSearchFacts() async throws {
        let store = try await makeStore(dim: 2)
        try await store.upsertFactEmbedding(factId: "f1", embedding: [1.0, 0.0])
        try await store.upsertFactEmbedding(factId: "f2", embedding: [0.0, 1.0])
        let results = try await store.searchFacts(queryEmbedding: [0.0, 1.0], limit: 1)
        XCTAssertEqual(results.first?.id, "f2")
    }

    func testSearchFactsWrongDimReturnsEmpty() async throws {
        let store = try await makeStore(dim: 3)
        try await store.upsertFactEmbedding(factId: "f", embedding: [1, 0, 0])
        let results = try await store.searchFacts(queryEmbedding: [1.0, 0.0], limit: 5) // wrong dim
        XCTAssertEqual(results.count, 0)
    }
}
