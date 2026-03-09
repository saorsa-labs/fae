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

    func testRecallHandlesQuotedAndPathLikeQueriesWithoutFTSSyntaxErrors() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try makeStore(path: dbPath)
        let orchestrator = MemoryOrchestrator(store: store, config: enabledMemoryConfig())

        _ = await orchestrator.capture(
            turnId: UUID().uuidString,
            userText: "remember the hosts file lives at /etc/hosts and the phrase 'hello fae test' matters",
            assistantText: "Noted"
        )

        let recall = await orchestrator.recall(query: "use the read tool to get /etc/hosts and write 'hello fae test'")

        let context = try XCTUnwrap(recall)
        XCTAssertTrue(context.contains("/etc/hosts"))
        XCTAssertTrue(context.contains("hello fae test"))
    }

    func testCaptureSkipsEpisodeForArithmeticQuery() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try makeStore(path: dbPath)
        let orchestrator = MemoryOrchestrator(store: store, config: enabledMemoryConfig())

        let report = await orchestrator.capture(
            turnId: UUID().uuidString,
            userText: "What is seven times eight?",
            assistantText: "Fifty-six."
        )

        XCTAssertNil(report.episodeId)
        let records = try await store.listRecords(includeInactive: true)
        XCTAssertTrue(records.isEmpty)
    }

    func testSQLiteSupersedeMarksOldRecordInactiveAndLinksNewRecord() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try SQLiteMemoryStore(path: dbPath)
        let metadata = #"{"utterance_at":"2026-03-05T12:00:00.000Z"}"#

        let old = try await store.insertRecord(
            kind: .fact,
            text: "I like coffee",
            confidence: 0.8,
            sourceTurnId: UUID().uuidString,
            tags: ["preference"],
            importanceScore: 0.85,
            staleAfterSecs: 600,
            speakerId: "owner",
            metadata: metadata
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
        XCTAssertEqual(newRecord.speakerId, "owner")
        XCTAssertEqual(newRecord.metadata, metadata)
        XCTAssertEqual(newRecord.importanceScore ?? 0, 0.85, accuracy: 0.0001)
        XCTAssertEqual(newRecord.staleAfterSecs, 600)

        let active = try await store.listRecords(includeInactive: false)
        XCTAssertTrue(active.contains(where: { $0.id == newRecord.id }))
        XCTAssertFalse(active.contains(where: { $0.id == old.id }))
    }

    func testProfileCaptureScopesNameRecordsBySpeaker() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try makeStore(path: dbPath)
        let orchestrator = MemoryOrchestrator(store: store, config: enabledMemoryConfig())

        _ = await orchestrator.capture(
            turnId: UUID().uuidString,
            userText: "my name is Alice",
            assistantText: "Noted",
            speakerId: "owner"
        )
        _ = await orchestrator.capture(
            turnId: UUID().uuidString,
            userText: "my name is Bob",
            assistantText: "Noted",
            speakerId: "guest"
        )

        let ownerNames = try await store.findActiveByTag("name", speakerId: "owner")
        let guestNames = try await store.findActiveByTag("name", speakerId: "guest")
        let allNames = try await store.findActiveByTag("name")

        XCTAssertEqual(ownerNames.count, 1)
        XCTAssertEqual(guestNames.count, 1)
        XCTAssertEqual(allNames.count, 2)
        XCTAssertTrue(ownerNames[0].text.contains("Alice"))
        XCTAssertTrue(guestNames[0].text.contains("Bob"))
    }

    func testSensitiveScreenObservationIsNotPersisted() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try makeStore(path: dbPath)
        let orchestrator = MemoryOrchestrator(store: store, config: enabledMemoryConfig())

        _ = await orchestrator.captureProactiveRecord(
            turnId: UUID().uuidString,
            taskId: "screen_activity_check",
            prompt: "[PROACTIVE SCREEN OBSERVATION]",
            responseText: "1Password was open next to a banking dashboard showing an account balance."
        )

        let records = try await store.listRecords(includeInactive: true)
        XCTAssertTrue(records.isEmpty)
    }

    func testProactiveCaptureBuildsMorningBriefingContextFromSourceMetadata() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try makeStore(path: dbPath)
        let orchestrator = MemoryOrchestrator(store: store, config: enabledMemoryConfig())

        _ = await orchestrator.captureProactiveRecord(
            turnId: UUID().uuidString,
            taskId: "overnight_work",
            prompt: "[OVERNIGHT RESEARCH CYCLE]",
            responseText: "The Rust release train added a new async diagnostics pass."
        )
        _ = await orchestrator.captureProactiveRecord(
            turnId: UUID().uuidString,
            taskId: "screen_activity_check",
            prompt: "[PROACTIVE SCREEN OBSERVATION]",
            responseText: "You were editing the permissions contract and scheduler notes."
        )

        let context = await orchestrator.recall(
            query: "morning briefing",
            proactiveTaskId: "enhanced_morning_briefing"
        )

        let unwrapped = try XCTUnwrap(context)
        XCTAssertTrue(unwrapped.contains("<proactive_memory_context"))
        XCTAssertTrue(unwrapped.contains("Rust release train"))
        XCTAssertTrue(unwrapped.contains("permissions contract"))
        XCTAssertTrue(unwrapped.contains("overnight research"))
        XCTAssertTrue(unwrapped.contains("screen context"))
    }
}
