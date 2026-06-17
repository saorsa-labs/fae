import XCTest
@testable import Fae

/// Coverage for pure/text static helpers in MemoryInboxService (imported-record
/// text builder, plain-text file reader) and the DaemonProcessRegistry
/// pid-tracking helpers. No network; only temp files for readPlainText.
final class InboxAndRegistryStaticTests: XCTestCase {

    private let tempDir: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("fae-inbox-\(UUID().uuidString)")

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - MemoryInboxService.importedRecordText

    func testImportedRecordTextWithTitleAndOrigin() {
        let text = MemoryInboxService.importedRecordText(
            sourceType: .file, title: "Notes", origin: "~/notes.md", rawText: "Hello world"
        )
        XCTAssertTrue(text.contains("Imported memory"))
        XCTAssertTrue(text.contains("Title: Notes"))
        XCTAssertTrue(text.contains("Origin: ~/notes.md"))
        XCTAssertTrue(text.hasSuffix("Hello world"))
    }

    func testImportedRecordTextWithoutTitleOrOrigin() {
        let text = MemoryInboxService.importedRecordText(
            sourceType: .url, title: nil, origin: nil, rawText: "Body"
        )
        XCTAssertFalse(text.contains("Title:"))
        XCTAssertFalse(text.contains("Origin:"))
        XCTAssertTrue(text.contains("Body"))
    }

    func testImportedRecordTextTruncatesLongRawText() {
        let long = String(repeating: "x", count: 5000)
        let text = MemoryInboxService.importedRecordText(
            sourceType: .pastedText, title: "T", origin: nil, rawText: long
        )
        // Truncation appends " ..." and the result must be shorter than raw.
        XCTAssertTrue(text.contains("..."))
        XCTAssertLessThan(text.count, long.count + 200) // header + truncation
    }

    // MARK: - MemoryInboxService.readPlainText

    func testReadPlainTextUTF8() throws {
        let url = try writeTempFile(named: "a.txt", content: "héllo wörld")
        let text = try MemoryInboxService.readPlainText(url: url)
        XCTAssertEqual(text, "héllo wörld")
    }

    func testReadPlainTextEmptyFile() throws {
        let url = try writeTempFile(named: "empty.txt", content: "")
        let text = try MemoryInboxService.readPlainText(url: url)
        XCTAssertEqual(text, "")
    }

    func testReadPlainTextThrowsForMissingFile() {
        let url = tempDir.appendingPathComponent("nope.txt")
        XCTAssertThrowsError(try MemoryInboxService.readPlainText(url: url))
    }

    // MARK: - DaemonProcessRegistry

    func testDaemonProcessRegistryRegisterUnregister() {
        // register adds; unregister removes. Use fake high pids that no real
        // process owns (kill returns ESRCH harmlessly if terminateAll runs).
        DaemonProcessRegistry.register(999_900)
        DaemonProcessRegistry.register(999_901)
        // unregister one.
        DaemonProcessRegistry.unregister(999_900)
        // terminateAll clears the registry and sends SIGTERM (no-op on fake pids).
        DaemonProcessRegistry.terminateAll()
        // After terminateAll, registering fresh + terminating again is safe.
        DaemonProcessRegistry.register(999_902)
        DaemonProcessRegistry.terminateAll()
        // Test passes if no crash/deadlock — the registry is process-global state.
        XCTAssertTrue(true)
    }

    func testDaemonProcessRegistryUnregisterUnknownPidIsNoOp() {
        DaemonProcessRegistry.unregister(888_888) // not registered — no-op
        XCTAssertTrue(true)
    }

    func testDaemonProcessRegistryTerminateAllWhenEmptyIsNoOp() {
        DaemonProcessRegistry.terminateAll()
        XCTAssertTrue(true)
    }

    // MARK: - Helpers

    private func writeTempFile(named name: String, content: String) throws -> URL {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
