import XCTest
@testable import Fae

final class BatchApprovalTests: XCTestCase {

    // MARK: - Helpers

    private func makeManager(timeoutSeconds: TimeInterval = 5) -> ApprovalManager {
        ApprovalManager(eventBus: FaeEventBus(), timeoutSeconds: timeoutSeconds)
    }

    // MARK: - BatchApprovalRequest

    func testBatchApprovalRequestFields() {
        let batch = BatchApprovalRequest(
            batchId: "write-1",
            toolName: "write",
            count: 5,
            representativeDescription: "Write to /tmp/test"
        )
        XCTAssertEqual(batch.batchId, "write-1")
        XCTAssertEqual(batch.toolName, "write")
        XCTAssertEqual(batch.count, 5)
        XCTAssertEqual(batch.representativeDescription, "Write to /tmp/test")
    }

    // MARK: - Batch Grant Consumption

    func testBatchApprovalGrantsRemainingCount() async {
        let manager = makeManager()

        // Approve a batch of 3.
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            await manager.resolveBatch(batchId: "write-1", approved: true, source: "test")
        }

        let approved = await manager.requestBatchApproval(
            toolName: "write",
            count: 3,
            representativeDescription: "Write to /tmp/test"
        )
        XCTAssertTrue(approved, "Batch should be approved")

        // Now the next 2 individual requests should auto-approve from the batch grant.
        let second = await manager.requestApproval(toolName: "write", description: "Write /tmp/2")
        XCTAssertTrue(second, "Second request should auto-approve from batch grant")

        let third = await manager.requestApproval(toolName: "write", description: "Write /tmp/3")
        XCTAssertTrue(third, "Third request should auto-approve from batch grant")

