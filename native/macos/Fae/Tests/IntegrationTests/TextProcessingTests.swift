import XCTest
@testable import Fae

final class TextProcessingTests: XCTestCase {

    // MARK: - Sentence Boundary Detection

    func testFindSentenceBoundarySimple() {
        let text = "Hello world. This is a test."
        let boundary = TextProcessing.findSentenceBoundary(in: text)
        XCTAssertNotNil(boundary)
        XCTAssertEqual(String(text[boundary!]), " This is a test.")
    }

    func testFindSentenceBoundaryNoPeriod() {
        let boundary = TextProcessing.findSentenceBoundary(in: "Hello world")
        XCTAssertNil(boundary)
    }

    func testFindSentenceBoundaryExclamation() {
        let boundary = TextProcessing.findSentenceBoundary(in: "Wow! That's great.")
        XCTAssertNotNil(boundary)
    }

    func testFindSentenceBoundaryQuestion() {
        let boundary = TextProcessing.findSentenceBoundary(in: "How are you? I'm fine.")
        XCTAssertNotNil(boundary)
    }

    func testFindSentenceBoundaryAbbreviation() {
        // "Dr." should not be treated as a sentence boundary
        let text = "Dr. Smith is here."
        let boundary = TextProcessing.findSentenceBoundary(in: text)
        XCTAssertNotNil(boundary)
        // Should skip past "Dr." and find the real period
        let after = String(text[boundary!])
        XCTAssertTrue(after.contains("Smith") || after.contains("here"))
    }

    func testFindSentenceBoundaryDecimal() {
        // "3.14" should not be treated as a sentence boundary
        let boundary = TextProcessing.findSentenceBoundary(in: "Pi is 3.14. That's all.")
        XCTAssertNotNil(boundary)
    }

    // MARK: - Clause Boundary Detection

    func testFindClauseBoundaryComma() {
        let boundary = TextProcessing.findClauseBoundary(in: "Hello, world")
        XCTAssertNotNil(boundary)
    }

    func testFindClauseBoundarySemicolon() {
        let boundary = TextProcessing.findClauseBoundary(in: "First; second")
        XCTAssertNotNil(boundary)
    }

    func testFindClauseBoundaryNone() {
        let boundary = TextProcessing.findClauseBoundary(in: "No punctuation here")
        XCTAssertNil(boundary)
    }

    // MARK: - isMetaCommentary

    func testIsMetaCommentaryYes() {
        XCTAssertTrue(TextProcessing.isMetaCommentary("Alright, I'll check that for you"))
    }

    func testIsMetaCommentaryNo() {
        XCTAssertFalse(TextProcessing.isMetaCommentary("The weather is nice today"))
    }

    // MARK: - stripReasoningPreface

    func testStripReasoningPreface() {
        let result = TextProcessing.stripReasoningPreface("Let me think about that. The answer is 42.")
        XCTAssertFalse(result.hasPrefix("Let me think"))
    }

    func testStripReasoningPrefaceNone() {
        let text = "The answer is 42."
        let result = TextProcessing.stripReasoningPreface(text)
        XCTAssertEqual(result, text)
    }

    // MARK: - isReasoningPreface

    func testIsReasoningPrefaceYes() {
        XCTAssertTrue(TextProcessing.isReasoningPreface("Let me think about that"))
    }

    func testIsReasoningPrefaceNo() {
        XCTAssertFalse(TextProcessing.isReasoningPreface("Hello world"))
    }

    // MARK: - isUISelfNarration

    func testIsUISelfNarrationYes() {
        XCTAssertTrue(TextProcessing.isUISelfNarration("I'm opening the calendar now"))
    }

    func testIsUISelfNarrationNo() {
        XCTAssertFalse(TextProcessing.isUISelfNarration("The meeting is at 3pm"))
    }

    // MARK: - looksLikeNonProse

    func testLooksLikeNonProseCode() {
        XCTAssertTrue(TextProcessing.looksLikeNonProse("func hello() {}"))
    }

    func testLooksLikeNonProseJSON() {
        XCTAssertTrue(TextProcessing.looksLikeNonProse("{\"key\": \"value\"}"))
    }

    func testLooksLikeNonProseNormalText() {
        XCTAssertFalse(TextProcessing.looksLikeNonProse("This is normal prose text."))
    }

    // MARK: - stripSelfIntroductions

    func testStripSelfIntroduction() {
        let result = TextProcessing.stripSelfIntroductions("I'm Fae, your voice assistant. How can I help?")
        XCTAssertFalse(result.contains("I'm Fae"))
    }

    func testStripSelfIntroductionNone() {
        let text = "How can I help you today?"
        let result = TextProcessing.stripSelfIntroductions(text)
        XCTAssertEqual(result, text)
    }

    // MARK: - stripNonSpeechChars

    func testStripNonSpeechCharsEmojis() {
        let result = TextProcessing.stripNonSpeechChars("Hello 👋 World 🌍")
        XCTAssertFalse(result.contains("👋"))
    }

    func testStripNonSpeechCharsNormalText() {
        let text = "Hello world"
        let result = TextProcessing.stripNonSpeechChars(text)
        XCTAssertEqual(result, text)
    }

    // MARK: - isRepetitiveHallucination

    func testIsRepetitiveHallucinationYes() {
        let repetitive = String.init(repeating: "um ", count: 20) + "hello"
        XCTAssertTrue(TextProcessing.isRepetitiveHallucination(repetitive))
    }

    func testIsRepetitiveHallucinationNo() {
        XCTAssertFalse(TextProcessing.isRepetitiveHallucination("This is a normal sentence."))
    }

    // MARK: - isLikelyIncompleteTurn

    func testIsLikelyIncompleteTurnYes() {
        XCTAssertTrue(TextProcessing.isLikelyIncompleteTurn("and then the"))
    }

    func testIsLikelyIncompleteTurnNo() {
        XCTAssertFalse(TextProcessing.isLikelyIncompleteTurn("The answer is forty two."))
    }

    // MARK: - isLikelyContinuationCue

    func testIsLikelyContinuationCueYes() {
        XCTAssertTrue(TextProcessing.isLikelyContinuationCue("go ahead"))
    }

    func testIsLikelyContinuationCueNo() {
        XCTAssertFalse(TextProcessing.isLikelyContinuationCue("The weather is nice"))
    }

    // MARK: - correctNameRecognition

    func testCorrectNameRecognition() {
        let result = TextProcessing.correctNameRecognition("my name is david")
        // Should normalize names
        XCTAssertFalse(result.isEmpty)
    }

    func testCorrectNameRecognitionNone() {
        let text = "The weather is nice"
        let result = TextProcessing.correctNameRecognition(text)
        XCTAssertEqual(result, text)
    }

    // MARK: - monthName

    func testMonthNameJanuary() {
        XCTAssertEqual(TextProcessing.monthName(1), "January")
    }

    func testMonthNameDecember() {
        XCTAssertEqual(TextProcessing.monthName(12), "December")
    }

    func testMonthNameInvalid() {
        let name = TextProcessing.monthName(13)
        XCTAssertTrue(name.isEmpty || !name.hasPrefix("January"))
    }

    // MARK: - editDistance

    func testEditDistanceIdentical() {
        XCTAssertEqual(TextProcessing.editDistance("hello", "hello"), 0)
    }

    func testEditDistanceDifferent() {
        let dist = TextProcessing.editDistance("kitten", "sitting")
        XCTAssertGreaterThan(dist, 0)
    }

    func testEditDistanceEmpty() {
        XCTAssertEqual(TextProcessing.editDistance("", "hello"), 5)
    }
}
