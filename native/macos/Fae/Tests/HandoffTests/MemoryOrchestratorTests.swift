import XCTest
@testable import Fae

final class MemoryOrchestratorTests: XCTestCase {

    private func makeStore(path: String) throws -> SQLiteMemoryStore {
        try SQLiteMemoryStore(path: path)
    }

    private func enabledMemoryConfig() -> FaeConfig.MemoryConfig {
        var config = FaeConfig.MemoryConfig()
        config.enabled = true
        config.maxRecallResults = 8
        return config
    }

    private func disabledMemoryConfig() -> FaeConfig.MemoryConfig {
        var config = FaeConfig.MemoryConfig()
        config.enabled = false
        config.maxRecallResults = 8
        return config
    }

    func testCaptureThenRecallReturnsMemoryContextContainingRememberedFact() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try makeStore(path: dbPath)

        let orchestrator = MemoryOrchestrator(store: store, config: enabledMemoryConfig())
        let fact = "the launch code is starlight"

        _ = await orchestrator.capture(
            turnId: UUID().uuidString,
            userText: "remember \(fact)",
            assistantText: "Got it."
        )

        let recall = await orchestrator.recall(query: "launch code")

        let context = try XCTUnwrap(recall)
        XCTAssertTrue(context.contains("<memory_context>"))
        XCTAssertTrue(context.contains(fact))
        XCTAssertTrue(context.contains("</memory_context>"))
    }

    func testRecallNilWhenMemoryDisabled() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try makeStore(path: dbPath)

        let orchestrator = MemoryOrchestrator(store: store, config: disabledMemoryConfig())

        _ = await orchestrator.capture(
            turnId: UUID().uuidString,
            userText: "remember I like tea",
            assistantText: "Noted"
        )

        let recall = await orchestrator.recall(query: "tea")
        XCTAssertNil(recall)
    }

    func testSQLiteSupersedeMarksOldRecordInactiveAndLinksNewRecord() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try SQLiteMemoryStore(path: dbPath)

        let old = try await store.insertRecord(
            kind: .fact,
            text: "I like coffee",
            confidence: 0.8,
            sourceTurnId: UUID().uuidString,
            tags: ["preference"]
        )

        let newRecord = try await store.supersedeRecord(
            oldId: old.id,
            newText: "I prefer tea",
            confidence: 0.9,
            sourceTurnId: UUID().uuidString,
            tags: ["preference"],
            note: "user corrected preference"
        )

        let all = try await store.listRecords(includeInactive: true)
        let oldFromAll = try XCTUnwrap(all.first(where: { $0.id == old.id }))
        XCTAssertEqual(oldFromAll.status, .superseded)
        XCTAssertEqual(newRecord.supersedes, old.id)

        let active = try await store.listRecords(includeInactive: false)
        XCTAssertTrue(active.contains(where: { $0.id == newRecord.id }))
        XCTAssertFalse(active.contains(where: { $0.id == old.id }))
    }
}