        // Fourth request should NOT auto-approve (grant exhausted).
        let hasBatch = await manager.hasBatchGrant(for: "write")
        XCTAssertFalse(hasBatch, "Grant should be exhausted after 2 consumptions")
    }

    // MARK: - Batch Denial

    func testBatchDenialBlocksSubsequentRequests() async {
        let manager = makeManager()

        // Deny a batch.
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            await manager.resolveBatch(batchId: "bash-1", approved: false, source: "test")
        }

        let approved = await manager.requestBatchApproval(
            toolName: "bash",
            count: 5,
            representativeDescription: "Run command"
        )
        XCTAssertFalse(approved, "Batch should be denied")

        // Subsequent individual requests for same tool should auto-deny.
        let hasDenial = await manager.hasBatchDenial(for: "bash")
        XCTAssertTrue(hasDenial, "Batch denial should be active for bash")

        let second = await manager.requestApproval(toolName: "bash", description: "Run command 2")
        XCTAssertFalse(second, "Subsequent request should auto-deny from batch denial")
    }

    // MARK: - Single Count Falls Through

    func testBatchWithCountOneFallsThrough() async {
        let manager = makeManager()

        // Count = 1 should fall through to regular approval.
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            await manager.resolveMostRecent(approved: true, source: "test")
        }

        let approved = await manager.requestBatchApproval(
            toolName: "read",
            count: 1,
            representativeDescription: "Read /tmp/test"
        )
        XCTAssertTrue(approved, "Single-count batch should work like regular approval")
    }

    func testBatchWithCountZeroReturnsFalse() async {
        let manager = makeManager()
        let approved = await manager.requestBatchApproval(
            toolName: "read",
            count: 0,
            representativeDescription: "Read /tmp/test"
        )
        XCTAssertFalse(approved, "Zero-count batch should return false")
    }

    // MARK: - Clear Batch State

    func testClearBatchStateRemovesGrantsAndDenials() async {
        let manager = makeManager()

        // Set up a batch grant.
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await manager.resolveBatch(batchId: "write-1", approved: true, source: "test")
        }
        _ = await manager.requestBatchApproval(
            toolName: "write",
            count: 5,
            representativeDescription: "Write files"
        )

        let hasGrant = await manager.hasBatchGrant(for: "write")
        XCTAssertTrue(hasGrant, "Grant should exist before clear")

        // Clear batch state.
        await manager.clearBatchState()

        let hasGrantAfter = await manager.hasBatchGrant(for: "write")
        XCTAssertFalse(hasGrantAfter, "Grant should be cleared")
    }

    // MARK: - Manual-Only / Disaster Never Batched

    func testManualOnlyRequestsIgnoreBatchGrants() async {
        let manager = makeManager()

        // Set up a batch grant for "bash".
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await manager.resolveBatch(batchId: "bash-1", approved: true, source: "test")
        }
        _ = await manager.requestBatchApproval(
            toolName: "bash",
            count: 5,
            representativeDescription: "Run command"
        )

        // Manual-only request should NOT consume the batch grant.
        // It should go to the approval overlay instead.
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await manager.resolveMostRecent(approved: true, source: "test")
        }
        let manualApproved = await manager.requestApproval(
            toolName: "bash",
            description: "Manual command",
            manualOnly: true,
            isDisasterLevel: false
        )
        XCTAssertTrue(manualApproved, "Manual-only request should still be approvable")

        // The batch grant should still have remaining count (not consumed by manual-only).
        let hasGrant = await manager.hasBatchGrant(for: "bash")
        XCTAssertTrue(hasGrant, "Batch grant should not be consumed by manual-only request")
    }

    func testDisasterLevelRequestsIgnoreBatchGrants() async {
        let manager = makeManager()

        // Set up a batch grant for "bash".
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await manager.resolveBatch(batchId: "bash-1", approved: true, source: "test")
        }
        _ = await manager.requestBatchApproval(
            toolName: "bash",
            count: 5,
            representativeDescription: "Run command"
        )

        // Disaster-level request should NOT consume the batch grant.
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await manager.resolveMostRecent(approved: true, source: "test")
        }
        let disasterApproved = await manager.requestApproval(
            toolName: "bash",
            description: "Disaster command",
            manualOnly: true,
            isDisasterLevel: true
        )
        XCTAssertTrue(disasterApproved, "Disaster-level request should still be approvable")

        // The batch grant should still have remaining count.
        let hasGrant = await manager.hasBatchGrant(for: "bash")
        XCTAssertTrue(hasGrant, "Batch grant should not be consumed by disaster-level request")
    }

    // MARK: - Mixed Risk Rejection

    func testBatchGrantDoesNotCrossToolNames() async {
        let manager = makeManager()

        // Set up a batch grant for "write".
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await manager.resolveBatch(batchId: "write-1", approved: true, source: "test")
        }
        _ = await manager.requestBatchApproval(
            toolName: "write",
            count: 5,
            representativeDescription: "Write files"
        )

        // "edit" should NOT get auto-approved from "write" batch grant.
        let hasEditGrant = await manager.hasBatchGrant(for: "edit")
        XCTAssertFalse(hasEditGrant, "Batch grant for 'write' should not apply to 'edit'")
    }

    // MARK: - clearPendingApprovals clears batch state

    func testClearPendingApprovalsClearsBatchState() async {
        let manager = makeManager()

        // Set up batch state.
        Task {
            try? await Task.sleep(nanoseconds: 50_000_000)
            await manager.resolveBatch(batchId: "write-1", approved: true, source: "test")
        }
        _ = await manager.requestBatchApproval(
            toolName: "write",
            count: 3,
            representativeDescription: "Write files"
        )

        let hasGrant = await manager.hasBatchGrant(for: "write")
        XCTAssertTrue(hasGrant, "Grant should exist before clearPendingApprovals")

        await manager.clearPendingApprovals(source: "test_reset")

        let hasGrantAfter = await manager.hasBatchGrant(for: "write")
        XCTAssertFalse(hasGrantAfter, "Batch state should be cleared by clearPendingApprovals")
    }
}
