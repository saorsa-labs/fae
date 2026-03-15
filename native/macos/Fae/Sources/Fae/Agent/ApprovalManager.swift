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
    private var pendingDescriptions: [UInt64: String] = [:]
    private var pendingOrder: [UInt64] = []
    private var nextRequestId: UInt64 = 1

    static let timeoutSeconds: TimeInterval = 20
    private let timeoutSeconds: TimeInterval

    init(eventBus: FaeEventBus, timeoutSeconds: TimeInterval? = nil) {
        self.eventBus = eventBus
        self.timeoutSeconds = timeoutSeconds ?? Self.timeoutSeconds
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
            pendingDescriptions[requestId] = description
            pendingOrder.append(requestId)

            // Start timeout task.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(self.timeoutSeconds * 1_000_000_000))
                self.resolveTimeoutIfPending(requestId: requestId)
            }
        }

        return approved
    }

    /// Resolve a pending approval (called from FaeCore when user responds).
    func resolve(requestId: UInt64, approved: Bool, source: String = "user") {
        guard resolveIfPending(requestId: requestId, approved: approved) else { return }
        eventBus.send(.approvalResolved(id: requestId, approved: approved, source: source))
    }

    /// Resolve with a progressive approval decision (yes, no, always).
    func resolve(requestId: UInt64, decision: VoiceCommandParser.ApprovalDecision, source: String = "user") {
        let toolName = pendingToolNames[requestId]

        let approved: Bool
        switch decision {
        case .yes, .always:
            approved = true
        case .no:
            approved = false
        }

        guard resolveIfPending(requestId: requestId, approved: approved) else { return }
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

    @discardableResult
    private func resolveIfPending(requestId: UInt64, approved: Bool) -> Bool {
        pendingOrder.removeAll { $0 == requestId }
        pendingToolNames.removeValue(forKey: requestId)
        pendingDescriptions.removeValue(forKey: requestId)
        if let continuation = pendingApprovals.removeValue(forKey: requestId) {
            continuation.resume(returning: approved)
            return true
        }
        return false
    }

    private func resolveTimeoutIfPending(requestId: UInt64) {
        guard resolveIfPending(requestId: requestId, approved: false) else { return }
        eventBus.send(.approvalResolved(id: requestId, approved: false, source: "timeout"))
    }

    func pendingApprovalSnapshots() -> [[String: Any]] {
        pendingOrder.compactMap { requestId in
            guard let toolName = pendingToolNames[requestId] else { return nil }
            return [
                "id": requestId,
                "tool": toolName,
                "summary": pendingDescriptions[requestId] ?? "",
            ]
        }
    }

    func mostRecentPendingApprovalID() -> UInt64? {
        pendingOrder.last
    }

    func clearPendingApprovals(source: String = "reset") {
        let pendingIDs = pendingOrder
        for requestId in pendingIDs {
            guard resolveIfPending(requestId: requestId, approved: false) else { continue }
            eventBus.send(.approvalResolved(id: requestId, approved: false, source: source))
        }
    }
}
