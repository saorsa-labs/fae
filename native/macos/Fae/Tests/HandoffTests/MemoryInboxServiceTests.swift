import XCTest
@testable import Fae

final class MemoryInboxServiceTests: XCTestCase {
    private func makeStore() throws -> SQLiteMemoryStore {
        let dbPath = "\(NSTemporaryDirectory())/memory-inbox-test-\(UUID().uuidString).sqlite"
        return try SQLiteMemoryStore(path: dbPath)
    }

    func testImportTextCreatesArtifactAndLinkedRecord() async throws {
        let store = try makeStore()
        let service = MemoryInboxService(store: store)

        let result = try await service.importText(
            title: "Release Notes",
            text: "Fae should remember the tester launch checklist and onboarding notes."
        )

        XCTAssertFalse(result.wasDuplicate)
        XCTAssertEqual(result.artifact.sourceType, .pastedText)
        XCTAssertEqual(result.record.kind, .fact)
        XCTAssertTrue(result.record.tags.contains("imported"))

        let artifact = try await store.fetchArtifact(id: result.artifact.id)
        XCTAssertEqual(artifact?.title, "Release Notes")

        let links = try await store.sourceLinks(recordID: result.record.id)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links.first?.artifactId, result.artifact.id)
        XCTAssertEqual(links.first?.role, .artifact)
    }

    func testImportTextDeduplicatesExactRepeatedImport() async throws {
        let store = try makeStore()
        let service = MemoryInboxService(store: store)

        let first = try await service.importText(text: "Persistent memory should cite its sources.")
        let second = try await service.importText(text: "Persistent memory should cite its sources.")

        XCTAssertFalse(first.wasDuplicate)
        XCTAssertTrue(second.wasDuplicate)
        XCTAssertEqual(first.artifact.id, second.artifact.id)
        XCTAssertEqual(first.record.id, second.record.id)
    }

    func testImportTextPreservesDistinctArtifactSourcesForSharedContent() async throws {
        let store = try makeStore()
        let service = MemoryInboxService(store: store)

        let first = try await service.importText(
            title: "Inbox A",
            text: "Shared content should keep both provenance labels.",
            origin: "https://example.com/a",
            sourceType: .url
        )
        let second = try await service.importText(
            title: "Inbox B",
            text: "Shared content should keep both provenance labels.",
            origin: "/tmp/shared.txt",
            sourceType: .file
        )

        XCTAssertFalse(first.wasDuplicate)
        XCTAssertFalse(second.wasDuplicate)
        XCTAssertNotEqual(first.artifact.id, second.artifact.id)
        XCTAssertEqual(first.record.id, second.record.id)

        let links = try await store.sourceLinks(recordID: first.record.id)
        let artifactIDs = Set(links.compactMap(\.artifactId))
        XCTAssertEqual(artifactIDs, Set([first.artifact.id, second.artifact.id]))
    }

    func testGenerateDigestCreatesLinkedDerivedRecord() async throws {
        let store = try makeStore()
        let inbox = MemoryInboxService(store: store)
        let digestService = MemoryDigestService(store: store)

        let first = try await inbox.importText(
            title: "Tester Notes",
            text: "The tester group needs a memory inbox, provenance labels, and a digest surface."
        )
        let second = try await inbox.importText(
            title: "Roadmap",
            text: "The overnight plan focuses on memory artifacts, source links, and digest-first recall."
        )

        let digest = try await digestService.generateDigest()
        let unwrapped = try XCTUnwrap(digest)

        XCTAssertEqual(unwrapped.kind, .digest)
        XCTAssertTrue(unwrapped.text.contains("Recent memory digest"))

        let links = try await store.sourceLinks(recordID: unwrapped.id)
        let linkedSourceIDs = Set(links.compactMap(\.sourceRecordId))
        XCTAssertEqual(linkedSourceIDs, Set([first.record.id, second.record.id]))
        XCTAssertTrue(links.allSatisfy { $0.role == .digestSupport })
    }

    func testGenerateDigestSkipsRepeatedSourceSetAcrossLaterRuns() async throws {
        let store = try makeStore()
        let inbox = MemoryInboxService(store: store)
        let digestService = MemoryDigestService(store: store)

        _ = try await inbox.importText(
            title: "Tester Notes",
            text: "The tester group needs provenance-aware imports."
        )
        _ = try await inbox.importText(
            title: "Roadmap",
            text: "Digest generation should not repeat unchanged source sets."
        )

        let now = Date()
        let first = try await digestService.generateDigest(now: now)
        let second = try await digestService.generateDigest(now: now.addingTimeInterval(12 * 3600))

        XCTAssertNotNil(first)
        XCTAssertNil(second)
    }
}
