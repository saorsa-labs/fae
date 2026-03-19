import Foundation

/// Errors produced by CoworkToolExecutor.
///
/// These are the failure modes when routing CoWork external LLM calls
/// through ToolExecutor's unified security pipeline.
enum CoworkToolExecutorError: LocalizedError, Sendable {
    /// ToolExecutor is not yet initialized — PipelineCoordinator has not started.
    case pipelineNotReady

    /// The underlying CoworkProviderError from the HTTP call.
    case providerError(underlying: CoworkProviderError)

    /// A network or transport error occurred.
    case networkError(underlying: Error)

    /// ToolExecutor security stack blocked the call.
    case securityBlocked(reason: String)

    /// DamageControlPolicy intervened.
    case damageControlIntervened(reason: String)

    /// Inbound response scan detected a prompt injection attempt.
    case inboundScanFlagged(reason: String)

    /// The request timed out.
    case timeout

    /// The provider returned an empty response.
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .pipelineNotReady:
            return "The security pipeline is not yet ready. Please try again."
        case .providerError(let underlying):
            return "Provider error: \(underlying.localizedDescription)"
        case .networkError(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .securityBlocked(let reason):
            return "Security blocked: \(reason)"
        case .damageControlIntervened(let reason):
            return "Action prevented: \(reason)"
        case .inboundScanFlagged(let reason):
            return "Response filtered: \(reason)"
        case .timeout:
            return "The request timed out."
        case .emptyResponse:
            return "The provider returned an empty response."
        }
    }
}
