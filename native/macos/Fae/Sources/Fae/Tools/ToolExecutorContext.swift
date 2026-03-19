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
}
