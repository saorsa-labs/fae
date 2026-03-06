import XCTest
@testable import Fae

final class WakeWordAcousticDetectorTests: XCTestCase {

    func testDetectorMatchesSameWakePhrase() throws {
        let samples = Self.syntheticWakePhrase()
        let template = try XCTUnwrap(
            WakeWordAcousticDetector.makeTemplate(samples: samples, sampleRate: 24_000)
        )

        let detection = WakeWordAcousticDetector.bestDetection(
            samples: samples,
            sampleRate: 24_000,
            templates: [template],
            threshold: 0.70
        )

        XCTAssertNotNil(detection)
        XCTAssertGreaterThanOrEqual(detection?.similarity ?? 0, 0.70)
    }

    func testDetectorRejectsDifferentPhrase() throws {
        let wake = Self.syntheticWakePhrase()
        let other = Self.syntheticNonWakePhrase()
        let template = try XCTUnwrap(
            WakeWordAcousticDetector.makeTemplate(samples: wake, sampleRate: 24_000)
        )

        let similarity = WakeWordAcousticDetector.bestSimilarity(
            samples: other,
            sampleRate: 24_000,
            templates: [template]
        ) ?? 0

        XCTAssertLessThan(similarity, 0.88)
    }

    static func syntheticWakePhrase(sampleRate: Int = 24_000) -> [Float] {
        syntheticPhrase(
            sampleRate: sampleRate,
            tones: [420, 640, 520],
            durations: [0.18, 0.20, 0.16]
        )
    }

    static func syntheticNonWakePhrase(sampleRate: Int = 24_000) -> [Float] {
        syntheticPhrase(
            sampleRate: sampleRate,
            tones: [880, 340, 960],
            durations: [0.14, 0.26, 0.12]
        )
    }

    private static func syntheticPhrase(
        sampleRate: Int,
        tones: [Float],
        durations: [Float]
    ) -> [Float] {
        precondition(tones.count == durations.count)
        var output: [Float] = []
        let silenceCount = Int(Float(sampleRate) * 0.025)
        output.append(contentsOf: Array(repeating: 0, count: Int(Float(sampleRate) * 0.05)))

        for (tone, duration) in zip(tones, durations) {
            let count = Int(Float(sampleRate) * duration)
            for i in 0..<count {
                let t = Float(i) / Float(sampleRate)
                let envelope = min(1.0, Float(i) / Float(max(1, sampleRate / 100)))
                let tail = min(1.0, Float(count - i) / Float(max(1, sampleRate / 100)))
                let shaped = min(envelope, tail)
                let sample = sin(2 * Float.pi * tone * t) * 0.32 * shaped
                output.append(sample)
            }
            output.append(contentsOf: Array(repeating: 0, count: silenceCount))
        }

        output.append(contentsOf: Array(repeating: 0, count: Int(Float(sampleRate) * 0.05)))
        return output
    }
}
