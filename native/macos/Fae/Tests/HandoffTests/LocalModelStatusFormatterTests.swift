import XCTest
@testable import Fae

final class LocalModelStatusFormatterTests: XCTestCase {
    func testShortModelNameExtractsLastComponent() {
        XCTAssertEqual(
            LocalModelStatusFormatter.shortModelName("mlx-community/Qwen3.5-2B-4bit"),
            "Qwen3.5-2B-4bit"
        )
    }

    func testStackSummaryUsesLoadedModel() {
        let summary = LocalModelStatusFormatter.stackSummary(
            loadedModelId: "mlx-community/Qwen3.5-2B-4bit",
            preset: "auto"
        )
        XCTAssertEqual(summary, "Qwen3.5-2B-4bit")
    }

    func testStackSummaryFallsBackToPreset() {
        let summary = LocalModelStatusFormatter.stackSummary(
            loadedModelId: nil,
            preset: "qwen3_5_4b"
        )
        XCTAssertTrue(summary.contains("Qwen3.5"))
    }
}
