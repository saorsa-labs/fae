import AVFoundation
import XCTest
@testable import Fae

// MARK: - Mock Engines for Benchmarking

// STT mock removed (S18 kill-list 3/3): ASR happens inside the LLM turn —
// QualityBenchmarkRunner no longer benchmarks a separate STT engine.

private actor MockLLMEngineForBenchmark: LLMEngine {
    var isLoaded: Bool = true
    var loadState: MLEngineLoadState = .loaded
    let tokenDelayMs: UInt64
    let tokenCount: Int

    init(tokenDelayMs: UInt64 = 10, tokenCount: Int = 5) {
        self.tokenDelayMs = tokenDelayMs
        self.tokenCount = tokenCount
    }

    func load(modelID: String) async throws {}

    func generate(
        messages: [LLMMessage],
        systemPrompt: String,
        options: GenerationOptions
    ) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let delayMs = tokenDelayMs
        let count = tokenCount
        return AsyncThrowingStream { continuation in
            Task {
                for i in 0..<count {
                    try await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    continuation.yield(.text("token\(i)"))
                }
                continuation.finish()
            }
        }
    }
}

private actor MockTTSEngineForBenchmark: TTSEngine {
    var isLoaded: Bool = true
    var isVoiceLoaded: Bool = false
    var loadState: MLEngineLoadState = .loaded
    let chunkDelayMs: UInt64
    let chunkCount: Int

    init(chunkDelayMs: UInt64 = 20, chunkCount: Int = 3) {
        self.chunkDelayMs = chunkDelayMs
        self.chunkCount = chunkCount
    }

    func load(modelID: String) async throws {}

    func synthesize(text: String) -> AsyncThrowingStream<AVAudioPCMBuffer, Error> {
        let delayMs = chunkDelayMs
        let count = chunkCount
        return AsyncThrowingStream { continuation in
            Task {
                guard let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1) else {
                    continuation.finish()
                    return
                }
                for _ in 0..<count {
                    try await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    if let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160) {
                        buffer.frameLength = 160
                        continuation.yield(buffer)
                    }
                }
                continuation.finish()
            }
        }
    }
}

// MARK: - Tests

final class QualityBenchmarkRunnerTests: XCTestCase {
    func testBenchmarkLLMRecordsThroughputAndLatency() async {
        let runner = QualityBenchmarkRunner()
        let llm = MockLLMEngineForBenchmark(tokenDelayMs: 10, tokenCount: 5)
        let result = await runner.runAll(llm: llm)

        let firstToken = result.metrics.filter { $0.metricName == .llmFirstTokenMs }
        let totalMs = result.metrics.filter { $0.metricName == .llmTotalMs }
        let throughput = result.metrics.filter { $0.metricName == .llmTokensPerSecond }

        XCTAssertEqual(firstToken.count, 1)
        XCTAssertEqual(totalMs.count, 1)
        XCTAssertEqual(throughput.count, 1)
        XCTAssertGreaterThan(throughput.first?.value ?? 0, 0)
    }

    func testRunAllProducesBenchmarkResult() async {
        let runner = QualityBenchmarkRunner()
        let llm = MockLLMEngineForBenchmark()
        let tts = MockTTSEngineForBenchmark()

        let result = await runner.runAll(llm: llm, tts: tts)
        XCTAssertFalse(result.runId.isEmpty)
        XCTAssertGreaterThan(result.metrics.count, 0)
        XCTAssertTrue(result.completedAt >= result.startedAt)
    }

    func testRunAllPassesWithFastMocks() async {
        let runner = QualityBenchmarkRunner()
        let llm = MockLLMEngineForBenchmark(tokenDelayMs: 1, tokenCount: 100)
        let tts = MockTTSEngineForBenchmark(chunkDelayMs: 5, chunkCount: 3)

        let result = await runner.runAll(llm: llm, tts: tts)
        // Fast mocks should pass all default thresholds
        XCTAssertTrue(result.passed)
    }

    func testRunAllFailsWithSlowMocks() async {
        let runner = QualityBenchmarkRunner()
        // First TTS chunk after 4 seconds exceeds the 3000ms max threshold.
        let tts = MockTTSEngineForBenchmark(chunkDelayMs: 4000, chunkCount: 1)

        let result = await runner.runAll(tts: tts)
        XCTAssertFalse(result.passed)

        let failedResults = result.thresholdResults.filter { $0.status == .fail }
        XCTAssertGreaterThan(failedResults.count, 0)
    }
}
