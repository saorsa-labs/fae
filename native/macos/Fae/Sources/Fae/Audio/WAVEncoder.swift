import Foundation

/// Encodes mono Float32 PCM samples into a 16-bit PCM WAV file (RIFF/fmt/data).
///
/// Built for the S18 push-to-talk path: captured mic audio (16 kHz mono) is
/// encoded to WAV and sent base64 inside the daemon's `conversation.inject_text`
/// payload so Gemma 4 hears the user directly. Counterpart of `WAVParser`
/// (read side) — `WAVEncoderTests` round-trips through both.
enum WAVEncoder {
    /// Encode samples as 16-bit PCM little-endian WAV. Samples are clamped to
    /// [-1, 1] before conversion; an empty sample array yields a valid,
    /// zero-length-data WAV.
    static func encode(samples: [Float], sampleRate: Int) -> Data {
        let dataLength = samples.count * 2
        var wav = Data(capacity: 44 + dataLength)

        func appendU32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        func appendU16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }

        let rate = UInt32(clamping: sampleRate)
        wav.append(contentsOf: Array("RIFF".utf8))
        appendU32(UInt32(36 + dataLength))
        wav.append(contentsOf: Array("WAVE".utf8))
        wav.append(contentsOf: Array("fmt ".utf8))
        appendU32(16) // fmt chunk size
        appendU16(1) // PCM
        appendU16(1) // mono
        appendU32(rate)
        appendU32(rate * 2) // byte rate (mono, 2 bytes/sample)
        appendU16(2) // block align
        appendU16(16) // bits per sample
        wav.append(contentsOf: Array("data".utf8))
        appendU32(UInt32(dataLength))

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            // Match WAVParser/libsndfile normalisation (divide by 32768): scale
            // by the full signed range and clamp the +1.0 edge case to Int16.max.
            let value = Int16(clamping: Int(clamped * 32768.0))
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        return wav
    }
}
