import Foundation

// MARK: - ImprovementHealthReport

/// A structured health report for the autonomous improvement loop.
///
/// Used by the self-diagnostic skill to surface improvement cycle status
/// without requiring raw database access.
struct ImprovementHealthReport: Sendable {
    /// Current cycle state (idle, collecting, training, etc.).
    let cycleState: String
    /// Total number of completed improvement cycles.
    let completedCycles: Int
    /// Number of user-approved cycles (for auto-deploy threshold).
    let userApprovedCycles: Int
    /// Current consecutive CONCERN deferral count.
    let deferralCount: Int
    /// ISO-8601 timestamp of the last completed cycle.
    let lastCycleAt: String?
    /// Error message from the last cycle, if any.
    let lastCycleError: String?
    /// Number of unconsumed feedback events waiting for the next cycle.
    let pendingFeedbackCount: Int
    /// Number of unconsumed correction events.
    let pendingCorrectionCount: Int
    /// Shadow evaluation stats: base wins, adapter wins, ties.
    let shadowEvalStats: ShadowEvalStats
    /// Whether auto-deploy has been earned (>= 5 approved cycles).
    let autoDeployEarned: Bool
    /// Current adapter path (nil = base model).
    let currentAdapterPath: String?
    /// Whether a previous directive exists for rollback.
    let directiveRollbackAvailable: Bool

    /// Shadow evaluation win/loss counts.
    struct ShadowEvalStats: Sendable {
        let baseWins: Int
        let adapterWins: Int
        let ties: Int
    }
}

// MARK: - ImprovementHealthReporter

/// Generates health reports for the autonomous improvement loop.
///
/// Reads from `ImprovementStore` to assemble a snapshot of the improvement
/// system's current state. Used by the self-diagnostic skill.
///
/// ## Usage
/// ```swift
/// let report = try await ImprovementHealthReporter.generateReport(store: improvementStore)
/// ```
enum ImprovementHealthReporter {

    /// Generate a health report from the current store state.
    ///
    /// - Parameter store: The `ImprovementStore` to read from.
    /// - Returns: An `ImprovementHealthReport` with current state and statistics.
    static func generateReport(store: ImprovementStore) async throws -> ImprovementHealthReport {
        try await store.ensureStateRow()
        let state = try await store.readState()
        let pendingCount = try await store.pendingFeedbackCount()
        let correctionCount = try await store.correctionFeedbackCount()
        let shadowCounts = try await store.shadowEvalCounts()

        return ImprovementHealthReport(
            cycleState: state.cycleState,
            completedCycles: state.completedCycles,
            userApprovedCycles: state.userApprovedCycles,
            deferralCount: state.deferralCount,
            lastCycleAt: state.lastCycleAt,
            lastCycleError: state.lastCycleError,
            pendingFeedbackCount: pendingCount,
            pendingCorrectionCount: correctionCount,
            shadowEvalStats: ImprovementHealthReport.ShadowEvalStats(
                baseWins: shadowCounts.baseWins,
                adapterWins: shadowCounts.adapterWins,
                ties: shadowCounts.ties
            ),
            autoDeployEarned: state.userApprovedCycles >= ImprovementCycleCoordinator.minCyclesForAutoDeploy,
            currentAdapterPath: state.currentAdapterPath,
            directiveRollbackAvailable: state.previousDirective != nil
        )
    }

    /// Format a health report as a dictionary suitable for DiagnosticsManager.
    ///
    /// - Parameter report: The report to format.
    /// - Returns: A string-keyed dictionary with all report fields.
    static func formatAsDictionary(_ report: ImprovementHealthReport) -> [String: String] {
        var dict: [String: String] = [
            "cycle_state": report.cycleState,
            "completed_cycles": "\(report.completedCycles)",
            "user_approved_cycles": "\(report.userApprovedCycles)",
            "deferral_count": "\(report.deferralCount)",
            "pending_feedback": "\(report.pendingFeedbackCount)",
            "pending_corrections": "\(report.pendingCorrectionCount)",
            "auto_deploy_earned": report.autoDeployEarned ? "yes" : "no",
            "directive_rollback": report.directiveRollbackAvailable ? "available" : "none",
            "shadow_eval": "base=\(report.shadowEvalStats.baseWins) adapter=\(report.shadowEvalStats.adapterWins) tie=\(report.shadowEvalStats.ties)",
        ]

        if let lastCycle = report.lastCycleAt {
            dict["last_cycle_at"] = lastCycle
        }
        if let error = report.lastCycleError {
            dict["last_cycle_error"] = error
        }
        if let adapter = report.currentAdapterPath {
            dict["current_adapter"] = adapter
        }

        return dict
    }
}
