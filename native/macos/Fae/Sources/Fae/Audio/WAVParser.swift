import Foundation

/// Lightweight WAV file parser for extracting PCM 16-bit mono audio samples.
///
/// Used by ModelManager (speaker enrollment from fae.wav) and AudioPlaybackManager
/// (WAV playback). No dependencies beyond Foundation.
enum WAVParser {

    /// Extract the sample rate from a WAV file header.
    /// Returns nil if the header is invalid or too short.
    static func parseSampleRate(_ data: Data) -> Int? {
        guard data.count >= 44 else { return nil }
        let riff = String(data: data[0..<4], encoding: .ascii)
        let wave = String(data: data[8..<12], encoding: .ascii)
        guard riff == "RIFF", wave == "WAVE" else { return nil }

        var offset = 12
        while offset + 8 < data.count {
            let chunkID = String(data: data[offset..<(offset + 4)], encoding: .ascii)
            let chunkSize = readU32(data, at: offset + 4)
            if chunkID == "fmt " {
                guard Int(chunkSize) >= 16, offset + 8 + 16 <= data.count else { return nil }
                let sampleRate = readU32(data, at: offset + 12)
                return Int(sampleRate)
            }
            offset += 8 + Int(chunkSize)
            if chunkSize % 2 != 0 { offset += 1 }
        }
        return nil
    }

    /// Parse a WAV file's raw bytes into Float32 samples normalized to [-1, 1].
    ///
    /// Expects PCM 16-bit mono WAV format. Returns an empty array if the format
    /// is not recognized.
    static func parseToFloat32(_ data: Data) -> [Float] {
        // Minimum WAV header: 44 bytes.
        guard data.count >= 44 else { return [] }

        // Verify RIFF header.
        let riff = String(data: data[0..<4], encoding: .ascii)
        let wave = String(data: data[8..<12], encoding: .ascii)
        guard riff == "RIFF", wave == "WAVE" else { return [] }

        // Parse chunks: validate fmt before reading data.
        var fmtValidated = false
        var offset = 12
        while offset + 8 < data.count {
            let chunkID = String(data: data[offset..<(offset + 4)], encoding: .ascii)
            let chunkSize = readU32(data, at: offset + 4)

            if chunkID == "fmt " {
                guard Int(chunkSize) >= 16, offset + 8 + 16 <= data.count else {
                    NSLog("WAVParser: fmt chunk too small (%d bytes)", chunkSize)
                    return []
                }
                let audioFormat = readU16(data, at: offset + 8)
                let numChannels = readU16(data, at: offset + 10)
                let bitsPerSample = readU16(data, at: offset + 22)
                guard audioFormat == 1 else {
                    NSLog("WAVParser: not PCM (format=%d)", audioFormat)
                    return []
                }
                guard numChannels == 1 else {
                    NSLog("WAVParser: not mono (channels=%d)", numChannels)
                    return []
                }
                guard bitsPerSample == 16 else {
                    NSLog("WAVParser: not 16-bit (bits=%d)", bitsPerSample)
                    return []
                }
                fmtValidated = true
            }

            if chunkID == "data" {
                guard fmtValidated else {
                    NSLog("WAVParser: data chunk found before fmt — invalid")
                    return []
                }
                let dataStart = offset + 8
                let dataEnd = min(dataStart + Int(chunkSize), data.count)
                let sampleCount = (dataEnd - dataStart) / 2

                var samples = [Float](repeating: 0, count: sampleCount)
                for i in 0..<sampleCount {
                    let int16 = readI16(data, at: dataStart + i * 2)
                    samples[i] = Float(int16) / 32768.0
                }
                return samples
            }
            offset += 8 + Int(chunkSize)
            // WAV chunks are word-aligned.
            if chunkSize % 2 != 0 { offset += 1 }
        }

        return []
    }

    // MARK: - Private helpers

    private static func readU16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readU32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func readI16(_ data: Data, at offset: Int) -> Int16 {
        Int16(bitPattern: readU16(data, at: offset))
    }
}
