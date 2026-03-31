import Foundation

/// Persists missed-wake audio clips as WAV files for future wake-word training.
///
/// Each clip is stored as a 16 kHz mono PCM WAV file. A FIFO eviction policy
/// keeps the total count at or below ``maxFiles``.
actor MissedWakeStore {

    /// Maximum number of stored missed-wake files.
    static let maxFiles: Int = 500

    /// Sample rate for stored audio (16 kHz mono).
    static let sampleRate: Int = 16_000

    private let storageURL: URL

    /// Create a store using the standard app support directory.
    init() throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let base = appSupport else {
            throw MissedWakeStoreError.noAppSupportDirectory
        }
        let url = base.appendingPathComponent("fae/wake_training/missed", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.storageURL = url
    }

    /// Create a store with a custom storage directory (for testing).
    /// - Parameter storageURL: Directory where WAV files are stored.
    init(storageURL: URL) throws {
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        self.storageURL = storageURL
    }

    /// Write `samples` as a 16 kHz mono WAV file.
    ///
    /// Oldest file is deleted first if the cap would be exceeded.
    /// - Parameter samples: Float32 audio samples at 16 kHz.
    /// - Returns: The URL of the written file, or nil on failure.
    @discardableResult
    func save(samples: [Float]) -> URL? {
        guard !samples.isEmpty else { return nil }

        evictIfNeeded()

        let now = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let filename = formatter.string(from: now)
            .replacingOccurrences(of: ":", with: "-") + "-\(UInt32.random(in: 0...9999)).wav"
        let fileURL = storageURL.appendingPathComponent(filename)

        let wavData = encodeWAV(samples: samples, sampleRate: Self.sampleRate)
        do {
            try wavData.write(to: fileURL)
            return fileURL
        } catch {
            NSLog("MissedWakeStore: failed to write \(fileURL.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Number of WAV files currently stored.
    var fileCount: Int {
        (try? sortedFiles().count) ?? 0
    }

    /// URLs of all stored files sorted by creation date, oldest first.
    var allFiles: [URL] {
        (try? sortedFiles()) ?? []
    }

    // MARK: - Private

    private func sortedFiles() throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: storageURL,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )
        return contents
            .filter { $0.pathExtension == "wav" }
            .sorted { a, b in
                let dateA = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let dateB = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return dateA < dateB
            }
    }

    private func evictIfNeeded() {
        guard let files = try? sortedFiles(), files.count >= Self.maxFiles else { return }
        let toRemove = files.count - Self.maxFiles + 1
        for file in files.prefix(toRemove) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Encode Float32 samples as a minimal 16-bit PCM WAV.
    private func encodeWAV(samples: [Float], sampleRate: Int) -> Data {
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count * 2) // 2 bytes per Int16 sample
        let chunkSize = 36 + dataSize

        var data = Data(capacity: 44 + Int(dataSize))

        // RIFF header
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        data.append(littleEndian: chunkSize)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // fmt  sub-chunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        data.append(littleEndian: UInt32(16)) // sub-chunk size
        data.append(littleEndian: UInt16(1))  // PCM format
        data.append(littleEndian: numChannels)
        data.append(littleEndian: UInt32(sampleRate))
        data.append(littleEndian: byteRate)
        data.append(littleEndian: blockAlign)
        data.append(littleEndian: bitsPerSample)

        // data sub-chunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        data.append(littleEndian: dataSize)

        // Convert Float32 to Int16
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            let int16Value = Int16(clamped * 32767.0)
            data.append(littleEndian: int16Value)
        }

        return data
    }
}

/// Errors from ``MissedWakeStore`` initialization.
enum MissedWakeStoreError: Error {
    /// Could not locate the Application Support directory.
    case noAppSupportDirectory
}

// MARK: - Data helpers

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        var v = value.littleEndian
        append(UnsafeBufferPointer(start: &v, count: 1))
    }

    mutating func append(littleEndian value: UInt16) {
        var v = value.littleEndian
        append(UnsafeBufferPointer(start: &v, count: 1))
    }

    mutating func append(littleEndian value: Int16) {
        var v = value.littleEndian
        append(UnsafeBufferPointer(start: &v, count: 1))
    }
}
