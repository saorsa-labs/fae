import Foundation

/// Routes CoWork external LLM calls through ToolExecutor's unified security pipeline.
///
/// All external LLM calls — whether to OpenAI-compatible APIs, Anthropic, or any
/// third-party provider — are routed through this actor. This ensures that the
/// same security layers (DamageControlPolicy, OutboundExfiltrationGuard,
/// TrustedActionBroker) apply to CoWork calls as to native tool calls.
///
/// The actor is created by PipelineCoordinator after ToolExecutor is initialized,
/// and is exposed via FaeCore for use by CoworkWorkspaceController.
///
/// ## Architecture
///
/// ```
/// CoworkWorkspaceController
///     │
///     ├── CoworkToolExecutor.submit(request:, provider:)
///     │       │
///     │       ├── performSecurityCheck() ← DRY helper
///     │       │       ├── DamageControlPolicy — blocks credential access
///     │       │       ├── OutboundExfiltrationGuard — novel recipient detection
///     │       │       └── TrustedActionBroker — default-deny chokepoint
///     │       │
///     │       ├── [emit FaeEvent.coworkRedactionApplied if content stripped]
///     │       │
///     │       ├── provider.submit() ← actual HTTP call
///     │       │
///     │       ├── guardNonEmpty() + scanForInjection()
///     │       │
///     │       ├── SecurityEventLogger (block/flag/allow)
///     │       │
///     │       └── metrics.increment(provider, outcome)
///     │
///     └── Response returned to CoWork UI
/// ```
actor CoworkToolExecutor {

    // MARK: - Per-Provider Metrics

    /// Lightweight per-provider security outcome counters.
    struct ProviderMetrics: Sendable {
        var allowed: Int = 0
        var blocked: Int = 0
        var flagged: Int = 0
    }

    // MARK: - Properties

    /// Reference to the shared ToolExecutor security pipeline.
    private let toolExecutor: any ToolExecutorProtocol

    /// Prompt injection patterns to detect in inbound responses.
    private let inboundScanPatterns: [String]

    /// Whether PipelineCoordinator has completed startup and ToolExecutor is ready.
    /// When false, submit calls fail fast with .pipelineNotReady.
    private var isReady: Bool = false

    /// Optional security event logger for structured JSONL audit trail.
    private let securityLogger: SecurityEventLogger?

    /// Optional event bus for publishing CoWork security events to the UI.
    private let eventBus: FaeEventBus?

    /// Per-provider security metrics (allowed/blocked/flagged counts).
    private var metrics: [String: ProviderMetrics] = [:]

    // MARK: - Init

    /// Create a CoworkToolExecutor with the shared security pipeline.
    ///
    /// - Parameters:
    ///   - toolExecutor: The ToolExecutor instance created by PipelineCoordinator.
    ///   - inboundScanPatterns: Patterns checked in responses to detect prompt injection.
    ///   - isReady: Whether the executor is ready to handle requests.
    ///   - securityLogger: Logger for structured security event audit trail.
    ///   - eventBus: Event bus for UI-visible security notifications.
    init(
        toolExecutor: any ToolExecutorProtocol,
        inboundScanPatterns: [String]? = nil,
        isReady: Bool = true,
        securityLogger: SecurityEventLogger? = nil,
        eventBus: FaeEventBus? = nil
    ) {
        self.toolExecutor = toolExecutor
        self.inboundScanPatterns = inboundScanPatterns ?? Self.defaultInboundPatterns
        self.isReady = isReady
        self.securityLogger = securityLogger
        self.eventBus = eventBus
    }

    /// Mark this executor as fully initialized and ready to handle requests.
    func markReady() {
        isReady = true
    }

    /// Read-only access to per-provider security metrics for diagnostics.
    func getMetrics() -> [String: ProviderMetrics] {
        metrics
    }

    // MARK: - Submit (Blocking)

    /// Submit a request to an external LLM through the unified security pipeline.
    func submit(
        request: CoworkProviderRequest,
        provider: some CoworkLLMProvider
    ) async throws -> CoworkProviderResponse {
        let providerKind = String(describing: provider.kind)
        try await performSecurityCheck(toolName: "external_llm", providerKind: providerKind, request: request)

        do {
            let response = try await provider.submit(request: request)
            try guardNonEmpty(response)
            try guardNoInjection(response, providerKind: providerKind)
            recordAllow(providerKind: providerKind, model: request.model)
            return response
        } catch let error as CoworkToolExecutorError {
            throw error
        } catch let error as CoworkProviderError {
            throw CoworkToolExecutorError.providerError(underlying: error)
        } catch {
            throw CoworkToolExecutorError.networkError(underlying: error)
        }
    }

    // MARK: - Submit (Streaming)

    /// Submit a streaming request through the unified security pipeline.
    func submitStreaming(
        request: CoworkProviderRequest,
        provider: some CoworkStreamingProvider,
        onPartialText: @escaping @Sendable (String) async -> Void
    ) async throws -> CoworkProviderResponse {
        let providerKind = String(describing: provider.kind)
        try await performSecurityCheck(toolName: "external_llm_streaming", providerKind: providerKind, request: request)

        var finalResponse: CoworkProviderResponse?
        var finalError: Error?

        do {
            let response = try await provider.stream(request: request) { partialText in
                await onPartialText(partialText)
            }
            finalResponse = response
        } catch let error as CoworkProviderError {
            finalError = CoworkToolExecutorError.providerError(underlying: error)
        } catch let error as CoworkToolExecutorError {
            finalError = error
        } catch {
            finalError = CoworkToolExecutorError.networkError(underlying: error)
        }

        if let response = finalResponse {
            try guardNonEmpty(response)
            try guardNoInjection(response, providerKind: providerKind)
        }

        if let error = finalError {
            throw error
        }

        guard let result = finalResponse else {
            throw CoworkToolExecutorError.networkError(
                underlying: NSError(domain: "CoworkToolExecutor", code: -1, userInfo: [NSLocalizedDescriptionKey: "Provider returned no response and no error"])
            )
        }
        recordAllow(providerKind: providerKind, model: request.model)
        return result
    }

    // MARK: - Submit (Web Search)

    /// Submit a web-search request through the unified security pipeline.
    func submitWithWebSearch(
        request: CoworkProviderRequest,
        provider: some CoworkWebSearchProvider
    ) async throws -> CoworkProviderResponse {
        let providerKind = String(describing: provider.kind)
        try await performSecurityCheck(toolName: "external_llm_websearch", providerKind: providerKind, request: request)

        do {
            let response = try await provider.submitWithWebSearch(request: request)
            try guardNonEmpty(response)
            try guardNoInjection(response, providerKind: providerKind)
            recordAllow(providerKind: providerKind, model: request.model)
            return response
        } catch let error as CoworkToolExecutorError {
            throw error
        } catch let error as CoworkProviderError {
            throw CoworkToolExecutorError.providerError(underlying: error)
        } catch {
            throw CoworkToolExecutorError.networkError(underlying: error)
        }
    }

    // MARK: - DRY Security Check (Task 2)

    /// Runs the ToolExecutor security check for a CoWork request.
    ///
    /// Builds a ToolExecutorContext with modelLocality=.nonLocal, executes through
    /// the full security stack, and throws if blocked or damage-controlled.
    private func performSecurityCheck(
        toolName: String,
        providerKind: String,
        request: CoworkProviderRequest
    ) async throws {
        guard isReady else {
            throw CoworkToolExecutorError.pipelineNotReady
        }

        let context = buildContext(for: request)
        let call = PipelineCoordinator.ToolCall(
            name: toolName,
            arguments: [
                "model": request.model,
                "provider": providerKind,
                "thinkingLevel": request.thinkingLevel.rawValue,
            ]
        )

        let outcome = await toolExecutor.execute(call, context: context, callbacks: .noop)

        if outcome.damageControlIntervened {
            let reason = outcome.result.output
            recordBlock(providerKind: providerKind, model: request.model, reason: reason)
            eventBus?.send(.coworkSecurityBlocked(provider: providerKind, reason: reason))
            throw CoworkToolExecutorError.damageControlIntervened(reason: reason)
        }

        if outcome.result.isError {
            let reason = outcome.result.output
            recordBlock(providerKind: providerKind, model: request.model, reason: reason)
            eventBus?.send(.coworkSecurityBlocked(provider: providerKind, reason: reason))
            throw CoworkToolExecutorError.securityBlocked(reason: reason)
        }
    }

    // MARK: - Response Guards (Task 3)

    /// Throws `.emptyResponse` if the provider returned no meaningful content.
    private func guardNonEmpty(_ response: CoworkProviderResponse) throws {
        if response.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CoworkToolExecutorError.emptyResponse
        }
    }

    /// Throws `.inboundScanFlagged` if a prompt injection pattern is detected.
    private func guardNoInjection(_ response: CoworkProviderResponse, providerKind: String) throws {
        if let pattern = scanForInjection(response.content) {
            recordFlag(providerKind: providerKind, pattern: pattern)
            eventBus?.send(.coworkInjectionFlagged(provider: providerKind, pattern: pattern))
            throw CoworkToolExecutorError.inboundScanFlagged(reason: pattern)
        }
    }

    // MARK: - Metrics (Task 6)

    /// Record a successful (allowed) CoWork call.
    private func recordAllow(providerKind: String, model: String) {
        metrics[providerKind, default: ProviderMetrics()].allowed += 1
        Task {
            await securityLogger?.log(
                event: "cowork_allowed",
                toolName: "external_llm",
                decision: "allow",
                arguments: ["provider": providerKind, "model": model]
            )
        }
    }

    /// Record a security-blocked CoWork call.
    private func recordBlock(providerKind: String, model: String, reason: String) {
        metrics[providerKind, default: ProviderMetrics()].blocked += 1
        Task {
            await securityLogger?.log(
                event: "cowork_blocked",
                toolName: "external_llm",
                decision: "block",
                reasonCode: reason,
                arguments: ["provider": providerKind, "model": model]
            )
        }
    }

    /// Record a flagged (injection-detected) CoWork response.
    private func recordFlag(providerKind: String, pattern: String) {
        metrics[providerKind, default: ProviderMetrics()].flagged += 1
        Task {
            await securityLogger?.log(
                event: "cowork_injection_flagged",
                toolName: "external_llm",
                decision: "flag",
                reasonCode: pattern,
                arguments: ["provider": providerKind]
            )
        }
    }

    // MARK: - Context Building

    /// Builds the ToolExecutorContext for a Cowork request using the shared factory.
    ///
    /// Delegates to ``ToolExecutorContext.coworkExternal()`` so that context
    /// construction for non-local models is defined in one place.
    private func buildContext(for request: CoworkProviderRequest) -> ToolExecutorContext {
        .coworkExternal()
    }

    // MARK: - Inbound Response Scan

    /// Scans a response for prompt injection patterns.
    /// Returns nil if clean, or the matched pattern if flagged.
    private func scanForInjection(_ content: String) -> String? {
        let lowercased = content.lowercased()
        for pattern in inboundScanPatterns {
            if lowercased.contains(pattern.lowercased()) {
                return "detected pattern: \(pattern)"
            }
        }
        return nil
    }

    // MARK: - Default Patterns

    /// Default prompt injection patterns.
    private static let defaultInboundPatterns: [String] = [
        "ignore previous instructions",
        "disregard all prior",
        "you are now",
        "forget all previous",
        "new instructions:",
        "previous instructions are",
        "instructions override",
        "assistant is now",
        "you now have",
        "disregard the above",
    ]
}
