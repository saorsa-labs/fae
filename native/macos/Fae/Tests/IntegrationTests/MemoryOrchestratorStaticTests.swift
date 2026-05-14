import XCTest
@testable import Fae

final class MemoryOrchestratorStaticTests: XCTestCase {

    // MARK: - normalizeForgetQuery

    func testNormalizeForgetQueryWhat() {
        let result = MemoryOrchestrator.normalizeForgetQuery("what is my name")
        XCTAssertEqual(result, "my name")
    }

    func testNormalizeForgetQuerySuffixIs() {
        let result = MemoryOrchestrator.normalizeForgetQuery("my favorite color is")
        XCTAssertEqual(result, "my favorite color")
    }

    func testNormalizeForgetQueryAnymore() {
        let result = MemoryOrchestrator.normalizeForgetQuery("do we still do this anymore")
        XCTAssertEqual(result, "do we still do this")
    }

    func testNormalizeForgetQueryEmpty() {
        let result = MemoryOrchestrator.normalizeForgetQuery("")
        XCTAssertNil(result)
    }

    // MARK: - normalizeRememberFact

    func testNormalizeRememberFactThat() {
        let result = MemoryOrchestrator.normalizeRememberFact("that I like pizza")
        XCTAssertEqual(result, "I like pizza")
    }

    func testNormalizeRememberFactPlain() {
        let result = MemoryOrchestrator.normalizeRememberFact("my birthday is Jan 1")
        XCTAssertEqual(result, "my birthday is Jan 1")
    }

    func testNormalizeRememberFactEmpty() {
        let result = MemoryOrchestrator.normalizeRememberFact("   ")
        XCTAssertNil(result)
    }

    // MARK: - substring

    func testSubstring() {
        let original = "Hello World"
        let lower = original.lowercased()
        guard let range = lower.range(of: "world") else { return }
        let sub = MemoryOrchestrator.substring(in: original, matchingLowerRange: range)
        XCTAssertEqual(sub, "World")
    }

    // MARK: - stripWakePrefix

    func testStripWakePrefixWithComma() {
        let result = MemoryOrchestrator.stripWakePrefix("fae, what is my name")
        XCTAssertEqual(result, "what is my name")
    }

    func testStripWakePrefixNoMatch() {
        let result = MemoryOrchestrator.stripWakePrefix("hello world")
        XCTAssertEqual(result, "hello world")
    }

    // MARK: - extractStoredName

    func testExtractStoredName() {
        let name = MemoryOrchestrator.extractStoredName(from: "Primary user name is Alice")
        XCTAssertEqual(name, "Alice")
    }

    func testExtractStoredNameNoMatch() {
        let name = MemoryOrchestrator.extractStoredName(from: "random text")
        XCTAssertNil(name)
    }

    // MARK: - extractFavoriteColor

    func testExtractFavoriteColor() {
        let color = MemoryOrchestrator.extractFavoriteColor(from: "my favorite color is blue")
        XCTAssertEqual(color, "blue")
    }

    func testExtractFavoriteColorNoMatch() {
        let color = MemoryOrchestrator.extractFavoriteColor(from: "random text")
        XCTAssertNil(color)
    }

    // MARK: - shouldSkipEpisodeCapture

    func testShouldSkipEpisodeCaptureArithmetic() {
        XCTAssertTrue(MemoryOrchestrator.shouldSkipEpisodeCapture(userText: "2 + 2"))
    }

    func testShouldSkipEpisodeCaptureNormal() {
        XCTAssertFalse(MemoryOrchestrator.shouldSkipEpisodeCapture(userText: "hello world"))
    }
}
