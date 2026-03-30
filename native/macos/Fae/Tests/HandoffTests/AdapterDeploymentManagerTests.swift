import XCTest
@testable import Fae

final class AdapterDeploymentManagerTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempStore() async throws -> ImprovementStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("improvement.db")
        let store = ImprovementStore()
        try await store.open(at: url)
        try await store.ensureStateRow()
        return store
    }

    // MARK: - Proposal Generation

    func testGenerateProposalWithMetrics() async throws {
        let proposal = AdapterDeploymentManager.generateProposal(
            adapterPath: "/tmp/adapter",
            feedbackCount: 25,
            correctionCount: 8,
            baselineAccuracy: 85.0,
            postAccuracy: 92.5
        )

        XCTAssertEqual(proposal.adapterPath, "/tmp/adapter")
        XCTAssertTrue(proposal.improvementSummary.contains("+7.5%"))
        XCTAssertTrue(proposal.metricsComparison.contains("85.0%"))
        XCTAssertTrue(proposal.metricsComparison.contains("92.5%"))
        XCTAssertTrue(proposal.personalMessage.contains("25 interactions"))
        XCTAssertTrue(proposal.personalMessage.contains("8 corrections"))
        XCTAssertFalse(proposal.generatedAt.isEmpty)
    }

    func testGenerateProposalWithoutMetrics() async throws {
        let proposal = AdapterDeploymentManager.generateProposal(
            adapterPath: "/tmp/adapter",
            feedbackCount: 30,
            correctionCount: 10,
            baselineAccuracy: nil,
            postAccuracy: nil
        )

        XCTAssertTrue(proposal.improvementSummary.contains("pending"))
        XCTAssertTrue(proposal.metricsComparison.contains("No metrics"))
    }

    // MARK: - Auto-Deploy Decision

    func testShouldAutoDeployFalseWhenBelowThreshold() async throws {
        let state = ImprovementState(
            id: 1,
            cycleState: "idle",
            lastCycleAt: nil,
            completedCycles: 3,
            userApprovedCycles: 4,
            currentAdapterPath: nil,
            previousAdapterPath: nil,
            trainingStartedAt: nil,
            lastCycleError: nil
        )
        XCTAssertFalse(AdapterDeploymentManager.shouldAutoDeploy(state: state))
    }

    func testShouldAutoDeployTrueWhenAtThreshold() async throws {
        let state = ImprovementState(
            id: 1,
            cycleState: "idle",
            lastCycleAt: nil,
            completedCycles: 5,
            userApprovedCycles: 5,
            currentAdapterPath: nil,
            previousAdapterPath: nil,
            trainingStartedAt: nil,
            lastCycleError: nil
        )
        XCTAssertTrue(AdapterDeploymentManager.shouldAutoDeploy(state: state))
    }

    func testShouldAutoDeployTrueWhenAboveThreshold() async throws {
        let state = ImprovementState(
            id: 1,
            cycleState: "idle",
            lastCycleAt: nil,
            completedCycles: 10,
            userApprovedCycles: 8,
            currentAdapterPath: nil,
            previousAdapterPath: nil,
            trainingStartedAt: nil,
            lastCycleError: nil
        )
        XCTAssertTrue(AdapterDeploymentManager.shouldAutoDeploy(state: state))
    }

    // MARK: - Deploy

    func testDeployUpdatesAdapterPaths() async throws {
        let store = try await makeTempStore()

        var state = try await store.readState()
        state.currentAdapterPath = "/old/adapter"
        try await store.writeState(state)

        try await AdapterDeploymentManager.deploy(adapterPath: "/new/adapter", store: store)

        let updated = try await store.readState()
        XCTAssertEqual(updated.currentAdapterPath, "/new/adapter")
        XCTAssertEqual(updated.previousAdapterPath, "/old/adapter")
    }

    func testDeployFromBaseModel() async throws {
        let store = try await makeTempStore()

        try await AdapterDeploymentManager.deploy(adapterPath: "/first/adapter", store: store)

        let updated = try await store.readState()
        XCTAssertEqual(updated.currentAdapterPath, "/first/adapter")
        XCTAssertNil(updated.previousAdapterPath)
    }

    // MARK: - Rollback

    func testRollbackSwapsPaths() async throws {
        let store = try await makeTempStore()

        var state = try await store.readState()
        state.currentAdapterPath = "/v2/adapter"
        state.previousAdapterPath = "/v1/adapter"
        try await store.writeState(state)

        try await AdapterDeploymentManager.rollback(store: store)

        let updated = try await store.readState()
        XCTAssertEqual(updated.currentAdapterPath, "/v1/adapter")
        XCTAssertEqual(updated.previousAdapterPath, "/v2/adapter")
    }

    func testRollbackWithNoPreviousAdapter() async throws {
        let store = try await makeTempStore()

        var state = try await store.readState()
        state.currentAdapterPath = "/adapter"
        state.previousAdapterPath = nil
        try await store.writeState(state)

        try await AdapterDeploymentManager.rollback(store: store)

        let updated = try await store.readState()
        XCTAssertNil(updated.currentAdapterPath)
        XCTAssertEqual(updated.previousAdapterPath, "/adapter")
    }

    // MARK: - User Approval

    func testRecordApprovalIncrementsCounter() async throws {
        let store = try await makeTempStore()

        let before = try await store.readState()
        XCTAssertEqual(before.userApprovedCycles, 0)

        try await AdapterDeploymentManager.recordApproval(store: store)

        let after = try await store.readState()
        XCTAssertEqual(after.userApprovedCycles, 1)
    }

    func testMultipleApprovalsReachAutoDeployThreshold() async throws {
        let store = try await makeTempStore()

        for _ in 0..<5 {
            try await AdapterDeploymentManager.recordApproval(store: store)
        }

        let state = try await store.readState()
        XCTAssertEqual(state.userApprovedCycles, 5)
        XCTAssertTrue(AdapterDeploymentManager.shouldAutoDeploy(state: state))
    }
}
