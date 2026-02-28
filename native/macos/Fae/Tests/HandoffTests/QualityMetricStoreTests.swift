import XCTest
@testable import Fae

final class QualityMetricStoreTests: XCTestCase {
    private func makeTempStore() throws -> QualityMetricStore {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        return try QualityMetricStore(
            path: tmpDir.appendingPathComponent("quality.db").path
        )
    }

    func testInsertAndRetrieveMetric() async throws {
        let store = try makeTempStore()
        let metric = QualityMetricRecord(metricName: .sttLatencyMs, value: 150.0)
        try await store.record(metric: metric)

        let results = try await store.latestMetrics(name: .sttLatencyMs, limit: 10)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.metricName, .sttLatencyMs)
        XCTAssertEqual(results.first!.value, 150.0, accuracy: 0.01)
    }

    func testBatchInsert() async throws {
        let store = try makeTempStore()
        let metrics = (0..<5).map { i in
            QualityMetricRecord(metricName: .llmTotalMs, value: Double(i) * 100)
        }
        try await store.recordBatch(metrics: metrics)

        let results = try await store.latestMetrics(name: .llmTotalMs, limit: 10)
        XCTAssertEqual(results.count, 5)
    }

    func testAggregation() async throws {
        let store = try makeTempStore()
        let values: [Double] = [100, 200, 300, 400, 500]
        for v in values {
            try await store.record(metric: QualityMetricRecord(metricName: .sttLatencyMs, value: v))
        }

        let agg = try await store.aggregate(name: .sttLatencyMs, windowSeconds: 3600)
        XCTAssertNotNil(agg)
        XCTAssertEqual(agg?.count, 5)
        XCTAssertEqual(agg!.min, 100, accuracy: 0.01)
        XCTAssertEqual(agg!.max, 500, accuracy: 0.01)
        XCTAssertEqual(agg!.mean, 300, accuracy: 0.01)
    }

    func testAggregationEmptyReturnsNil() async throws {
        let store = try makeTempStore()
        let agg = try await store.aggregate(name: .sttLatencyMs, windowSeconds: 3600)
        XCTAssertNil(agg)
    }

    func testThresholdPassWhenUnderMax() async throws {
        let store = try makeTempStore()
        try await store.record(metric: QualityMetricRecord(metricName: .sttLatencyMs, value: 1000))

        let threshold = QualityThreshold(metricName: .sttLatencyMs, maxValue: 3000, minValue: nil, warnValue: 2000)
        let result = try await store.checkThreshold(name: .sttLatencyMs, threshold: threshold)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, .pass)
    }

    func testThresholdFailWhenOverMax() async throws {
        let store = try makeTempStore()
        try await store.record(metric: QualityMetricRecord(metricName: .sttLatencyMs, value: 5000))

        let threshold = QualityThreshold(metricName: .sttLatencyMs, maxValue: 3000, minValue: nil, warnValue: 2000)
        let result = try await store.checkThreshold(name: .sttLatencyMs, threshold: threshold)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, .fail)
    }

    func testThresholdWarnBetween() async throws {
        let store = try makeTempStore()
        try await store.record(metric: QualityMetricRecord(metricName: .sttLatencyMs, value: 2500))

        let threshold = QualityThreshold(metricName: .sttLatencyMs, maxValue: 3000, minValue: nil, warnValue: 2000)
        let result = try await store.checkThreshold(name: .sttLatencyMs, threshold: threshold)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, .warn)
    }

    func testMinValueCheckForThroughput() async throws {
        let store = try makeTempStore()
        try await store.record(metric: QualityMetricRecord(metricName: .llmTokensPerSecond, value: 10))

        let threshold = QualityThreshold(metricName: .llmTokensPerSecond, maxValue: nil, minValue: 20, warnValue: 30)
        let result = try await store.checkThreshold(name: .llmTokensPerSecond, threshold: threshold)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, .fail)
    }

    func testPruneOlderThan() async throws {
        let store = try makeTempStore()
        // Record a metric with old timestamp
        let old = QualityMetricRecord(
            metricName: .sttLatencyMs, value: 100,
            recordedAt: Date().addingTimeInterval(-86400 * 10)
        )
        let recent = QualityMetricRecord(metricName: .sttLatencyMs, value: 200)
        try await store.record(metric: old)
        try await store.record(metric: recent)

        let pruned = try await store.pruneOlderThan(days: 7)
        XCTAssertEqual(pruned, 1)

        let remaining = try await store.latestMetrics(name: .sttLatencyMs, limit: 10)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first!.value, 200, accuracy: 0.01)
    }

    func testMetricsInRangeFilters() async throws {
        let store = try makeTempStore()
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        let twoHoursAgo = now.addingTimeInterval(-7200)

        try await store.record(metric: QualityMetricRecord(
            metricName: .llmTotalMs, value: 100, recordedAt: twoHoursAgo
        ))
        try await store.record(metric: QualityMetricRecord(
            metricName: .llmTotalMs, value: 200, recordedAt: oneHourAgo
        ))
        try await store.record(metric: QualityMetricRecord(
            metricName: .llmTotalMs, value: 300, recordedAt: now
        ))

        // Query only last 90 minutes
        let results = try await store.metricsInRange(
            name: .llmTotalMs,
            from: now.addingTimeInterval(-5400),
            to: now.addingTimeInterval(60)
        )
        XCTAssertEqual(results.count, 2)
    }
}
