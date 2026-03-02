import Foundation

/// Generates short tonal cues for pipeline state transitions.
///
/// Replaces: `src/audio/tone.rs`
enum AudioToneGenerator {
    static let sampleRate: Double = 24_000

    /// Thinking tone: warm ascending two-note (A3 → C4).
    /// Duration: 300ms total (2 × 150ms). Volume: 0.05. Envelope: 40% fade.
    static func thinkingTone() -> [Float] {
        generateTwoNote(
            freq1: 220.0,   // A3
            freq2: 261.63,  // C4
            noteDuration: 0.150,
            volume: 0.05,
            fadeFraction: 0.4
        )
    }

    /// Listening tone: bright ascending two-note (C5 → E5).
    /// Duration: 200ms total (2 × 100ms). Volume: 0.10. Envelope: 20% fade.
    static func listeningTone() -> [Float] {
        generateTwoNote(
            freq1: 523.25,  // C5
            freq2: 659.25,  // E5
            noteDuration: 0.100,
            volume: 0.10,
            fadeFraction: 0.2
        )
    }

    /// Ready beep: single clean note signaling "speak now" before voice capture.
    /// G5 (784 Hz), 150ms, volume 0.12. Quick attack/decay envelope.
    static func readyBeep() -> [Float] {
        let freq = 784.0  // G5
        let duration = 0.150
        let volume: Float = 0.12
        let totalSamples = Int(sampleRate * duration)
        let fadeLen = Int(Double(totalSamples) * 0.15)
        var output = [Float](repeating: 0, count: totalSamples)
        for i in 0..<totalSamples {
            let envelope: Float
            if i < fadeLen {
                envelope = Float(i) / Float(fadeLen)
            } else if i > totalSamples - fadeLen {
                envelope = Float(totalSamples - i) / Float(fadeLen)
            } else {
                envelope = 1.0
            }
            let phase = 2.0 * Double.pi * freq * Double(i) / sampleRate
            output[i] = volume * envelope * Float(sin(phase))
        }
        return output
    }

    // MARK: - Private

    private static func generateTwoNote(
        freq1: Double, freq2: Double,
        noteDuration: Double, volume: Float, fadeFraction: Double
    ) -> [Float] {
        let samplesPerNote = Int(sampleRate * noteDuration)
        let totalSamples = samplesPerNote * 2
        var output = [Float](repeating: 0, count: totalSamples)

        for noteIndex in 0..<2 {
            let freq = noteIndex == 0 ? freq1 : freq2
            let offset = noteIndex * samplesPerNote
            let fadeLen = Int(Double(samplesPerNote) * fadeFraction)

            for i in 0..<samplesPerNote {
                let envelope: Float
                if fadeLen > 0 {
                    if i < fadeLen {
                        envelope = Float(i) / Float(fadeLen)
                    } else if i > samplesPerNote - fadeLen {
                        envelope = Float(samplesPerNote - i) / Float(fadeLen)
                    } else {
                        envelope = 1.0
                    }
                } else {
                    envelope = 1.0
                }

                let phase = 2.0 * Double.pi * freq * Double(i) / sampleRate
                output[offset + i] = volume * envelope * Float(sin(phase))
            }
        }

        return output
    }
}
