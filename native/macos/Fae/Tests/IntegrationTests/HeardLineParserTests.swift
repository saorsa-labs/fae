import XCTest

@testable import Fae

// MARK: - HeardLineParser (S18 transcript contract)
//
// The [heard] line is the ONLY bridge from audio-direct turns back to the
// transcript/memory/correction paths — if splitting breaks, memory capture
// silently records placeholders. The tool-call residue strip is what keeps
// Gemma's leaked markup out of TTS.

final class HeardLineParserTests: XCTestCase {

    func testSplitsHeardLineFromReply() {
        let (heard, remainder) = HeardLineParser.split(
            "[heard]: What is on my calendar today?\nYou have two meetings.")
        XCTAssertEqual(heard, "What is on my calendar today?")
        XCTAssertEqual(remainder, "You have two meetings.")
    }

    func testSingleLineReplyIsAllTranscription() {
        let (heard, remainder) = HeardLineParser.split("[heard]: Good morning Fae")
        XCTAssertEqual(heard, "Good morning Fae")
        XCTAssertEqual(remainder, "")
    }

    func testMissingHeardLineReturnsNilAndFullText() {
        let (heard, remainder) = HeardLineParser.split("You have two meetings.")
        XCTAssertNil(heard)
        XCTAssertEqual(remainder, "You have two meetings.")
    }

    func testEmptyTranscriptionIsNil() {
        let (heard, _) = HeardLineParser.split("[heard]: \nHello")
        XCTAssertNil(heard, "an empty transcription must not become the user turn")
    }

    func testCaseInsensitiveMarker() {
        let (heard, _) = HeardLineParser.split("[Heard]: hello there\nHi.")
        XCTAssertEqual(heard, "hello there")
    }

    func testStripsGemmaPipeToolCallResidue() {
        // Observed live: Gemma 4 leaks raw markup into the text channel
        // alongside the parsed structured calls.
        let text = "<|tool_call>call:calendar{day:<|\"|>2026-06-11<|\"|>}"
        XCTAssertEqual(HeardLineParser.stripToolCallResidue(text), "")
    }

    func testStripsStandardToolCallResidueKeepingProse() {
        let text = "Let me check.\n<tool_call>\ncalendar(day=\"today\")\n</tool_call>"
        XCTAssertEqual(HeardLineParser.stripToolCallResidue(text), "Let me check.")
    }

    func testResidueStripLeavesPlainTextAlone() {
        XCTAssertEqual(
            HeardLineParser.stripToolCallResidue("You have two meetings."),
            "You have two meetings.")
    }

    func testFullAudioToolTurnPipeline() {
        // The exact shape returned by the live S18 proof run.
        let reply = "[heard]: What is on my calendar today?\n"
            + "<|tool_call>call:calendar{day:<|\"|>2026-06-11<|\"|>}"
        let (heard, remainder) = HeardLineParser.split(reply)
        XCTAssertEqual(heard, "What is on my calendar today?")
        XCTAssertEqual(
            HeardLineParser.stripToolCallResidue(remainder), "",
            "a pure tool-call turn must produce no speakable text")
    }
}
