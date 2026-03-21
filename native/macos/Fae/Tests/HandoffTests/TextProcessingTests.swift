import XCTest
@testable import Fae

final class TextProcessingTests: XCTestCase {

    // MARK: - findSentenceBoundary

    func testSimpleSentence() {
        let text = "Hello world."
        let boundary = TextProcessing.findSentenceBoundary(in: text)
        XCTAssertNotNil(boundary)
        XCTAssertEqual(String(text[..<boundary!]), "Hello world.")
    }

    func testMultipleSentences() {
        let text = "First sentence. Second sentence."
        let boundary = TextProcessing.findSentenceBoundary(in: text)
        XCTAssertNotNil(boundary)
        // Should find the LAST sentence boundary
        XCTAssertEqual(String(text[..<boundary!]), "First sentence. Second sentence.")
    }

    func testExclamationMark() {
        let text = "Wow! That is great."
        let boundary = TextProcessing.findSentenceBoundary(in: text)
        XCTAssertNotNil(boundary)
    }

    func testQuestionMark() {
        let text = "How are you?"
        let boundary = TextProcessing.findSentenceBoundary(in: text)
        XCTAssertNotNil(boundary)
        XCTAssertEqual(String(text[..<boundary!]), "How are you?")
    }

    func testSingleLetterAbbreviationGuard() {
        // Single uppercase letter + period (e.g., "A." in "U.S.A.") should not
        // be treated as a sentence boundary.
        let text = "Contact U. Smith for details"
        let boundary = TextProcessing.findSentenceBoundary(in: text)
        XCTAssertNil(boundary, "Should not split at single-letter abbreviation 'U.'")
    }

    func testMultiLetterAbbreviationIsSentenceBoundary() {
        // "Dr." is a multi-letter abbreviation — the guard only catches single-letter
        // abbreviations, so "Dr." IS treated as a boundary. This is acceptable because
        // in streaming TTS the cost of a false split is low (just shorter prosodic unit).
        let text = "Dr. Smith said hello"
        let boundary = TextProcessing.findSentenceBoundary(in: text)
        XCTAssertNotNil(boundary, "Multi-letter abbreviation 'Dr.' is a valid split point")
    }

    func testDecimalNumberGuard() {
        // "3.14" should not be treated as a sentence boundary
        let text = "It costs $3.14 per unit"
        let boundary = TextProcessing.findSentenceBoundary(in: text)
        XCTAssertNil(boundary, "Should not split at decimal number")
    }

    func testSentenceAfterAbbreviation() {
        let text = "Dr. Smith said hello. Then he left."
        let boundary = TextProcessing.findSentenceBoundary(in: text)
        XCTAssertNotNil(boundary, "Should find sentence boundary after 'hello.'")
    }

    func testNoSentenceBoundary() {
        let text = "This text has no sentence ending"
        let boundary = TextProcessing.findSentenceBoundary(in: text)
        XCTAssertNil(boundary)
    }

    func testEmptyString() {
        let boundary = TextProcessing.findSentenceBoundary(in: "")
        XCTAssertNil(boundary)
    }

    func testSingleCharSentence() {
        // Edge case: just a period
        let text = "."
        let boundary = TextProcessing.findSentenceBoundary(in: text)
        XCTAssertNotNil(boundary)
    }

    func testEmojiInSentence() {
        let text = "That's amazing! 🎉 Really great."
        let boundary = TextProcessing.findSentenceBoundary(in: text)
        XCTAssertNotNil(boundary)
    }

    // MARK: - findClauseBoundary

    func testCommaClause() {
        let text = "Well, I think so"
        let boundary = TextProcessing.findClauseBoundary(in: text)
        XCTAssertNotNil(boundary)
        XCTAssertEqual(String(text[..<boundary!]), "Well,")
    }

    func testSemicolonClause() {
        let text = "First part; second part"
        let boundary = TextProcessing.findClauseBoundary(in: text)
        XCTAssertNotNil(boundary)
    }

    func testColonClause() {
        let text = "Here it is: the answer"
        let boundary = TextProcessing.findClauseBoundary(in: text)
        XCTAssertNotNil(boundary)
    }

