import CryptoKit
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
            lastCycleError: nil,
            deferralCount: 0,
            previousDirective: nil,
            metaOptKeptTotal: 0,
            metaOptTestedTotal: 0,
            metaOptLastRunAt: nil,
            metaOptConsecutiveNoImprovement: 0
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
            lastCycleError: nil,
            deferralCount: 0,
            previousDirective: nil,
            metaOptKeptTotal: 0,
            metaOptTestedTotal: 0,
            metaOptLastRunAt: nil,
            metaOptConsecutiveNoImprovement: 0
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
            lastCycleError: nil,
            deferralCount: 0,
            previousDirective: nil,
            metaOptKeptTotal: 0,
            metaOptTestedTotal: 0,
            metaOptLastRunAt: nil,
            metaOptConsecutiveNoImprovement: 0
        )
        XCTAssertTrue(AdapterDeploymentManager.shouldAutoDeploy(state: state))
    }

    // MARK: - Deploy

    /// P9/C4 (W4): deploy now requires a verifying gate receipt — mint one for a real
    /// candidate file and deploy that.
    private func makeReceiptCandidate(cycleId: String, key: SymmetricKey) throws -> (String, GateReceipt) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fae-adm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("adapter.gguf").path
        try "weights".write(toFile: path, atomically: true, encoding: .utf8)
        let receipt = try GateMinter.mint(
            cycleId: cycleId, candidatePath: path, kind: .gguf,
            measured: [.toolCalling: 3.0, .faeCapability: 1.0, .assistantFit: 2.0, .serialization: 0.0],
            evaluatorId: "DaemonABEvaluator", baseModelId: "gemma-test",
            evalSuiteVersion: "v1", mintedAt: "2026-06-22T00:00:00Z", using: key
        )
        return (path, receipt)
    }

    func testDeployPromotesReceiptCandidateAndConsumes() async throws {
        let store = try await makeTempStore()
        let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))
        var state = try await store.readState()
        state.currentAdapterPath = "/old/adapter"
        try await store.writeState(state)

        let (path, receipt) = try makeReceiptCandidate(cycleId: "adm-1", key: key)
        try await store.insertGateReceipt(receipt)
        try await AdapterDeploymentManager.deploy(receipt: receipt, store: store, verifyingWith: key)

        let updated = try await store.readState()
        XCTAssertEqual(updated.currentAdapterPath, path)
        XCTAssertEqual(updated.previousAdapterPath, "/old/adapter")
        let consumed = try await store.isGateReceiptConsumed(cycleId: "adm-1")
        XCTAssertTrue(consumed, "receipt consumed after deploy")
    }

    func testDeployRejectsConsumedReceipt() async throws {
        let store = try await makeTempStore()
        let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))
        let (_, receipt) = try makeReceiptCandidate(cycleId: "adm-2", key: key)
        try await store.insertGateReceipt(receipt)
        try await store.consumeGateReceipt(cycleId: "adm-2", at: "2026-06-22T00:00:00Z")

        do {
            try await AdapterDeploymentManager.deploy(receipt: receipt, store: store, verifyingWith: key)
            XCTFail("deploy must reject an already-consumed receipt")
        } catch ImprovementStoreError.receiptNotConsumable {
            // expected — atomic consume affected 0 rows (already consumed)
        }
    }

    /// A validly-signed receipt that was never STORED cannot deploy (closes the
    /// "signed offline, never evaluated" loophole) — P9/C4 W4.
    func testDeployRejectsUnstoredReceipt() async throws {
        let store = try await makeTempStore()
        let key = SymmetricKey(data: Data(repeating: 0x42, count: 32))
        let (_, receipt) = try makeReceiptCandidate(cycleId: "adm-3", key: key)
        // Do NOT insert the receipt into the store.
        do {
            try await AdapterDeploymentManager.deploy(receipt: receipt, store: store, verifyingWith: key)
            XCTFail("deploy must reject a receipt that was never stored")
        } catch ImprovementStoreError.receiptNotConsumable {
            // expected — atomic consume found no row to consume
        }
        let after = try await store.readState()
        XCTAssertNil(after.currentAdapterPath, "Nothing deployed")
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
