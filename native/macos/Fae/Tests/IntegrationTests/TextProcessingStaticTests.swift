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

    // MARK: - verbalizeDates

    func testVerbalizeDatesUSStyle() {
        let result = TextProcessing.verbalizeDates("Meeting on 12/25/2024")
        XCTAssertTrue(result.contains("December"))
    }

    func testVerbalizeDatesNoDates() {
        let result = TextProcessing.verbalizeDates("hello world")
        XCTAssertEqual(result, "hello world")
    }

    // MARK: - applyCommandCorrections

    func testApplyCommandCorrections() {
        let result = TextProcessing.applyCommandCorrections("run this command")
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - normalizeWakeAlias

    func testNormalizeWakeAlias() {
        // Non-alphanumeric characters become token separators so alias
        // matching works on spoken words ("Fae-Bot!" is heard as "fae bot").
        let normalized = TextProcessing.normalizeWakeAlias("Fae-Bot!")
        XCTAssertEqual(normalized, "fae bot")
    }

    func testNormalizeWakeAliasSpecialChars() {
        let normalized = TextProcessing.normalizeWakeAlias("My @Voice# Agent!")
        XCTAssertFalse(normalized.contains("@"))
        XCTAssertFalse(normalized.contains("#"))
    }

    // MARK: - isBoundary

    func testIsBoundaryStartOfText() {
        let text = "hello"
        XCTAssertTrue(TextProcessing.isBoundary(text.startIndex, in: text, before: true))
    }

    func testIsBoundaryEndOfText() {
        let text = "hello"
        XCTAssertTrue(TextProcessing.isBoundary(text.endIndex, in: text, before: false))
    }

}
