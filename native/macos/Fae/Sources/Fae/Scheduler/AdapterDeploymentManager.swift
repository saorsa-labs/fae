import CryptoKit
import Foundation

// MARK: - DeploymentProposal

/// A proposal to deploy a newly-trained LoRA adapter.
///
/// Generated after the evaluation phase passes. Contains the adapter path,
/// a human-readable summary of improvements, metrics comparison, and a
/// personal message for the morning briefing.
struct DeploymentProposal: Sendable {
    /// Path to the candidate LoRA adapter.
    let adapterPath: String

    /// Human-readable summary of what improved (e.g. "tool calling accuracy +5%").
    let improvementSummary: String

    /// Formatted metrics comparison (baseline vs post-training).
    let metricsComparison: String

    /// Personal message for the user (e.g. "I trained on 25 corrections from this week...").
    let personalMessage: String

    /// ISO-8601 timestamp when the proposal was generated.
    let generatedAt: String
}

// MARK: - AdapterDeploymentManager

/// Manages adapter deployment decisions: proposals, auto-deploy, and rollback.
///
/// The deployment flow:
/// 1. After evaluation, `generateProposal()` creates a `DeploymentProposal`
/// 2. `shouldAutoDeploy()` checks if the user has approved enough cycles (>= 5)
/// 3. If auto-deploy: `deploy()` immediately applies the adapter
/// 4. If not: the proposal is held for user approval in the morning briefing
/// 5. `rollback()` can swap back to the previous adapter if issues arise
///
/// ## Earned Auto-Deploy
/// After the user explicitly approves 5 improvement cycles, Fae earns the trust
/// to auto-deploy future adapters without asking. This counter is tracked in
/// `ImprovementState.userApprovedCycles`.
enum AdapterDeploymentManager {

    /// Number of user-approved cycles required before auto-deploy is earned.
    static let autoDeployThreshold = 5

    // MARK: - Proposal Generation

    /// Generate a deployment proposal after a successful evaluation.
    ///
    /// - Parameters:
    ///   - adapterPath: Path to the candidate adapter.
    ///   - feedbackCount: Number of feedback events that went into training.
    ///   - correctionCount: Number of correction events specifically.
    ///   - baselineAccuracy: Baseline tool-calling accuracy (percentage).
    ///   - postAccuracy: Post-training tool-calling accuracy (percentage).
    /// - Returns: A `DeploymentProposal` ready for user presentation or auto-deploy.
    static func generateProposal(
        adapterPath: String,
        feedbackCount: Int,
        correctionCount: Int,
        baselineAccuracy: Double?,
        postAccuracy: Double?
    ) -> DeploymentProposal {
        let delta: String
        if let base = baselineAccuracy, let post = postAccuracy {
            let diff = post - base
            let sign = diff >= 0 ? "+" : ""
            delta = "tool calling accuracy \(sign)\(String(format: "%.1f", diff))% (\(String(format: "%.1f", base))% -> \(String(format: "%.1f", post))%)"
        } else {
            delta = "metrics pending evaluation"
        }

        let personal = "I trained on \(feedbackCount) interactions from recent conversations, " +
            "including \(correctionCount) corrections you gave me. " +
            "Would you like me to apply this update?"

        let comparison: String
        if let base = baselineAccuracy, let post = postAccuracy {
            comparison = "Baseline: \(String(format: "%.1f", base))% | Post-training: \(String(format: "%.1f", post))%"
        } else {
            comparison = "No metrics comparison available yet"
        }

        return DeploymentProposal(
            adapterPath: adapterPath,
            improvementSummary: delta,
            metricsComparison: comparison,
            personalMessage: personal,
            generatedAt: ISO8601DateFormatter().string(from: Date())
        )
    }

    // MARK: - Auto-Deploy Decision

    /// Determine whether Fae has earned auto-deploy trust.
    ///
    /// Auto-deploy is granted after the user has manually approved at least
    /// `autoDeployThreshold` (5) improvement cycles.
    ///
    /// - Parameter state: The current improvement state.
    /// - Returns: `true` if auto-deploy is allowed.
    static func shouldAutoDeploy(state: ImprovementState) -> Bool {
        state.userApprovedCycles >= autoDeployThreshold
    }

    // MARK: - Deploy

    /// Deploy a **receipt-gated** candidate by updating the improvement state.
    ///
    /// Moves the current adapter to `previousAdapterPath` and promotes the receipt's
    /// candidate to `currentAdapterPath`. Does NOT trigger model reload — the caller is
    /// responsible for signalling the pipeline to swap adapters.
    ///
    /// P9/C4 (W4, F4): the previous `deploy(adapterPath:)` wrote an ARBITRARY path with
    /// no gate. It now requires a verifying, unconsumed `GateReceipt` — there is no longer
    /// any path in the codebase that deploys an un-gated adapter. The autonomous loop
    /// deploys via `ImprovementCycleCoordinator.performDeploy`; this util mirrors that
    /// gate for out-of-loop/manual use.
    ///
    /// - Parameters:
    ///   - receipt: A receipt that passed the eval gate for its `candidatePath`.
    ///   - store: The improvement store to update.
    ///   - key: HMAC key to verify the receipt (production: the Keychain key).
    static func deploy(
        receipt: GateReceipt, store: ImprovementStore, verifyingWith key: SymmetricKey
    ) async throws {
        try GateReceiptVerifier.verify(
            receipt, expectedCandidatePath: receipt.candidatePath, using: key
        )
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.previousAdapterPath = state.currentAdapterPath
        state.currentAdapterPath = receipt.candidatePath
        // Atomic promote + consume: requires a STORED, unconsumed receipt row or the whole
        // transaction rolls back (throws `receiptNotConsumable`). A merely signed receipt
        // object that was never persisted by an evaluator cannot deploy.
        try await store.promoteAndConsumeReceipt(
            state: state, cycleId: receipt.cycleId, at: ISO8601DateFormatter().string(from: Date())
        )
        NSLog("AdapterDeploymentManager: deployed receipt-gated adapter at %@", receipt.candidatePath)
    }

    // MARK: - Rollback

    /// Roll back to the previous adapter.
    ///
    /// Swaps `currentAdapterPath` and `previousAdapterPath`. If there is no
    /// previous adapter, clears the current adapter (returns to base model).
    ///
    /// - Parameter store: The improvement store to update.
    static func rollback(store: ImprovementStore) async throws {
        try await store.ensureStateRow()
        var state = try await store.readState()
        let current = state.currentAdapterPath
        state.currentAdapterPath = state.previousAdapterPath
        state.previousAdapterPath = current
        try await store.writeState(state)
        NSLog(
            "AdapterDeploymentManager: rolled back to %@",
            state.currentAdapterPath ?? "base model"
        )
    }

    // MARK: - User Approval

    /// Record that the user approved a deployment, incrementing the trust counter.
    ///
    /// After `autoDeployThreshold` approvals, future cycles auto-deploy.
    ///
    /// - Parameter store: The improvement store to update.
    static func recordApproval(store: ImprovementStore) async throws {
        try await store.ensureStateRow()
        var state = try await store.readState()
        state.userApprovedCycles += 1
        try await store.writeState(state)
        NSLog(
            "AdapterDeploymentManager: user approved cycle (%d/%d for auto-deploy)",
            state.userApprovedCycles, autoDeployThreshold
        )
    }
}
