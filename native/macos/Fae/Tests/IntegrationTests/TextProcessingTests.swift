import XCTest
@testable import Fae

final class TextProcessingTests: XCTestCase {

    // MARK: - Sentence Boundary Detection

    func testFindSentenceBoundarySimple() {
        // The boundary is the split point AFTER the terminator: the complete
        // sentence flushes to TTS, the incomplete remainder stays buffered.
        let text = "Hello world. This is a test"
        let boundary = TextProcessing.findSentenceBoundary(in: text)
        XCTAssertNotNil(boundary)
        XCTAssertEqual(String(text[boundary!...]), " This is a test")
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
        // A single uppercase initial ("J.") is an abbreviation, not a sentence
        // boundary — the text must stay buffered until a real terminator arrives.
        XCTAssertNil(TextProcessing.findSentenceBoundary(in: "J. Smith is here"))
        // A real terminator after the initial is still found.
        let text = "J. Smith is here. And more"
        let boundary = TextProcessing.findSentenceBoundary(in: text)
        XCTAssertNotNil(boundary)
        XCTAssertEqual(String(text[boundary!...]), " And more")
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
        // Leaked reasoning that narrates the user's input must never reach TTS.
        XCTAssertTrue(TextProcessing.isMetaCommentary("The user says hello and asks about the weather."))
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
        // The model describing its own interface should be suppressed.
        XCTAssertTrue(TextProcessing.isUISelfNarration("The orb is pulsing blue right now"))
    }

    func testIsUISelfNarrationNo() {
        XCTAssertFalse(TextProcessing.isUISelfNarration("The meeting is at 3pm"))
    }

    // MARK: - looksLikeNonProse

    func testLooksLikeNonProseCode() {
        // Leaked tool-call markup must be flagged so it never reaches TTS.
        XCTAssertTrue(TextProcessing.looksLikeNonProse("<tool_call>{\"name\": \"read\"}</tool_call>"))
    }

    func testLooksLikeNonProseJSON() {
        // Machine payloads (tool-ish JSON keys) are non-prose.
        XCTAssertTrue(TextProcessing.looksLikeNonProse("{\"name\": \"web_search\", \"arguments\": {\"q\": \"x\"}}"))
    }

    func testLooksLikeNonProseNormalText() {
        XCTAssertFalse(TextProcessing.looksLikeNonProse("This is normal prose text."))
    }

    // MARK: - stripSelfIntroductions

    func testStripSelfIntroduction() {
        // SOUL.md: Fae never opens with a self-introduction — refText bleed is stripped.
        let result = TextProcessing.stripSelfIntroductions("I'm Fae, your personal voice assistant. How can I help?")
        XCTAssertFalse(result.contains("I'm Fae"))
    }

    func testStripSelfIntroductionNone() {
        let text = "How can I help you today?"
        let result = TextProcessing.stripSelfIntroductions(text)
        XCTAssertEqual(result, text)
    }

    // MARK: - stripNonSpeechChars

    func testStripNonSpeechCharsMarkdown() {
        // Markdown emphasis/code markers sound terrible when spoken — stripped before TTS.
        let result = TextProcessing.stripNonSpeechChars("**Hello** `world`")
        XCTAssertFalse(result.contains("**"))
        XCTAssertFalse(result.contains("`"))
        XCTAssertTrue(result.contains("Hello"))
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
        XCTAssertTrue(TextProcessing.isLikelyContinuationCue("go on"))
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
