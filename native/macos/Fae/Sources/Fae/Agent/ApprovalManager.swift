import Foundation

/// Manages tool approval requests via voice or button UI.
///
/// When a tool requires approval, the manager:
/// 1. Sends `.approvalRequested` via FaeEventBus → ApprovalOverlayView shows
/// 2. Waits for user response (voice "yes"/"no", button, or 58s timeout → auto-deny)
/// 3. Returns the approval decision
///
/// Replaces: `src/pipeline/voice_approval.rs`
actor ApprovalManager {
    private let eventBus: FaeEventBus
    private var pendingApprovals: [UInt64: CheckedContinuation<Bool, Never>] = [:]
    private var nextRequestId: UInt64 = 1

    static let timeoutSeconds: TimeInterval = 58

    init(eventBus: FaeEventBus) {
        self.eventBus = eventBus
    }

    /// Request approval for a tool execution.
    ///
    /// Shows the approval overlay and waits for a response.
    /// Returns `true` if approved, `false` if denied or timed out.
    func requestApproval(toolName: String, description: String) async -> Bool {
        let requestId = nextRequestId
        nextRequestId += 1

        eventBus.send(.approvalRequested(
            id: requestId,
            toolName: toolName,
            input: description
        ))

        // Wait for response with timeout.
        let approved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            pendingApprovals[requestId] = continuation

            // Start timeout task.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds * 1_000_000_000))
                self.resolveIfPending(requestId: requestId, approved: false)
            }
        }

        return approved
    }

    /// Resolve a pending approval (called from FaeCore when user responds).
    func resolve(requestId: UInt64, approved: Bool) {
        resolveIfPending(requestId: requestId, approved: approved)
        eventBus.send(.approvalResolved(id: requestId, approved: approved, source: "user"))
    }

    private func resolveIfPending(requestId: UInt64, approved: Bool) {
        if let continuation = pendingApprovals.removeValue(forKey: requestId) {
            continuation.resume(returning: approved)
        }
    }
}
