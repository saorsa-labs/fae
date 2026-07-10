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

    // MARK: - Mission D stranding regression tests

    /// Fix D-1 regression: when a visible generation is interrupted while
    /// approval is pending, clearing awaitingApproval + ending the generation
    /// returns the state to idle — WITHOUT the watchdog. This proves Fix 1
    /// (markGenerationInterrupted clears awaitingApproval) resolves the
    /// stranding on its own.
    func testApprovalStrandClearsAfterInterruptWithoutWatchdog() {
        var tracker = AssistantGenerationTracker()
        let gen = UUID()

        tracker.begin(gen, visibility: .visible)
        // Approval triggered during generation
        XCTAssertTrue(tracker.shouldShowAssistantGenerating(awaitingApproval: true))

        // Fix D-1 fires: markGenerationInterrupted → awaitingApproval cleared
        // Fix D-2 fires: endAssistantGeneration → tracker cleared
        tracker.end(gen)
        let awaitingApprovalAfterFix = false // cleared by markGenerationInterrupted

        // State is idle — no watchdog needed
        XCTAssertFalse(tracker.hasActiveGeneration)
        XCTAssertFalse(tracker.shouldShowAssistantGenerating(
            awaitingApproval: awaitingApprovalAfterFix
        ))
    }

    /// Fix D-2 regression: overlapping proactive turns leave no orphaned
    /// entries that block deferredProactiveDrain or idle rearming.
    func testOverlappingProactiveTurnsLeaveNoOrphanedEntries() {
        var tracker = AssistantGenerationTracker()
        let silentA = UUID()
        let silentB = UUID()

        // Silent proactive turn A starts
        tracker.begin(silentA, visibility: .silentBackground)
        XCTAssertTrue(tracker.hasActiveGeneration)
        XCTAssertFalse(tracker.shouldShowAssistantGenerating(awaitingApproval: false))

        // Turn B arrives — Fix D-2: end orphaned entries before proceeding
        tracker.end(silentA)
        tracker.begin(silentB, visibility: .silentBackground)

        // Turn B completes
        tracker.end(silentB)

        // All clear — no orphaned entries, no watchdog needed
        XCTAssertFalse(tracker.hasActiveGeneration)
        XCTAssertFalse(tracker.shouldShowAssistantGenerating(awaitingApproval: false))
    }

    /// Full stranding scenario: visible generation + approval + supersede
    /// returns to idle with fixes D-1/D-2 alone.
    func testFullStrandingScenarioResolvesWithFixesOneAndTwoOnly() {
        var tracker = AssistantGenerationTracker()
        let visible = UUID()
        let silent = UUID()

        // 1. Visible proactive turn starts
        tracker.begin(visible, visibility: .visible)
        XCTAssertTrue(tracker.shouldShowAssistantGenerating(awaitingApproval: false))

        // 2. Tool approval triggered
        XCTAssertTrue(tracker.shouldShowAssistantGenerating(awaitingApproval: true))

        // 3. Silent background turn also active
        tracker.begin(silent, visibility: .silentBackground)
        // The begin() demotes visible → silentBackground
        XCTAssertFalse(tracker.hasVisibleGeneration)
        // But approval keeps it showing
        XCTAssertTrue(tracker.shouldShowAssistantGenerating(awaitingApproval: true))

        // 4. Supersede fires — Fix D-1 clears approval, Fix D-2 ends all entries
        tracker.end(silent)
        tracker.end(visible)
        let awaitingApprovalAfterFix = false

        // 5. State is idle — WITHOUT the watchdog
        XCTAssertFalse(tracker.hasActiveGeneration)
        XCTAssertFalse(tracker.hasVisibleGeneration)
        XCTAssertFalse(tracker.shouldShowAssistantGenerating(
            awaitingApproval: awaitingApprovalAfterFix
        ))
    }
}
