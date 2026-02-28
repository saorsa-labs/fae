import Foundation

/// Categories of quality metrics tracked by Fae.
enum MetricCategory: String, Codable, Sendable {
    case latency
    case throughput
    case errorRate
    case memoryQuality
}

/// Named metrics collected during pipeline execution.
enum MetricName: String, Codable, Sendable {
    // Latency
    case sttLatencyMs
    case llmFirstTokenMs
    case llmTotalMs
    case ttsFirstChunkMs
    case ttsTotalMs
    case memoryRecallMs
    case memoryCaptureMs
    case endToEndLatencyMs

    // Throughput
    case llmTokensPerSecond
    case ttsCharsPerSecond

    // Error rates
    case sttErrorCount
    case llmErrorCount
    case ttsErrorCount
    case toolErrorCount

    // Memory quality
    case recallPrecision
    case recallHitRate
    case captureSuccessRate

    var category: MetricCategory {
        switch self {
        case .sttLatencyMs, .llmFirstTokenMs, .llmTotalMs,
             .ttsFirstChunkMs, .ttsTotalMs, .memoryRecallMs,
             .memoryCaptureMs, .endToEndLatencyMs:
            return .latency
        case .llmTokensPerSecond, .ttsCharsPerSecond:
            return .throughput
        case .sttErrorCount, .llmErrorCount, .ttsErrorCount, .toolErrorCount:
            return .errorRate
        case .recallPrecision, .recallHitRate, .captureSuccessRate:
            return .memoryQuality
        }
    }

    var unit: String {
        switch self {
        case .sttLatencyMs, .llmFirstTokenMs, .llmTotalMs,
             .ttsFirstChunkMs, .ttsTotalMs, .memoryRecallMs,
             .memoryCaptureMs, .endToEndLatencyMs:
            return "ms"
        case .llmTokensPerSecond:
            return "tokens/s"
        case .ttsCharsPerSecond:
            return "chars/s"
        case .sttErrorCount, .llmErrorCount, .ttsErrorCount, .toolErrorCount:
            return "count"
        case .recallPrecision, .recallHitRate, .captureSuccessRate:
            return "ratio"
        }
    }
}

/// A single quality metric measurement.
struct QualityMetricRecord: Codable, Sendable {
    let id: Int64?
    let category: MetricCategory
    let metricName: MetricName
    let value: Double
    let unit: String
    let context: String?
    let recordedAt: Date
    let runId: String?

    init(
        id: Int64? = nil,
        metricName: MetricName,
        value: Double,
        context: String? = nil,
        recordedAt: Date = Date(),
        runId: String? = nil
    ) {
        self.id = id
        self.category = metricName.category
        self.metricName = metricName
        self.value = value
        self.unit = metricName.unit
        self.context = context
        self.recordedAt = recordedAt
        self.runId = runId
    }
}

/// Aggregated metric statistics over a time window.
struct MetricAggregation: Sendable {
    let metricName: MetricName
    let count: Int
    let min: Double
    let max: Double
    let mean: Double
    let p50: Double
    let p95: Double
    let p99: Double
}
