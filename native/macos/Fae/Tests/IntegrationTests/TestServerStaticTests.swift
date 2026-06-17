import XCTest
@testable import Fae

/// Coverage for TestServer.swift (was 0% covered, 981 lines). Three pure static
/// helpers: nonce appending + digest source-count parsing.
@MainActor
final class TestServerStaticTests: XCTestCase {

    // MARK: - TestServer.appendNonce

    func testAppendNonceNilValueReturnsNil() {
        XCTAssertNil(TestServer.appendNonce(value: nil, nonce: "abc"))
    }

    func testAppendNonceEmptyValueReturnedAsIs() {
        XCTAssertEqual(TestServer.appendNonce(value: "", nonce: "abc"), "")
    }

    func testAppendNonceNilNonceReturnsValue() {
        XCTAssertEqual(TestServer.appendNonce(value: "hello", nonce: nil), "hello")
    }

    func testAppendNonceEmptyNonceReturnsValue() {
        XCTAssertEqual(TestServer.appendNonce(value: "hello", nonce: ""), "hello")
    }

    func testAppendNonceTruncatesTo8Chars() {
        let result = TestServer.appendNonce(value: "v", nonce: "abcdefghijklmnop")
        XCTAssertEqual(result, "v [abcdefgh]")
    }

    func testAppendNonceShortNonce() {
        let result = TestServer.appendNonce(value: "v", nonce: "ab")
        XCTAssertEqual(result, "v [ab]")
    }

    // MARK: - TestServer.appendNonceToText

    func testAppendNonceToTextAppends() {
        XCTAssertEqual(
            TestServer.appendNonceToText("body", nonce: "1234"),
            "body\n\nTest nonce: 1234")
    }

    func testAppendNonceToTextNilNonceReturnsOriginal() {
        XCTAssertEqual(TestServer.appendNonceToText("body", nonce: nil), "body")
    }

    func testAppendNonceToTextEmptyNonceReturnsOriginal() {
        XCTAssertEqual(TestServer.appendNonceToText("body", nonce: ""), "body")
    }

    // MARK: - TestServer.digestSourceCount

    func testDigestSourceCountParsesIDs() {
        let json = #"{"source_record_ids": ["a", "b", "c"]}"#
        XCTAssertEqual(TestServer.digestSourceCount(from: json), 3)
    }

    func testDigestSourceCountEmptyArray() {
        let json = #"{"source_record_ids": []}"#
        XCTAssertEqual(TestServer.digestSourceCount(from: json), 0)
    }

    func testDigestSourceCountNilMetadata() {
        XCTAssertEqual(TestServer.digestSourceCount(from: nil), 0)
    }

    func testDigestSourceCountMissingKey() {
        let json = #"{"other": 1}"#
        XCTAssertEqual(TestServer.digestSourceCount(from: json), 0)
    }

    func testDigestSourceCountInvalidJSON() {
        XCTAssertEqual(TestServer.digestSourceCount(from: "not json"), 0)
    }
}
