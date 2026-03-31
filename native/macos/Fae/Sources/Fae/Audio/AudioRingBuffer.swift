/// Fixed-capacity overwrite ring buffer for mono Float32 audio samples.
///
/// When the buffer is full, new samples overwrite the oldest data.
/// Thread safety is the caller's responsibility.
struct AudioRingBuffer {
    /// The maximum number of samples this buffer can hold.
    let capacity: Int

    /// Total number of samples written since creation (monotonically increasing).
    private(set) var totalWritten: Int = 0

    private var storage: [Float]
    private var writeIndex: Int = 0

    /// Create a buffer with the given capacity in samples.
    /// - Parameter capacity: Maximum number of samples to store. Must be > 0.
    init(capacity: Int) {
        precondition(capacity > 0, "AudioRingBuffer capacity must be positive")
        self.capacity = capacity
        self.storage = [Float](repeating: 0, count: capacity)
    }

    /// Append samples, overwriting the oldest data when full.
    /// - Parameter samples: Audio samples to write.
    mutating func write(_ samples: [Float]) {
        for sample in samples {
            storage[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
            totalWritten += 1
        }
    }

    /// Copy the most recent `count` samples into a new array, oldest-first.
    ///
    /// Returns fewer samples if fewer than `count` have been written.
    /// Returns an empty array if `count` is 0 or nothing has been written.
    /// - Parameter count: Number of recent samples to retrieve.
    /// - Returns: Array of samples ordered oldest to newest.
    func read(last count: Int) -> [Float] {
        guard count > 0, totalWritten > 0 else { return [] }

        let available = min(count, min(totalWritten, capacity))
        var result = [Float]()
        result.reserveCapacity(available)

        // writeIndex points to the NEXT write position,
        // so the most recent sample is at (writeIndex - 1).
        // The oldest of the requested samples starts at (writeIndex - available).
        let startIndex = (writeIndex - available + capacity) % capacity

        for i in 0..<available {
            result.append(storage[(startIndex + i) % capacity])
        }

        return result
    }
}
