import XCTest
@testable import Fae

final class PipelineCoordinatorPolicyTests: XCTestCase {
    func testToolModeUpgradePopupShownOnlyForActionableReasons() {
        XCTAssertTrue(PipelineCoordinator.shouldShowToolModeUpgradePopup(reasonCode: "owner_enrollment_required"))
        XCTAssertTrue(PipelineCoordinator.shouldShowToolModeUpgradePopup(reasonCode: "tool_not_called"))
        XCTAssertTrue(PipelineCoordinator.shouldShowToolModeUpgradePopup(reasonCode: "non-owner"))

        XCTAssertFalse(PipelineCoordinator.shouldShowToolModeUpgradePopup(reasonCode: "toolMode=off"))
        XCTAssertFalse(PipelineCoordinator.shouldShowToolModeUpgradePopup(reasonCode: "quick_voice_fast_path"))
        XCTAssertFalse(PipelineCoordinator.shouldShowToolModeUpgradePopup(reasonCode: "concierge_route"))
        XCTAssertFalse(PipelineCoordinator.shouldShowToolModeUpgradePopup(reasonCode: "unknown"))
    }
}
