import XCTest
@testable import Fae

final class ConversationStateTaggingTests: XCTestCase {

    func testRemoveMessagesByTagPreservesOtherHistory() async {
        let state = ConversationStateTracker()

        await state.addUserMessage("proactive-user", tag: "proactive-1")
        await state.addAssistantMessage("proactive-assistant", tag: "proactive-1")
        await state.addUserMessage("normal-user")
        await state.addAssistantMessage("normal-assistant")

        await state.removeMessages(taggedWith: "proactive-1")

        let history = await state.history
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(history[0].content, "normal-user")
        XCTAssertEqual(history[1].content, "normal-assistant")
    }

    func testRemoveMessagesByTagRefreshesLastAssistantText() async {
        let state = ConversationStateTracker()

        await state.addAssistantMessage("older")
        await state.addAssistantMessage("proactive", tag: "proactive-2")

        await state.removeMessages(taggedWith: "proactive-2")

        let last = await state.lastAssistantText
        XCTAssertEqual(last, "older")
    }

    // MARK: - Phase G2 pinned-summary compression

    /// Evicted turns are BUFFERED for compaction, not silently dropped — the
    /// kept window is the hard-truncated tail, and the dropped prefix surfaces as
    /// pending compaction work.
    func testEvictedTurnsAreBufferedNotDroppedForCompaction() async {
        let state = ConversationStateTracker()
        await state.setMaxHistory(4)

        // Six messages ⇒ 2 evicted (oldest), 4 kept.
        for i in 0..<6 { await state.addUserMessage("m\(i)") }

        let history = await state.history
        XCTAssertEqual(history.count, 4, "kept window is the hard-truncated tail")
        XCTAssertEqual(history.map(\.content), ["m2", "m3", "m4", "m5"])

        let work = await state.pendingCompaction()
        XCTAssertEqual(
            work?.evicted.map(\.content), ["m0", "m1"],
            "the two oldest turns are buffered for compaction, not dropped")
        XCTAssertNil(work?.priorSummary, "no prior summary on the first compaction")
    }

    /// Applying a compaction result installs the pinned summary, records the
    /// covered count, and drains the buffered backlog.
    func testApplyCompactionResultInstallsPinnedSummaryAndDrainsBacklog() async {
        let state = ConversationStateTracker()
        await state.setMaxHistory(4)
        for i in 0..<6 { await state.addUserMessage("m\(i)") }

        let work = await state.pendingCompaction()
        XCTAssertEqual(work?.evicted.count, 2)

        await state.applyCompactionResult(summary: "user counted from 0 to 5", covered: 2)

        let pinned = await state.pinnedSummary
        XCTAssertEqual(pinned, "user counted from 0 to 5")
        let covered = await state.pinnedSummaryCoveredCount
        XCTAssertEqual(covered, 2)
        // Backlog drained ⇒ no further compaction work pending.
        let after = await state.pendingCompaction()
        XCTAssertNil(after)
        let remaining = await state.pendingEvictionCount()
        XCTAssertEqual(remaining, 0)
    }

    /// Hysteresis: once a summary exists, a FEW further evicted turns do NOT
    /// trigger a recompute — only after `recomputeEvictionThreshold` more.
    func testCompactionHysteresisGatesRecompaction() async {
        let state = ConversationStateTracker()
        await state.setMaxHistory(4)
        for i in 0..<6 { await state.addUserMessage("m\(i)") }
        await state.applyCompactionResult(summary: "s1", covered: 2)

        // A couple more evictions — below the threshold ⇒ still no recompute.
        for i in 6..<9 { await state.addUserMessage("m\(i)") }
        let evictedSoFar = await state.pendingEvictionCount()
        XCTAssertGreaterThan(evictedSoFar, 0, "more turns evicted")
        let belowThreshold = await state.pendingCompaction()
        XCTAssertNil(belowThreshold, "recompaction must wait for the hysteresis threshold")

        // Push evictions past the threshold ⇒ recompute becomes available, and it
        // carries the prior summary so the fold is cumulative.
        for i in 9..<(9 + ConversationStateTracker.recomputeEvictionThreshold) {
            await state.addUserMessage("m\(i)")
        }
        let work = await state.pendingCompaction()
        XCTAssertNotNil(work, "recompaction fires once the watermark is reached")
        XCTAssertEqual(work?.priorSummary, "s1", "re-compaction folds on top of the prior summary")
    }

    /// The compaction FALLBACK contract, at the state level: if the caller never
    /// applies a result (a compact failure), the turn already proceeded on the
    /// hard-truncated tail, no pinned summary is installed, and the backlog is
    /// RETAINED so a later attempt can still fold it — never dropped silently.
    func testFailedCompactionLeavesHardTruncatedHistoryAndRetainsBacklog() async {
        let state = ConversationStateTracker()
        await state.setMaxHistory(4)
        for i in 0..<6 { await state.addUserMessage("m\(i)") }

        let before = await state.pendingCompaction()
        XCTAssertEqual(before?.evicted.count, 2)

        // Simulate a compact failure: the caller does NOT applyCompactionResult.
        let history = await state.history
        XCTAssertEqual(history.count, 4, "turn proceeds on the hard-truncated window")
        let pinned = await state.pinnedSummary
        XCTAssertNil(pinned, "no summary installed on failure")
        // Backlog retained for retry.
        let retained = await state.pendingEvictionCount()
        XCTAssertEqual(retained, 2)
        let retry = await state.pendingCompaction()
        XCTAssertNotNil(retry, "failure retains the work for a retry")
    }
}
