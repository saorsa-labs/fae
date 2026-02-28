import AVFoundation
import XCTest
@testable import Fae

// MARK: - Mock Engines for Benchmarking

private actor MockSTTEngineForBenchmark: STTEngine {
    var isLoaded: Bool = true
    var loadState: MLEngineLoadState = .loaded
    let latencyMs: UInt64

    init(latencyMs: UInt64 = 50) {
        self.latencyMs = latencyMs
    }

    func load(modelID: String) async throws {}

    func transcribe(samples: [Float], sampleRate: Int) async throws -> STTResult {
        try await Task.sleep(nanoseconds: latencyMs * 1_000_000)
        return STTResult(text: "hello", language: "en", confidence: 0.95)
    }
}

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
    ) -> AsyncThrowingStream<String, Error> {
        let delayMs = tokenDelayMs
        let count = tokenCount
        return AsyncThrowingStream { continuation in
            Task {
                for i in 0..<count {
                    try await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    continuation.yield("token\(i)")
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
    func testBenchmarkSTTRecordsLatencyMetric() async {
        let runner = QualityBenchmarkRunner()
        let stt = MockSTTEngineForBenchmark(latencyMs: 50)
        let result = await runner.runAll(stt: stt)

        let sttMetrics = result.metrics.filter { $0.metricName == .sttLatencyMs }
        XCTAssertEqual(sttMetrics.count, 1)
        XCTAssertGreaterThan(sttMetrics.first?.value ?? 0, 0)
    }

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
        let stt = MockSTTEngineForBenchmark()
        let llm = MockLLMEngineForBenchmark()
        let tts = MockTTSEngineForBenchmark()

        let result = await runner.runAll(stt: stt, llm: llm, tts: tts)
        XCTAssertFalse(result.runId.isEmpty)
        XCTAssertGreaterThan(result.metrics.count, 0)
        XCTAssertTrue(result.completedAt >= result.startedAt)
    }

    func testRunAllPassesWithFastMocks() async {
        let runner = QualityBenchmarkRunner()
        let stt = MockSTTEngineForBenchmark(latencyMs: 10)
        let llm = MockLLMEngineForBenchmark(tokenDelayMs: 1, tokenCount: 100)
        let tts = MockTTSEngineForBenchmark(chunkDelayMs: 5, chunkCount: 3)

        let result = await runner.runAll(stt: stt, llm: llm, tts: tts)
        // Fast mocks should pass all default thresholds
        XCTAssertTrue(result.passed)
    }

    func testRunAllFailsWithSlowMocks() async {
        let runner = QualityBenchmarkRunner()
        // STT taking 5 seconds exceeds 3000ms max threshold
        let stt = MockSTTEngineForBenchmark(latencyMs: 5000)

        let result = await runner.runAll(stt: stt)
        XCTAssertFalse(result.passed)

        let failedResults = result.thresholdResults.filter { $0.status == .fail }
        XCTAssertGreaterThan(failedResults.count, 0)
    }
}
