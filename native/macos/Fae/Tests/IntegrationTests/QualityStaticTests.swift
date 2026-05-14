import XCTest
@testable import Fae

final class QualityStaticTests: XCTestCase {

    // MARK: - evaluate (QualityThresholdSet)

    func testEvaluatePass() {
        let threshold = QualityThreshold(metricName: .sttLatencyMs, maxValue: 100, minValue: 0, warnValue: 80)
        let result = QualityThresholdSet.evaluate(value: 50, threshold: threshold)
        XCTAssertEqual(result.status, .pass)
    }

    func testEvaluateFailMax() {
        let threshold = QualityThreshold(metricName: .sttLatencyMs, maxValue: 100, minValue: 0, warnValue: 80)
        let result = QualityThresholdSet.evaluate(value: 200, threshold: threshold)
        XCTAssertEqual(result.status, .fail)
    }

    func testEvaluateFailMin() {
        let threshold = QualityThreshold(metricName: .sttLatencyMs, maxValue: nil, minValue: 10, warnValue: nil)
        let result = QualityThresholdSet.evaluate(value: 5, threshold: threshold)
        XCTAssertEqual(result.status, .fail)
    }

    // MARK: - percentile (QualityMetricStore)

    func testPercentileMedian() {
        let values = [1.0, 2.0, 3.0, 4.0, 5.0]
        let median = QualityMetricStore.percentile(values, 0.5)
        XCTAssertEqual(median, 3.0, accuracy: 0.001)
    }

    func testPercentileEmpty() {
        let result = QualityMetricStore.percentile([], 0.5)
        XCTAssertEqual(result, 0)
    }

    // MARK: - hexToRGB (OrbColor)

    func testHexToRGB() {
        let rgb = OrbColor.hexToRGB(0xFF0000)
        XCTAssertEqual(rgb.x, 1.0, accuracy: 0.001)
        XCTAssertEqual(rgb.y, 0.0, accuracy: 0.001)
        XCTAssertEqual(rgb.z, 0.0, accuracy: 0.001)
    }

    func testHexToRGBWhite() {
        let rgb = OrbColor.hexToRGB(0xFFFFFF)
        XCTAssertEqual(rgb.x, 1.0, accuracy: 0.001)
        XCTAssertEqual(rgb.y, 1.0, accuracy: 0.001)
        XCTAssertEqual(rgb.z, 1.0, accuracy: 0.001)
    }
}
