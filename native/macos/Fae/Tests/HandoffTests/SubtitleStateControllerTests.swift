import XCTest
@testable import Fae

@MainActor
final class SubtitleStateControllerTests: XCTestCase {
    func testPersistentToolMessagesCanBeClearedAndReplaced() {
        let controller = SubtitleStateController()

        controller.showPersistentToolMessage("Running calendar lookup")
        XCTAssertEqual(controller.toolText, "Running calendar lookup")

        controller.clearToolMessage()
        XCTAssertEqual(controller.toolText, "")

        controller.showPersistentToolMessage("Next turn activity")
        XCTAssertEqual(controller.toolText, "Next turn activity")
    }
}
