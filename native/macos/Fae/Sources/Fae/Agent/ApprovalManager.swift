import Foundation

/// Manages tool approval requests via voice or button UI.
///
/// When a tool requires approval, the manager:
/// 1. Sends `.approvalRequested` via FaeEventBus → ApprovalOverlayView shows
/// 2. Waits for user response (yes/no/always/approveAllReadOnly/approveAll)
/// 3. Returns the approval decision
/// 4. Persists escalation decisions to `ApprovedToolsStore`
///
/// Replaces: `src/pipeline/voice_approval.rs`
actor ApprovalManager {
    private let eventBus: FaeEventBus
    private var pendingApprovals: [UInt64: CheckedContinuation<Bool, Never>] = [:]
    private var pendingToolNames: [UInt64: String] = [:]
    private var pendingOrder: [UInt64] = []
    private var nextRequestId: UInt64 = 1

    static let timeoutSeconds: TimeInterval = 20

    init(eventBus: FaeEventBus) {
        self.eventBus = eventBus
    }

    /// Request approval for a tool execution.
    ///
    /// Shows the approval overlay and waits for a response.
    /// Returns `true` if approved, `false` if denied or timed out.
    ///
    /// - `manualOnly`: When true, the overlay suppresses voice-approval and "Always"/"Allow All" options.
    ///   Only a deliberate physical button press can approve. Set by `DamageControlPolicy`.
    /// - `isDisasterLevel`: When true, the overlay shows the red DISASTER WARNING variant.
    func requestApproval(
        toolName: String,
        description: String,
        manualOnly: Bool = false,
        isDisasterLevel: Bool = false
    ) async -> Bool {
        let requestId = nextRequestId
        nextRequestId += 1

        eventBus.send(.approvalRequested(
            id: requestId,
            toolName: toolName,
            input: description,
            manualOnly: manualOnly,
            isDisasterLevel: isDisasterLevel
        ))

        // Wait for response with timeout.
        let approved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            pendingApprovals[requestId] = continuation
            pendingToolNames[requestId] = toolName
            pendingOrder.append(requestId)

            // Start timeout task.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(Self.timeoutSeconds * 1_000_000_000))
                self.resolveIfPending(requestId: requestId, approved: false)
            }
        }

        return approved
    }

    /// Resolve a pending approval (called from FaeCore when user responds).
    func resolve(requestId: UInt64, approved: Bool, source: String = "user") {
        resolveIfPending(requestId: requestId, approved: approved)
        eventBus.send(.approvalResolved(id: requestId, approved: approved, source: source))
    }

    /// Resolve with a progressive approval decision (always, approveAllReadOnly, approveAll).
    func resolve(requestId: UInt64, decision: VoiceCommandParser.ApprovalDecision, source: String = "user") {
        let toolName = pendingToolNames[requestId]

        let approved: Bool
        switch decision {
        case .yes, .always, .approveAllReadOnly, .approveAll:
            approved = true
        case .no:
            approved = false
        }

        resolveIfPending(requestId: requestId, approved: approved)
        eventBus.send(.approvalResolved(id: requestId, approved: approved, source: source))

        // Persist escalation decisions.
        Task {
            let store = ApprovedToolsStore.shared
            let logger = SecurityEventLogger.shared

            switch decision {
            case .always:
                if let toolName {
                    await store.approveTool(toolName)
                    await logger.log(
                        event: "progressive_approval",
                        toolName: toolName,
                        decision: "always",
                        reasonCode: "user_granted_always"
                    )
                }

            case .approveAllReadOnly:
                await store.setApproveAllReadonly(true)
                await logger.log(
                    event: "progressive_approval",
                    toolName: toolName ?? "unknown",
                    decision: "approve_all_readonly",
                    reasonCode: "user_granted_approve_all_readonly"
                )

            case .approveAll:
                await store.setApproveAll(true)
                await logger.log(
                    event: "progressive_approval",
                    toolName: toolName ?? "unknown",
                    decision: "approve_all",
                    reasonCode: "user_granted_approve_all"
                )

            case .yes, .no:
                break // No persistence needed
            }
        }
    }

    /// Resolve the most recent pending approval (used by voice yes/no).
    @discardableResult
    func resolveMostRecent(approved: Bool, source: String = "voice") -> Bool {
        guard let requestId = pendingOrder.last else { return false }
        resolve(requestId: requestId, approved: approved, source: source)
        return true
    }

    /// Resolve the most recent pending approval with a progressive decision.
    @discardableResult
    func resolveMostRecent(decision: VoiceCommandParser.ApprovalDecision, source: String = "voice") -> Bool {
        guard let requestId = pendingOrder.last else { return false }
        resolve(requestId: requestId, decision: decision, source: source)
        return true
    }

    private func resolveIfPending(requestId: UInt64, approved: Bool) {
        pendingOrder.removeAll { $0 == requestId }
        pendingToolNames.removeValue(forKey: requestId)
        if let continuation = pendingApprovals.removeValue(forKey: requestId) {
            continuation.resume(returning: approved)
        }
    }
}