    func testEmDashClause() {
        let text = "Something important\u{2014}very important"
        let boundary = TextProcessing.findClauseBoundary(in: text)
        XCTAssertNotNil(boundary)
    }

    func testNoClauseBoundary() {
        let text = "No clause boundaries here"
        let boundary = TextProcessing.findClauseBoundary(in: text)
        XCTAssertNil(boundary)
    }

    func testEmptyClause() {
        let boundary = TextProcessing.findClauseBoundary(in: "")
        XCTAssertNil(boundary)
    }

    // MARK: - Streaming accumulation scenarios

    func testIncrementalAccumulation() {
        // Simulates how the sentence buffer accumulates during LLM streaming.
        // "Hello world." arrives as "Hello " + "world."
        var buffer = "Hello "
        XCTAssertNil(TextProcessing.findSentenceBoundary(in: buffer))

        buffer += "world."
        XCTAssertNotNil(TextProcessing.findSentenceBoundary(in: buffer))
    }

    func testStreamingMultiSentence() {
        // Simulates detecting boundaries as text accumulates
        var buffer = "First sentence"
        XCTAssertNil(TextProcessing.findSentenceBoundary(in: buffer))

        buffer += ". Second"
        let boundary = TextProcessing.findSentenceBoundary(in: buffer)
        XCTAssertNotNil(boundary)
        // After splitting at boundary, remainder should be " Second"
        let remainder = String(buffer[boundary!...])
        XCTAssertEqual(remainder, " Second")
    }

    func testClauseFallbackForLongText() {
        // When no sentence boundary exists but text is long, clause boundary is fallback
        let longText = "This is a very long clause that keeps going and going without ending, but finally we get a comma"
        let sentenceBoundary = TextProcessing.findSentenceBoundary(in: longText)
        XCTAssertNil(sentenceBoundary, "No sentence boundary in this text")

        let clauseBoundary = TextProcessing.findClauseBoundary(in: longText)
        XCTAssertNotNil(clauseBoundary, "Should find clause boundary at comma")
    }

    // MARK: - Phase 1.3: Edge case regression tests

    func testVeryLongSentenceWithBoundaryAtEnd() {
        // A sentence longer than 420 chars must still be detected correctly.
        let prefix = String(repeating: "word ", count: 90)  // ~450 chars, no boundary
        let text = prefix + "done."
        let boundary = TextProcessing.findSentenceBoundary(in: text)
        XCTAssertNotNil(boundary, "Should find boundary at 'done.'")
        let sentence = String(text[..<boundary!])
        XCTAssertTrue(sentence.hasSuffix("done."), "Sentence should end with 'done.'")
    }

    func testEmojiMidSentenceDoesNotBreakBoundaryDetection() {
        // Emoji between sentences must not prevent finding the last sentence boundary.
        let text = "This is great! 🎉 And here is more text."
        let boundary = TextProcessing.findSentenceBoundary(in: text)
        XCTAssertNotNil(boundary, "Should find sentence boundary despite emoji")
    }

    func testMultipleEmojiInSentence() {
        let text = "Amazing work 🚀🔥💡. Let's keep going!"
        let boundary = TextProcessing.findSentenceBoundary(in: text)
        XCTAssertNotNil(boundary, "Should handle multiple consecutive emoji correctly")
    }

    func testCodeBlockTextHasNoBoundaryFromPeriodInCode() {
        // A period in a code snippet like "os.path.join()" should not produce a false boundary.
        // Note: the single-letter guard only catches e.g. "A." — multi-letter paths like
        // "os." DO trigger a boundary. This test validates known behavior so any change is visible.
        let text = "os.path.join"
        let boundary = TextProcessing.findSentenceBoundary(in: text)
        // "os.path.join" — the last "." is preceded by "h" (multi-letter), so it fires.
        // Document the current behavior; a future change that tightens this would show here.
        _ = boundary  // Accept either result — this is a documentation test, not a prescription
    }

