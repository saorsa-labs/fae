import XCTest
@testable import Fae

final class PipelineCoordinatorRelayReplyTests: XCTestCase {

    func testResolveRelayReplyPrefersCapturedTurnReply() {
        let resolved = PipelineCoordinator.resolveRelayReply(
            capturedReply: "Current remote reply",
            assistantCountBefore: 4,
            assistantCountAfter: 4,
            assistantHistoryAfter: "Older assistant turn"
        )

        XCTAssertEqual(resolved, "Current remote reply")
    }

    func testResolveRelayReplyFallsBackToNewAssistantHistoryEntry() {
        let resolved = PipelineCoordinator.resolveRelayReply(
            capturedReply: nil,
            assistantCountBefore: 2,
            assistantCountAfter: 3,
            assistantHistoryAfter: "Fresh history reply"
        )

        XCTAssertEqual(resolved, "Fresh history reply")
    }

    func testResolveRelayReplyReturnsNilWhenTurnDidNotProduceANewReply() {
        let resolved = PipelineCoordinator.resolveRelayReply(
            capturedReply: nil,
            assistantCountBefore: 5,
            assistantCountAfter: 5,
            assistantHistoryAfter: "Stale previous assistant turn"
        )

        XCTAssertNil(resolved)
    }
}
