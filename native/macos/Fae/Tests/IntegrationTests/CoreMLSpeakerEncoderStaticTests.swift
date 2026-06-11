import XCTest
@testable import Fae

final class CoreMLSpeakerEncoderStaticTests: XCTestCase {

    // MARK: - closestEnumeratedFrameCount

    func testClosestEnumeratedFrameCount() {
        let count = CoreMLSpeakerEncoder.closestEnumeratedFrameCount(128)
        XCTAssertGreaterThan(count, 0)
    }

    // MARK: - l2Normalize

    func testL2Normalize() {
        let vec: [Float] = [3.0, 4.0]
        let normalized = CoreMLSpeakerEncoder.l2Normalize(vec)
        XCTAssertEqual(normalized.count, vec.count)
        // L2 norm should be ~1.0
        let sumSq = normalized.reduce(0) { $0 + $1 * $1 }
        XCTAssertEqual(sumSq, 1.0, accuracy: 0.001)
    }

    func testL2NormalizeZero() {
        let vec: [Float] = [0.0, 0.0]
        let normalized = CoreMLSpeakerEncoder.l2Normalize(vec)
        XCTAssertEqual(normalized, vec) // returns input for zero vector
    }

    // MARK: - resample

    func testResampleSameRate() {
        let audio: [Float] = [1.0, 2.0, 3.0]
        let result = CoreMLSpeakerEncoder.resample(audio, from: 16000, to: 16000)
        XCTAssertEqual(result, audio)
    }

    func testResampleDown() {
        let audio: [Float] = [1.0, 2.0, 3.0, 4.0]
        let result = CoreMLSpeakerEncoder.resample(audio, from: 16000, to: 8000)
        XCTAssertEqual(result.count, 2) // half the samples
    }

    func testResampleUp() {
        let audio: [Float] = [1.0, 2.0]
        let result = CoreMLSpeakerEncoder.resample(audio, from: 8000, to: 16000)
        XCTAssertEqual(result.count, 4) // doubling the rate doubles the samples
    }
}
