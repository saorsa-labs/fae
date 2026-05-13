import XCTest
@testable import Fae

final class TextProcessingStaticTests: XCTestCase {

    // MARK: - normalizeForSpeechOutput

    func testNormalizeForSpeechOutputMergesTokens() {
        let normalized = TextProcessing.normalizeForSpeechOutput("ab acus")
        XCTAssertEqual(normalized, "abacus")
    }

    func testNormalizeForSpeechOutputPlain() {
        let normalized = TextProcessing.normalizeForSpeechOutput("hello world")
        XCTAssertEqual(normalized, "hello world")
    }

    // MARK: - replaceRegexMatches

    func testReplaceRegexMatches() {
        let result = TextProcessing.replaceRegexMatches(
            in: "hello 123 world 456",
            pattern: "\\d+"
        ) { _, _ in "X" }
        XCTAssertTrue(result.contains("X"))
        XCTAssertFalse(result.contains("123"))
    }

    func testReplaceRegexMatchesNoMatch() {
        let result = TextProcessing.replaceRegexMatches(
            in: "no numbers here",
            pattern: "\\d+"
        ) { _, _ in "X" }
        XCTAssertEqual(result, "no numbers here")
    }

    // MARK: - isAliasCandidate

    func testIsAliasCandidateValid() {
        XCTAssertTrue(TextProcessing.isAliasCandidate("fae"))
    }

    func testIsAliasCandidateTooLong() {
        XCTAssertFalse(TextProcessing.isAliasCandidate("falconassistant"))
    }

    func testIsAliasCandidateWrongLetter() {
        XCTAssertFalse(TextProcessing.isAliasCandidate("bae"))
    }
}
