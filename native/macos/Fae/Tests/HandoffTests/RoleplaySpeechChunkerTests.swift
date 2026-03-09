import XCTest
@testable import Fae

final class RoleplaySpeechChunkerTests: XCTestCase {
    func testBuffersNarratorFragmentsUntilSentenceBoundary() {
        var chunker = RoleplaySpeechChunker()

        let first = chunker.process([VoiceSegment(text: "The fog rolls", character: nil)])
        XCTAssertTrue(first.isEmpty)

        let second = chunker.process([VoiceSegment(text: " across the moor.", character: nil)])
        XCTAssertEqual(second.map(\.text), ["The fog rolls across the moor."])
        XCTAssertEqual(second.first?.character, nil)
    }

    func testPreservesCharacterChunksAcrossFragments() {
        var chunker = RoleplaySpeechChunker()

        _ = chunker.process([VoiceSegment(text: "To be", character: "Hamlet")])
        let ready = chunker.process([VoiceSegment(text: " or not to be.", character: "Hamlet")])

        XCTAssertEqual(ready.count, 1)
        XCTAssertEqual(ready.first?.text, "To be or not to be.")
        XCTAssertEqual(ready.first?.character, "Hamlet")
    }

    func testFlushesBufferedLineWhenSpeakerChanges() {
        var chunker = RoleplaySpeechChunker()

        let ready = chunker.process([
            VoiceSegment(text: "Wait", character: "Hamlet"),
            VoiceSegment(text: "Now listen.", character: "Ophelia"),
        ])

        XCTAssertEqual(ready.count, 2)
        XCTAssertEqual(ready.first?.text.trimmingCharacters(in: .whitespacesAndNewlines), "Wait")
        XCTAssertEqual(ready.first?.character, "Hamlet")
        XCTAssertEqual(ready.last?.text, "Now listen.")
        XCTAssertEqual(ready.last?.character, "Ophelia")
        XCTAssertTrue(chunker.flush().isEmpty)
    }

    func testVoiceParserAndChunkerHandleStreamingVoiceTags() {
        var parser = VoiceTagStripper()
        var chunker = RoleplaySpeechChunker()

        let firstSegments = parser.process(#"<voice character="Guide">Come this"#)
        XCTAssertTrue(chunker.process(firstSegments).isEmpty)

        let secondSegments = parser.process(#" way.</voice> The lantern glows."#)
        let ready = chunker.process(secondSegments, isFinal: true)

        XCTAssertEqual(ready.map(\.text), ["Come this way.", " The lantern glows."])
        XCTAssertEqual(ready.map(\.character), ["Guide", nil])
    }
}
