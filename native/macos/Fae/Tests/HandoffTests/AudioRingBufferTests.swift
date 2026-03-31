import Testing
@testable import Fae

@Suite("AudioRingBuffer")
struct AudioRingBufferTests {

    @Test("Empty buffer returns empty array")
    func emptyBufferReturnsEmpty() {
        let buffer = AudioRingBuffer(capacity: 10)
        #expect(buffer.read(last: 10) == [])
        #expect(buffer.totalWritten == 0)
    }

    @Test("Read last zero returns empty")
    func readLastZeroReturnsEmpty() {
        var buffer = AudioRingBuffer(capacity: 10)
        buffer.write([1, 2, 3])
        #expect(buffer.read(last: 0) == [])
    }

    @Test("Partial fill returns all written samples")
    func partialFill() {
        var buffer = AudioRingBuffer(capacity: 10)
        buffer.write([1, 2, 3])
        #expect(buffer.read(last: 5) == [1, 2, 3])
        #expect(buffer.totalWritten == 3)
    }

    @Test("Exact fill returns all samples in order")
    func exactFill() {
        var buffer = AudioRingBuffer(capacity: 5)
        buffer.write([10, 20, 30, 40, 50])
        #expect(buffer.read(last: 5) == [10, 20, 30, 40, 50])
        #expect(buffer.totalWritten == 5)
    }

    @Test("Overwrite returns last capacity samples in order")
    func overwrite() {
        var buffer = AudioRingBuffer(capacity: 4)
        buffer.write([1, 2, 3, 4, 5])
        #expect(buffer.read(last: 4) == [2, 3, 4, 5])
        #expect(buffer.totalWritten == 5)
    }

    @Test("Total written accumulates across multiple writes")
    func totalWrittenAccumulates() {
        var buffer = AudioRingBuffer(capacity: 100)
        buffer.write([1, 2, 3])
        buffer.write([4, 5])
        #expect(buffer.totalWritten == 5)
        #expect(buffer.read(last: 5) == [1, 2, 3, 4, 5])
    }

    @Test("Read more than written returns only written samples")
    func readMoreThanWritten() {
        var buffer = AudioRingBuffer(capacity: 100)
        buffer.write([7, 8, 9])
        #expect(buffer.read(last: 50) == [7, 8, 9])
    }

    @Test("Multi-cycle overwrite preserves correct order")
    func multiCycleOverwrite() {
        var buffer = AudioRingBuffer(capacity: 3)
        // Cycle 1: [1, 2, 3]
        buffer.write([1, 2, 3])
        #expect(buffer.read(last: 3) == [1, 2, 3])
        // Cycle 2: overwrites -> [4, 5, 6]
        buffer.write([4, 5, 6])
        #expect(buffer.read(last: 3) == [4, 5, 6])
        // Partial cycle 3: write 2 more -> [6, 7, 8]
        buffer.write([7, 8])
        #expect(buffer.read(last: 3) == [6, 7, 8])
        #expect(buffer.totalWritten == 8)
    }
}
