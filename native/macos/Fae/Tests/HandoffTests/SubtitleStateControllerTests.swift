import XCTest
@testable import Fae

@MainActor
final class SubtitleStateControllerTests: XCTestCase {
    func testDismissThinkingSuppressesFurtherUpdatesUntilNextTurn() {
        let controller = SubtitleStateController()

        controller.appendToolActivity("Running calendar lookup")
        XCTAssertEqual(controller.thinkingText, "Running calendar lookup")
        XCTAssertTrue(controller.isThinking)

        controller.dismissThinkingUntilNextTurn()
        XCTAssertEqual(controller.thinkingText, "")
        XCTAssertFalse(controller.isThinking)

        controller.appendToolActivity("Still running")
        controller.appendThinkingText("Thinking...")
        XCTAssertEqual(controller.thinkingText, "")
        XCTAssertFalse(controller.isThinking)

        controller.clearThinking()
        controller.appendToolActivity("Next turn activity")
        XCTAssertEqual(controller.thinkingText, "Next turn activity")
        XCTAssertTrue(controller.isThinking)
    }
}
