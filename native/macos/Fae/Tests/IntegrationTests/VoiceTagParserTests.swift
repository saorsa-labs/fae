import XCTest
@testable import Fae

// MARK: - VoiceSegment Tests

final class VoiceSegmentTests: XCTestCase {

    func testNarratorSegment() {
        let seg = VoiceSegment(text: "Hello world", character: nil)
        XCTAssertEqual(seg.text, "Hello world")
        XCTAssertNil(seg.character)
    }

    func testCharacterSegment() {
        let seg = VoiceSegment(text: "I am Hamlet", character: "Hamlet")
        XCTAssertEqual(seg.text, "I am Hamlet")
        XCTAssertEqual(seg.character, "Hamlet")
    }

    func testIsSendable() {
        let seg = VoiceSegment(text: "test", character: nil)
        _ = seg as any Sendable
    }
}

// MARK: - RoleplaySpeechChunk Tests

final class RoleplaySpeechChunkTests: XCTestCase {

    func testCreateChunk() {
        let chunk = RoleplaySpeechChunk(text: "Hello", character: "Alice")
        XCTAssertEqual(chunk.text, "Hello")
        XCTAssertEqual(chunk.character, "Alice")
    }

    func testIsSendable() {
        let chunk = RoleplaySpeechChunk(text: "test", character: nil)
        _ = chunk as any Sendable
    }
}

// MARK: - VoiceTagStripper Tests

final class VoiceTagStripperTests: XCTestCase {

    // MARK: - Basic text (no tags)

    func testPlainTextReturnsNarrator() {
        var stripper = VoiceTagStripper()
        let segments = stripper.process("Hello world")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Hello world")
        XCTAssertNil(segments[0].character)
    }

    func testEmptyTextReturnsNoSegments() {
        var stripper = VoiceTagStripper()
        let segments = stripper.process("")
        XCTAssertTrue(segments.isEmpty)
    }

    // MARK: - Single voice tag

    func testSingleVoiceTag() {
        var stripper = VoiceTagStripper()
        let segments = stripper.process("<voice character=\"Alice\">Hello</voice>")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].text, "Hello")
        XCTAssertEqual(segments[0].character, "Alice")
    }

    func testVoiceTagWithSingleQuotes() {
        var stripper = VoiceTagStripper()
        let segments = stripper.process("<voice character='Bob'>Hi there</voice>")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].character, "Bob")
    }

    // MARK: - Mixed narrator and character

    func testNarratorBeforeVoiceTag() {
        var stripper = VoiceTagStripper()
        let segments = stripper.process("Once upon a time <voice character=\"Alice\">hello</voice>")
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].text, "Once upon a time ")
        XCTAssertNil(segments[0].character)
        XCTAssertEqual(segments[1].text, "hello")
        XCTAssertEqual(segments[1].character, "Alice")
    }

    func testNarratorAfterVoiceTag() {
        var stripper = VoiceTagStripper()
        let segments = stripper.process("<voice character=\"Alice\">hello</voice> and then some")
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].character, "Alice")
        XCTAssertNil(segments[1].character)
    }

    // MARK: - Multiple voice tags

    func testMultipleVoiceTags() {
        var stripper = VoiceTagStripper()
        let segments = stripper.process(
            "<voice character=\"A\">Hello</voice> and <voice character=\"B\">Hi back</voice>"
        )
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments[0].character, "A")
        XCTAssertNil(segments[1].character)
        XCTAssertEqual(segments[2].character, "B")
    }

    // MARK: - Incremental processing

    func testIncrementalProcessing() {
        var stripper = VoiceTagStripper()
        let s1 = stripper.process("<voice character=\"")
        let s2 = stripper.process("Alice\">Hello</voice>")
        let all = s1 + s2
        // Partial tag should wait, then resolve on second chunk
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].character, "Alice")
        XCTAssertEqual(all[0].text, "Hello")
    }

    func testFlushWithRemainingBuffer() {
        var stripper = VoiceTagStripper()
        stripper.process("Some text without tags")
        let flushed = stripper.flush()
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed[0].text, "Some text without tags")
        XCTAssertNil(flushed[0].character)
    }

    func testFlushWithUnterminatedVoiceTag() {
        var stripper = VoiceTagStripper()
        stripper.process("<voice character=\"Alice\">Hello world")
        let flushed = stripper.flush()
        XCTAssertEqual(flushed.count, 1)
        XCTAssertEqual(flushed[0].character, "Alice")
        XCTAssertEqual(flushed[0].text, "Hello world")
    }

    // MARK: - Partial tag handling

    func testPartialClosingTagDoesNotEmit() {
        var stripper = VoiceTagStripper()
        let segments = stripper.process("<voice character=\"A\">Hello </voi")
        // Should not emit because closing tag is partial
        XCTAssertTrue(segments.isEmpty)
    }

    func testPartialOpeningTagDoesNotEmit() {
        var stripper = VoiceTagStripper()
        let segments = stripper.process("Hello <voi")
        // Partial opening — should wait
        XCTAssertTrue(segments.isEmpty)
    }

    // MARK: - Character name extraction edge cases

    func testCharacterNameWithSpacesInAttributes() {
        var stripper = VoiceTagStripper()
        let segments = stripper.process("<voice character  =  \"Alice\" >Hi</voice>")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].character, "Alice")
    }

    func testEmptyCharacterName() {
        var stripper = VoiceTagStripper()
        let segments = stripper.process("<voice character=\"\">Hi</voice>")
        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].character, "")
    }

    // MARK: - Flush after processing

    func testFlushAfterCompleteTagsReturnsEmpty() {
        var stripper = VoiceTagStripper()
        stripper.process("<voice character=\"A\">Hi</voice>")
        let flushed = stripper.flush()
        XCTAssertTrue(flushed.isEmpty)
    }
}

// MARK: - Optional asyncFlatMap Tests

final class OptionalAsyncFlatMapTests: XCTestCase {

    func testSomeValueTransformed() async {
        let value: String? = "hello"
        let result = await value.asyncFlatMap { $0.uppercased() }
        XCTAssertEqual(result, "HELLO")
    }

    func testNilReturnsNil() async {
        let value: String? = nil
        let result = await value.asyncFlatMap { $0.uppercased() }
        XCTAssertNil(result)
    }

    func testTransformReturnsNil() async {
        let value: String? = "hello"
        let result = await value.asyncFlatMap { (_: String) -> String? in nil }
        XCTAssertNil(result)
    }

    func testSomeValueWithNonOptionalResult() async {
        let value: Int? = 5
        let result = await value.asyncFlatMap { $0 * 2 }
        XCTAssertEqual(result, 10)
    }
}
