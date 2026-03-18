import CryptoKit
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
        XCTAssertEqual(result.imported, 1)
        XCTAssertEqual(result.total, 1)

        // Verify the record was created by searching the store.
        let hits = try await store.search(query: "tester launch checklist", limit: 5)
        XCTAssertFalse(hits.isEmpty)
        XCTAssertEqual(hits.first?.record.kind, .fact)
        XCTAssertTrue(hits.first?.record.tags.contains("imported") ?? false)
    }

    func testImportTextDeduplicatesExactRepeatedImport() async throws {
        let store = try makeStore()
        let service = MemoryInboxService(store: store)

        let first = try await service.importText(text: "Persistent memory should cite its sources.")
        let second = try await service.importText(text: "Persistent memory should cite its sources.")

        XCTAssertFalse(first.wasDuplicate)
        XCTAssertTrue(second.wasDuplicate)
        XCTAssertEqual(first.imported, 1)
        XCTAssertEqual(second.imported, 0)
        XCTAssertEqual(second.duplicates, 1)

        // Verify artifact sharing: only one artifact exists for the content hash,
        // confirming the second import reused (not recreated) the artifact.
        let contentHash = SHA256.hash(data: Data("Persistent memory should cite its sources.".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let artifacts = try await store.fetchArtifacts(matchingContentHash: contentHash)
        XCTAssertEqual(artifacts.count, 1, "Duplicate import must share the same artifact record")
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

        // Both imports succeed (different origins create distinct artifacts).
        XCTAssertFalse(first.wasDuplicate)
        XCTAssertFalse(second.wasDuplicate)

        // Verify distinct artifacts: compute the content hash and query the store
        // for all artifacts with that hash. Different origins must produce separate
        // artifact records even when the content is identical.
        let contentHash = SHA256.hash(data: Data("Shared content should keep both provenance labels.".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let artifacts = try await store.fetchArtifacts(matchingContentHash: contentHash)
        let origins = Set(artifacts.compactMap(\.origin))
        XCTAssertEqual(origins.count, 2, "Each distinct origin must produce its own artifact record")
    }

    func testGenerateDigestCreatesLinkedDerivedRecord() async throws {
        let store = try makeStore()
        let inbox = MemoryInboxService(store: store)
        let digestService = MemoryDigestService(store: store)

        _ = try await inbox.importText(
            title: "Tester Notes",
            text: "The tester group needs a memory inbox, provenance labels, and a digest surface."
        )
        _ = try await inbox.importText(
            title: "Roadmap",
            text: "The overnight plan focuses on memory artifacts, source links, and digest-first recall."
        )

        // Snapshot record IDs before generating the digest.
        let preDigest = try await store.recentRecords(limit: 10)
        let sourceRecordIDs = Set(preDigest.filter { $0.kind == .fact }.map(\.id))

        let digest = try await digestService.generateDigest()
        let unwrapped = try XCTUnwrap(digest)

        XCTAssertEqual(unwrapped.kind, .digest)
        XCTAssertTrue(unwrapped.text.contains("Recent memory digest"))

        // Verify bidirectional source linking: the digest record is linked back to
        // each imported source record via the digestSupport role.
        let links = try await store.sourceLinks(recordID: unwrapped.id)
        let linkedSourceIDs = Set(links.compactMap(\.sourceRecordId))
        XCTAssertEqual(linkedSourceIDs, sourceRecordIDs, "Digest must link back to all imported source records")
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

    // MARK: - Multi-Item Splitting Tests

    func testImportTextSplitsMultiLineInputIntoSeparateRecords() async throws {
        let store = try makeStore()
        let service = MemoryInboxService(store: store)

        let result = try await service.importText(
            text: """
            My birthday is March 15
            My favorite language is Rust
            I prefer coffee over tea
            """
        )

        XCTAssertEqual(result.total, 3)
        XCTAssertEqual(result.imported, 3)
        XCTAssertEqual(result.duplicates, 0)

        // Each fact should be independently searchable.
        let birthday = try await store.search(query: "birthday March", limit: 5)
        XCTAssertFalse(birthday.isEmpty)
        let language = try await store.search(query: "favorite language Rust", limit: 5)
        XCTAssertFalse(language.isEmpty)
        let coffee = try await store.search(query: "coffee over tea", limit: 5)
        XCTAssertFalse(coffee.isEmpty)
    }

    func testImportTextStripsDatePrefixesFromMigrationFormat() async throws {
        let items = MemoryInboxService.splitImportedItems("""
        [2024-03-15] - David's birthday is March 15
        [2024-06-01] - Prefers Rust for systems programming
        [March 15, 2024] - Lives in Edinburgh
        """)

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0], "David's birthday is March 15")
        XCTAssertEqual(items[1], "Prefers Rust for systems programming")
        XCTAssertEqual(items[2], "Lives in Edinburgh")
    }

    func testImportTextStripsListMarkers() async throws {
        let items = MemoryInboxService.splitImportedItems("""
        - Name is David
        * Lives in Edinburgh
        1. Prefers dark mode
        2) Uses Rust
        """)

        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items[0], "Name is David")
        XCTAssertEqual(items[1], "Lives in Edinburgh")
        XCTAssertEqual(items[2], "Prefers dark mode")
        XCTAssertEqual(items[3], "Uses Rust")
    }

    func testImportTextSkipsEmptyLines() async throws {
        let items = MemoryInboxService.splitImportedItems("""
        First fact

        Second fact


        Third fact
        """)

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0], "First fact")
        XCTAssertEqual(items[1], "Second fact")
        XCTAssertEqual(items[2], "Third fact")
    }

    func testImportTextSingleLineNotSplit() async throws {
        let store = try makeStore()
        let service = MemoryInboxService(store: store)

        let result = try await service.importText(text: "Just one memory here")

        XCTAssertEqual(result.total, 1)
        XCTAssertEqual(result.imported, 1)
    }

    func testImportTextDeduplicatesWithinMultiLinePaste() async throws {
        let store = try makeStore()
        let service = MemoryInboxService(store: store)

        let result = try await service.importText(
            text: """
            My name is David
            My name is David
            I like coffee
            """
        )

        XCTAssertEqual(result.total, 3)
        XCTAssertEqual(result.imported, 2)
        XCTAssertEqual(result.duplicates, 1)
    }
}
