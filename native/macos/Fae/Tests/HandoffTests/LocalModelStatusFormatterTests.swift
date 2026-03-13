import XCTest
@testable import Fae

final class LocalModelStatusFormatterTests: XCTestCase {
    func testConciergeLabelShowsLoadingWhileWorkerIsRunning() {
        var config = FaeConfig()
        config.llm.dualModelEnabled = true
        config.llm.keepConciergeHot = true

        let plan = FaeConfig.recommendedLocalModelStack(
            config: config,
            totalMemoryBytes: UInt64(96) * 1024 * 1024 * 1024
        )

        let label = LocalModelStatusFormatter.conciergeLabel(
            plan: plan,
            loadedConciergeModelId: nil,
            conciergeLoaded: false,
            conciergeRuntime: "worker_process",
            conciergeWorkerLastError: nil
        )

        XCTAssertEqual(label, "saorsa1-concierge-pre-release (loading...)")
    }

    func testStackSummaryIncludesLoadedConciergeModel() {
        var config = FaeConfig()
        config.llm.dualModelEnabled = true
        config.llm.keepConciergeHot = true

        let plan = FaeConfig.recommendedLocalModelStack(
            config: config,
            totalMemoryBytes: UInt64(96) * 1024 * 1024 * 1024
        )

        let summary = LocalModelStatusFormatter.stackSummary(
            plan: plan,
            loadedOperatorModelId: "saorsa-labs/saorsa1-worker-pre-release",
            loadedConciergeModelId: "saorsa-labs/saorsa1-concierge-pre-release",
            conciergeLoaded: true,
            conciergeRuntime: "worker_process",
            conciergeWorkerLastError: nil
        )

        XCTAssertEqual(
            summary,
            "Operator: saorsa1-worker-pre-release · Concierge: saorsa1-concierge-pre-release"
        )
    }
}
