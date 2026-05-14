import XCTest
@testable import Fae

final class SessionStoreStaticTests: XCTestCase {

    // MARK: - unixTimestamp / dateFromTimestamp

    func testUnixTimestamp() {
        let date = Date(timeIntervalSince1970: 1609459200)
        let ts = SessionStore.unixTimestamp(date)
        XCTAssertEqual(ts, 1609459200)
    }

    func testDateFromTimestamp() {
        let date = SessionStore.dateFromTimestamp(1609459200)
        XCTAssertEqual(date.timeIntervalSince1970, 1609459200)
    }

    func testOptionalDateFromTimestampNil() {
        XCTAssertNil(SessionStore.optionalDateFromTimestamp(nil))
    }

    func testOptionalDateFromTimestampValue() {
        let date = SessionStore.optionalDateFromTimestamp(1609459200)
        XCTAssertEqual(date?.timeIntervalSince1970, 1609459200)
    }

    // MARK: - newID

    func testNewId() {
        let id = SessionStore.newID(prefix: "session")
        XCTAssertTrue(id.hasPrefix("session-"))
        XCTAssertEqual(id.count, "session-".count + 36) // UUID length
    }

    // MARK: - derivedTitle

    func testDerivedTitle() {
        let title = SessionStore.derivedTitle(from: "Hello world this is a test message")
        XCTAssertNotNil(title)
        XCTAssertEqual(title?.count, 80)
    }

    func testDerivedTitleShort() {
        let title = SessionStore.derivedTitle(from: "Hi")
        XCTAssertEqual(title, "Hi")
    }

    func testDerivedTitleEmpty() {
        XCTAssertNil(SessionStore.derivedTitle(from: "   "))
    }

    // MARK: - searchTokens

    func testSearchTokens() {
        let tokens = SessionStore.searchTokens(from: "Hello world test")
        XCTAssertFalse(tokens.isEmpty)
        XCTAssertTrue(tokens.contains("hello"))
    }

    func testSearchTokensRemovesStopwords() {
        let tokens = SessionStore.searchTokens(from: "the and a is was hello")
        XCTAssertTrue(tokens.contains("hello"))
        XCTAssertFalse(tokens.contains("the"))
    }

    // MARK: - ftsMatchQuery

    func testFtsMatchQuery() {
        let query = SessionStore.ftsMatchQuery(from: ["hello", "world"])
        XCTAssertTrue(query.contains("\"hello\""))
        XCTAssertTrue(query.contains("\"world\""))
    }

    // MARK: - matchedTokenCount

    func testMatchedTokenCount() {
        let count = SessionStore.matchedTokenCount(in: "hello world", tokens: ["hello", "foo"])
        XCTAssertEqual(count, 1)
    }

    // MARK: - normalizeSearchText

    func testNormalizeSearchText() {
        let normalized = SessionStore.normalizeSearchText("Hello  World")
        XCTAssertEqual(normalized, "hello world")
    }

    // MARK: - cleanSnippet

    func testCleanSnippet() {
        let cleaned = SessionStore.cleanSnippet("Line 1\nLine 2  with spaces")
        XCTAssertEqual(cleaned, "Line 1 Line 2 with spaces")
    }
}
