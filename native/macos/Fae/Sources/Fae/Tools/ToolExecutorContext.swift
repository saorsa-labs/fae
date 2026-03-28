import Foundation

/// All per-call runtime state needed by ``ToolExecutor`` to evaluate and execute
/// a single tool invocation. Built by the caller (e.g. `PipelineCoordinator`)
/// from its own instance fields so that `ToolExecutor` never reaches back into
/// the coordinator.
struct ToolExecutorContext: Sendable {
    /// Current tool mode (e.g. "full", "read_only", "off").
    let toolMode: String

    /// Current privacy mode (e.g. "local_preferred", "strict_local").
    let privacyMode: String

    /// Whether the active LLM is running locally or via a non-local API.
    let modelLocality: ModelLocality

    /// The resolved capability ticket for this turn, if any.
    let capabilityTicket: CapabilityTicket?

    /// Whether the ticket grants access to the tool being executed.
    /// Pre-resolved by the caller so `ToolExecutor` doesn't need ticket logic.
    let hasCapabilityTicketForTool: Bool

    /// Whether the user explicitly authorized this action (e.g. voice confirmation).
    let explicitUserAuthorization: Bool

    /// Whether the current speaker is the verified owner.
    let isOwner: Bool

    /// Speaker liveness score from the most recent voice segment, if available.
    let livenessScore: Float?

    /// Stable speaker profile ID for the current speaker (Phase 2 trust envelopes).
    let speakerId: String?

    /// What triggered this tool invocation (voice, text, scheduler, proactive, etc.).
    let actionSource: ActionSource

    /// Proactive task context, if this tool call originated from a scheduler task.
    let proactiveContext: PipelineCoordinator.ProactiveRequestContext?

    /// Whether vision capabilities are currently enabled on the pipeline.
    let visionEnabled: Bool

    /// Whether the first-owner enrollment flow is active.
    let firstOwnerEnrollmentActive: Bool

    /// Workflow trace turn ID for audit logging.
    let workflowTurnID: String?

    /// Workflow trace tool-call ID for audit logging.
    let traceToolCallID: String?

    /// Workflow trace run ID. When non-nil, ``ToolExecutor`` records
    /// `tool_call` and `tool_result` steps via ``WorkflowTraceStore``.
    /// The caller is responsible for creating the run beforehand.
    let workflowRunID: String?

    // MARK: - Factory Methods

    /// Creates a restrictive context suitable for CoWork external LLM calls.
    ///
    /// `modelLocality` is always `.nonLocal` — this triggers DamageControlPolicy's
    /// nonLocalOnly zeroAccessPaths rules, protecting credentials from exfiltration
    /// through external providers.
    ///
    /// - Parameter actionSource: The action source for this context (defaults to `.relay`).
    /// - Returns: A context configured for non-local, relay-origin tool execution.
    static func coworkExternal(actionSource: ActionSource = .relay) -> ToolExecutorContext {
        ToolExecutorContext(
            toolMode: "full",
            privacyMode: "shareable",
            modelLocality: .nonLocal,
            capabilityTicket: nil,
            hasCapabilityTicketForTool: false,
            explicitUserAuthorization: false,
            isOwner: true,
            livenessScore: nil,
            speakerId: nil,
            actionSource: actionSource,
            proactiveContext: nil,
            visionEnabled: false,
            firstOwnerEnrollmentActive: false,
            workflowTurnID: nil,
            traceToolCallID: nil,
            workflowRunID: nil
        )
    }

    /// Creates a restrictive fallback context suitable for use when the coordinator
    /// is unavailable (e.g. in tests, developer harness, or after deallocation).
    ///
    /// Tool mode is `"off"`, privacy is `"strict_local"`, and locality is `.local`.
    static func restrictedFallback() -> ToolExecutorContext {
        ToolExecutorContext(
            toolMode: "off",
            privacyMode: "strict_local",
            modelLocality: .local,
            capabilityTicket: nil,
            hasCapabilityTicketForTool: false,
            explicitUserAuthorization: false,
            isOwner: false,
            livenessScore: nil,
            speakerId: nil,
            actionSource: .voice,
            proactiveContext: nil,
            visionEnabled: false,
            firstOwnerEnrollmentActive: false,
            workflowTurnID: nil,
            traceToolCallID: nil,
            workflowRunID: nil
        )
    }
}

/// Closures that ``ToolExecutor`` calls to push side effects back to its
/// caller. Each closure captures the caller's actor context.
struct ToolExecutorCallbacks: Sendable {
    /// Update the `awaitingApproval` and `manualOnlyApprovalPending` flags
    /// on the pipeline coordinator.
    let onApprovalPending: @Sendable (_ awaiting: Bool, _ manualOnly: Bool) async -> Void

    /// Enable vision on the live pipeline (sets `visionEnabledLive = true`
    /// and posts the config patch).
    let onVisionAutoEnabled: @Sendable () async -> Void

    /// Increment the computer-use step counter and return the new value.
    let onComputerUseStep: @Sendable () async -> Int

    /// No-op callbacks for use by CoworkToolExecutor and other callers that
    /// don't need side effects routed back to a pipeline coordinator.
    static let noop = ToolExecutorCallbacks(
        onApprovalPending: { _, _ in },
        onVisionAutoEnabled: { },
        onComputerUseStep: { 0 }
    )
}