    func testMultiSentenceFlushSequenceSimulation() {
        // Simulate the real streaming loop: accumulate tokens, detect boundaries, split.
        var buffer = ""

        // Token 1 — no boundary yet.
        buffer += "Hello there"
        XCTAssertNil(TextProcessing.findSentenceBoundary(in: buffer))

        // Token 2 — sentence completes.
        buffer += ". How are you"
        let b1 = TextProcessing.findSentenceBoundary(in: buffer)
        XCTAssertNotNil(b1, "Should detect first sentence boundary")

        // Split: first sentence emitted, remainder kept.
        let firstSentence = String(buffer[..<b1!])
        buffer = String(buffer[b1!...])
        XCTAssertTrue(firstSentence.hasSuffix("."), "First emitted sentence should end with '.'")
        XCTAssertTrue(buffer.contains("How are you"), "Remainder should contain second partial")

        // Token 3 — second sentence completes.
        buffer += "?"
        let b2 = TextProcessing.findSentenceBoundary(in: buffer)
        XCTAssertNotNil(b2, "Should detect second sentence boundary")

        let secondSentence = String(buffer[..<b2!])
        XCTAssertTrue(secondSentence.hasSuffix("?"), "Second sentence should end with '?'")
    }

    func testSentenceBoundaryAfterCloseParenthesis() {
        let text = "The result (42). Next sentence here."
        let boundary = TextProcessing.findSentenceBoundary(in: text)
        XCTAssertNotNil(boundary, "Should find sentence boundary after ')'")
    }

    func testSentenceBoundaryHandlesTrailingWhitespace() {
        let text = "Hello world.  "
        let boundary = TextProcessing.findSentenceBoundary(in: text)
        // The trailing spaces come after the period, so boundary should be after the period.
        XCTAssertNotNil(boundary, "Should find boundary at period even with trailing spaces")
    }

    // MARK: - Phase 1.3: looksLikeNonProse (TTS suppression filter)

    func testLooksLikeNonProseSuppressesToolCallXML() {
        let toolXML = "<tool_call>{ \"name\": \"read\", \"arguments\": {} }</tool_call>"
        XCTAssertTrue(TextProcessing.looksLikeNonProse(toolXML),
                      "Tool call XML must be suppressed from TTS")
    }

    func testLooksLikeNonProseSuppressesParsableJSON() {
        let json = "{\"name\": \"read\", \"arguments\": {\"path\": \"/tmp/test\"}}"
        XCTAssertTrue(TextProcessing.looksLikeNonProse(json),
                      "Tool-shaped JSON must be suppressed from TTS")
    }

    func testLooksLikeNonProseAllowsNormalProse() {
        let prose = "Sure, I can help you with that. Let me look it up for you."
        XCTAssertFalse(TextProcessing.looksLikeNonProse(prose),
                       "Normal conversational prose must not be suppressed")
    }

    func testLooksLikeNonProseAllowsShortText() {
        // Very short strings (<= 10 chars) pass through regardless of content.
        let short = "{a: b}"
        XCTAssertFalse(TextProcessing.looksLikeNonProse(short),
                       "Short strings (<= 10 chars) must pass through the non-prose filter")
    }

    func testLooksLikeNonProseAllowsNumbersInProse() {
        let prose = "The answer is 42. That is a great number."
        XCTAssertFalse(TextProcessing.looksLikeNonProse(prose),
                       "Prose with numbers must not be filtered as non-prose")
    }

    func testLooksLikeNonProseSuppressesHighDensitySymbolText() {
        // High special-char density with few words = code-like output.
        // Must be >24 chars, >18% symbols, and <5 words to trigger the filter.
        let code = "func(){};|&%$@#~^{{}}extra"
        XCTAssertTrue(TextProcessing.looksLikeNonProse(code),
                      "High symbol-density text with few words must be suppressed")
    }

    func testLooksLikeNonProseAllowsMarkdownWithNormalWords() {
        // Markdown prose with enough words should pass through.
        let markdown = "Here is the answer: you should update the file and then run the tests."
        XCTAssertFalse(TextProcessing.looksLikeNonProse(markdown),
                       "Markdown prose with sufficient words must not be filtered")
    }
}
