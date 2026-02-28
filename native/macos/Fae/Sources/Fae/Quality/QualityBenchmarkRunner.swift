import AVFoundation
import Foundation

/// Result of a benchmark run.
struct BenchmarkResult: Sendable {
    let runId: String
    let startedAt: Date
    let completedAt: Date
    let metrics: [QualityMetricRecord]
    let thresholdResults: [ThresholdResult]
    let passed: Bool
}

/// Runs benchmarks against ML engine protocols to measure pipeline quality.
actor QualityBenchmarkRunner {
    private let store: QualityMetricStore?

    init(store: QualityMetricStore? = nil) {
        self.store = store
    }

    /// Run all benchmarks and return aggregated results.
    func runAll(
        stt: (any STTEngine)? = nil,
        llm: (any LLMEngine)? = nil,
        tts: (any TTSEngine)? = nil
    ) async -> BenchmarkResult {
        let runId = UUID().uuidString
        let startedAt = Date()
        var metrics: [QualityMetricRecord] = []

        if let stt {
            let sttMetrics = await benchmarkSTT(stt, runId: runId)
            metrics.append(contentsOf: sttMetrics)
        }

        if let llm {
            let llmMetrics = await benchmarkLLM(llm, runId: runId)
            metrics.append(contentsOf: llmMetrics)
        }

        if let tts {
            let ttsMetrics = await benchmarkTTS(tts, runId: runId)
            metrics.append(contentsOf: ttsMetrics)
        }

        if let store {
            try? await store.recordBatch(metrics: metrics)
        }

        let thresholdSet = QualityThresholdSet.default
        var metricValues: [MetricName: Double] = [:]
        for m in metrics {
            metricValues[m.metricName] = m.value
        }
        let thresholdResults = thresholdSet.checkAll(metrics: metricValues)
        let passed = thresholdResults.allSatisfy { $0.status != .fail }

        return BenchmarkResult(
            runId: runId,
            startedAt: startedAt,
            completedAt: Date(),
            metrics: metrics,
            thresholdResults: thresholdResults,
            passed: passed
        )
    }

    // MARK: - Individual Benchmarks

    private func benchmarkSTT(_ engine: any STTEngine, runId: String) async -> [QualityMetricRecord] {
        var metrics: [QualityMetricRecord] = []

        let sampleRate = 16000
        let samples = [Float](repeating: 0.0, count: sampleRate) // 1 second of silence

        let start = Date()
        do {
            _ = try await engine.transcribe(samples: samples, sampleRate: sampleRate)
            let latency = Date().timeIntervalSince(start) * 1000
            metrics.append(QualityMetricRecord(
                metricName: .sttLatencyMs, value: latency,
                context: "benchmark", runId: runId
            ))
        } catch {
            metrics.append(QualityMetricRecord(
                metricName: .sttErrorCount, value: 1,
                context: "benchmark: \(error.localizedDescription)", runId: runId
            ))
        }

        return metrics
    }

    private func benchmarkLLM(_ engine: any LLMEngine, runId: String) async -> [QualityMetricRecord] {
        var metrics: [QualityMetricRecord] = []

        let messages = [LLMMessage(role: .user, content: "Say hello in one sentence.", toolCallID: nil, name: nil)]
        let options = GenerationOptions(temperature: 0.7, maxTokens: 50)
        let start = Date()
        var firstTokenTime: Date?
        var tokenCount = 0

        do {
            let stream = await engine.generate(
                messages: messages,
                systemPrompt: "You are a helpful assistant.",
                options: options
            )

            for try await _ in stream {
                if firstTokenTime == nil {
                    firstTokenTime = Date()
                }
                tokenCount += 1
            }

            let endTime = Date()
            let totalMs = endTime.timeIntervalSince(start) * 1000

            if let firstToken = firstTokenTime {
                let firstTokenMs = firstToken.timeIntervalSince(start) * 1000
                metrics.append(QualityMetricRecord(
                    metricName: .llmFirstTokenMs, value: firstTokenMs,
                    context: "benchmark", runId: runId
                ))
            }

            metrics.append(QualityMetricRecord(
                metricName: .llmTotalMs, value: totalMs,
                context: "benchmark", runId: runId
            ))

            if totalMs > 0 {
                let tokensPerSecond = Double(tokenCount) / (totalMs / 1000)
                metrics.append(QualityMetricRecord(
                    metricName: .llmTokensPerSecond, value: tokensPerSecond,
                    context: "benchmark", runId: runId
                ))
            }
        } catch {
            metrics.append(QualityMetricRecord(
                metricName: .llmErrorCount, value: 1,
                context: "benchmark: \(error.localizedDescription)", runId: runId
            ))
        }

        return metrics
    }

    private func benchmarkTTS(_ engine: any TTSEngine, runId: String) async -> [QualityMetricRecord] {
        var metrics: [QualityMetricRecord] = []

        let text = "Hello, this is a benchmark test."
        let start = Date()
        var firstChunkTime: Date?

        do {
            let stream = await engine.synthesize(text: text)

            for try await _ in stream {
                if firstChunkTime == nil {
                    firstChunkTime = Date()
                }
            }

            let endTime = Date()
            let totalMs = endTime.timeIntervalSince(start) * 1000

            if let firstChunk = firstChunkTime {
                let firstChunkMs = firstChunk.timeIntervalSince(start) * 1000
                metrics.append(QualityMetricRecord(
                    metricName: .ttsFirstChunkMs, value: firstChunkMs,
                    context: "benchmark", runId: runId
                ))
            }

            metrics.append(QualityMetricRecord(
                metricName: .ttsTotalMs, value: totalMs,
                context: "benchmark", runId: runId
            ))
        } catch {
            metrics.append(QualityMetricRecord(
                metricName: .ttsErrorCount, value: 1,
                context: "benchmark: \(error.localizedDescription)", runId: runId
            ))
        }

        return metrics
    }
}
