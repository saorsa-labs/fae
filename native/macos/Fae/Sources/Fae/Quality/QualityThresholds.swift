import Foundation

/// A quality threshold defining acceptable ranges for a metric.
struct QualityThreshold: Sendable {
    let metricName: MetricName
    let maxValue: Double?
    let minValue: Double?
    let warnValue: Double?
}

/// Result of checking a metric against a threshold.
enum ThresholdStatus: String, Sendable {
    case pass
    case warn
    case fail
}

/// Result of a threshold check with context.
struct ThresholdResult: Sendable {
    let metricName: MetricName
    let status: ThresholdStatus
    let actualValue: Double
    let threshold: QualityThreshold
    let message: String
}

/// Built-in quality threshold sets with sensible SLOs.
struct QualityThresholdSet: Sendable {
    let thresholds: [QualityThreshold]

    /// Default production SLOs for Fae's pipeline.
    static let `default` = QualityThresholdSet(thresholds: [
        QualityThreshold(metricName: .sttLatencyMs, maxValue: 3000, minValue: nil, warnValue: 2000),
        QualityThreshold(metricName: .llmFirstTokenMs, maxValue: 2000, minValue: nil, warnValue: 1500),
        QualityThreshold(metricName: .llmTokensPerSecond, maxValue: nil, minValue: 20, warnValue: 30),
        QualityThreshold(metricName: .ttsFirstChunkMs, maxValue: 3000, minValue: nil, warnValue: 2000),
        QualityThreshold(metricName: .endToEndLatencyMs, maxValue: 8000, minValue: nil, warnValue: 6000),
        QualityThreshold(metricName: .memoryRecallMs, maxValue: 100, minValue: nil, warnValue: 50),
    ])

    /// Check a single metric value against its threshold.
    func check(metricName: MetricName, value: Double) -> ThresholdResult? {
        guard let threshold = thresholds.first(where: { $0.metricName == metricName }) else {
            return nil
        }
        return Self.evaluate(value: value, threshold: threshold)
    }

    /// Check all thresholds against provided metric values.
    func checkAll(metrics: [MetricName: Double]) -> [ThresholdResult] {
        thresholds.compactMap { threshold in
            guard let value = metrics[threshold.metricName] else { return nil }
            return Self.evaluate(value: value, threshold: threshold)
        }
    }

    private static func evaluate(value: Double, threshold: QualityThreshold) -> ThresholdResult {
        if let maxValue = threshold.maxValue, value > maxValue {
            return ThresholdResult(
                metricName: threshold.metricName, status: .fail, actualValue: value,
                threshold: threshold,
                message: "\(threshold.metricName.rawValue) = \(value) exceeds max \(maxValue)"
            )
        }

        if let minValue = threshold.minValue, value < minValue {
            return ThresholdResult(
                metricName: threshold.metricName, status: .fail, actualValue: value,
                threshold: threshold,
                message: "\(threshold.metricName.rawValue) = \(value) below min \(minValue)"
            )
        }

        if let warnValue = threshold.warnValue {
            if threshold.maxValue != nil && value > warnValue {
                return ThresholdResult(
                    metricName: threshold.metricName, status: .warn, actualValue: value,
                    threshold: threshold,
                    message: "\(threshold.metricName.rawValue) = \(value) exceeds warn \(warnValue)"
                )
            }
            if threshold.minValue != nil && value < warnValue {
                return ThresholdResult(
                    metricName: threshold.metricName, status: .warn, actualValue: value,
                    threshold: threshold,
                    message: "\(threshold.metricName.rawValue) = \(value) below warn \(warnValue)"
                )
            }
        }

        return ThresholdResult(
            metricName: threshold.metricName, status: .pass, actualValue: value,
            threshold: threshold,
            message: "\(threshold.metricName.rawValue) = \(value) within limits"
        )
    }
}
