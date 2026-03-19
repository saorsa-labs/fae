import Foundation

/// A batch approval request groups multiple identical-tool-name actions into
/// a single user decision, avoiding N popups for N loop iterations.
///
/// Batch approval is **never** used for manual-only or disaster-level requests;
/// those always go through individual approval to preserve their elevated
/// scrutiny semantics.
struct BatchApprovalRequest: Sendable {
    /// Unique identifier for this batch.
    let batchId: String
    /// The tool name shared by all grouped actions.
    let toolName: String
    /// Number of pending actions in the batch.
    let count: Int
    /// Representative description (from the first action).
    let representativeDescription: String
}

/// Manages tool approval requests via voice or button UI.
///
/// When a tool requires approval, the manager:
/// 1. Sends `.approvalRequested` via FaeEventBus → ApprovalOverlayView shows
/// 2. Waits for user response (yes/no/always/approveAllReadOnly/approveAll)
/// 3. Returns the approval decision
/// 4. Persists escalation decisions to `ApprovedToolsStore`
///
/// **Batch approval**: When a script loops and triggers N identical tool
/// approvals, the manager groups them into a single ``BatchApprovalRequest``
/// instead of showing N individual popups. The user sees "Tool X wants to
/// run N times" and can Allow All or Deny All.
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

    // MARK: - Batch Approval State

    /// Active batch grants keyed by tool name. When a batch is approved,
    /// the tool name is added here with the remaining count. Subsequent
    /// requests for the same tool consume from the grant without prompting.
    private var batchGrants: [String: Int] = [:]

    /// Active batch denials. When a batch is denied, the tool name is added
    /// here so subsequent requests in the same batch are auto-denied.
    private var batchDenials: Set<String> = []

    /// When > 0, the manager is in script mode. First approval for a tool
    /// automatically sets a batch grant for the remaining budget so looped
    /// script actions don't produce N popups.
    private var scriptBudgetRemaining: Int = 0

    /// Maps batch IDs to the set of request IDs in that batch,
    /// so resolving a batch can resolve all pending continuations.
    private var batchRequestIds: [String: [UInt64]] = [:]

    init(eventBus: FaeEventBus, timeoutSeconds: TimeInterval? = nil) {
        self.eventBus = eventBus
        self.timeoutSeconds = timeoutSeconds ?? Self.timeoutSeconds
    }

    // MARK: - Single Approval

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
        // Check for an active batch grant (never applies to manual-only or disaster).
        if !manualOnly && !isDisasterLevel {
            if let remaining = batchGrants[toolName], remaining > 0 {
                batchGrants[toolName] = remaining - 1
                if remaining - 1 <= 0 {
                    batchGrants.removeValue(forKey: toolName)
                }
                return true
            }
            if batchDenials.contains(toolName) {
                return false
            }
        }

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

        // In script mode, first approval for a tool auto-grants remaining budget.
        if approved && scriptBudgetRemaining > 0 && !manualOnly && !isDisasterLevel {
            let grant = max(scriptBudgetRemaining - 1, 0)
            if grant > 0 {
                batchGrants[toolName] = (batchGrants[toolName] ?? 0) + grant
            }
        }

        return approved
    }

    // MARK: - Script Mode

    /// Enter script mode. When a tool is approved for the first time in
    /// script mode, a batch grant of `budgetToolCalls - 1` is automatically
    /// created so subsequent calls to the same tool skip the popup.
    func enterScriptMode(budgetToolCalls: Int) {
        scriptBudgetRemaining = budgetToolCalls
    }

    /// Exit script mode and clear any remaining script-originated batch state.
    func exitScriptMode() {
        scriptBudgetRemaining = 0
    }

    // MARK: - Batch Approval

    /// Request batch approval for multiple identical tool actions.
    ///
    /// Instead of showing N individual popups, this method shows a single
    /// grouped approval card. The user can Allow All (grants all N) or
    /// Deny All (denies all N).
    ///
    /// **Never used for manual-only or disaster-level requests.** Those
    /// always go through individual ``requestApproval`` calls.
    ///
    /// - Parameters:
    ///   - toolName: The tool being invoked repeatedly.
    ///   - count: How many times the tool will be invoked.
    ///   - representativeDescription: A description from the first invocation.
    /// - Returns: `true` if the batch was approved, `false` if denied.
    func requestBatchApproval(
        toolName: String,
        count: Int,
        representativeDescription: String
    ) async -> Bool {
        guard count > 0 else { return false }

        // If only one action, fall through to regular approval.
        if count == 1 {
            return await requestApproval(toolName: toolName, description: representativeDescription)
        }

        let batchId = "\(toolName)-\(nextRequestId)"
        let requestId = nextRequestId
        nextRequestId += 1

        let batch = BatchApprovalRequest(
            batchId: batchId,
            toolName: toolName,
            count: count,
            representativeDescription: representativeDescription
        )

        eventBus.send(.batchApprovalRequested(batch: batch))

        let approved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            pendingApprovals[requestId] = continuation
            pendingToolNames[requestId] = toolName
            pendingDescriptions[requestId] = representativeDescription
            pendingOrder.append(requestId)
            batchRequestIds[batchId] = [requestId]

            Task {
                try? await Task.sleep(nanoseconds: UInt64(self.timeoutSeconds * 1_000_000_000))
                self.resolveTimeoutIfPending(requestId: requestId)
            }
        }

        // Clean up batch tracking.
        batchRequestIds.removeValue(forKey: batchId)

        if approved {
            // Grant the remaining count minus 1 (the first one is this call).
            let remainingGrant = count - 1
            if remainingGrant > 0 {
                batchGrants[toolName] = remainingGrant
            }
        } else {
            // Deny subsequent requests for this tool in the current batch.
            batchDenials.insert(toolName)
        }

        return approved
    }

    /// Check whether a batch grant is available for the given tool without
    /// consuming it. Used by callers to decide whether to skip approval.
    func hasBatchGrant(for toolName: String) -> Bool {
        if let remaining = batchGrants[toolName], remaining > 0 {
            return true
        }
        return false
    }

    /// Check whether a batch denial is active for the given tool.
    func hasBatchDenial(for toolName: String) -> Bool {
        batchDenials.contains(toolName)
    }

    /// Clear all batch grants and denials. Called when a conversation turn
    /// ends or the pipeline resets to prevent stale grants from carrying over.
    func clearBatchState() {
        batchGrants.removeAll()
        batchDenials.removeAll()
        batchRequestIds.removeAll()
    }

    /// Resolve a batch approval (called from overlay controller).
    func resolveBatch(batchId: String, approved: Bool, source: String = "user") {
        guard let requestIds = batchRequestIds[batchId] else { return }
        for requestId in requestIds {
            guard resolveIfPending(requestId: requestId, approved: approved) else { continue }
            eventBus.send(.approvalResolved(id: requestId, approved: approved, source: source))
        }
    }

    // MARK: - Single Resolve

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
        clearBatchState()
    }
}
