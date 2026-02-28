import XCTest
@testable import Fae

final class QualityThresholdsTests: XCTestCase {
    func testDefaultThresholdsContainExpectedMetrics() {
        let thresholds = QualityThresholdSet.default
        let names = Set(thresholds.thresholds.map(\.metricName))
        XCTAssertTrue(names.contains(.sttLatencyMs))
        XCTAssertTrue(names.contains(.llmFirstTokenMs))
        XCTAssertTrue(names.contains(.llmTokensPerSecond))
        XCTAssertTrue(names.contains(.ttsFirstChunkMs))
        XCTAssertTrue(names.contains(.endToEndLatencyMs))
        XCTAssertTrue(names.contains(.memoryRecallMs))
        XCTAssertEqual(thresholds.thresholds.count, 6)
    }

    func testThresholdCheckPassLogic() {
        let thresholds = QualityThresholdSet.default
        let result = thresholds.check(metricName: .sttLatencyMs, value: 500)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, .pass)
    }

    func testThresholdCheckWarnLogic() {
        let thresholds = QualityThresholdSet.default
        // sttLatencyMs: max 3000, warn 2000 — value 2500 should warn
        let result = thresholds.check(metricName: .sttLatencyMs, value: 2500)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, .warn)
    }

    func testThresholdCheckFailLogic() {
        let thresholds = QualityThresholdSet.default
        // sttLatencyMs: max 3000 — value 4000 should fail
        let result = thresholds.check(metricName: .sttLatencyMs, value: 4000)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, .fail)
    }

    func testMinValueThresholdPass() {
        let thresholds = QualityThresholdSet.default
        // llmTokensPerSecond: min 20 — value 50 should pass
        let result = thresholds.check(metricName: .llmTokensPerSecond, value: 50)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, .pass)
    }

    func testMinValueThresholdWarn() {
        let thresholds = QualityThresholdSet.default
        // llmTokensPerSecond: min 20, warn 30 — value 25 should warn
        let result = thresholds.check(metricName: .llmTokensPerSecond, value: 25)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, .warn)
    }

    func testMinValueThresholdFail() {
        let thresholds = QualityThresholdSet.default
        // llmTokensPerSecond: min 20 — value 10 should fail
        let result = thresholds.check(metricName: .llmTokensPerSecond, value: 10)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, .fail)
    }

    func testCheckAllReturnsResults() {
        let thresholds = QualityThresholdSet.default
        let metrics: [MetricName: Double] = [
            .sttLatencyMs: 500,
            .llmFirstTokenMs: 1000,
            .llmTokensPerSecond: 50,
            .ttsFirstChunkMs: 1000,
            .endToEndLatencyMs: 3000,
            .memoryRecallMs: 30,
        ]
        let results = thresholds.checkAll(metrics: metrics)
        XCTAssertEqual(results.count, 6)
        XCTAssertTrue(results.allSatisfy { $0.status == .pass })
    }

    func testCheckAllSkipsMissingMetrics() {
        let thresholds = QualityThresholdSet.default
        let metrics: [MetricName: Double] = [
            .sttLatencyMs: 500,
        ]
        let results = thresholds.checkAll(metrics: metrics)
        XCTAssertEqual(results.count, 1)
    }

    func testUnknownMetricReturnsNil() {
        let thresholds = QualityThresholdSet.default
        // captureSuccessRate has no default threshold
        let result = thresholds.check(metricName: .captureSuccessRate, value: 0.95)
        XCTAssertNil(result)
    }
}
