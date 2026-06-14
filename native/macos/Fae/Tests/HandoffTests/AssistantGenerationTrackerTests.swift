import XCTest
@testable import Fae

final class AssistantGenerationTrackerTests: XCTestCase {
    func testOverlappingSilentProactiveGenerationsLeaveThinkingFalseAtQuiescence() {
        var tracker = AssistantGenerationTracker()
        let first = UUID()
        let second = UUID()

        tracker.begin(first, visibility: .silentBackground)
        XCTAssertEqual(tracker.activeGenerationID, first)
        XCTAssertFalse(tracker.shouldShowAssistantGenerating(awaitingApproval: false))

        tracker.begin(second, visibility: .silentBackground)
        XCTAssertEqual(tracker.activeGenerationID, second)
        XCTAssertFalse(tracker.shouldShowAssistantGenerating(awaitingApproval: false))

        tracker.end(first)
        XCTAssertEqual(tracker.activeGenerationID, second)
        XCTAssertFalse(tracker.shouldShowAssistantGenerating(awaitingApproval: false))

        tracker.end(second)
        XCTAssertNil(tracker.activeGenerationID)
        XCTAssertFalse(tracker.hasActiveGeneration)
        XCTAssertFalse(tracker.shouldShowAssistantGenerating(awaitingApproval: false))
    }

    func testStaleVisibleGenerationDoesNotClearNewerVisibleGeneration() {
        var tracker = AssistantGenerationTracker()
        let older = UUID()
        let newer = UUID()

        tracker.begin(older, visibility: .visible)
        tracker.begin(newer, visibility: .visible)

        tracker.end(older)
        XCTAssertEqual(tracker.activeGenerationID, newer)
        XCTAssertTrue(tracker.shouldShowAssistantGenerating(awaitingApproval: false))

        tracker.end(newer)
        XCTAssertNil(tracker.activeGenerationID)
        XCTAssertFalse(tracker.shouldShowAssistantGenerating(awaitingApproval: false))
    }

    func testVisibleEndingClearsThinkingWhenOnlySilentGenerationRemains() {
        var tracker = AssistantGenerationTracker()
        let visible = UUID()
        let silent = UUID()

        tracker.begin(silent, visibility: .silentBackground)
        tracker.begin(visible, visibility: .visible)
        XCTAssertTrue(tracker.shouldShowAssistantGenerating(awaitingApproval: false))

        tracker.end(visible)
        XCTAssertNil(tracker.activeGenerationID)
        XCTAssertTrue(tracker.hasActiveGeneration)
        XCTAssertFalse(tracker.shouldShowAssistantGenerating(awaitingApproval: false))

        tracker.end(silent)
        XCTAssertNil(tracker.activeGenerationID)
        XCTAssertFalse(tracker.shouldShowAssistantGenerating(awaitingApproval: false))
    }

    func testEndingNewestGenerationDoesNotResurrectSupersededOlderGeneration() {
        var tracker = AssistantGenerationTracker()
        let older = UUID()
        let newer = UUID()

        tracker.begin(older, visibility: .visible)
        tracker.begin(newer, visibility: .visible)
        tracker.end(newer)

        XCTAssertNil(tracker.activeGenerationID)
        XCTAssertTrue(tracker.hasActiveGeneration)
        XCTAssertFalse(tracker.shouldShowAssistantGenerating(awaitingApproval: false))

        tracker.end(older)
        XCTAssertNil(tracker.activeGenerationID)
        XCTAssertFalse(tracker.hasActiveGeneration)
        XCTAssertFalse(tracker.shouldShowAssistantGenerating(awaitingApproval: false))
    }

    func testAwaitingApprovalKeepsThinkingVisibleUntilApprovalClears() {
        var tracker = AssistantGenerationTracker()
        let visible = UUID()

        tracker.begin(visible, visibility: .visible)
        tracker.end(visible)

        XCTAssertTrue(tracker.shouldShowAssistantGenerating(awaitingApproval: true))
        XCTAssertFalse(tracker.shouldShowAssistantGenerating(awaitingApproval: false))
    }
}
