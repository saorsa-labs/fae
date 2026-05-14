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

    // MARK: - meanCenter (WakeWordAcousticDetector)

    func testMeanCenter() {
        let centered = WakeWordAcousticDetector.meanCenter([1.0, 3.0, 5.0].map { Float($0) })
        XCTAssertEqual(centered[0], -2.0, accuracy: 0.001)
        XCTAssertEqual(centered[1], 0.0, accuracy: 0.001)
    }

    func testMeanCenterEmpty() {
        let centered = WakeWordAcousticDetector.meanCenter([])
        XCTAssertTrue(centered.isEmpty)
    }

    // MARK: - l2Normalize (WakeWordAcousticDetector)

    func testL2Normalize() {
        let normalized = WakeWordAcousticDetector.l2Normalize([3.0, 4.0].map { Float($0) })
        XCTAssertEqual(normalized[0], 0.6, accuracy: 0.01)
        XCTAssertEqual(normalized[1], 0.8, accuracy: 0.01)
    }

    func testL2NormalizeEmpty() {
        let normalized = WakeWordAcousticDetector.l2Normalize([])
        XCTAssertTrue(normalized.isEmpty)
    }

    // MARK: - cosineSimilarity (WakeWordAcousticDetector)

    func testCosineSimilarityIdentical() {
        let sim = WakeWordAcousticDetector.cosineSimilarity([1.0, 0.0].map(Float.init), [1.0, 0.0].map(Float.init))
        XCTAssertEqual(sim, 1.0, accuracy: 0.001)
    }

    func testCosineSimilarityDifferent() {
        let sim = WakeWordAcousticDetector.cosineSimilarity([1.0, 0.0].map(Float.init), [0.0, 1.0].map(Float.init))
        XCTAssertEqual(sim, 0.0, accuracy: 0.001)
    }

    func testCosineSimilarityMismatchedLength() {
        let sim = WakeWordAcousticDetector.cosineSimilarity([1.0].map(Float.init), [1.0, 2.0].map(Float.init))
        XCTAssertEqual(sim, -.greatestFiniteMagnitude)
    }
}
