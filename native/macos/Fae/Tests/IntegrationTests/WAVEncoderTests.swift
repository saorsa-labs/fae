import XCTest

@testable import Fae

// MARK: - WAVEncoder (S18 push-to-talk capture format)
//
// The encoder feeds the daemon's audio lane: a malformed WAV would make Gemma
// "hear nothing" with no parse error anywhere, so the header shape and the
// round-trip through WAVParser are both pinned here.

final class WAVEncoderTests: XCTestCase {

    func testHeaderShape() {
        let samples: [Float] = [0, 0.5, -0.5, 1.0]
        let data = WAVEncoder.encode(samples: samples, sampleRate: 16_000)

        XCTAssertEqual(data.count, 44 + samples.count * 2)
        XCTAssertEqual(String(data: data.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: data.subdata(in: 8..<12), encoding: .ascii), "WAVE")
        XCTAssertEqual(String(data: data.subdata(in: 36..<40), encoding: .ascii), "data")
        XCTAssertEqual(WAVParser.parseSampleRate(data), 16_000)
    }

    func testRoundTripThroughWAVParser() {
        let samples: [Float] = [0, 0.25, -0.25, 0.99, -0.99, 0.001]
        let data = WAVEncoder.encode(samples: samples, sampleRate: 16_000)
        let decoded = WAVParser.parseToFloat32(data)

        XCTAssertEqual(decoded.count, samples.count)
        for (original, roundTripped) in zip(samples, decoded) {
            // 16-bit quantisation: tolerance of one LSB.
            XCTAssertEqual(original, roundTripped, accuracy: 1.0 / 32_000.0)
        }
    }

    func testClampsOutOfRangeSamples() {
        let data = WAVEncoder.encode(samples: [2.0, -2.0], sampleRate: 16_000)
        let decoded = WAVParser.parseToFloat32(data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertLessThanOrEqual(decoded[0], 1.0)
        XCTAssertGreaterThanOrEqual(decoded[1], -1.0)
    }

    func testEmptyInputYieldsValidEmptyWAV() {
        let data = WAVEncoder.encode(samples: [], sampleRate: 16_000)
        XCTAssertEqual(data.count, 44)
        XCTAssertEqual(WAVParser.parseSampleRate(data), 16_000)
        XCTAssertTrue(WAVParser.parseToFloat32(data).isEmpty)
    }
}
