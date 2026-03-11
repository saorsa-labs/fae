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

    func testProfileCaptureHandlesImCalledForm() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try makeStore(path: dbPath)
        let orchestrator = MemoryOrchestrator(store: store, config: enabledMemoryConfig())

        _ = await orchestrator.capture(
            turnId: UUID().uuidString,
            userText: "I'm called TestUser",
            assistantText: "Got it."
        )

        let names = try await store.findActiveByTag("name")
        XCTAssertEqual(names.count, 1)
        XCTAssertTrue(names[0].text.contains("TestUser"))
    }

    func testProfileCaptureIgnoresGenericImStatusStatement() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try makeStore(path: dbPath)
        let orchestrator = MemoryOrchestrator(store: store, config: enabledMemoryConfig())

        _ = await orchestrator.capture(
            turnId: UUID().uuidString,
            userText: "I'm exhausted",
            assistantText: "Let's take a break."
        )

        let names = try await store.findActiveByTag("name")
        XCTAssertTrue(names.isEmpty)
    }

    func testHandleDirectPersonalRecallUsesStoredName() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try makeStore(path: dbPath)
        let orchestrator = MemoryOrchestrator(store: store, config: enabledMemoryConfig())

        _ = await orchestrator.capture(
            turnId: UUID().uuidString,
            userText: "my name is TestUser",
            assistantText: "Got it."
        )

        let reply = await orchestrator.handleDirectPersonalRecallIfNeeded(
            userText: "Fae, what's my name?"
        )

        XCTAssertEqual(reply, "Your name is TestUser.")
    }

    func testHandleDirectPersonalRecallUsesStoredFavoriteColor() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try makeStore(path: dbPath)
        let orchestrator = MemoryOrchestrator(store: store, config: enabledMemoryConfig())

        _ = await orchestrator.capture(
            turnId: UUID().uuidString,
            userText: "remember that my favorite color is blue",
            assistantText: "Got it."
        )

        let reply = await orchestrator.handleDirectPersonalRecallIfNeeded(
            userText: "Fae, what color do I like?"
        )

        XCTAssertEqual(reply, "Your favorite color is blue.")
    }

    func testCaptureRememberCommandHandlesWantYouToRememberPhrasing() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try makeStore(path: dbPath)
        let orchestrator = MemoryOrchestrator(store: store, config: enabledMemoryConfig())

        _ = await orchestrator.capture(
            turnId: UUID().uuidString,
            userText: "I want you to remember that my favorite color is blue",
            assistantText: "Got it."
        )

        let reply = await orchestrator.handleDirectPersonalRecallIfNeeded(
            userText: "what's my favorite color?"
        )

        XCTAssertEqual(reply, "Your favorite color is blue.")
    }

    func testHandleDirectPersonalRecallUsesImportedRecentLearning() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try makeStore(path: dbPath)
        let inboxService = MemoryInboxService(store: store)
        let digestService = MemoryDigestService(store: store)
        let orchestrator = MemoryOrchestrator(store: store, config: enabledMemoryConfig())

        _ = try await inboxService.importText(
            title: "Release tester note",
            text: "Imported note: testers need artifact provenance and digest-first recall."
        )
        _ = try await inboxService.importText(
            title: "Pending ingest note",
            text: "Imported note: verify the pending-folder ingest path before release."
        )
        _ = try await digestService.generateDigest()

        let reply = await orchestrator.handleDirectPersonalRecallIfNeeded(
            userText: "Fae, what have you learned recently?"
        )
        let unwrapped = try XCTUnwrap(reply)

        XCTAssertTrue(unwrapped.contains("imported notes"))
        XCTAssertTrue(unwrapped.contains("artifact provenance"))
        XCTAssertTrue(unwrapped.contains("pending-folder ingest"))
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

    func testRecallPrefersDigestSectionAndShowsArtifactProvenance() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try makeStore(path: dbPath)
        let inboxService = MemoryInboxService(store: store)
        let digestService = MemoryDigestService(store: store)
        let orchestrator = MemoryOrchestrator(store: store, config: enabledMemoryConfig())

        _ = try await inboxService.importText(
            title: "Memory Plan",
            text: "Build a memory inbox with provenance labels for imported artifacts."
        )
        _ = try await inboxService.importText(
            title: "Digest Plan",
            text: "Generate digest-first recall so Fae can explain what she learned recently."
        )
        _ = try await digestService.generateDigest()

        let recall = await orchestrator.recall(query: "what have you learned recently about memory inbox")
        let context = try XCTUnwrap(recall)

        XCTAssertTrue(context.contains("Memory insights:"))
        XCTAssertTrue(context.contains("Supporting memories:"))
        XCTAssertTrue(context.contains("sources: pasted text"))
    }

    func testRecallRecentSummaryQueryFallsBackToLatestDigest() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try makeStore(path: dbPath)
        let inboxService = MemoryInboxService(store: store)
        let digestService = MemoryDigestService(store: store)
        let orchestrator = MemoryOrchestrator(store: store, config: enabledMemoryConfig())

        _ = try await inboxService.importText(
            title: "Release tester note",
            text: "Memory inbox note alpha: the release candidate for testers needs provenance labels."
        )
        _ = try await inboxService.importText(
            title: "Roadmap",
            text: "Memory inbox note beta: digest-first recall should summarize imported files for testers."
        )
        _ = try await digestService.generateDigest()

        let recall = await orchestrator.recall(query: "what have you learned recently?")
        let context = try XCTUnwrap(recall)

        XCTAssertTrue(context.contains("Grounding: Use only the memory records below."))
        XCTAssertTrue(context.contains("summarize Memory insights first"))
        XCTAssertTrue(context.contains("Memory insights:"))
        XCTAssertTrue(context.contains("Supporting memories:"))
        XCTAssertTrue(context.contains("sources: pasted text"))
    }

    func testRecallFavoriteColorQueryPrefersFactOverPriorEpisode() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try makeStore(path: dbPath)
        let orchestrator = MemoryOrchestrator(store: store, config: enabledMemoryConfig())

        _ = await orchestrator.capture(
            turnId: UUID().uuidString,
            userText: "remember that my favorite color is blue",
            assistantText: "Got it."
        )
        _ = await orchestrator.capture(
            turnId: UUID().uuidString,
            userText: "what color do I like?",
            assistantText: "I don't know."
        )

        let recall = await orchestrator.recall(query: "what color do I like?")
        let context = try XCTUnwrap(recall)

        XCTAssertTrue(context.contains("my favorite color is blue"), context)
        XCTAssertFalse(context.contains("I don't know."), context)
    }

    func testRecallNameQueryPrefersStoredProfileOverPriorEpisode() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try makeStore(path: dbPath)
        let orchestrator = MemoryOrchestrator(store: store, config: enabledMemoryConfig())

        _ = await orchestrator.capture(
            turnId: UUID().uuidString,
            userText: "my name is TestUser",
            assistantText: "Nice to meet you."
        )
        _ = await orchestrator.capture(
            turnId: UUID().uuidString,
            userText: "what do you call me?",
            assistantText: "hey! i'm Fae."
        )

        let recall = await orchestrator.recall(query: "what do you call me?")
        let context = try XCTUnwrap(recall)

        XCTAssertTrue(context.contains("Primary user name is TestUser."), context)
        XCTAssertFalse(context.contains("hey! i'm Fae."), context)
    }

    func testRecallRecentSummaryStaysFocusedOnImportedMaterial() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try makeStore(path: dbPath)
        let inboxService = MemoryInboxService(store: store)
        let digestService = MemoryDigestService(store: store)
        let orchestrator = MemoryOrchestrator(store: store, config: enabledMemoryConfig())

        _ = try await inboxService.importText(
            title: "Release tester note",
            text: "Imported note: testers need artifact provenance and digest-first recall."
        )
        _ = try await inboxService.importText(
            title: "Pending ingest note",
            text: "Imported note: verify the pending-folder ingest path before release."
        )
        _ = try await digestService.generateDigest()
        _ = await orchestrator.capture(
            turnId: UUID().uuidString,
            userText: "my sister Alice works at Google",
            assistantText: "Noted."
        )

        let recall = await orchestrator.recall(query: "what have you learned recently?")
        let context = try XCTUnwrap(recall)

        XCTAssertTrue(context.contains("artifact provenance"), context)
        XCTAssertTrue(context.contains("pending-folder ingest"), context)
        XCTAssertFalse(context.contains("Alice"), context)
        XCTAssertFalse(context.contains("Google"), context)
    }

    func testRecallAddsNoGuessGuidanceForPersonalQueryWithoutActiveMatch() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try makeStore(path: dbPath)
        let orchestrator = MemoryOrchestrator(store: store, config: enabledMemoryConfig())

        _ = await orchestrator.capture(
            turnId: UUID().uuidString,
            userText: "remember that my favorite color is blue",
            assistantText: "Got it."
        )

        let activeRecords = try await store.listRecords(includeInactive: false)
        for record in activeRecords where record.text.localizedCaseInsensitiveContains("favorite color")
            || record.text.localizedCaseInsensitiveContains("blue")
        {
            try await store.forgetSoftRecord(id: record.id, note: "test forget")
        }

        let recall = await orchestrator.recall(query: "what's my favorite color?")
        let context = try XCTUnwrap(recall)

        XCTAssertTrue(context.contains("No matching stored memory found"))
        XCTAssertTrue(context.contains("Do not guess"))
        XCTAssertFalse(context.contains("blue"))
    }

    func testHandleForgetCommandParsesPleaseForgetPhrasing() async throws {
        let dbPath = "\(NSTemporaryDirectory())/memory-orchestrator-test-\(UUID().uuidString).sqlite"
        let store = try makeStore(path: dbPath)
        let orchestrator = MemoryOrchestrator(store: store, config: enabledMemoryConfig())

        _ = await orchestrator.capture(
            turnId: UUID().uuidString,
            userText: "remember that my favorite color is blue",
            assistantText: "Got it."
        )

        let response = await orchestrator.handleForgetCommandIfNeeded(
            userText: "please forget what my favorite color is"
        )
        let unwrapped = try XCTUnwrap(response)
        XCTAssertTrue(unwrapped.contains("forget"))

        let recall = await orchestrator.recall(query: "what's my favorite color?")
        let context = try XCTUnwrap(recall)
        XCTAssertTrue(context.contains("No matching stored memory found"))
        XCTAssertFalse(context.contains("blue"))
    }
}
