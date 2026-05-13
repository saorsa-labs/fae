import XCTest
@testable import Fae

final class MemoryInboxTests: XCTestCase {

    // MARK: - splitImportedItems

    func testSplitImportedItemsMultiple() {
        let text = """
        ## Item 1
        First item content.

        ## Item 2
        Second item content.
        """
        let items = MemoryInboxService.splitImportedItems(text)
        XCTAssertGreaterThanOrEqual(items.count, 2)
    }

    func testSplitImportedItemsSingle() {
        let text = "Just one item"
        let items = MemoryInboxService.splitImportedItems(text)
        XCTAssertEqual(items.count, 1)
    }

    func testSplitImportedItemsEmpty() {
        let items = MemoryInboxService.splitImportedItems("")
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - normalizeImportedText

    func testNormalizeImportedTextWhitespace() {
        let normalized = MemoryInboxService.normalizeImportedText("  hello   world  ")
        XCTAssertFalse(normalized.hasPrefix(" "))
        XCTAssertFalse(normalized.hasSuffix(" "))
    }

    func testNormalizeImportedTextNewlines() {
        let normalized = MemoryInboxService.normalizeImportedText("line1\n\n\nline2")
        XCTAssertFalse(normalized.isEmpty)
    }

    // MARK: - sha256Hex

    func testSha256HexConsistent() {
        let hash1 = MemoryInboxService.sha256Hex("hello world")
        let hash2 = MemoryInboxService.sha256Hex("hello world")
        XCTAssertEqual(hash1, hash2)
    }

    func testSha256HexDifferent() {
        let hash1 = MemoryInboxService.sha256Hex("hello")
        let hash2 = MemoryInboxService.sha256Hex("world")
        XCTAssertNotEqual(hash1, hash2)
    }

    func testSha256HexLength() {
        let hash = MemoryInboxService.sha256Hex("test")
        XCTAssertEqual(hash.count, 64) // SHA-256 hex = 64 chars
    }

    // MARK: - sourceLabel

    func testSourceLabelFile() {
        let label = MemoryInboxService.sourceLabel(for: .file)
        XCTAssertFalse(label.isEmpty)
    }

    func testSourceLabelPastedText() {
        let label = MemoryInboxService.sourceLabel(for: .pastedText)
        XCTAssertFalse(label.isEmpty)
    }

    func testSourceLabelURL() {
        let label = MemoryInboxService.sourceLabel(for: .url)
        XCTAssertFalse(label.isEmpty)
    }
}
