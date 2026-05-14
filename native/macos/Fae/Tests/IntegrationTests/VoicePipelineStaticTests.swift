import XCTest
@testable import Fae

final class VoicePipelineStaticTests: XCTestCase {

    // MARK: - extractCharacterName (VoiceTagParser)

    func testExtractCharacterNameDoubleQuote() {
        let name = VoiceTagStripper.extractCharacterName(from: "character=\"Alice\"")
        XCTAssertEqual(name, "Alice")
    }

    func testExtractCharacterNameSingleQuote() {
        let name = VoiceTagStripper.extractCharacterName(from: "character='Bob'")
        XCTAssertEqual(name, "Bob")
    }

    func testExtractCharacterNameNone() {
        let name = VoiceTagStripper.extractCharacterName(from: "no character here")
        XCTAssertNil(name)
    }

    // MARK: - trimSilence (WakeWordAcousticDetector)

    func testTrimSilenceAllSilence() {
        let samples = [Float()]
        let trimmed = WakeWordAcousticDetector.trimSilence(samples)
        XCTAssertEqual(trimmed, samples)
    }

    func testTrimSilenceWithSignal() {
        let samples = [0.0, 0.0, 1.0, 1.0, 0.0, 0.0].map { Float($0) }
        let trimmed = WakeWordAcousticDetector.trimSilence(samples)
        XCTAssertFalse(trimmed.isEmpty)
    }

    func testTrimSilenceEmpty() {
        let trimmed = WakeWordAcousticDetector.trimSilence([])
        XCTAssertTrue(trimmed.isEmpty)
    }
}
