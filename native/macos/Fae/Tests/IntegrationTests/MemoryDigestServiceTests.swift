import XCTest
@testable import Fae

final class MemoryDigestServiceTests: XCTestCase {

    // MARK: - compactSnippet

    func testCompactSnippetShort() {
        let snippet = MemoryDigestService.compactSnippet(from: "Hello world", maxLength: 50)
        XCTAssertEqual(snippet, "Hello world")
    }

    func testCompactSnippetLong() {
        let snippet = MemoryDigestService.compactSnippet(from: String(repeating: "a", count: 100), maxLength: 20)
        XCTAssertTrue(snippet.hasSuffix("..."))
        XCTAssertEqual(snippet.count, 20)
    }

    func testCompactSnippetNewlines() {
        let snippet = MemoryDigestService.compactSnippet(from: "line1\nline2", maxLength: 50)
        XCTAssertFalse(snippet.contains("\n"))
        XCTAssertEqual(snippet, "line1 line2")
    }

    // MARK: - digestMetadataJSON

    func testDigestMetadataJSON() {
        let now = Date()
        let json = MemoryDigestService.digestMetadataJSON(sourceRecordIDs: ["abc", "def"], generatedAt: now)
        XCTAssertNotNil(json)
        XCTAssertTrue(json!.contains("abc"))
        XCTAssertTrue(json!.contains("def"))
    }

    func testDigestMetadataJSONEmpty() {
        let json = MemoryDigestService.digestMetadataJSON(sourceRecordIDs: [], generatedAt: Date())
        XCTAssertNotNil(json)
    }

    // MARK: - digestSourceRecordIDs

    func testDigestSourceRecordIDsValid() {
        let metadata = #"{"source_record_ids": ["a", "b"]}"#
        let ids = MemoryDigestService.digestSourceRecordIDs(from: metadata)
        XCTAssertEqual(ids, ["a", "b"])
    }

    func testDigestSourceRecordIDSNil() {
        let ids = MemoryDigestService.digestSourceRecordIDs(from: nil)
        XCTAssertTrue(ids.isEmpty)
    }

    func testDigestSourceRecordIDsInvalidJSON() {
        let ids = MemoryDigestService.digestSourceRecordIDs(from: "not json")
        XCTAssertTrue(ids.isEmpty)
    }

    // MARK: - digestSourceKey

    func testDigestSourceKeySorted() {
        let key = MemoryDigestService.digestSourceKey(["b", "a", "c"])
        XCTAssertEqual(key, "a|b|c")
    }

    func testDigestSourceKeyEmpty() {
        let key = MemoryDigestService.digestSourceKey([])
        XCTAssertEqual(key, "")
    }
}
